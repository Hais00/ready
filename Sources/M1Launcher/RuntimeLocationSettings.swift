// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  private func ensureRuntimeLocationIdle() throws {
    guard !maintenanceInProgress, !session.running, pendingLaunch == nil,
      authenticationSession == nil, !storeClient.hasActiveRequests else { throw LauncherError.busy }
  }
  @objc func runtimeLocationSettings() {
    guard !maintenanceInProgress, !session.running, pendingLaunch == nil,
      authenticationSession == nil, !storeClient.hasActiveRequests else {
      showError(LauncherError.unavailable("Attendi il termine delle operazioni in corso prima di cambiare la posizione dei motori."))
      return
    }
    let location = FrontendSupportPaths(paths: paths)
    let config = FrontendSupportPaths.configuration(paths: paths, runtimeRoot: runtimeRoot)
    let validation = try? RuntimeLocationStore.validate(runtimeRoot)
    let prompt = NSAlert()
    prompt.messageText = "Motori condivisi"
    var detail = "Cartella: \(runtimeRoot.path)\nConfigurazione: \(config.path)\n\n"
    if let validation {
      detail += validation.windowsAvailable ? "Wine presente nella configurazione della cartella selezionata. " : "La configurazione della cartella selezionata non dichiara Wine. "
      detail += validation.storeToolsAvailable ? "Cartella degli strumenti store presente." : "Strumenti store non installati in questa posizione."
    } else {
      detail += "La configurazione dei motori non è disponibile o richiede una verifica."
    }
    detail += "\n\nScegli la cartella centrale che contiene runtime.json. I motori e gli strumenti restano nella loro posizione."
    if location.runtimeLocationOrigin == "environment" {
      detail += "\nREADY_RUNTIME_ROOT ha priorità sulla posizione salvata finché è impostata nell’ambiente."
    }
    if config.path != runtimeRoot.appendingPathComponent("runtime.json").path {
      detail += "\nGli avvii usano la configurazione personale indicata sopra, che ha priorità su quella della cartella selezionata. La disponibilità del motore viene verificata prima di ogni avvio."
    }
    if let issue = location.runtimeLocationIssue { detail += "\n" + issue }
    prompt.informativeText = detail
    prompt.addButton(withTitle: "Scegli cartella…")
    prompt.addButton(withTitle: "Usa posizione predefinita")
    prompt.addButton(withTitle: "Ripristina posizione precedente")
    prompt.buttons[2].isEnabled = RuntimeLocationStore.hasPrevious(paths: paths)
    prompt.addButton(withTitle: "Annulla")
    let choice = prompt.runModal()
    do {
      if choice == .alertFirstButtonReturn {
        let panel = NSOpenPanel()
        panel.title = "Cartella dei motori condivisi"
        panel.prompt = "Usa questa cartella"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = runtimeRoot
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        try ensureRuntimeLocationIdle()
        try RuntimeLocationStore.set(selected, paths: paths)
      } else if choice == .alertSecondButtonReturn {
        try ensureRuntimeLocationIdle()
        try RuntimeLocationStore.reset(paths: paths)
      } else if choice == .alertThirdButtonReturn {
        try ensureRuntimeLocationIdle()
        try RuntimeLocationStore.restorePrevious(paths: paths)
      } else { return }
      // Replace idle clients together so the library, launches and store bridge
      // all use the same newly resolved external location immediately.
      runtimeRoot = FrontendSupportPaths(paths: paths).runtimeRoot
      configureRuntimeClients()
      canvas.evaluationMode = activeRuntime().evaluationModeEnabled == true
      canvas.message = location.runtimeLocationOrigin == "environment"
        ? "Posizione salvata · READY_RUNTIME_ROOT resta attiva nell’ambiente"
        : "Posizione dei motori aggiornata"
      canvas.refresh()
    } catch { showError(error) }
  }
}
