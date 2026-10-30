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
      let restoringRollback = LegacyMigration.recoveryKind(paths: paths) == "rollback"
      _ = try LegacyMigration.recoverInterrupted(paths: paths)
      return (
        nil,
        restoringRollback
          ? "Annullamento interrotto recuperato: copie migrate ripristinate, originali e dati personali conservati."
          : "Copie parziali archiviate. Puoi ripetere la migrazione; originali e dati personali conservati."
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
    let progress = presentDialog(title: "Operazione in corso", message: message,
      actions: []) { _ in }
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
          if self.pages.isShowing(progress) {
            self.dismissDialog(progress)
            self.dataMaintenance()
            self.pages.showNotice(message)
          }
        case .failure(let error):
          if self.pages.isShowing(progress) {
            self.dismissDialog(progress)
            self.dataMaintenance()
          }
          self.showError(error)
        }
      }
    }
  }
  @objc func dataMaintenance() {
    guard (session.running ? (gameInterfaceVisible && !maintenanceInProgress && pendingLaunch==nil):canMaintainData()) else { return }
    beginSettingsSection(.data)
    if LegacyMigration.requiresRecovery(paths: paths) {
      let restoringRollback = LegacyMigration.recoveryKind(paths: paths) == "rollback"
      presentDialog(
        title: restoringRollback ? "Annullamento interrotto" : "Migrazione interrotta",
        message: restoringRollback
          ? "Le copie migrate saranno ripristinate nei loro ambienti, così i collegamenti della libreria resteranno validi. L’originale e i dati personali rimarranno intatti; eventuali copie in conflitto saranno conservate in archivio. Potrai poi ripetere l’annullamento."
          : "Il vecchio ambiente è intatto. Le copie parziali saranno archiviate insieme al registro dell’operazione; i dati personali persistenti saranno conservati. Potrai poi ripetere la migrazione.",
        actions: [.init(restoringRollback ? "Ripristina copie migrate" : "Archivia copie parziali", role: .primary), .init("Annulla", role: .cancel)]
      ) { [weak self] choice in
        guard let self, choice == 0, self.canMaintainData() else { return }
        self.maintain("Recupero dell’operazione interrotta…", operation: .recover)
      }
      return
    }
    if let plan = LegacyMigration.loadPlan(paths: paths),
      plan.status == "copied-awaiting-real-validation-original-retained"
    {
      let owner = state.profiles.first(where: { $0.id == plan.ownerProfile })?.name ?? "profilo precedente"
      presentDialog(title: "Migrazione da verificare",
        message: "Copie isolate preparate per \(owner). Verifica ogni gioco e i suoi salvataggi prima di considerare conclusa la migrazione. L’originale resta conservato. Annullando, le copie saranno archiviate; le installazioni contenute nelle copie richiederanno una reimportazione.",
        actions: [.init("Completa collegamenti libreria", role: .primary), .init("Annulla migrazione…", role: .destructive), .init("Chiudi", role: .cancel)]
      ) { [weak self] choice in
        guard let self, self.canMaintainData() else { return }
        if choice == 0 { self.maintain("Collegamento delle installazioni migrate…", operation: .bind(plan, self.state)) }
        else if choice == 1 { self.confirmMigrationRollback(plan) }
      }
      return
    }
    guard FileManager.default.fileExists(atPath: paths.legacyPrefix.path) else {
      presentDialog(title: "Dati dei profili",
        message: "Non è presente un vecchio ambiente unico da migrare. Documenti e salvataggi dei profili sono già conservati fuori dagli ambienti dei giochi.",
        actions: [.init("Apri cartella del profilo", role: .primary), .init("Chiudi", role: .cancel)]
      ) { [weak self] choice in
        guard let self, choice == 0, self.canMaintainData() else { return }
        let folder = self.paths.profile(self.state.activeProfile)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(folder)
      }
      return
    }
    let profiles = state.profiles
    let owner = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 30))
    owner.addItem(withTitle: "Seleziona il proprietario dei dati…")
    owner.addItems(withTitles: profiles.map { $0.name })
    presentDialog(title: "Importa il vecchio ambiente",
      message: "Scegli il profilo a cui appartengono i vecchi account e salvataggi. Non è possibile separare automaticamente dati di utenti già mescolati. Verranno create copie isolate per i giochi Windows senza un ambiente esistente; l’originale resterà intatto.",
      content: owner, actions: [.init("Prepara migrazione", role: .primary), .init("Annulla", role: .cancel)]
    ) { [weak self] choice in
      guard let self, choice == 0, self.canMaintainData() else { return }
      let index = owner.indexOfSelectedItem - 1
      guard profiles.indices.contains(index), let profile = self.state.profiles.first(where: { $0.id == profiles[index].id }) else {
        self.showError(LauncherError.invalid("Seleziona esplicitamente il proprietario dei vecchi dati.")); return
      }
      self.reviewMigration(for: profile)
    }
  }
  private func confirmMigrationRollback(_ plan: LegacyMigrationPlan) {
    presentDialog(title: "Archiviare le copie migrate?",
      message: "Nessun dato sarà eliminato. Gli ambienti copiati saranno archiviati; Documenti, salvataggi e l’originale rimarranno al loro posto. I giochi installati dentro le copie non saranno più avviabili finché non li reimporterai.",
      actions: [.init("Archivia e annulla migrazione", role: .destructive), .init("Mantieni migrazione", role: .cancel)]
    ) { [weak self] choice in
      guard let self, choice == 0, self.canMaintainData() else { return }
      self.maintain("Archiviazione delle copie migrate…", operation: .rollback(plan, self.state))
    }
  }
  private func reviewMigration(for profile: Profile) {
    guard canMaintainData() else { return }
    let candidates = state.games.filter {
      ($0.profileIDs == nil || $0.profileIDs!.contains(profile.id))
        && $0.variants.contains(where: { $0.platform == .windows })
        && !FileManager.default.fileExists(atPath: paths.prefix(profile: profile.id, gameID: $0.id).path)
    }
    guard !candidates.isEmpty else {
      showError(LauncherError.unavailable("Non ci sono giochi Windows da migrare per questo profilo. Importa i giochi precedenti o sincronizza la libreria; gli ambienti già presenti non vengono sovrascritti.")); return
    }
    presentDialog(title: "Migrazione per \(profile.name)",
      message: "Giochi: \(candidates.count)\n\n" + candidates.prefix(12).map { $0.title }.joined(separator: "\n")
        + "\n\nGli originali saranno conservati. Spazio insufficiente o interruzioni non eliminano la sorgente. I giochi e i salvataggi dovranno essere verificati dopo la copia.",
      actions: [.init("Crea copie isolate", role: .primary), .init("Annulla", role: .cancel)]
    ) { [weak self] choice in
      guard let self, choice == 0, self.canMaintainData() else { return }
      self.maintain("Migrazione dei dati per \(profile.name)…", operation: .migrate(profile, candidates, self.state))
    }
  }
}
