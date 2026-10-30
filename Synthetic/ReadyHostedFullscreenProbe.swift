// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore
import ReadyHostedView

@_silgen_name("RHGFixtureReset") func fixtureReset()
@_silgen_name("RHGFixtureCreateCount") func fixtureCreateCount()->Int32
@_silgen_name("RHGFixtureStopCount") func fixtureStopCount()->Int32
@_silgen_name("RHGFixturePresent") func fixturePresent()
@_silgen_name("RHGFixturePointerEnabled") func fixturePointerEnabled()->Int32
@_silgen_name("RHGFixtureTransportMode") func fixtureTransportMode()->Int32
@_silgen_name("RHGFixtureDeviceRegistryID") func fixtureDeviceRegistryID()->UInt64
@_silgen_name("RHGFixtureHUDRequested") func fixtureHUDRequested()->Int32
@_silgen_name("RHGFixtureSetFailCreate") func fixtureSetFailCreate(_ fail:Int32)
@_silgen_name("RHGFixtureOverlayGate") func fixtureOverlayGate()->Int32

/// Eligibility is simulated inside this isolated helper; this does not activate
/// an application or acquire the physical pointer.
final class FixtureApplication:NSApplication {
  override var isActive:Bool {true}
}

@MainActor final class FullscreenDriverState:NSObject {
  let center=NotificationCenter()
  var fullscreen=false
  var toggles=0
  var configurations=0
  var restores=0
  func placement(timeout:TimeInterval=0.5)->HostedWindowPlacement {
    HostedWindowPlacement(driver:.init(notificationObject:self,
      isFullscreen:{[self] in fullscreen},configure:{[self] in configurations+=1},
      toggle:{[self] in toggles+=1},restore:{[self] in restores+=1}),center:center,timeout:timeout)
  }
  func post(_ name:Notification.Name){center.post(name:name,object:self)}
}
final class OffscreenFixtureWindow:NSWindow {
  var simulatedFullscreen=false
  override var styleMask:NSWindow.StyleMask {
    get{simulatedFullscreen ? super.styleMask.union(.fullScreen):super.styleMask}
    set{super.styleMask=newValue}
  }
  override var isKeyWindow:Bool {simulatedFullscreen}
  override var isOnActiveSpace:Bool {simulatedFullscreen}
  override func makeKeyAndOrderFront(_ sender:Any?){}
  override func displayIfNeeded(){}
}

