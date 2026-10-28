// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  private func ensureRuntimeLocationIdle() throws {
    guard !maintenanceInProgress, !session.running, pendingLaunch == nil,
      authenticationSession == nil, !storeClient.hasActiveRequests
    else { throw LauncherError.busy }
  }
  @objc func runtimeLocationSettings() {
    guard !maintenanceInProgress, !session.running, pendingLaunch == nil,
      authenticationSession == nil, !storeClient.hasActiveRequests
    else {
      showError(
        LauncherError.unavailable(
          "Attendi il termine delle operazioni in corso prima di cambiare la posizione dei motori.")
      )
      return
    }
    let location = FrontendSupportPaths(paths: paths)
    let config = FrontendSupportPaths.configuration(paths: paths, runtimeRoot: runtimeRoot)
    let validation = try? RuntimeLocationStore.validate(runtimeRoot)
    var detail = "Cartella: \(runtimeRoot.path)\nConfigurazione: \(config.path)\n\n"
    if let validation {
      detail +=
        validation.windowsAvailable
        ? "Wine presente nella configurazione della cartella selezionata. "
        : "La configurazione della cartella selezionata non dichiara Wine. "
      detail +=
        validation.storeToolsAvailable
        ? "Cartella degli strumenti store presente."
        : "Strumenti store non installati in questa posizione."
    } else {
      detail += "La configurazione dei motori non è disponibile o richiede una verifica."
    }
    detail +=
      "\n\nScegli la cartella centrale che contiene runtime.json. I motori e gli strumenti restano nella loro posizione."
    if location.runtimeLocationOrigin == "environment" {
      detail +=
        "\nREADY_RUNTIME_ROOT ha priorità sulla posizione salvata finché è impostata nell’ambiente."
    }
    if config.path != runtimeRoot.appendingPathComponent("runtime.json").path {
      detail +=
        "\nGli avvii usano la configurazione personale indicata sopra, che ha priorità su quella della cartella selezionata. La disponibilità del motore viene verificata prima di ogni avvio."
    }
    if let issue = location.runtimeLocationIssue { detail += "\n" + issue }
    presentDialog(
      title: "Motori condivisi", message: detail,
      actions: [
        .init("Scegli cartella…", role: .primary), .init("Usa posizione predefinita"),
        .init(
          "Ripristina posizione precedente", enabled: RuntimeLocationStore.hasPrevious(paths: paths)
        ), .init("Annulla", role: .cancel),
      ]
    ) { [weak self] choice in
      guard let self else { return }
      if choice == 0 {
        self.selectLocalFile(
          title: "Cartella dei motori condivisi", prompt: "Usa questa cartella",
          directory: self.runtimeRoot, mode: .directory
        ) { [weak self] selected in
          guard let self, let selected else { return }
          self.applyRuntimeLocation(choice: choice, selected: selected)
        }
      } else if choice == 1 || choice == 2 {
        self.applyRuntimeLocation(choice: choice)
      }
    }
  }
  private func applyRuntimeLocation(choice: Int, selected: URL? = nil) {
    do {
      try ensureRuntimeLocationIdle()
      if choice == 0, let selected {
        try RuntimeLocationStore.set(selected, paths: paths)
      } else if choice == 1 {
        try RuntimeLocationStore.reset(paths: paths)
      } else if choice == 2 {
        try RuntimeLocationStore.restorePrevious(paths: paths)
      } else {
        return
      }
      let location = FrontendSupportPaths(paths: paths)
      // Replace idle clients together so the library, launches and store bridge
      // all use the same newly resolved external location immediately.
      runtimeRoot = FrontendSupportPaths(paths: paths).runtimeRoot
      configureRuntimeClients()
      canvas.evaluationMode = activeRuntime().evaluationModeEnabled == true
      canvas.message =
        location.runtimeLocationOrigin == "environment"
        ? "Posizione salvata · READY_RUNTIME_ROOT resta attiva nell’ambiente"
        : "Posizione dei motori aggiornata"
      canvas.refresh()
    } catch { showError(error) }
  }
}
