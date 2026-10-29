// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import LauncherCore
import ReadyHostedView
import QuartzCore

/// Native AppKit fullscreen belongs to Ready, rather than to one game. A
/// completed/failed game returns to the same NSWindow in the same fullscreen
/// Space. Display capture, shielding levels and manual display-fill are not used.
@MainActor final class HostedWindowPlacement {
  /// This small driver makes the real notification/cancellation state machine
  /// testable without taking a display or changing an actual macOS Space.
  struct Driver {
    let notificationObject:AnyObject
    let isFullscreen:()->Bool
    let configure:()->Void
    let toggle:()->Void
    let restore:()->Void
  }
  enum Failure:Error {case busy,failed,timeout,cancelled,closed}
  private let driver:Driver
  private let center:NotificationCenter
  private let timeout:TimeInterval
  private var observers=[NSObjectProtocol]()
  private var deadline:DispatchWorkItem?
  private var pending:(id:UUID,completion:(Result<Void,Error>)->Void)?
  private var entering=false
  private var exiting=false
  private var uncertainTransition=false
  private var exitRequested=false
  var isFullscreen:Bool {driver.isFullscreen() && !entering && !exiting}
  var isFullscreenOrEntering:Bool {driver.isFullscreen() || entering || exiting}

  convenience init(window:NSWindow){
    let collection=window.collectionBehavior
    self.init(driver:Driver(notificationObject:window,
      isFullscreen:{[weak window] in window?.styleMask.contains(.fullScreen)==true},
      configure:{[weak window] in
        guard let window else{return}
        var behavior=window.collectionBehavior
        behavior.subtract([.fullScreenAuxiliary,.fullScreenNone,.canJoinAllSpaces,.moveToActiveSpace,.fullScreenAllowsTiling])
        behavior.formUnion([.fullScreenPrimary,.fullScreenDisallowsTiling])
        window.collectionBehavior=behavior
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true
        window.isOpaque=true;window.backgroundColor = .black
      },
      toggle:{[weak window] in window?.toggleFullScreen(nil)},
      restore:{[weak window] in window?.collectionBehavior=collection}))
  }
  init(driver:Driver,center:NotificationCenter = .default,timeout:TimeInterval=10){
    self.driver=driver;self.center=center;self.timeout=timeout
    observe(NSWindow.willEnterFullScreenNotification){[weak self] in self?.entering=true}
    observe(NSWindow.didEnterFullScreenNotification){[weak self] in
      guard let self else{return}
      self.entering=false;self.exiting=false;self.uncertainTransition=false
      guard self.driver.isFullscreen() else{self.complete(.failure(Failure.failed));return}
      if self.exitRequested {
        self.complete(.failure(Failure.cancelled))
        DispatchQueue.main.async{[weak self] in self?.toggleExitIfNeeded()}
      }else{self.complete(.success(()))}
    }
    observe(NSWindow.willExitFullScreenNotification){[weak self] in self?.exiting=true}
    observe(NSWindow.didExitFullScreenNotification){[weak self] in
      guard let self else{return}
      self.entering=false;self.exiting=false;self.uncertainTransition=false;self.exitRequested=false
      self.driver.restore();self.complete(.failure(Failure.cancelled))
    }
    observe(NSWindow.willCloseNotification){[weak self] in self?.complete(.failure(Failure.closed))}
  }
  deinit{deadline?.cancel();for observer in observers{center.removeObserver(observer)}}
  private func observe(_ name:Notification.Name,_ body:@escaping()->Void){
    observers.append(center.addObserver(forName:name,object:driver.notificationObject,queue:.main){_ in
      MainActor.assumeIsolated{body()}
    })
  }
  @discardableResult func enter(completion:@escaping(Result<Void,Error>)->Void)->UUID {
    let id=UUID()
    guard pending==nil,!exitRequested,!uncertainTransition,!exiting else{
      DispatchQueue.main.async{completion(.failure(Failure.busy))};return id
    }
    pending=(id,completion)
    if driver.isFullscreen(),!entering{complete(.success(()));return id}
    driver.configure()
    let deadline=DispatchWorkItem{[weak self] in
      guard let self,self.pending?.id==id else{return}
      self.uncertainTransition=self.entering
      self.complete(.failure(Failure.timeout))
    }
    self.deadline=deadline
    DispatchQueue.main.asyncAfter(deadline:.now()+timeout,execute:deadline)
    if !entering{entering=true;driver.toggle()}
    return id
  }
  func cancelPending(_ id:UUID?){
    guard let id,pending?.id==id else{return};complete(.failure(Failure.cancelled))
  }
  /// NSWindowDelegate supplies failures; AppKit has no matching failure
  /// notification. A failed transition never authorizes host creation.
  func failedToEnter(){
    entering=false;uncertainTransition=false;exitRequested=false
    driver.restore();complete(.failure(Failure.failed))
  }
  func failedToExit(){exiting=false;exitRequested=false}
  /// Explicit fullscreen exit. A transition already in flight must finish before
  /// asking AppKit to reverse it; cancelling a game alone does not exit Ready.
  func restore(){
    if exitRequested{return};exitRequested=true
    complete(.failure(Failure.cancelled))
    if !entering && !exiting{toggleExitIfNeeded()}
  }
  private func toggleExitIfNeeded(){
    guard exitRequested else{return}
    if driver.isFullscreen(){driver.toggle()}
    else{exitRequested=false;driver.restore()}
  }
  private func complete(_ result:Result<Void,Error>){
    guard let pending else{return};self.pending=nil
    deadline?.cancel();deadline=nil
    DispatchQueue.main.async{pending.completion(result)}
  }
}

