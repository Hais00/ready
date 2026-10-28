// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  func activeRuntime() -> RuntimeConfiguration {
    RuntimeConfiguration.load(
      FrontendSupportPaths.configuration(paths: paths, runtimeRoot: runtimeRoot))
  }
  @objc func evaluationSettings() {
    guard !maintenanceInProgress, !session.running, pendingLaunch == nil,
      authenticationSession == nil, !storeClient.hasActiveRequests
    else {
      showError(
        LauncherError.unavailable(
          "Attendi il termine delle operazioni in corso prima di cambiare runtime."))
      return
    }
    let restoring =
      activeRuntime().evaluationModeEnabled == true || EvaluationMode.hasRestorePoint(paths: paths)
    let prompt = NSAlert()
    prompt.messageText =
      restoring ? "Ripristina il runtime precedente" : "Valutazione locale con il toolkit Apple"
    prompt.informativeText =
      restoring
      ? "Ripristina la configurazione precedente alla valutazione. Gli ambienti dei giochi e i loro dati non vengono modificati ora; il runtime verrà preparato al prossimo avvio. Le configurazioni sono conservate nella cronologia."
      : "Questa modalità serve a sviluppare e valutare porting sul Mac e richiede i componenti e i diritti d’uso previsti da Apple. I componenti proprietari sono esterni al progetto open source. L’attivazione non concede una licenza e non autorizza il gioco ordinario o la redistribuzione."
    prompt.addButton(withTitle: restoring ? "Ripristina" : "Usa per valutazione")
    prompt.addButton(withTitle: "Leggi documentazione")
    prompt.addButton(withTitle: "Annulla")
    let choice = prompt.runModal()
    if choice == .alertSecondButtonReturn {
      NSWorkspace.shared.open(project.appendingPathComponent("Docs/LICENSES.md"))
      return
    }
    guard choice == .alertFirstButtonReturn else { return }
    do {
      if restoring {
        try EvaluationMode.restore(paths: paths)
      } else {
        try EvaluationMode.enable(
          fragment: runtimeRoot.appendingPathComponent("evaluation-runtime.json"), paths: paths)
      }
      canvas.evaluationMode = activeRuntime().evaluationModeEnabled == true
      canvas.message =
        canvas.evaluationMode
        ? "Valutazione locale attiva · componenti Apple esterni con licenza separata"
        : "Configurazione precedente ripristinata"
      canvas.refresh()
    } catch { showError(error) }
  }
}
