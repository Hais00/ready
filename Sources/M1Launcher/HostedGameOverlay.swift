// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// AppKit controls above Ready's own hosted Metal surface. No guest injection,
/// screenshot, texture copy, frame observer or timer is needed by this panel.
@MainActor final class HostedGameOverlay {
  private weak var window:NSWindow?
  private weak var container:NSView?
  private weak var gameResponder:NSResponder?
  private let capture:(Bool)->Void
  private let quit:()->Void
  private var monitor:Any?
  private var consumed=Set<UInt16>()
  private var surface:HostedOverlaySurface?
  private var stopped=false
  private(set) var visible=false
  private(set) var selection=0
  init(window:NSWindow,container:NSView,gameResponder:NSResponder,
       capture:@escaping(Bool)->Void,quit:@escaping()->Void){
    self.window=window;self.container=container;self.gameResponder=gameResponder
    self.capture=capture;self.quit=quit
    monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged]){[weak self] event in
      var filtered:NSEvent?=event
      MainActor.assumeIsolated{if let self{filtered=self.filter(event)}}
      return filtered
    }
  }
  deinit{if let monitor{NSEvent.removeMonitor(monitor)}}
  func toggle(){setVisible(!visible)}
  func move(_ delta:Int){guard visible,!stopped else{return};selection=(selection+delta%2+2)%2;surface?.select(selection)}
  func confirm(){guard visible,!stopped else{return};if selection==1{setVisible(false);quit()}else{setVisible(false)}}
  func resume(){setVisible(false)}
  func stop(){
    guard !stopped else{return};setVisible(false);stopped=true
    if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil}
    consumed.removeAll()
  }
  private func setVisible(_ value:Bool){
    guard !stopped,value != visible else{return}
    if value {
      guard let window,let container else{return}
      capture(true) // Release the guest's pointer and input before exposing UI.
      visible=true;selection=0
      let surface=HostedOverlaySurface(frame:container.bounds)
      surface.autoresizingMask=[.width,.height]
      surface.onAction={[weak self] index in self?.selection=index;self?.confirm()}
      container.addSubview(surface,positioned:.above,relativeTo:nil)
      self.surface=surface
      window.makeFirstResponder(surface)
    }else{
      visible=false;surface?.removeFromSuperview();surface=nil
      if let window,let gameResponder{window.makeFirstResponder(gameResponder)}
      capture(false) // Eligibility remains enforced independently by the C host.
    }
  }
  /// The real local event monitor calls this before NSApplication.sendEvent
  /// reaches RHGHostView. Matching releases are consumed even after hide.
  func filter(_ event:NSEvent)->NSEvent? {
    guard !stopped else{return event}
    if event.type == .keyUp,consumed.remove(event.keyCode) != nil{return nil}
    guard let window,event.window === window,window.isKeyWindow,NSApp.isActive else{return event}
    if event.type == .keyDown {
      let modifiers=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let shortcut=event.keyCode==49 && modifiers.contains([.control,.shift])
        && modifiers.intersection([.command,.option]).isEmpty
      if shortcut {
        consumed.insert(event.keyCode)
        if !event.isARepeat{toggle()}
        return nil
      }
      if visible {
        switch event.keyCode {
        case 53:setVisible(false)
        case 125,124,48:move(event.modifierFlags.contains(.shift) ? -1:1)
        case 126,123:move(-1)
        case 36,76:if !event.isARepeat{confirm()}
        default:break
        }
        consumed.insert(event.keyCode);return nil
      }
      // A release can disappear while another app/Space owns input. A fresh
      // forwarded press begins a new gesture; its release must reach the game.
      // Repeats and keys consumed above still belong to the original gesture.
      if !event.isARepeat{consumed.remove(event.keyCode)}
    }
    if visible && event.type == .flagsChanged{return nil}
    return event
  }
}

@MainActor private final class HostedOverlaySurface:NSView {
  var onAction:((Int)->Void)?
  private let panel=NSView()
  private var buttons=[NSButton]()
  override var acceptsFirstResponder:Bool{true}
  override init(frame:NSRect){
    super.init(frame:frame)
    wantsLayer=true;layer?.backgroundColor=NSColor.black.withAlphaComponent(0.48).cgColor
    panel.wantsLayer=true;panel.layer?.backgroundColor=NSColor(calibratedRed:0.065,green:0.085,blue:0.12,alpha:0.98).cgColor
    panel.layer?.cornerRadius=18;panel.layer?.borderWidth=1
    panel.layer?.borderColor=NSColor.white.withAlphaComponent(0.2).cgColor
    panel.translatesAutoresizingMaskIntoConstraints=false;addSubview(panel)
    let title=NSTextField(labelWithString:"Ready")
    title.font = .systemFont(ofSize:28,weight:.semibold);title.textColor = .white
    let hint=NSTextField(labelWithString:"Ctrl + Maiusc + Spazio · torna al gioco")
    hint.font = .systemFont(ofSize:13);hint.textColor = .secondaryLabelColor
    let stack=NSStackView(views:[title,hint]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
    for (index,label) in ["Riprendi gioco","Esci dal gioco"].enumerated(){
      let button=NSButton(title:label,target:self,action:#selector(pressed(_:)))
      button.tag=index;button.bezelStyle = .rounded;button.font = .systemFont(ofSize:16,weight:.medium)
      button.focusRingType = .none;button.setAccessibilityIdentifier(index==0 ? "readyHostedResume":"readyHostedQuit")
      buttons.append(button);stack.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
      button.heightAnchor.constraint(equalToConstant:40).isActive=true
    }
    stack.translatesAutoresizingMaskIntoConstraints=false;panel.addSubview(stack)
    NSLayoutConstraint.activate([
      panel.centerXAnchor.constraint(equalTo:centerXAnchor),panel.centerYAnchor.constraint(equalTo:centerYAnchor),
      panel.widthAnchor.constraint(lessThanOrEqualToConstant:420),panel.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-32),
      panel.widthAnchor.constraint(equalToConstant:420).withPriority(.defaultHigh),
      stack.leadingAnchor.constraint(equalTo:panel.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:panel.trailingAnchor,constant:-28),
      stack.topAnchor.constraint(equalTo:panel.topAnchor,constant:26),stack.bottomAnchor.constraint(equalTo:panel.bottomAnchor,constant:-26)])
    select(0)
  }
  required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
  override func hitTest(_ point:NSPoint)->NSView?{bounds.contains(point) ? (super.hitTest(point) ?? self):nil}
  func select(_ index:Int){for (offset,button) in buttons.enumerated(){button.contentTintColor=offset==index ? .systemCyan:.white;button.state=offset==index ? .on:.off}}
  @objc private func pressed(_ sender:NSButton){onAction?(sender.tag)}
}
private extension NSLayoutConstraint {
  func withPriority(_ value:NSLayoutConstraint.Priority)->NSLayoutConstraint{priority=value;return self}
}
