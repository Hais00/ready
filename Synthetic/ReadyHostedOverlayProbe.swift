// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Metal
import QuartzCore

@MainActor private final class GameSurface:NSView {
  var delivered=[UInt16]()
  override var acceptsFirstResponder:Bool{true}
  override func keyDown(with event:NSEvent){delivered.append(event.keyCode)}
  override func keyUp(with event:NSEvent){delivered.append(event.keyCode)}
}
/// A caller-owned responder stands in for real Ready controls. The shortcut
/// controller must forward their normal keys; it never creates another UI.
@MainActor private final class ReadyControlResponder:NSResponder {
  var delivered=[UInt16]()
  override var acceptsFirstResponder:Bool{true}
  override func keyDown(with event:NSEvent){delivered.append(event.keyCode)}
  override func keyUp(with event:NSEvent){delivered.append(event.keyCode)}
}
@main struct ReadyHostedOverlayProbe {
  @MainActor static func main() throws {
    let app=NSApplication.shared;app.setActivationPolicy(.regular)
    let window=NSWindow(contentRect:NSRect(x:100,y:100,width:620,height:440),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.title="Ready own shortcut and Metal fixture";window.isReleasedWhenClosed=false
    let game=GameSurface(frame:window.contentView!.bounds);window.contentView=game
    let controls=ReadyControlResponder(),device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
    let metal=CAMetalLayer();metal.device=device;metal.pixelFormat = .bgra8Unorm;metal.framebufferOnly=false
    game.wantsLayer=true;game.layer=metal;metal.drawableSize=CGSize(width:620,height:440)
    var checks=[String:Bool](),transitions=[Bool](),moves=[Int](),activations=0
    let overlay=HostedGameOverlay(window:window,show:{transitions.append(true);window.makeFirstResponder(controls);return true},hide:{transitions.append(false);window.makeFirstResponder(game)},move:{moves.append($0)},confirm:{activations+=1})
    func expect(_ name:String,_ value:Bool){checks[name]=value}
    func pump(_ seconds:Double){let deadline=Date(timeIntervalSinceNow:seconds);while Date()<deadline{
      if let event=app.nextEvent(matching:.any,until:Date(timeIntervalSinceNow:0.005),inMode:.default,dequeue:true){app.sendEvent(event)}
      RunLoop.current.run(until:Date(timeIntervalSinceNow:0.001))
    }}
    func event(_ code:UInt16,_ type:NSEvent.EventType = .keyDown,_ flags:NSEvent.ModifierFlags=[],repeatKey:Bool=false,number:Int?=nil)->NSEvent{
      NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:number ?? window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:repeatKey,keyCode:code)!
    }
    func send(_ code:UInt16,_ flags:NSEvent.ModifierFlags=[]){app.postEvent(event(code,.keyUp,flags),atStart:true);app.postEvent(event(code,.keyDown,flags),atStart:true);pump(0.025)}
    var presentations=0,gpuReadback=false
    func render()throws{
      guard let drawable=metal.nextDrawable(),let command=queue.makeCommandBuffer()else{throw NSError(domain:"ownMetalFixture",code:1)}
      let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store;pass.colorAttachments[0].clearColor=MTLClearColorMake(0.1,0.2,0.3,1)
      command.makeRenderCommandEncoder(descriptor:pass)!.endEncoding();command.present(drawable);command.commit();command.waitUntilCompleted()
      // Test-owned solid-color drawable, not a window or screen capture.
      var bytes=[UInt8](repeating:0,count:4);drawable.texture.getBytes(&bytes,bytesPerRow:4,from:MTLRegionMake2D(0,0,1,1),mipmapLevel:0)
      gpuReadback=command.status == .completed && abs(Int(bytes[0])-77)<3 && abs(Int(bytes[1])-51)<3;presentations+=1
    }
    window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true);window.makeFirstResponder(game);pump(0.15)
    defer{overlay.stop();window.orderOut(nil);window.close()}
    expect("own-window-active-for-real-local-monitor",window.isKeyWindow && app.isActive)
    try render();expect("actual-own-metal-render-present-and-readback",gpuReadback)
    let originalWindow=window.windowNumber,originalViews=game.subviews.count,originalLayers=metal.sublayers?.count ?? 0
    send(49,[.control,.shift]);expect("posted-shortcut-reaches-real-local-monitor",overlay.visible && transitions == [true])
    expect("shortcut-press-and-release-never-reach-game",game.delivered.isEmpty)
    expect("shortcut-controller-creates-no-view-layer-or-window",window.windowNumber==originalWindow && window.contentView===game && game.subviews.count==originalViews && (metal.sublayers?.count ?? 0)==originalLayers && game.layer===metal)
    let repeatEvent=event(49,.keyDown,[.control,.shift],repeatKey:true);expect("repeated-shortcut-is-consumed-without-retoggle",overlay.filter(repeatEvent)==nil && overlay.visible && transitions.count==1)
    for code:UInt16 in [0,125,126,36,48]{let before=controls.delivered.count;send(code);expect("ordinary-ui-key-\(code)-passes-through",controls.delivered.count==before+2 && controls.delivered.suffix(2)==[code,code])}
    expect("ordinary-ui-keys-do-not-leak-to-game-responder",game.delivered.isEmpty)
    try render();expect("same-metal-surface-keeps-presenting-during-interface",presentations==2 && gpuReadback && game.layer===metal)
    overlay.move(-2);overlay.confirm();expect("controller-actions-forward-to-real-ui-owner",moves==[-2] && activations==1 && overlay.visible)
    send(53);expect("escape-hides-and-restores-game-responder",!overlay.visible && window.firstResponder===game && transitions==[true,false] && game.delivered.isEmpty)
    send(0);expect("ordinary-game-input-returns-after-hide",game.delivered==[0,0])
    overlay.toggle();let beforeLost=game.delivered.count
    app.postEvent(event(49,.keyDown,[.control,.shift]),atStart:true);pump(0.025)
    expect("closing-shortcut-press-is-consumed-before-missing-release",!overlay.visible && game.delivered.count==beforeLost)
    send(49);expect("fresh-space-after-lost-shortcut-release-remains-paired",game.delivered.count==beforeLost+2 && game.delivered.suffix(2)==[49,49])
    overlay.toggle();let beforePaired=game.delivered.count;send(49,[.control,.shift]);expect("same-gesture-release-stays-consumed-after-hide",!overlay.visible && game.delivered.count==beforePaired)
    let foreign=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:20,height:20),styleMask:[],backing:.buffered,defer:false);foreign.isReleasedWhenClosed=false
    let otherEvent=event(49,.keyDown,[.control,.shift],number:foreign.windowNumber);expect("other-window-shortcut-is-not-consumed",overlay.filter(otherEvent)===otherEvent && !overlay.visible);foreign.close()
    let withOption=event(49,.keyDown,[.control,.shift,.option]);expect("shortcut-with-option-is-not-consumed",overlay.filter(withOption)===withOption && !overlay.visible)
    let withCommand=event(49,.keyDown,[.control,.shift,.command]);expect("shortcut-with-command-is-not-consumed",overlay.filter(withCommand)===withCommand && !overlay.visible)
    let frames=presentations;pump(0.05);expect("shortcut-controller-adds-no-render-loop-or-panel",presentations==frames && game.subviews.count==originalViews && (metal.sublayers?.count ?? 0)==originalLayers)
    overlay.toggle();overlay.stop();overlay.stop();expect("stop-hides-and-detaches-monitor-idempotently",!overlay.visible && transitions.last==false && window.firstResponder===game)
    let beforeStopped=game.delivered.count;send(49,[.control,.shift]);expect("stopped-shortcut-is-forwarded-normally",!overlay.visible && game.delivered.count==beforeStopped+2 && game.delivered.suffix(2)==[49,49])
    var rejectedShows=0,rejectedHides=0
    let rejected=HostedGameOverlay(window:window,show:{rejectedShows+=1;return false},hide:{rejectedHides+=1});rejected.toggle();expect("rejected-show-cleans-up-without-latching-visible",!rejected.visible && rejectedShows==1 && rejectedHides==1);rejected.stop()
    var reentrant:HostedGameOverlay?,reentrantShows=0,reentrantHides=0
    reentrant=HostedGameOverlay(window:window,show:{reentrantShows+=1;reentrant?.stop();return true},hide:{reentrantHides+=1});reentrant?.toggle();reentrant?.toggle();expect("reentrant-stop-during-show-cannot-resurrect-interface",reentrant?.visible==false && reentrantShows==1 && reentrantHides==1);reentrant=nil
    var reentrantHide:HostedGameOverlay?,hideShows=0,hideCalls=0
    reentrantHide=HostedGameOverlay(window:window,show:{hideShows+=1;return true},hide:{hideCalls+=1;reentrantHide?.stop()});reentrantHide?.toggle();reentrantHide?.resume();reentrantHide?.toggle();expect("reentrant-stop-during-hide-completes-once",reentrantHide?.visible==false && hideShows==1 && hideCalls==1);reentrantHide=nil
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"metalPresentations":presentations,"actualMetalGPUReadback":gpuReadback,"actualAppKitLocalMonitor":true,"actualAppKitRaster":false,"ownWindowOnly":true,"globalInputInjection":false,"screenCaptureUsed":false,"accountOrGameUsed":false,"actualCommercialGameVerified":false,"scope":"actual shortcut local monitor and caller-owned responders; own solid-color Metal readback, no interface rendering or screen capture"]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]);print(String(data:data,encoding:.utf8)!);if !checks.values.allSatisfy({$0}){exit(1)}
  }
}
