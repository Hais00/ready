// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Window-scoped shortcut controller. The content is Ready's real interface,
/// mounted by HostedGamePresentationController, never a second overlay UI.
@MainActor final class HostedGameOverlay {
  private weak var window:NSWindow?
  private let show:()->Bool
  private let hide:()->Void
  private let navigate:(Int)->Void
  private let activate:()->Void
  private var monitor:Any?
  private var consumed=Set<UInt16>()
  private var stopped=false
  private(set) var visible=false
  init(window:NSWindow,show:@escaping()->Bool,hide:@escaping()->Void,
       move:@escaping(Int)->Void={_ in},confirm:@escaping()->Void={}) {
    self.window=window;self.show=show;self.hide=hide;self.navigate=move;self.activate=confirm
    monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]){[weak self]event in
      var result:NSEvent?=event
      MainActor.assumeIsolated{if let self{result=self.filter(event)}}
      return result
    }
  }
  deinit{if let monitor{NSEvent.removeMonitor(monitor)}}
  func toggle(){
    guard !stopped else{return}
    if visible{resume();return}
    visible=true
    let accepted=show()
    if !accepted || stopped{resume()}
  }
  func resume(){guard visible else{return};visible=false;hide()}
  func move(_ delta:Int){guard visible,!stopped else{return};navigate(delta)}
  func confirm(){guard visible,!stopped else{return};activate()}
  func stop(){guard !stopped else{return};resume();stopped=true;if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil};consumed.removeAll()}
  func filter(_ event:NSEvent)->NSEvent? {
    guard !stopped else{return event}
    if event.type == .keyUp,consumed.remove(event.keyCode) != nil{return nil}
    guard let window,event.window === window,window.isKeyWindow,NSApp.isActive else{return event}
    if event.type == .keyDown {
      let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let shortcut=event.keyCode==49&&flags.contains([.control,.shift])&&flags.intersection([.command,.option]).isEmpty
      if shortcut || (visible&&event.keyCode==53){
        consumed.insert(event.keyCode)
        if !event.isARepeat{if shortcut{toggle()}else{resume()}}
        return nil
      }
      // Real Ready controls receive ordinary keys, including arrows, text,
      // Return and Tab. Releases belonging to a fresh press remain paired.
      if !event.isARepeat{consumed.remove(event.keyCode)}
    }
    return event
  }
}
