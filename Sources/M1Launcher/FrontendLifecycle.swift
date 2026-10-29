// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  func restoreLauncher(_ message: String) {
    MainActor.assumeIsolated {
      // A cancelled fullscreen transition may still be pending before active
      // becomes true. stop() is idempotent and clears that preparation too.
      hostedPresentation?.stop()
      hostedPresentation=nil
    }
    canvas.resumeGraphics()
    canvas.message =
      backgroundNotices.isEmpty ? message : message + " · Nuove notifiche in Libreria → Notifiche"
    window.contentView = canvas
    window.makeFirstResponder(canvas)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    canvas.refresh()
  }

  /// Runs the real frontend/keeper/native-session lifecycle, without accounts or
  /// synthesized UI input. Logical window/resource state is not a visual/direct-display proof.
  func runBackgroundErrorProbe() {
    guard
      FileManager.default.fileExists(
        atPath: paths.root.appendingPathComponent(".ready-frontend-probe").path)
    else {
      FileHandle.standardError.write(Data("A marked synthetic --data-root is required.\n".utf8))
      NSApp.terminate(nil)
      return
    }
    var checks = [String: Bool]()
    window.makeKeyAndOrderFront(nil)
    canvas.refresh()
    checks["initialCanvasAllocated"] = canvas.allocatedTextureBytes > 0
    // Exercise the new defensive teardown with an active internal panel and a
    // queued panel, not merely NSApp.modalWindow (which is intentionally nil).
    presentDialog(
      title: "Synthetic panel", message: "Retained as a notification during play",
      content: NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60)),
      actions: [.init("Chiudi", role: .cancel)]
    ) { _ in }
    dialogs.present(
      title: "Synthetic queued panel", message: "Queued notification during play",
      content:nil,
      actions: [.init("Chiudi", role: .cancel)]
    ) { _ in }
    checks["internalPanelPresentBeforeLaunch"] = dialogs.isPresenting && pages.isPresenting
    var started = false
    session.onFinish = { [weak self] message in
      guard let self else { return }
      self.restoreLauncher(message)
      checks["realSessionStarted"] = started
      checks["returnRestoresCanvas"] = self.canvas.allocatedTextureBytes > 0
      checks["returnRestoresWindowContent"] = self.window.contentView === self.canvas
      checks["returnRestoresKeyboardFocus"] = self.window.firstResponder === self.canvas
      checks["notificationRemainsAccessible"] = self.backgroundNotices.count == 3
      checks["interfaceCommandsRestoredAfterGame"] = self.validateMenuItem(
        NSMenuItem(title: "Settings", action: #selector(AppDelegate.settings), keyEquivalent: ""))
      let report: [String: Any] = [
        "passed": checks.values.allSatisfy { $0 }, "checks": checks,
        "scope":
          "actual AppDelegate + MetalCanvas + SessionManager + native keeper; logical resource/window state, no visual input or real game",
        "directToDisplayVerified": false, "visualVerificationPerformed": false,
      ]
      if let bytes = try? JSONSerialization.data(
        withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
      {
        FileHandle.standardOutput.write(bytes)
      }
      NSApp.terminate(nil)
    }
    let variant = GameVariant(
      id: "native", platform: .macOS, architecture: .arm64,
      executable: "/bin/sleep", arguments: ["2"], installed: true)
    let game = Game(
      id: "frontend-lifecycle-probe", store: .local, storeID: "probe", title: "Synthetic session",
      variants: [variant])
    session.start(game: game, variant: variant, profile: state.activeProfile) {
      [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        started = true
        self.showError(LauncherError.failed("Synthetic background store failure"))
        checks["errorDoesNotCreateModal"] = NSApp.modalWindow == nil && !self.dialogs.isPresenting
        checks["activeAndQueuedPanelsDetachedDuringGame"] = !self.dialogs.isPresenting && !self.pages.isPresenting
        checks["errorDoesNotShowLauncher"] = !self.window.isVisible
        checks["errorDoesNotRestoreGPUTexture"] = self.canvas.allocatedTextureBytes == 0
        checks["errorIsDeferred"] = self.backgroundNotices.count == 3
        checks["interfaceCommandsDisabledDuringGame"] = !self.validateMenuItem(
          NSMenuItem(title: "Settings", action: #selector(AppDelegate.settings), keyEquivalent: ""))
      case .failure:
        FileHandle.standardError.write(Data("Synthetic session startup failed.\n".utf8))
        NSApp.terminate(nil)
      }
    }
  }
}
