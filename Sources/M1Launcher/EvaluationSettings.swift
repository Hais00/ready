// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  func activeRuntime() -> RuntimeConfiguration {
    RuntimeConfiguration.load(
      FrontendSupportPaths.configuration(paths: paths, runtimeRoot: runtimeRoot))
  }
  @objc func evaluationSettings() {
    guard !maintenanceInProgress, canNavigateInterfaceWhilePlaying, pendingLaunch == nil,
      authenticationSession == nil, (!storeClient.hasActiveRequests || gameInterfaceVisible)
    else {
      showError(
        LauncherError.unavailable(
          "Attendi il termine delle operazioni in corso prima di cambiare runtime."))
      return
    }
    beginSettingsSection(.evaluation)
    let restoring =
      activeRuntime().evaluationModeEnabled == true || EvaluationMode.hasRestorePoint(paths: paths)
    let title = restoring ? "Ripristina il runtime precedente" : "Valutazione locale con il toolkit Apple"
    let message = restoring
      ? "Ripristina la configurazione precedente alla valutazione. Gli ambienti dei giochi e i loro dati non vengono modificati ora; il runtime verrà preparato al prossimo avvio. Le configurazioni sono conservate nella cronologia."
      : "Questa modalità serve a sviluppare e valutare porting sul Mac e richiede i componenti e i diritti d’uso previsti da Apple. I componenti proprietari sono esterni al progetto open source. L’attivazione non concede una licenza e non autorizza il gioco ordinario o la redistribuzione."
    _ = presentDialog(
      title: title, message: message,
      actions: [ReadyDialogAction(restoring ? "Ripristina" : "Usa per valutazione", role: .primary),
                ReadyDialogAction("Leggi documentazione"),
                ReadyDialogAction("Annulla", role: .cancel)]
    ) { [weak self] choice in
      guard let self else { return }
      if choice == 1 {
        NSWorkspace.shared.open(self.project.appendingPathComponent("Docs/LICENSES.md"))
        return
      }
      guard choice == 0 else { return }
      // The dialog is asynchronous: a callback or external configuration change
      // must not turn the reviewed action into a different runtime operation.
      guard !self.maintenanceInProgress, self.session?.running != true,
        self.pendingLaunch == nil, self.authenticationSession == nil,
        self.storeClient?.hasActiveRequests != true
      else {
        self.showError(LauncherError.unavailable("Attendi il termine delle operazioni in corso prima di cambiare runtime."))
        return
      }
      let currentRestoring = self.activeRuntime().evaluationModeEnabled == true
        || EvaluationMode.hasRestorePoint(paths: self.paths)
      guard currentRestoring == restoring else {
        self.showError(LauncherError.unavailable("La configurazione è cambiata. Riapri le impostazioni di valutazione prima di continuare."))
        return
      }
      do {
        if restoring {
          try EvaluationMode.restore(paths: self.paths)
        } else {
          try EvaluationMode.enable(
            fragment: self.runtimeRoot.appendingPathComponent("evaluation-runtime.json"), paths: self.paths)
        }
        self.canvas.evaluationMode = self.activeRuntime().evaluationModeEnabled == true
        self.canvas.message = self.canvas.evaluationMode
          ? "Valutazione locale attiva · componenti Apple esterni con licenza separata"
          : "Configurazione precedente ripristinata"
        self.canvas.refresh()
      } catch { self.showError(error) }
    }
  }
}
