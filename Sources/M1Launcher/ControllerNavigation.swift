// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreFoundation

/// Public AppKit control APIs only. No synthesized keyboard/mouse events or modal aborts.
enum ControllerNavigation {
  enum Direction: Equatable { case left, right, up, down }
  enum Action: Equatable {
    case move(Direction), activate, cancel, profiles, previousStore, nextStore
  }

  /// Main-run-loop work remains serviceable inside NSAlert.runModal and control tracking.
  /// A GCD main-queue block that synchronously enters runModal can otherwise retain the
  /// serial queue while subsequent controller callbacks are waiting on that same queue.
  static func enqueue(_ action: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking], block: action)
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }

  enum Destination: Equatable { case ignore, modal, authentication, library }

  static func destination(
    running: Bool, maintenance: Bool, active: Bool, hasModal: Bool, authentication: Bool
  ) -> Destination {
    guard allowsParentInput(running: running, maintenance: maintenance, active: active) else {
      return .ignore
    }
    if hasModal { return .modal }
    return authentication ? .authentication : .library
  }

  static func allowsParentInput(running: Bool, maintenance: Bool, active: Bool) -> Bool {
    !running && !maintenance && active
  }

  struct AxisGate {
    private var held: Direction?
    private var firstEmission = -Double.infinity
    private var lastEmission = -Double.infinity
    /// Engage at 0.55, require return below 0.30 for neutral, debounce 80 ms.
    /// Holding repeats after 400 ms, at most every 180 ms when GC sends updates.
    mutating func update(x: Float, y: Float, now: TimeInterval) -> Direction? {
      guard x.isFinite, y.isFinite, now.isFinite else {
        held = nil
        return nil
      }
      let magnitude = max(abs(x), abs(y))
      if magnitude < 0.30 {
        held = nil
        return nil
      }
      guard magnitude >= 0.55 else { return nil }
      let direction: Direction = abs(x) >= abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
      if direction != held {
        guard now - lastEmission >= 0.08 else { return nil }
        held = direction
        firstEmission = now
        lastEmission = now
        return direction
      }
      guard now - firstEmission >= 0.40, now - lastEmission >= 0.18 else { return nil }
      lastEmission = now
      return direction
    }
  }

  static func movedSelection(_ current: Int, count: Int, delta: Int) -> Int {
    guard count > 0 else { return 0 }
    return max(0, min(count - 1, current + delta))
  }
  static func wrappedIndex(_ current: Int, count: Int, delta: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((current + delta) % count + count) % count
  }
  static func nextEnabledIndex(_ current: Int, enabled: [Bool], delta: Int) -> Int? {
    guard !enabled.isEmpty, delta != 0 else { return nil }
    let step = delta > 0 ? 1 : -1
    var index = current < 0 ? (step > 0 ? 0 : enabled.count - 1) : current + step
    while enabled.indices.contains(index) {
      if enabled[index] { return index }
      index += step
    }
    return nil
  }
  static func isCancelButton(title: String, keyEquivalent: String) -> Bool {
    if keyEquivalent == "\u{1b}" { return true }
    return ["annulla", "chiudi", "cancel", "close"].contains(
      title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  private static func focusedControl(in window: NSWindow) -> NSControl? {
    if let control = window.firstResponder as? NSControl { return control }
    if let field = window.firstResponder as? NSTextView, field.isFieldEditor {
      return field.delegate as? NSControl
    }
    return nil
  }
  private static func usable(_ button: NSButton, in window: NSWindow) -> Bool {
    button.window === window && button.isEnabled && !button.isHiddenOrHasHiddenAncestor
  }
  private static func buttons(in view: NSView) -> [NSButton] {
    let current = (view as? NSButton).map { [$0] } ?? []
    return current + view.subviews.flatMap { buttons(in: $0) }
  }
  private static func activateDefault(in window: NSWindow) {
    if let button = window.defaultButtonCell?.controlView as? NSButton,
      !(button is NSPopUpButton), usable(button, in: window)
    {
      button.performClick(nil)
    }
  }

  /// The caller consumes EVERY action when a modal exists, even if this method has
  /// no matching safe control. In particular Menu/shoulders never reach the library.
  static func handleModal(_ action: Action, window: NSWindow) {
    precondition(Thread.isMainThread)
    switch action {
    case .move(let direction):
      if direction == .up || direction == .down,
        let popup = focusedControl(in: window) as? NSPopUpButton, usable(popup, in: window)
      {
        let enabled = popup.itemArray.map { $0.isEnabled && !$0.isSeparatorItem && !$0.isHidden }
        if let index = nextEnabledIndex(
          popup.indexOfSelectedItem, enabled: enabled,
          delta: direction == .down ? 1 : -1)
        {
          popup.selectItem(at: index)
          if let action = popup.action { _ = popup.sendAction(action, to: popup.target) }
        }
      } else if direction == .left || direction == .up {
        window.selectPreviousKeyView(nil)
      } else {
        window.selectNextKeyView(nil)
      }
    case .activate:
      // Popups subclass NSButton. Confirm the dialog instead of entering a menu's
      // tracking loop; dpad up/down already selects its value without events.
      if focusedControl(in: window) is NSPopUpButton {
        activateDefault(in: window)
      } else if let button = focusedControl(in: window) as? NSButton, usable(button, in: window) {
        button.performClick(nil)
      } else {
        activateDefault(in: window)
      }
    case .cancel:
      guard let content = window.contentView else { return }
      let candidates = buttons(in: content).filter { usable($0, in: window) }
      let cancel =
        candidates.first { $0.keyEquivalent == "\u{1b}" }
        ?? candidates.first { isCancelButton(title: $0.title, keyEquivalent: $0.keyEquivalent) }
      cancel?.performClick(nil)
    case .profiles, .previousStore, .nextStore: break
    }
  }
}
