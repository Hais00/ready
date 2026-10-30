// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor func performOtherStoreInstallation(game:Game,variant:GameVariant,profile:UUID,base:URL,reservation:StorageReservation){
    do {
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    } catch {
      try? storageLibraries.release(reservationID:reservation.id)
      showError(error)
      return
    }
    let storageJob="other:"+reservation.id.uuidString
    activeOtherStorageJobs.insert(storageJob)
    storageWork.async{[storageLibraries]in try?storageLibraries.attachJob(reservationID:reservation.id,jobID:storageJob)}
    canvas.message = "Installazione di \(game.title)…"
    canvas.refresh()
    let options: [String: Any] = [
      "gameID": game.storeID, "platform": variant.platform.rawValue, "installDir": base.path,
      "metadata": game.metadata?.mapValues { $0.foundation } ?? [:],
    ]
    storeClient.request(
      operation: "download", store: game.store, profile: profile, options: options
    ) { [weak self] event in
      guard let self else { return }
      switch event["type"] as? String {
      case "error":
        self.activeOtherStorageJobs.remove(storageJob)
        self.storageWork.async{[weak self]in try?self?.storageLibraries.release(reservationID:reservation.id)}
        MainActor.assumeIsolated { if self.state.activeProfile == profile && self.gameDetailID == game.id { self.gameDetailView?.setTransferStatus(nil) } }
        self.showError(LauncherError.failed(event["message"] as? String ?? "Download non riuscito"))
      case "progress":
        self.canvas.message =
          "Download \(game.title) · \(event["message"] as? String ?? "in corso")"
        self.canvas.refresh()
        if self.state.activeProfile == profile && self.gameDetailID == game.id {
          MainActor.assumeIsolated { self.gameDetailView?.setTransferStatus(event["message"] as? String ?? "Download in corso", fraction:event["fraction"] as? Double) }
        }
      case "result":
        self.activeOtherStorageJobs.remove(storageJob)
        self.storageWork.async{[weak self]in try?self?.storageLibraries.markInstalled(reservationID:reservation.id)}
        self.gameStorageSizes.invalidate(game:game)
        MainActor.assumeIsolated { if self.state.activeProfile == profile && self.gameDetailID == game.id { self.gameDetailView?.setTransferStatus(nil) } }
        if let raw = event["installedVariant"] as? [String: Any],
          let data = try? JSONSerialization.data(withJSONObject: raw),
          var installed = try? JSONDecoder().decode(GameVariant.self, from: data),
          let i = self.state.games.firstIndex(where: { $0.id == game.id })
        {
          installed.id = variant.id
          installed.installationRoot = event["installDir"] as? String ?? base.path
          self.state.clearVariantOverride(profile: profile, gameID: game.id, variantID: variant.id)
          PEImports.annotate(&self.state.games[i], variant: installed)
          if let j = self.state.games[i].variants.firstIndex(where: { $0.id == variant.id }) {
            self.state.games[i].variants[j] = installed
          } else {
            self.state.games[i].variants.append(installed)
          }
          self.canvas.message = "\(game.title) installato · \(installed.title)"
          try? self.persist()
          return
        }
        self.presentDialog(
          title: "File di \(game.title) scaricati",
          message: "Seleziona il programma di avvio per verificare l’architettura.",
          actions: [
            .init("Seleziona eseguibile", role: .primary), .init("Più tardi", role: .cancel),
          ]
        ) { [weak self] choice in
          guard let self, choice == 0 else { return }
          self.selectLocalFile(
            title: "Programma di avvio", prompt: "Seleziona", directory: base, mode: .file
          ) { [weak self] url in
            guard let self, !self.maintenanceInProgress, !self.session.running,
              self.pendingLaunch == nil,
              self.state.activeProfile == profile, let url,
              let imported = try? LocalDiscovery.importGame(url),
              let checked = imported.variants.first,
              let i = self.state.games.firstIndex(where: { $0.id == game.id })
            else { return }
            var v = checked
            v.id = variant.id
            v.installationRoot = base.path
            self.state.clearVariantOverride(
              profile: profile, gameID: game.id, variantID: variant.id)
            if let j = self.state.games[i].variants.firstIndex(where: { $0.id == variant.id }) {
              self.state.games[i].variants[j] = v
            }
            try? self.persist()
          }
        }
      default: break
      }
    }
  }
}