/// Experimental direct-drawable presentation in the launcher's existing window.
/// This controller never starts/authenticates a game or adopts another window.
@MainActor final class HostedGamePresentationController {
  private weak var window:NSWindow?
  private weak var canvas:MetalCanvas?
  private var handle:RHGHostRef?
  private var pending:((Result<SessionGamePresentation?,Error>)->Void)?
  private var activating=false
  private let placement:HostedWindowPlacement
  private weak var hostView:NSView?
  private(set) var isLoading=true
  private var transitionGeneration=UUID()
  private var exclusiveRequested=false
  private var placementRequest:UUID?
  private var pointerObservers=[NSObjectProtocol]()
  private var fullscreenTransitioning=false
  private var diagnostics:URL?
  private var onFailure:((Error)->Void)?
  private var captureFacts=[String:Any]()
  private var previousCanvasInteraction:Bool?
  var active:Bool { handle != nil }
  init(window:NSWindow,canvas:MetalCanvas,placement:HostedWindowPlacement,onFailure:((Error)->Void)?=nil){
    self.window=window;self.canvas=canvas;self.placement=placement;self.onFailure=onFailure
  }

  func prepare(executable:URL,shim:URL,diagnostics:URL,metalHUD:Bool,exclusive:Bool=false,
               completion:@escaping(Result<SessionGamePresentation?,Error>)->Void) {
    guard pending==nil,handle==nil,let window else {
      completion(.failure(LauncherError.busy));return
    }
    guard executable.path.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:executable.path),
      shim.path.hasPrefix("/"),FileManager.default.fileExists(atPath:shim.path) else {
      completion(.failure(LauncherError.unavailable("Il prototipo della finestra condivisa non è installato.")));return
    }
    let digest:String
    do{digest=try Self.hash(shim)}catch{completion(.failure(error));return}
    self.diagnostics=diagnostics;self.exclusiveRequested=exclusive
    if let canvas{previousCanvasInteraction=canvas.interactionEnabled;canvas.interactionEnabled=false}
    pending=completion
    let originalWindowNumber=window.windowNumber
    let activate={ [weak self] in
      guard let self,!self.activating,self.pending != nil,let window=self.window else{return}
      guard self.placement.isFullscreen else{
        self.finish(.failure(LauncherError.unavailable("Ready ha lasciato lo Space a schermo intero prima dell’avvio.")));return
      }
      self.activating=true;self.placementRequest=nil
      let placement:[String:Any] = ["schema":1,"mode":"existing-window-native-fullscreen-space",
        "windowBefore":originalWindowNumber,"windowAfter":window.windowNumber,
        "windowResourcePreserved":originalWindowNumber==window.windowNumber,
        "nativeFullscreenSpace":window.styleMask.contains(.fullScreen),
        "coversDisplay":window.screen.map{window.frame==($0.frame)} ?? false,
        "displayCaptureUsed":false,"captureSuppressedForNativeSpace":exclusive]
      if let data=try?JSONSerialization.data(withJSONObject:placement,options:[.sortedKeys]) {
        try?AtomicFile.writePrivate(data,to:diagnostics.appendingPathExtension("placement.json"))
      }
      guard let host=RHGHostCreate(Unmanaged.passUnretained(window).toOpaque(),metalHUD,executable.path,diagnostics.path) else {
        self.finish(.failure(LauncherError.unavailable("La superficie diretta di Ready non è disponibile.")));return
      }
      guard let rawView=RHGHostGetView(host),let service=RHGHostService(host),let nonce=RHGHostNonce(host) else{
        RHGHostStop(host);RHGHostDestroy(host)
        self.finish(.failure(LauncherError.unavailable("La superficie diretta di Ready non è disponibile.")));return
      }
      self.handle=host
      self.armPointerObservers()
      RHGHostSetFirstFrameCallback(host,Unmanaged.passUnretained(self).toOpaque(),{context in
        guard let context else{return}
        MainActor.assumeIsolated {
          Unmanaged<HostedGamePresentationController>.fromOpaque(context).takeUnretainedValue().firstFrame()
        }
      })
      let view=Unmanaged<NSView>.fromOpaque(rawView).takeUnretainedValue()
      view.frame=window.contentView?.bounds ?? window.contentLayoutRect
      view.autoresizingMask=[.width,.height]
      view.layer?.cornerRadius=0;view.layer?.maskedCorners=[]
      window.contentView=view;window.acceptsMouseMovedEvents=true;window.makeFirstResponder(nil)
      self.hostView=view
      // Keep the existing rendered launcher above the host layer until the
      // first validated, GPU-complete PRESENT can replace it atomically.
      if let canvas=self.canvas {
        canvas.frame=view.bounds;canvas.autoresizingMask=[.width,.height]
        view.addSubview(canvas)
      }
      window.makeKeyAndOrderFront(nil)
      view.layoutSubtreeIfNeeded();window.displayIfNeeded();CATransaction.flush()
      let environment=["READY_HOSTED_GAME_SERVICE":String(cString:service),
        "READY_HOSTED_GAME_NONCE":String(cString:nonce),"MTL_HUD_ENABLED":"0"]
      let lease=SessionGamePresentation(environment:environment,shim:shim,shimSHA256:digest,
        keepLauncherWindow:true,stop:{[weak self]in MainActor.assumeIsolated{self?.stop()}})
      self.finish(.success(lease))
    }
    placementRequest=placement.enter{[weak self] result in
      guard let self,self.pending != nil else{return}
      switch result {
      case .success:activate()
      case .failure:
        self.recordCapture(phase:"fullscreen-space-failed")
        self.finish(.failure(LauncherError.unavailable("Ready non è riuscito a entrare nel proprio Space a schermo intero. Riprova al termine della transizione.")))
      }
    }
  }

  func resize(){if let handle{RHGHostResize(handle)}}
  /// Called inside the C host's first validated PRESENT transaction, after the
  /// guest's GPU work has completed. No waiting, hashing or capture is allowed
  /// here: hiding the UI and committing the host surface must stay one handoff.
  private func firstFrame(){
    guard isLoading,handle != nil else{return}
    isLoading=false
    if let canvas,canvas.superview === hostView{canvas.removeFromSuperview()}
    if let hostView{window?.makeFirstResponder(hostView)}
    let generation=transitionGeneration
    DispatchQueue.main.async{[weak self] in
      guard let self,self.transitionGeneration==generation,self.handle != nil,!self.isLoading else{return}
      // The C CATransaction has now committed. releaseGraphics may wait for the
      // old canvas command buffer, so it deliberately runs outside that commit.
      self.canvas?.releaseGraphics()
      self.captureFacts["firstValidPresentReceived"]=true
      self.recordCapture(phase:"first-valid-present")
      self.updatePointer()
    }
  }
  /// Explicit fullscreen exit uses AppKit's native Space transition. It does
  /// not capture/release a display or change the window's shielding level.
  func leaveFullscreen(){
    fullscreenTransitioning=true
    if let handle{RHGHostSetPointerEnabled(handle,false)}
    placement.restore()
  }
  func fullscreenTransitionFailed(){
    fullscreenTransitioning=false
    updatePointer()
  }
  func stop(preserveFullscreen:Bool=true){
    transitionGeneration=UUID()
    placement.cancelPending(placementRequest);placementRequest=nil
    removePointerObservers()
    restoreCanvasInteraction()
    if let canvas,canvas.superview === hostView{canvas.removeFromSuperview()}
    if let handle{
      RHGHostSetPointerEnabled(handle,false)
      RHGHostSetFirstFrameCallback(handle,nil,nil)
      RHGHostStop(handle);RHGHostDestroy(handle);self.handle=nil
    }
    hostView=nil
    if pending != nil{finish(.failure(LauncherError.failed("Presentazione condivisa annullata.")))}
    if !preserveFullscreen{placement.restore()}
  }
  private func armPointerObservers(){
    let center=NotificationCenter.default
    for name in [NSApplication.didBecomeActiveNotification,NSApplication.didResignActiveNotification,
      NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,
      NSWindow.willEnterFullScreenNotification,NSWindow.willExitFullScreenNotification,NSWindow.didExitFullScreenNotification,
      NSWindow.didEnterFullScreenNotification,NSWindow.didChangeOcclusionStateNotification] {
      let object:AnyObject? = (name==NSApplication.didBecomeActiveNotification || name==NSApplication.didResignActiveNotification) ? NSApp:window
      pointerObservers.append(center.addObserver(forName:name,object:object,queue:.main){[weak self] notification in
        MainActor.assumeIsolated {
          if notification.name==NSWindow.willExitFullScreenNotification || notification.name==NSWindow.willEnterFullScreenNotification {
            self?.fullscreenTransitioning=true
            if let handle=self?.handle{RHGHostSetPointerEnabled(handle,false)}
          }else{
            if notification.name==NSWindow.didEnterFullScreenNotification || notification.name==NSWindow.didExitFullScreenNotification{self?.fullscreenTransitioning=false}
            self?.updatePointer()
          }
        }
      })
    }
    for name in [NSWorkspace.sessionDidResignActiveNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
      pointerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main){[weak self] notification in
        MainActor.assumeIsolated {
          if notification.name==NSWorkspace.sessionDidResignActiveNotification {
            if let handle=self?.handle{RHGHostSetPointerEnabled(handle,false)}
          }else{self?.updatePointer()}
        }
      })
    }
    pointerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main){[weak self] _ in
        MainActor.assumeIsolated{self?.updatePointer()}
      })
  }
  private func updatePointer(){
    guard let handle else{return}
    let enabled = !isLoading && !fullscreenTransitioning && placement.isFullscreen && window?.styleMask.contains(.fullScreen)==true
      && window?.isOnActiveSpace==true && window?.isKeyWindow==true && NSApp.isActive
    RHGHostSetPointerEnabled(handle,enabled)
  }
  private func removePointerObservers(){
    for observer in pointerObservers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    pointerObservers.removeAll()
  }
  private func restoreCanvasInteraction(){
    if let previousCanvasInteraction{canvas?.interactionEnabled=previousCanvasInteraction;self.previousCanvasInteraction=nil}
  }
  private func recordCapture(phase:String){
    guard let diagnostics else{return}
    var facts=captureFacts
    facts["schema"]=1;facts["phase"]=phase;facts["exclusiveRequested"]=exclusiveRequested
    facts["nativeFullscreenSpace"]=window?.styleMask.contains(.fullScreen)==true
    facts["displayCaptureUsed"]=false;facts["captureSuppressedForNativeSpace"]=exclusiveRequested
    // Native fullscreen Space and pointer confinement are separate from display
    // exclusivity and from addPresentedHandler's on-glass observation.
    facts["directDisplayVerified"]=false;facts["onGlassVerified"]=false
    if let data=try?JSONSerialization.data(withJSONObject:facts,options:[.sortedKeys]){
      try?AtomicFile.writePrivate(data,to:diagnostics.appendingPathExtension("display.json"))
    }
  }
  private func finish(_ result:Result<SessionGamePresentation?,Error>){
    guard let callback=pending else{return};pending=nil
    if case .failure=result{restoreCanvasInteraction()}
    callback(result)
  }
  private static func hash(_ path:URL)throws->String {
    let input=try FileHandle(forReadingFrom:path);defer{try?input.close()}
    var hash=SHA256()
    while let data=try input.read(upToCount:1024*1024),!data.isEmpty{hash.update(data:data)}
    return hash.finalize().map{String(format:"%02x",$0)}.joined()
  }
}