@main struct ReadyHostedFullscreenProbe {
  @MainActor static func pump(_ seconds:TimeInterval=0.05){
    let until=Date().addingTimeInterval(seconds)
    while Date()<until{RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.001))}
  }
  @MainActor static func run(_ directory:URL)throws {
    var checks=[String:Bool]()
    func check(_ name:String,_ value:Bool){checks[name]=value}
    func success(_ result:Result<Void,Error>)->Bool {if case .success=result{return true};return false}
    do {
      let state=FullscreenDriverState(),placement=state.placement()
      var results=[Bool]()
      placement.enter{results.append(success($0))}
      check("entry-requests-native-toggle-once",state.toggles==1 && state.configurations==1)
      check("lease-waits-for-did-enter",results.isEmpty)
      state.fullscreen=true;pump()
      check("style-bit-alone-does-not-complete",results.isEmpty)
      state.center.post(name:NSWindow.didEnterFullScreenNotification,object:NSObject());pump()
      check("other-window-notification-ignored",results.isEmpty)
      state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("did-enter-completes-once",results==[true])
      state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("repeated-did-enter-does-not-repeat-completion",results==[true])
      check("completion-preserves-fullscreen",state.fullscreen && state.restores==0 && state.toggles==1)
      var already=[Bool]();placement.enter{already.append(success($0))}
      check("already-fullscreen-completion-is-asynchronous",already.isEmpty)
      pump();check("already-fullscreen-does-not-toggle",already==[true] && state.toggles==1)
      placement.restore();placement.restore()
      check("explicit-exit-is-idempotent",state.toggles==2)
      state.fullscreen=false;state.post(NSWindow.didExitFullScreenNotification);pump()
      check("collection-restored-after-did-exit",state.restores==1)
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement();var results=[Bool]()
      placement.enter{results.append(success($0))};placement.failedToEnter();pump()
      check("delegate-failure-completes-with-error",results==[false] && state.restores==1)
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("late-entry-after-failure-cannot-authorize",results==[false])
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement(timeout:0.05);var results=[Bool]()
      placement.enter{results.append(success($0))};pump(0.09)
      check("timeout-completes-with-error",results==[false])
      var retry=[Bool]();placement.enter{retry.append(success($0))};pump()
      check("uncertain-transition-does-not-double-toggle",retry==[false] && state.toggles==1)
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("late-entry-after-timeout-cannot-authorize",results==[false])
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement();var results=[Bool]()
      let id=placement.enter{results.append(success($0))};placement.cancelPending(UUID());pump()
      check("unrelated-cancellation-ignored",results.isEmpty)
      placement.cancelPending(id);pump();check("matching-cancellation-completes-once",results==[false])
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("cancelled-late-entry-preserves-ui-without-success",results==[false] && state.fullscreen && state.toggles==1)
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement();var first=[Bool](),second=[Bool]()
      placement.enter{first.append(success($0))};placement.enter{second.append(success($0))};pump()
      check("concurrent-entry-fails-only-second-request",first.isEmpty && second==[false] && state.toggles==1)
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("first-entry-survives-busy-request",first==[true])
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement();var old=[Bool](),next=[Bool]()
      let id=placement.enter{old.append(success($0))};placement.cancelPending(id)
      placement.enter{next.append(success($0))};pump()
      check("retry-during-cancelled-animation-does-not-retoggle",old==[false] && next.isEmpty && state.toggles==1)
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("retry-can-use-completed-existing-transition",next==[true])
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement();var results=[Bool]()
      placement.enter{results.append(success($0))};placement.restore();pump()
      check("exit-during-entry-cancels-before-reversing",results==[false] && state.toggles==1)
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("exit-waits-for-entry-to-finish",state.toggles==2)
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement();state.fullscreen=true
      state.post(NSWindow.willExitFullScreenNotification);var results=[Bool]()
      placement.enter{results.append(success($0))};pump()
      check("entry-during-exit-cannot-use-stale-fullscreen-bit",results==[false] && state.toggles==0)
      placement.failedToExit();var retry=[Bool]()
      placement.enter{retry.append(success($0))};pump()
      check("failed-exit-can-reuse-still-fullscreen-window",retry==[true] && state.toggles==0)
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement();var results=[Bool]()
      placement.enter{results.append(success($0))};state.post(NSWindow.willCloseNotification);pump()
      check("window-close-cancels-pending-entry",results==[false])
    }
    do {
      let state=FullscreenDriverState(),placement=state.placement();var results=[Bool]()
      placement.enter{results.append(success($0))};state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("invalid-did-enter-without-fullscreen-is-rejected",results==[false])
    }
    let shim=directory.appendingPathComponent("own-fixture-shim")
    try Data("Not a dylib; consumed only by controlled fake host.\n".utf8).write(to:shim)
    func controller(_ state:FullscreenDriverState)->(HostedGamePresentationController,MetalCanvas,OffscreenFixtureWindow){
      let window=OffscreenFixtureWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:900,height:620));window.contentView=canvas
      let controller=HostedGamePresentationController(window:window,canvas:canvas,placement:state.placement())
      return(controller,canvas,window)
    }
    do {
      fixtureReset();let state=FullscreenDriverState();let (host,canvas,window)=controller(state)
      var callbacks=0,failed=false
      host.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("cancel.jsonl"),metalHUD:false){result in
        callbacks+=1;if case .failure=result{failed=true}
      }
      check("production-controller-keeps-canvas-before-space",fixtureCreateCount()==0 && canvas.releases==0 && window.contentView===canvas && !canvas.interactionEnabled)
      host.stop();pump()
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("cancel-before-space-never-creates-host",fixtureCreateCount()==0 && callbacks==1 && failed)
      check("cancel-restores-original-canvas-interaction",canvas.interactionEnabled && canvas.releases==0)
      _=window
    }
    do {
      fixtureReset();let state=FullscreenDriverState();let (host,canvas,window)=controller(state)
      var callbacks=0,lease:SessionGamePresentation?
      host.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("success.jsonl"),metalHUD:true,exclusive:true){result in
        callbacks+=1;if case .success(let value)=result{lease=value}
      }
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("host-lease-created-only-after-native-entry",fixtureCreateCount()==1 && callbacks==1 && lease?.keepLauncherWindow==true)
      check("existing-surface-default-preserved",fixtureTransportMode()==0 && fixtureDeviceRegistryID()==0 && fixtureHUDRequested()==1)
      check("surface-disables-child-native-hud",lease?.environment["MTL_HUD_ENABLED"]=="0" && lease?.environment["READY_HOSTED_GAME_TRANSPORT"]==nil)
      check("loading-keeps-rendered-canvas-overlay",canvas.superview != nil && canvas.releases==0 && !canvas.interactionEnabled)
      window.simulatedFullscreen=true
      fixturePresent()
      check("first-frame-removes-overlay-synchronously",canvas.superview==nil && canvas.releases==0)
      pump();check("graphics-release-occurs-after-frame-transaction",canvas.releases==1)
      check("eligible-first-frame-enables-pointer-request",fixturePointerEnabled()==1)
      state.post(NSWindow.willExitFullScreenNotification)
      NotificationCenter.default.post(name:NSWindow.willExitFullScreenNotification,object:window)
      check("will-exit-disables-pointer-before-transition",fixturePointerEnabled()==0)
      NotificationCenter.default.post(name:NSWindow.didChangeOcclusionStateNotification,object:window)
      check("occlusion-cannot-reenable-pointer-during-exit",fixturePointerEnabled()==0)
      // This is exactly the production delegate's failure callback ordering.
      host.fullscreenTransitionFailed()
      check("controller-reset-alone-cannot-bypass-placement-exit",fixturePointerEnabled()==0)
      // The actual placement object is private to the controller; construct it
      // explicitly below to test the real delegate ordering with both objects.
      host.stop();host.stop();pump()
      check("session-stop-preserves-fullscreen-space",state.fullscreen && state.toggles==1)
      check("session-stop-releases-host-once",fixtureStopCount()==1 && !host.active)
      check("session-stop-restores-canvas-interaction",canvas.interactionEnabled)
      let data=(try?Data(contentsOf:directory.appendingPathComponent("success.jsonl.placement.json"))) ?? Data("{}".utf8)
      let receipt=try JSONSerialization.jsonObject(with:data) as! [String:Any]
      check("legacy-capture-suppressed-by-native-space",receipt["displayCaptureUsed"] as? Bool==false && receipt["captureSuppressedForNativeSpace"] as? Bool==true)
      check("same-window-resource-preserved",receipt["windowResourcePreserved"] as? Bool==true)
      _=window
    }
    do {
      fixtureReset();let state=FullscreenDriverState(),placement=state.placement()
      let window=OffscreenFixtureWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:900,height:620));window.contentView=canvas
      let host=HostedGamePresentationController(window:window,canvas:canvas,placement:placement)
      host.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("failed-exit.jsonl"),metalHUD:false){_ in}
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      window.simulatedFullscreen=true;fixturePresent();pump()
      state.post(NSWindow.willExitFullScreenNotification)
      NotificationCenter.default.post(name:NSWindow.willExitFullScreenNotification,object:window)
      placement.failedToExit();host.fullscreenTransitionFailed()
      check("failed-exit-restores-pointer-request-in-eligible-fullscreen",fixturePointerEnabled()==1)
      host.stop();check("stop-disables-pointer-after-failed-exit",fixturePointerEnabled()==0)
    }
    do {
      fixtureReset();let state=FullscreenDriverState();let (host,canvas,window)=controller(state)
      var callbacks=0,lease:SessionGamePresentation?
      host.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("remote-success.jsonl"),metalHUD:true,exclusive:true,remoteLayer:true){result in
        callbacks+=1;if case .success(let value)=result{lease=value}
      }
      check("remote-waits-for-native-space-before-host",fixtureCreateCount()==0 && canvas.alphaValue==1 && canvas.layer?.opacity==1 && canvas.releases==0)
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("remote-uses-existing-scalar-device-identity",fixtureCreateCount()==1 && fixtureTransportMode()==1 && fixtureDeviceRegistryID()==42)
      check("remote-host-does-not-request-host-metal-hud",fixtureHUDRequested()==0)
      check("remote-native-game-hud-environment",lease?.environment["READY_HOSTED_GAME_TRANSPORT"]=="remote-layer" && lease?.environment["MTL_HUD_ENABLED"]=="1" && lease?.environment["MTL_HUD_LOG_ENABLED"]=="0" && lease?.environment["MTL_HUD_DISABLE_MENU_BAR"]=="1")
      check("remote-loading-keeps-original-canvas",callbacks==1 && lease?.keepLauncherWindow==true && canvas.superview===window.contentView && canvas.releases==0 && !canvas.interactionEnabled)
      check("remote-loading-translucent-view-and-layer",abs(canvas.alphaValue-0.999)<0.000001 && abs((canvas.layer?.opacity ?? 0)-0.999)<0.000001)
      check("remote-loading-does-not-capture-pointer",fixturePointerEnabled()==0)
      window.simulatedFullscreen=true;fixturePresent()
      check("remote-first-frame-removes-loading-cover",canvas.superview==nil && canvas.alphaValue==1 && canvas.layer?.opacity==1)
      check("remote-first-frame-defers-graphics-release",canvas.releases==0)
      pump();check("remote-release-after-handoff-enables-pointer",canvas.releases==1 && fixturePointerEnabled()==1)
      fixturePresent();pump();check("remote-duplicate-first-frame-is-idempotent",canvas.releases==1 && canvas.alphaValue==1 && canvas.layer?.opacity==1)
      state.post(NSWindow.willExitFullScreenNotification)
      NotificationCenter.default.post(name:NSWindow.willExitFullScreenNotification,object:window)
      check("remote-fullscreen-exit-disables-pointer",fixturePointerEnabled()==0)
      NotificationCenter.default.post(name:NSWindow.didChangeOcclusionStateNotification,object:window)
      check("remote-occlusion-cannot-undo-fullscreen-exit",fixturePointerEnabled()==0)
      host.stop();host.stop();pump()
      check("remote-stop-preserves-native-fullscreen-space",state.fullscreen && state.toggles==1 && state.restores==0)
      check("remote-stop-restores-canvas-and-releases-host-once",!host.active && fixtureStopCount()==1 && canvas.interactionEnabled && canvas.alphaValue==1 && canvas.layer?.opacity==1)
      _=window
    }
    do {
      fixtureReset();let state=FullscreenDriverState();let (host,canvas,window)=controller(state)
      var lease:SessionGamePresentation?
      host.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("remote-launch-failure.jsonl"),metalHUD:false,remoteLayer:true){result in
        if case .success(let value)=result{lease=value}
      }
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("remote-hud-off-is-propagated",lease?.environment["MTL_HUD_ENABLED"]=="0" && lease?.environment["READY_HOSTED_GAME_TRANSPORT"]=="remote-layer")
      check("remote-launch-pending-cover-is-translucent",abs(canvas.alphaValue-0.999)<0.000001 && abs((canvas.layer?.opacity ?? 0)-0.999)<0.000001 && canvas.superview != nil)
      // The session uses this same lease cleanup if the game fails to launch.
      lease?.stop();pump()
      check("remote-launch-failure-stop-restores-loading-canvas",canvas.alphaValue==1 && canvas.layer?.opacity==1 && canvas.interactionEnabled && canvas.superview==nil && canvas.releases==0)
      check("remote-launch-failure-never-exits-native-space",state.fullscreen && state.toggles==1 && fixtureStopCount()==1 && fixturePointerEnabled()==0 && !host.active)
      fixturePresent();pump();check("remote-stopped-host-cannot-deliver-late-first-frame",canvas.releases==0 && canvas.alphaValue==1 && canvas.layer?.opacity==1)
      _=window
    }
    do {
      fixtureReset();fixtureSetFailCreate(1);let state=FullscreenDriverState();let (host,canvas,window)=controller(state)
      canvas.alphaValue=0.8;canvas.layer?.opacity=0.7
      var callbacks=0,failed=false
      host.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("remote-create-failure.jsonl"),metalHUD:true,remoteLayer:true){result in
        callbacks+=1;if case .failure=result{failed=true}
      }
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump()
      check("remote-host-creation-failure-is-reported-once",callbacks==1 && failed && fixtureCreateCount()==1 && fixtureTransportMode()==1 && fixtureDeviceRegistryID()==42 && !host.active)
      check("remote-create-failure-preserves-original-canvas-properties",canvas.interactionEnabled && abs(canvas.alphaValue-0.8)<0.000001 && abs((canvas.layer?.opacity ?? 0)-0.7)<0.000001 && canvas.releases==0 && window.contentView===canvas)
      host.stop();pump();check("remote-create-failure-stop-does-not-alter-space",state.fullscreen && state.toggles==1 && fixtureStopCount()==0)
      _=window
    }
    do {
      fixtureReset();let state=FullscreenDriverState(),placement=state.placement()
      let window=OffscreenFixtureWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:900,height:620));window.contentView=canvas
      let app=AppDelegate();app.window=window;app.canvas=canvas
      var starts=0,ends=0,lease:SessionGamePresentation?
      let controller=HostedGamePresentationController(window:window,canvas:canvas,placement:placement,onShowInterface:{starts+=1;app.beginGameInterface(gameID:"fixture")},onHideInterface:{ends+=1;app.endGameInterface()},onInterfaceMove:{app.moveGameInterfaceSelection($0)},onInterfaceConfirm:{app.activateGameInterfaceSelection()})
      controller.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("actual-ui.jsonl"),metalHUD:false,remoteLayer:true){result in if case .success(let value)=result{lease=value}}
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump();window.simulatedFullscreen=true;fixturePresent();pump()
      let game=window.contentView!,number=window.windowNumber,windows=NSApp.windows.count,releaseAtStart=canvas.releases
      check("closed-interface-does-not-retain-ready-graphics",!controller.interfaceVisible && !canvas.renderResourcesActive && canvas.superview==nil && !canvas.gameInterfaceMode)
      weak var retiredRoot:NSView?,backdrop:NSView?
      autoreleasepool {
      lease?.overlay?.toggle()
      var root:NSView?=window.contentView;retiredRoot=root;backdrop=root?.subviews.first(where:{$0 !== game && $0 !== canvas})
      check("interface-reuses-identical-real-canvas",controller.interfaceVisible && canvas.superview===root && root!.subviews.contains(where:{$0===canvas}) && starts==1)
      check("interface-mounts-game-and-canvas-as-same-window-siblings",game.superview===root && canvas.window===window && game.window===window && window.windowNumber==number && NSApp.windows.count==windows)
      check("interface-uses-static-shade-instead-of-live-blur",backdrop != nil && !(backdrop is NSVisualEffectView) && backdrop?.layer?.contents==nil && root!.subviews.first===game && root!.subviews.last===canvas)
      check("interface-matches-window-bounds-and-backing",canvas.frame==root!.bounds && game.frame==root!.bounds && canvas.window?.backingScaleFactor==window.backingScaleFactor)
      check("interface-begins-real-ui-and-focuses-canvas",canvas.gameInterfaceMode && canvas.renderResourcesActive && canvas.resumes==1 && window.firstResponder===canvas)
      check("interface-gates-game-input-and-pointer",fixtureOverlayGate()==1 && fixturePointerEnabled()==0)
      lease?.overlay?.move(2);lease?.overlay?.confirm()
      check("interface-controller-routing-reuses-real-ui-callbacks",canvas.interfaceMoves==[2] && canvas.interfaceConfirms==1)
      lease?.overlay?.resume();pump()
      check("close-restores-exact-original-game-content-view",!controller.interfaceVisible && window.contentView===game && window.firstResponder===game && game.window===window)
      check("close-detaches-identical-ready-canvas-and-releases-graphics",canvas.superview==nil && !canvas.renderResourcesActive && !canvas.gameInterfaceMode && canvas.releases==releaseAtStart+1 && ends==1)
      check("close-releases-temporary-interface-tree",root!.subviews.isEmpty && backdrop?.superview==nil)
      root=nil
      }
      pump(0.24);check("closed-container-and-backdrop-are-not-retained",retiredRoot==nil && backdrop==nil)
      check("close-restores-game-input-and-same-space",fixtureOverlayGate()==0 && fixturePointerEnabled()==1 && state.fullscreen && state.toggles==1 && NSApp.windows.count==windows)
      lease?.overlay?.toggle();lease?.overlay?.resume();pump()
      check("repeated-open-close-reuses-canvas-with-balanced-resources",starts==2 && ends==2 && canvas.resumes==2 && canvas.releases==releaseAtStart+2 && !canvas.renderResourcesActive && window.contentView===game)
      lease?.overlay?.toggle();controller.stop();pump()
      check("stop-while-interface-open-restores-game-and-cleans-ui",!controller.active && !controller.interfaceVisible && window.contentView===game && canvas.superview==nil && !canvas.renderResourcesActive && fixtureStopCount()==1 && starts==3 && ends==3)
      check("stop-while-interface-open-preserves-native-space",state.fullscreen && state.toggles==1 && state.restores==0)
      _=window
    }
    do {
      let window=OffscreenFixtureWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled],backing:.buffered,defer:false);window.simulatedFullscreen=true
      var showed=0,hid=0,moved=[Int](),confirmed=0
      let shortcut=HostedGameOverlay(window:window,show:{showed+=1;return true},hide:{hid+=1},move:{moved.append($0)},confirm:{confirmed+=1})
      func event(_ code:UInt16,_ type:NSEvent.EventType = .keyDown,flags:NSEvent.ModifierFlags=[])->NSEvent{NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:1,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
      let opening=event(49,flags:[.control,.shift]);check("shortcut-opens-actual-interface-only",shortcut.filter(opening)==nil && shortcut.visible && showed==1)
      check("shortcut-release-is-consumed",shortcut.filter(event(49,.keyUp,flags:[.control,.shift]))==nil)
      for code:UInt16 in [0,125,126,36,48]{let press=event(code);check("ordinary-real-ui-key-\(code)-is-forwarded",shortcut.filter(press)===press);let release=event(code,.keyUp);check("ordinary-real-ui-release-\(code)-is-forwarded",shortcut.filter(release)===release)}
      shortcut.move(-1);shortcut.confirm();check("shortcut-controller-actions-dispatch-to-real-ui",moved==[-1] && confirmed==1)
      check("escape-hides-interface-and-consumes-release",shortcut.filter(event(53))==nil && !shortcut.visible && hid==1 && shortcut.filter(event(53,.keyUp))==nil)
      shortcut.stop();let stopped=event(49,flags:[.control,.shift]);check("stopped-shortcut-controller-leaves-normal-input-alone",shortcut.filter(stopped)===stopped && showed==1)
      _=window
    }
    do {
      fixtureReset();let state=FullscreenDriverState(),placement=state.placement()
      let window=OffscreenFixtureWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled],backing:.buffered,defer:false)
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:900,height:620));window.contentView=canvas
      var reference:HostedGamePresentationController?,lease:SessionGamePresentation?,ends=0
      let controller=HostedGamePresentationController(window:window,canvas:canvas,placement:placement,onShowInterface:{canvas.gameInterfaceMode=true;canvas.interactionEnabled=true;canvas.resumeGraphics();reference?.stop()},onHideInterface:{ends+=1;canvas.releaseGraphics();canvas.gameInterfaceMode=false})
      reference=controller;controller.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("reentrant-show.jsonl"),metalHUD:false,remoteLayer:true){result in if case .success(let value)=result{lease=value}}
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump();window.simulatedFullscreen=true;fixturePresent();pump();let game=window.contentView!
      lease?.overlay?.toggle();pump()
      check("reentrant-stop-during-show-restores-original-game",!controller.active && !controller.interfaceVisible && window.contentView===game && canvas.superview==nil && !canvas.renderResourcesActive && ends==1 && fixtureStopCount()==1)
      reference=nil;_=window
    }
    do {
      fixtureReset();let state=FullscreenDriverState(),placement=state.placement()
      let window=OffscreenFixtureWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled],backing:.buffered,defer:false)
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:900,height:620));window.contentView=canvas
      var reference:HostedGamePresentationController?,lease:SessionGamePresentation?
      let controller=HostedGamePresentationController(window:window,canvas:canvas,placement:placement,onShowInterface:{canvas.gameInterfaceMode=true;canvas.interactionEnabled=true;canvas.resumeGraphics()},onHideInterface:{canvas.releaseGraphics();canvas.gameInterfaceMode=false;reference?.stop()})
      reference=controller;controller.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("reentrant-hide.jsonl"),metalHUD:false,remoteLayer:true){result in if case .success(let value)=result{lease=value}}
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump();window.simulatedFullscreen=true;fixturePresent();pump();let game=window.contentView!
      lease?.overlay?.toggle();lease?.overlay?.resume();pump()
      check("reentrant-stop-during-hide-restores-original-game",!controller.active && !controller.interfaceVisible && window.contentView===game && canvas.superview==nil && !canvas.renderResourcesActive && fixtureStopCount()==1)
      reference=nil;_=window
    }
    func ownImage()->CGImage {
      let context=CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.setFillColor(CGColor(red:0.1,green:0.2,blue:0.3,alpha:1));context.fill(CGRect(x:0,y:0,width:4,height:4));return context.makeImage()!
    }
    do {
      fixtureReset();let state=FullscreenDriverState(),placement=state.placement()
      let window=OffscreenFixtureWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled],backing:.buffered,defer:false)
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:900,height:620));window.contentView=canvas
      var requests=[(@MainActor(CGImage?)->Void)](),lease:SessionGamePresentation?,showed=0,hidden=0,captureBeforeMount=true
      let controller=HostedGamePresentationController(window:window,canvas:canvas,placement:placement,onShowInterface:{showed+=1;canvas.interactionEnabled=true;canvas.gameInterfaceMode=true;canvas.resumeGraphics()},onHideInterface:{hidden+=1;canvas.releaseGraphics();canvas.gameInterfaceMode=false},captureBackdrop:{captured,completion in captureBeforeMount = captureBeforeMount && captured===window && captured.contentView?.subviews.contains(where:{$0===canvas})==false;requests.append(completion)})
      controller.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("controlled-capture.jsonl"),metalHUD:false,remoteLayer:true){result in if case .success(let value)=result{lease=value}}
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump();window.simulatedFullscreen=true;fixturePresent();pump();let game=window.contentView!,number=window.windowNumber
      lease?.overlay?.toggle()
      check("snapshot-is-requested-before-ui-mount",requests.count==1 && captureBeforeMount && controller.interfaceVisible && window.contentView===game && canvas.superview==nil && showed==0 && fixtureOverlayGate()==1)
      lease?.overlay?.resume();check("cancel-pending-capture-restores-game-window-and-input",!controller.interfaceVisible && window.contentView===game && game.window===window && fixtureOverlayGate()==0 && !canvas.renderResourcesActive)
      let image=ownImage();requests[0](image);pump();check("late-capture-after-hide-cannot-open-ui",showed==0 && !controller.interfaceVisible && window.contentView===game && canvas.superview==nil)
      lease?.overlay?.toggle();check("reopen-starts-independent-capture",requests.count==2 && showed==0 && controller.interfaceVisible)
      requests[0](image);check("previous-generation-capture-cannot-complete-reopen",showed==0 && window.contentView===game)
      requests[1](image)
      let currentRoot=window.contentView!,backdrop=currentRoot.subviews.first(where:{$0 !== game && $0 !== canvas})
      check("successful-capture-mounts-identical-real-ui-once",showed==1 && canvas.superview===currentRoot && canvas.renderResourcesActive && window.windowNumber==number)
      check("successful-capture-uses-static-image-no-visual-effect",backdrop != nil && !(backdrop is NSVisualEffectView) && (backdrop?.layer?.contents as AnyObject?)===image && !currentRoot.subviews.contains(where:{$0 is NSVisualEffectView}))
      requests[1](nil);check("duplicate-completion-cannot-replace-first-image",showed==1 && window.contentView===currentRoot && (backdrop?.layer?.contents as AnyObject?)===image)
      lease?.overlay?.resume();pump();check("hide-clears-image-and-releases-ready-graphics",backdrop?.layer?.contents==nil && backdrop?.superview==nil && canvas.superview==nil && !canvas.renderResourcesActive && window.contentView===game)
      lease?.overlay?.toggle();check("stop-test-has-a-pending-third-capture",requests.count==3 && controller.interfaceVisible)
      controller.stop();requests[2](image);pump();check("late-capture-after-stop-cannot-resurrect-ui",!controller.active && !controller.interfaceVisible && window.contentView===game && game.window===window && canvas.superview==nil && !canvas.renderResourcesActive && showed==1 && hidden==3 && fixtureStopCount()==1)
      _=window
    }
    do {
      fixtureReset();let state=FullscreenDriverState(),placement=state.placement()
      let window=OffscreenFixtureWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled],backing:.buffered,defer:false)
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:900,height:620));window.contentView=canvas
      var pending:(@MainActor(CGImage?)->Void)?,lease:SessionGamePresentation?,showed=0
      let controller=HostedGamePresentationController(window:window,canvas:canvas,placement:placement,onShowInterface:{showed+=1;canvas.interactionEnabled=true;canvas.resumeGraphics()},onHideInterface:{canvas.releaseGraphics()},captureBackdrop:{_,completion in pending=completion})
      controller.prepare(executable:URL(fileURLWithPath:"/usr/bin/true"),shim:shim,diagnostics:directory.appendingPathComponent("capture-timeout.jsonl"),metalHUD:false,remoteLayer:true){result in if case .success(let value)=result{lease=value}}
      state.fullscreen=true;state.post(NSWindow.didEnterFullScreenNotification);pump();window.simulatedFullscreen=true;fixturePresent();pump();let game=window.contentView!
      lease?.overlay?.toggle();pump(1.65)
      let root=window.contentView!,backdrop=root.subviews.first(where:{$0 !== game && $0 !== canvas})
      check("capture-watchdog-opens-real-ui-with-cheap-shade",showed==1 && controller.interfaceVisible && canvas.superview===root && backdrop?.layer?.contents==nil && !(backdrop is NSVisualEffectView) && abs((backdrop?.layer?.backgroundColor?.alpha ?? 0)-0.55)<0.00001)
      pending?(ownImage());pump();check("late-image-after-timeout-is-ignored",showed==1 && window.contentView===root && backdrop?.layer?.contents==nil)
      lease?.overlay?.resume();controller.stop();check("timeout-fallback-closes-without-persistent-ui-resources",!canvas.renderResourcesActive && canvas.superview==nil && window.contentView===game && fixtureStopCount()==1)
      _=window
    }
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,
      "fixtureOnly":true,"realSpaceTransitionPerformed":false,"displayCaptureUsed":false,"accountOrGameOrSDKUsed":false,
      "scope":"actual Swift placement/controller with controlled notification driver and host C fixture; no shown window, actual Space, input, GPU or display capture"]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]);FileHandle.standardOutput.write(data)
    if !checks.values.allSatisfy({$0}){exit(1)}
  }
  static func main(){
    _=FixtureApplication.shared;NSApp.setActivationPolicy(.prohibited)
    guard CommandLine.arguments.count==2 else{exit(64)}
    do{try MainActor.assumeIsolated{try run(URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true))}}
    catch{FileHandle.standardError.write(Data("Own fullscreen fixture failed.\n".utf8));exit(1)}
  }
}
