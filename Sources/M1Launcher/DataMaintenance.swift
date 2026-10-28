// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

private enum MaintenanceOperation {
  case recover
  case bind(LegacyMigrationPlan, LibraryState)
  case rollback(LegacyMigrationPlan, LibraryState)
  case migrate(Profile, [Game], LibraryState)

  func execute(paths: LauncherPaths) throws -> (LibraryState?, String) {
    switch self {
    case .recover:
      _ = try LegacyMigration.recoverInterrupted(paths: paths)
      return (
        nil,
        "Copie parziali archiviate. Puoi ripetere la migrazione; originali e dati personali conservati."
      )
    case .bind(let plan, let library):
      let rebound = try LegacyMigration.bindLibrary(library, plan: plan, paths: paths)
      try LibraryRepository(paths: paths).save(rebound)
      return (
        rebound,
        "Installazioni collegate al profilo proprietario. Verifica giochi e salvataggi; originale conservato."
      )
    case .rollback(let plan, let library):
      _ = try LegacyMigration.rollback(plan, paths: paths)
      let updated = LegacyMigration.libraryAfterRollback(library, plan: plan)
      try LibraryRepository(paths: paths).save(updated)
      return (
        updated, "Migrazione annullata. Copie archiviate, originali e dati personali conservati."
      )
    case .migrate(let profile, let games, let library):
      guard let plan = try LegacyMigration.prepare(paths: paths, profile: profile.id, games: games)
      else {
        throw LauncherError.unavailable("Il vecchio ambiente non è più disponibile.")
      }
      let backup = paths.root.appendingPathComponent(
        "Migration/Plans/" + plan.id.uuidString + "/library-before.json")
      try AtomicFile.writePrivate(JSONEncoder().encode(library), to: backup)
      let copied = try LegacyMigration.execute(plan, paths: paths)
      let updated = try LegacyMigration.bindLibrary(library, plan: copied, paths: paths)
      try LibraryRepository(paths: paths).save(updated)
      return (
        updated,
        "Copie create per \(profile.name). Verifica ogni gioco e salvataggio; originale e ripristino conservati."
      )
    }
  }
}