extension AppDelegate {
  @MainActor func prepareHostedGamePresentation(game:Game,variant:GameVariant,sessionID:UUID,
      completion:@escaping(Result<SessionGamePresentation?,Error>)->Void) {
    let args=CommandLine.arguments
    guard let index=args.firstIndex(of:"--host-game-view"),args.indices.contains(index+1),
      args[index+1]==game.storeID else{completion(.success(nil));return}
    guard variant.platform == .macOS,let raw=variant.executable else {
      completion(.failure(LauncherError.unavailable("Il prototipo della finestra condivisa richiede un gioco macOS nativo.")));return
    }
    do {
      let entry=URL(fileURLWithPath:raw)
      let executable=entry.pathExtension.lowercased()=="app" ? try NativeBinaryProbe.applicationExecutable(entry):entry
      try FileManager.default.createDirectory(at:paths.logs,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
      let placement=hostedWindowPlacement ?? HostedWindowPlacement(window:window)
      hostedWindowPlacement=placement
      let controller=HostedGamePresentationController(window:window,canvas:canvas,placement:placement,
        onFailure:{[weak self] error in self?.showError(error);self?.session?.quit()})
      hostedPresentation=controller
      let shim:URL
      if let index=args.firstIndex(of:"--host-game-shim"),args.indices.contains(index+1),args[index+1].hasPrefix("/") {
        shim=URL(fileURLWithPath:args[index+1])
      }else{shim=project.appendingPathComponent("Build/libReadyHostedGame.dylib")}
      controller.prepare(executable:executable,shim:shim,
        diagnostics:paths.logs.appendingPathComponent("hosted-game-"+sessionID.uuidString.lowercased()+".jsonl"),
        metalHUD:args.contains("--metal-hud"),exclusive:args.contains("--exclusive-hosted-view"),completion:completion)
    }catch{completion(.failure(error))}
  }
}
