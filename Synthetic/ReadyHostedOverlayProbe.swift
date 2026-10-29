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
@main struct ReadyHostedOverlayProbe {
  @MainActor static func main() throws {
    let app=NSApplication.shared
    app.setActivationPolicy(.regular)
    let window=NSWindow(contentRect:NSRect(x:100,y:100,width:620,height:440),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.title="Ready Hosted Overlay Lab — own finite Metal fixture"
    let game=GameSurface(frame:window.contentView!.bounds)
    window.contentView=game
    let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
    let metal=CAMetalLayer();metal.device=device;metal.pixelFormat = .bgra8Unorm;metal.framebufferOnly=false
    game.wantsLayer=true;game.layer=metal;metal.drawableSize=CGSize(width:620,height:440)
    var checks=[String:Bool](),capture=[Bool](),quits=0
    let overlay=HostedGameOverlay(window:window,container:game,gameResponder:game,capture:{capture.append($0)},quit:{quits+=1})
    func expect(_ name:String,_ value:Bool){checks[name]=value}
    func pump(_ seconds:Double){
      let deadline=Date(timeIntervalSinceNow:seconds)
      while Date()<deadline {
        if let event=app.nextEvent(matching:.any,until:Date(timeIntervalSinceNow:0.005),inMode:.default,dequeue:true){app.sendEvent(event)}
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.001))
      }
    }
    func event(_ code:UInt16,_ type:NSEvent.EventType = .keyDown,_ flags:NSEvent.ModifierFlags=[])->NSEvent {
      NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
    }
    func send(_ code:UInt16,_ flags:NSEvent.ModifierFlags=[]){
      // Put the own pair ahead of unrelated AppKit activation/paint events,
      // preserving down/up order rather than relying on a fixed queue delay.
      app.postEvent(event(code,.keyUp,flags),atStart:true)
      app.postEvent(event(code,.keyDown,flags),atStart:true);pump(0.025)
    }
    var presentations=0,gpuReadback=false
    func render() throws {
      guard let drawable=metal.nextDrawable(),let command=queue.makeCommandBuffer() else{throw NSError(domain:"ownMetalFixture",code:1)}
      let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=drawable.texture
      pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor=MTLClearColorMake(0.1,0.2,0.3,1)
      command.makeRenderCommandEncoder(descriptor:pass)!.endEncoding();command.present(drawable);command.commit();command.waitUntilCompleted()
      var bytes=[UInt8](repeating:0,count:4)
      drawable.texture.getBytes(&bytes,bytesPerRow:4,from:MTLRegionMake2D(0,0,1,1),mipmapLevel:0)
      gpuReadback=command.status == .completed && abs(Int(bytes[0])-77)<3 && abs(Int(bytes[1])-51)<3
      presentations+=1
    }
    window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true);window.makeFirstResponder(game);pump(0.15)
    defer{overlay.stop();window.orderOut(nil)}
    expect("own-window-active-for-local-event-proof",window.isKeyWindow && app.isActive)
    try render();expect("actual-metal-render-present-and-readback",gpuReadback)
    let originalWindow=window.windowNumber
    send(49,[.control,.shift])
    expect("posted-hotkey-reaches-real-local-monitor",overlay.visible && capture == [true])
    expect("shortcut-press-and-release-not-delivered-to-game",game.delivered.isEmpty)
    expect("overlay-is-subview-of-same-metal-window",window.windowNumber==originalWindow && game.subviews.count==1 && game.layer === metal)
    let surface=game.subviews.first!
    surface.layoutSubtreeIfNeeded();surface.displayIfNeeded();CATransaction.flush()
    let bitmap=surface.bitmapImageRepForCachingDisplay(in:surface.bounds)!
    surface.cacheDisplay(in:surface.bounds,to:bitmap)
    let png=bitmap.representation(using:.png,properties:[:])!
    let target=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("overlay-own-window.png")
    try png.write(to:target)
    var lit=0
    for y in stride(from:0,to:bitmap.pixelsHigh,by:3){for x in stride(from:0,to:bitmap.pixelsWide,by:3){if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),max(c.redComponent,c.greenComponent,c.blueComponent)>0.65{lit+=1}}}
    expect("actual-AppKit-overlay-raster-has-readable-controls",lit>80 && png.count>2000)
    try render();expect("metal-still-presents-with-native-overlay-open",presentations==2 && gpuReadback)
    send(125);expect("arrow-selects-quit",overlay.selection==1)
    expect("overlay-arrow-not-delivered-to-game",!game.delivered.contains(125))
    send(53);expect("escape-resumes-and-restores-game-responder",!overlay.visible && game.subviews.isEmpty && window.firstResponder === game && capture == [true,false])
    send(0);expect("ordinary-game-key-restored-after-hide",game.delivered == [0,0])
    send(49,[.control,.shift]);send(36)
    expect("enter-default-resumes-without-quit",!overlay.visible && quits==0)
    overlay.toggle()
    let beforeLostRelease=game.delivered.count
    app.postEvent(event(49,.keyDown,[.control,.shift]),atStart:true);pump(0.025)
    expect("closing-hotkey-press-consumed-before-missing-release",!overlay.visible && game.delivered.count==beforeLostRelease)
    // Do not post its key-up: this is the state produced by losing the release
    // to another app/Space. The next unmodified gesture must be paired normally.
    send(49)
    expect("fresh-space-gesture-after-lost-hotkey-release-is-paired",game.delivered.count==beforeLostRelease+2 && game.delivered.suffix(2)==[49,49])
    overlay.toggle();let beforePairedClose=game.delivered.count
    send(49,[.control,.shift])
    expect("same-gesture-release-after-overlay-hide-still-consumed",!overlay.visible && game.delivered.count==beforePairedClose)
    overlay.toggle();overlay.move(1);overlay.confirm()
    expect("typed-controller-actions-route-to-same-overlay",!overlay.visible && quits==1)
    overlay.toggle()
    let resume=game.subviews.flatMap{$0.subviews}.flatMap{$0.subviews}.flatMap{$0.subviews}.compactMap{$0 as? NSButton}.first{$0.tag==0}
    resume?.performClick(nil)
    expect("native-button-click-resumes",resume != nil && !overlay.visible)
    let frames=presentations;pump(0.05)
    expect("hidden-overlay-creates-no-render-loop-or-retained-panel",presentations==frames && game.subviews.isEmpty)
    overlay.toggle();overlay.stop();overlay.stop()
    expect("stop-releases-capture-panel-and-monitor-idempotently",!overlay.visible && game.subviews.isEmpty && capture.last==false)
    send(49,[.control,.shift]);expect("stopped-shortcut-no-longer-captured",!overlay.visible && game.delivered.suffix(2) == [49,49])
    window.orderOut(nil)
    let report:[String:Any] = ["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,
      "metalPresentations":presentations,"actualMetalGPUReadback":gpuReadback,"actualAppKitRaster":true,
      "ownWindowOnly":true,"globalInputInjection":false,"accountOrGameUsed":false,"actualCommercialGameVerified":false]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]);print(String(data:data,encoding:.utf8)!)
    if !checks.values.allSatisfy({$0}){exit(1)}
  }
}
