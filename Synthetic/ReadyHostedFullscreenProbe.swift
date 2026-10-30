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
