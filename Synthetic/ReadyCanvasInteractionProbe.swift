// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import LauncherCore
import Metal

@main struct ReadyCanvasInteractionProbe {
  static func require(_ test: Bool, _ message: String) throws {
    if !test { throw NSError(domain: message, code: 1) }
  }
  static func main() throws {
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "NoMetal", code: 1) }
    let canvas = MetalCanvas(frame: NSRect(x: 0, y: 0, width: 1240, height: 760), device: device)
    let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = canvas; window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.makeFirstResponder(canvas)
    defer { canvas.releaseGraphics(); window.close() }
    canvas.refresh();canvas.renderDisplayTick()
    let original = canvas.interactionSnapshot.hits
    try require(Set(original.map(\.id)).count == original.count, "HitIDsNotUnique")
    var actions = [CanvasAction](); canvas.onAction = { actions.append($0) }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    var checked = [String]()
    for hit in original {
      let point = CGPoint(x: hit.rect.midX, y: hit.rect.midY)
      canvas.mouseMoved(with: event(.mouseMoved, point)); try require(canvas.interactionSnapshot.hover == hit.id, "HoverMismatch:" + hit.id)
      let count = actions.count
      canvas.mouseDown(with: event(.leftMouseDown, point)); try require(canvas.interactionSnapshot.pressed == hit.id, "PressedMismatch")
      let outside = CGPoint(x: canvas.bounds.maxX - 1, y: canvas.bounds.maxY - 1)
      canvas.mouseDragged(with: event(.leftMouseDragged, outside)); canvas.mouseUp(with: event(.leftMouseUp, outside))
      try require(actions.count == count, "DraggedOutsideActivated")
      canvas.mouseDown(with: event(.leftMouseDown, point)); canvas.mouseUp(with: event(.leftMouseUp, point))
      try require(actions.count == count + 1, "InsideClickNotActivated")
      checked.append(hit.id)
    }
    canvas.interactionEnabled = false
    let point = CGPoint(x: original[0].rect.midX, y: original[0].rect.midY), count = actions.count
    canvas.mouseMoved(with: event(.mouseMoved, point)); canvas.mouseDown(with: event(.leftMouseDown, point)); canvas.mouseUp(with: event(.leftMouseUp, point))
    try require(actions.count == count && canvas.interactionSnapshot.hover == nil, "DisabledCanvasActivated")
    canvas.interactionEnabled = true
    let result: [String: Any] = ["passed":true,"hitIDs":checked,"distinctHoverTargets":checked.count,"insideClickVerified":true,"dragOutsideDoesNotActivate":true,"dialogBlocksCanvas":true,"ownWindowProgrammaticEvents":true,"globalEventsInjected":false,"CUAInteractionVerified":false]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
  }
}