extension AppDelegate {
  private func canMaintainData() -> Bool {
    guard !maintenanceInProgress, !session.running, pendingLaunch == nil,
      !storeClient.hasActiveRequests
    else {
      showError(
        LauncherError.unavailable(
          "Attendi il termine del gioco, dell’accesso o del download prima di modificare i dati."))
      return false
    }
    return true
  }
  private func maintain(_ message: String, operation: MaintenanceOperation) {
    guard canMaintainData() else { return }
    maintenanceInProgress = true
    canvas.message = message
    canvas.refresh()
    let paths = self.paths
    DispatchQueue.global(qos: .userInitiated).async { [weak self, paths, operation] in
      let result = Result { try operation.execute(paths: paths) }
      DispatchQueue.main.async {
        guard let self else { return }
        self.maintenanceInProgress = false
        switch result {
        case .success(let (library, message)):
          if let library { self.state = library }
          self.canvas.state = self.state
          self.canvas.message = message
          self.canvas.refresh()
        case .failure(let error): self.showError(error)
        }
      }
    }
  }
  @objc func dataMaintenance() {
    guard canMaintainData() else { return }
    if LegacyMigration.requiresRecovery(paths: paths) {
      let prompt = NSAlert()
      prompt.messageText = "Migrazione interrotta"
      prompt.informativeText =
        "Il vecchio ambiente è intatto. Le copie parziali saranno archiviate insieme al registro dell’operazione; i dati personali persistenti saranno conservati. Potrai poi ripetere la migrazione."
      prompt.addButton(withTitle: "Archivia copie parziali")
      prompt.addButton(withTitle: "Annulla")
      guard prompt.runModal() == .alertFirstButtonReturn else { return }
      maintain("Recupero dell’operazione interrotta…", operation: .recover)
      return
    }
    if let plan = LegacyMigration.loadPlan(paths: paths),
      plan.status == "copied-awaiting-real-validation-original-retained"
    {
      let prompt = NSAlert()
      prompt.messageText = "Migrazione da verificare"
      let owner =
        state.profiles.first(where: { $0.id == plan.ownerProfile })?.name ?? "profilo precedente"
      prompt.informativeText =
        "Copie isolate preparate per \(owner). Verifica ogni gioco e i suoi salvataggi prima di considerare conclusa la migrazione. L’originale resta conservato. Annullando, le copie saranno archiviate; le installazioni contenute nelle copie richiederanno una reimportazione."
      prompt.addButton(withTitle: "Completa collegamenti libreria")
      prompt.addButton(withTitle: "Annulla migrazione…")
      prompt.addButton(withTitle: "Chiudi")
      let choice = prompt.runModal()
      if choice == .alertFirstButtonReturn {
        maintain("Collegamento delle installazioni migrate…", operation: .bind(plan, state))
      } else if choice == .alertSecondButtonReturn {
        let confirm = NSAlert()
        confirm.messageText = "Archiviare le copie migrate?"
        confirm.informativeText =
          "Nessun dato sarà eliminato. Gli ambienti copiati saranno archiviati; Documenti, salvataggi e l’originale rimarranno al loro posto. I giochi installati dentro le copie non saranno più avviabili finché non li reimporterai."
        confirm.addButton(withTitle: "Archivia e annulla migrazione")
        confirm.addButton(withTitle: "Mantieni migrazione")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        maintain("Archiviazione delle copie migrate…", operation: .rollback(plan, state))
      }
      return
    }
    guard FileManager.default.fileExists(atPath: paths.legacyPrefix.path) else {
      let prompt = NSAlert()
      prompt.messageText = "Dati dei profili"
      prompt.informativeText =
        "Non è presente un vecchio ambiente unico da migrare. Documenti e salvataggi dei profili sono già conservati fuori dagli ambienti dei giochi."
      prompt.addButton(withTitle: "Apri cartella del profilo")
      prompt.addButton(withTitle: "Chiudi")
      if prompt.runModal() == .alertFirstButtonReturn {
        let folder = paths.profile(state.activeProfile)
        try? FileManager.default.createDirectory(
          at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(folder)
      }
      return
    }
    let prompt = NSAlert()
    prompt.messageText = "Importa il vecchio ambiente"
    prompt.informativeText =
      "Scegli il profilo a cui appartengono i vecchi account e salvataggi. Non è possibile separare automaticamente dati di utenti già mescolati. Verranno create copie isolate per i giochi Windows senza un ambiente esistente; l’originale resterà intatto."
    let owner = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 30))
    owner.addItem(withTitle: "Seleziona il proprietario dei dati…")
    owner.addItems(withTitles: state.profiles.map { $0.name })
    prompt.accessoryView = owner
    prompt.addButton(withTitle: "Prepara migrazione")
    prompt.addButton(withTitle: "Annulla")
    guard prompt.runModal() == .alertFirstButtonReturn else { return }
    guard owner.indexOfSelectedItem > 0 else {
      showError(LauncherError.invalid("Seleziona esplicitamente il proprietario dei vecchi dati."))
      return
    }
    let profile = state.profiles[owner.indexOfSelectedItem - 1]
    let candidates = state.games.filter {
      ($0.profileIDs == nil || $0.profileIDs!.contains(profile.id))
        && $0.variants.contains(where: { $0.platform == .windows })
        && !FileManager.default.fileExists(
          atPath: paths.prefix(profile: profile.id, gameID: $0.id).path)
    }
    guard !candidates.isEmpty else {
      showError(
        LauncherError.unavailable(
          "Non ci sono giochi Windows da migrare per questo profilo. Importa i giochi precedenti o sincronizza la libreria; gli ambienti già presenti non vengono sovrascritti."
        ))
      return
    }
    let review = NSAlert()
    review.messageText = "Migrazione per \(profile.name)"
    review.informativeText =
      "Giochi: \(candidates.count)\n\n"
      + candidates.prefix(12).map { $0.title }.joined(separator: "\n")
      + "\n\nGli originali saranno conservati. Spazio insufficiente o interruzioni non eliminano la sorgente. I giochi e i salvataggi dovranno essere verificati dopo la copia."
    review.addButton(withTitle: "Crea copie isolate")
    review.addButton(withTitle: "Annulla")
    guard review.runModal() == .alertFirstButtonReturn else { return }
    maintain(
      "Migrazione dei dati per \(profile.name)…", operation: .migrate(profile, candidates, state))
  }
}
