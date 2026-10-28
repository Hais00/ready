// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct ReadyControllerNavigationProbe {
  static func main() throws {
    var checks = [String: Bool]()
    func require(_ condition: Bool, _ name: String) throws {
      guard condition else {
        throw NSError(
          domain: "ReadyControllerNavigation", code: 1,
          userInfo: [NSLocalizedDescriptionKey: name])
      }
      checks[name] = true
    }
    var axis = ControllerNavigation.AxisGate()
    try require(axis.update(x: 0.54, y: 0.2, now: 1) == nil, "axisDeadzone")
    try require(axis.update(x: 0.8, y: 0.1, now: 1.1) == .right, "axisDominantHorizontal")
    try require(axis.update(x: 0.9, y: 0.1, now: 1.12) == nil, "axisDebouncesHeldUpdates")
    try require(axis.update(x: 0.9, y: 0.1, now: 1.4) == nil, "axisWaitsForInitialRepeatDelay")
    try require(axis.update(x: 0.9, y: 0.1, now: 1.51) == .right, "axisRepeatsAfterInitialDelay")
    try require(axis.update(x: 0.9, y: 0.1, now: 1.6) == nil, "axisRepeatRateLimited")
    try require(axis.update(x: 0.9, y: 0.1, now: 1.7) == .right, "axisRepeatInterval")
    _ = axis.update(x: 0.4, y: 0.1, now: 1.8)
    try require(axis.update(x: 0.8, y: 0.1, now: 1.82) == nil, "axisHysteresisDoesNotRetrigger")
    _ = axis.update(x: 0.1, y: 0, now: 1.9)
    try require(
      axis.update(x: 0, y: -0.8, now: 2) == .down, "axisNeutralRearmsAndVerticalDirection")
    try require(axis.update(x: .nan, y: 0, now: 2.1) == nil, "axisRejectsNonFiniteInput")
    try require(axis.update(x: -0.8, y: 0, now: 2.2) == .left, "axisRecoversAfterInvalidInput")
    try require(
      ControllerNavigation.movedSelection(0, count: 0, delta: 1) == 0
        && ControllerNavigation.movedSelection(0, count: 3, delta: -1) == 0
        && ControllerNavigation.movedSelection(2, count: 3, delta: 1) == 2,
      "selectionBoundsAndEmptyLibrary")
    try require(
      ControllerNavigation.wrappedIndex(0, count: 6, delta: -1) == 5
        && ControllerNavigation.wrappedIndex(5, count: 6, delta: 1) == 0,
      "storeCycleWrapsBothDirections")
    try require(
      ControllerNavigation.nextEnabledIndex(0, enabled: [true, false, true], delta: 1) == 2
        && ControllerNavigation.nextEnabledIndex(2, enabled: [true, false, true], delta: -1) == 0,
      "popupSkipsDisabledAndSeparatorItems")
    try require(
      ControllerNavigation.nextEnabledIndex(0, enabled: [], delta: 1) == nil
        && ControllerNavigation.nextEnabledIndex(2, enabled: [true, false, true], delta: 1) == nil,
      "popupBoundsAndEmptyMenu")
    try require(
      ControllerNavigation.isCancelButton(title: "Annulla", keyEquivalent: "")
        && ControllerNavigation.isCancelButton(title: "Chiudi", keyEquivalent: "")
        && ControllerNavigation.isCancelButton(title: "Different locale", keyEquivalent: "\u{1b}"),
      "modalCancelUsesExplicitButtonSemantics")
    try require(
      !ControllerNavigation.isCancelButton(title: "Chiudi sessione", keyEquivalent: "")
        && !ControllerNavigation.isCancelButton(title: "Elimina tutto", keyEquivalent: ""),
      "modalCancelDoesNotChooseDestructiveTitleSubstring")
    for running in [false, true] {
      for maintenance in [false, true] {
        for active in [false, true] {
          try require(
            ControllerNavigation.allowsParentInput(
              running: running, maintenance: maintenance, active: active)
              == (!running && !maintenance && active),
            "parentRouting-\(running)-\(maintenance)-\(active)")
        }
      }
    }
    try require(
      ControllerNavigation.destination(
        running: true, maintenance: false, active: true,
        hasModal: true, authentication: true) == .ignore,
      "sessionOwnsControllerEvenWithModalAndAuthentication")
    try require(
      ControllerNavigation.destination(
        running: false, maintenance: true, active: true,
        hasModal: true, authentication: true) == .ignore,
      "maintenanceIgnoresControllerEvenWithModal")
    try require(
      ControllerNavigation.destination(
        running: false, maintenance: false, active: true,
        hasModal: true, authentication: true) == .modal, "modalPrecedesAuthenticationRouting")
    try require(
      ControllerNavigation.destination(
        running: false, maintenance: false, active: true,
        hasModal: false, authentication: true) == .authentication,
      "authenticationConsumesLibraryActions")
    try require(
      ControllerNavigation.destination(
        running: false, maintenance: false, active: true,
        hasModal: false, authentication: false) == .library, "libraryOnlyAfterOtherOwners")
    let report: [String: Any] = [
      "passed": true, "checks": checks,
      "testType":
        "pure input/navigation policy; AppKit routing compiled, no NSApplication/windows or physical controller exercised",
      "physicalControllerVerified": false, "modalAppKitInteractionVerified": false,
    ]
    FileHandle.standardOutput.write(
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
