// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import LauncherCore
import ReadyHostedView
import QuartzCore
import CoreGraphics

/// Display-fill placement belongs to Ready, rather than to one game. Keeping it
/// outside the presentation controller lets a failed/finished game return to
/// the same fullscreen launcher instead of exposing the Dock between attempts.
@MainActor final class HostedWindowPlacement {
  private weak var window:NSWindow?
  private let originalFrame:NSRect
  private let originalPresentation:NSApplication.PresentationOptions
  private let originallyNativeFullscreen:Bool
  private var windowButtons=[(NSButton,Bool)]()
  private(set) var isDisplayFill=false

  init(window:NSWindow){
    self.window=window;originalFrame=window.frame
    originalPresentation=NSApp.presentationOptions
    originallyNativeFullscreen=window.styleMask.contains(.fullScreen)
  }
  func fill(){
    guard !isDisplayFill,let window,let screen=window.screen ?? NSScreen.main else{return}
    for kind:NSWindow.ButtonType in [.closeButton,.miniaturizeButton,.zoomButton] {
      if let button=window.standardWindowButton(kind){windowButtons.append((button,button.isHidden));button.isHidden=true}
    }
    isDisplayFill=true
    window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    var options=NSApp.presentationOptions
    options.subtract([.autoHideDock,.autoHideMenuBar,.autoHideToolbar])
    options.formUnion([.hideDock,.hideMenuBar])
    NSApp.presentationOptions=options
    if !originallyNativeFullscreen{window.setFrame(screen.frame,display:true,animate:false)}
    window.layoutIfNeeded()
  }
  /// Only an explicit fullscreen exit or application termination restores the
  /// pre-experiment placement. Normal session teardown deliberately does not.
  func restore(){
    guard isDisplayFill else{return};isDisplayFill=false
    NSApp.presentationOptions=originalPresentation
    for (button,hidden) in windowButtons{button.isHidden=hidden};windowButtons.removeAll()
    if !originallyNativeFullscreen,let window{window.setFrame(originalFrame,display:true,animate:false)}
  }
}

/// Experimental direct-drawable presentation in the launcher's existing window.
/// This controller never starts/authenticates a game or adopts another window.
@MainActor final class HostedGamePresentationController {
  private weak var window:NSWindow?
  private weak var canvas:MetalCanvas?
  private var handle:RHGHostRef?
  private var observers=[NSObjectProtocol]()
  private var deadline:DispatchWorkItem?
  private var pending:((Result<SessionGamePresentation?,Error>)->Void)?
  private var activating=false
  private let placement:HostedWindowPlacement
  private weak var hostView:NSView?
  private(set) var isLoading=true
  private var transitionGeneration=UUID()
  private var exclusive=false
  private var exclusiveRequested=false
  private var capturedDisplay:CGDirectDisplayID?
  private var originalWindowLevel:NSWindow.Level?
  private var captureObservers=[NSObjectProtocol]()
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
    self.diagnostics=diagnostics;self.exclusive=exclusive;self.exclusiveRequested=exclusive
    if let canvas{previousCanvasInteraction=canvas.interactionEnabled;canvas.interactionEnabled=false}
    if exclusive{armCaptureObservers()}
    pending=completion
    let originalWindowNumber=window.windowNumber
    let activate={ [weak self] in
      guard let self,!self.activating,self.pending != nil,let window=self.window else{return}
      self.activating=true;self.removeObservers()
      let placement:[String:Any] = ["schema":1,"mode":"existing-window-display-fill",
        "windowBefore":originalWindowNumber,"windowAfter":window.windowNumber,
        "windowResourcePreserved":originalWindowNumber==window.windowNumber,
        "nativeFullscreenSpace":window.styleMask.contains(.fullScreen),
        "coversDisplay":window.screen.map{window.frame==($0.frame)} ?? false]
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
      RHGHostSetFirstFrameCallback(host,Unmanaged.passUnretained(self).toOpaque(),{context in
        guard let context else{return}
        MainActor.assumeIsolated {
          Unmanaged<HostedGamePresentationController>.fromOpaque(context).takeUnretainedValue().firstFrame()
        }
      })
      let view=Unmanaged<NSView>.fromOpaque(rawView).takeUnretainedValue()
      view.frame=window.contentView?.bounds ?? window.contentLayoutRect
      view.autoresizingMask=[.width,.height]
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
    placement.fill()
    DispatchQueue.main.async{activate()}
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
      if self.exclusive{self.captureDisplay()}
    }
  }
  /// Explicit fullscreen exit releases exclusive ownership immediately while
  /// leaving the hosted game in this same window until normal session teardown.
  func leaveFullscreen(){exclusive=false;removeCaptureObservers();releaseCapture();placement.restore()}
  func stop(preserveFullscreen:Bool=true){
    transitionGeneration=UUID()
    exclusive=false
    removeCaptureObservers()
    releaseCapture()
    restoreCanvasInteraction()
    if let canvas,canvas.superview === hostView{canvas.removeFromSuperview()}
    if let handle{
      RHGHostSetFirstFrameCallback(handle,nil,nil)
      RHGHostStop(handle);RHGHostDestroy(handle);self.handle=nil
    }
    hostView=nil
    if pending != nil{finish(.failure(LauncherError.failed("Presentazione condivisa annullata.")))}
    removeObservers()
    if !preserveFullscreen{placement.restore()}
  }
  private func captureDisplay(){
    guard exclusive,handle != nil,!isLoading,capturedDisplay==nil else{return}
    guard let window,NSApp.isActive,window.isKeyWindow,
      NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid(),
      let number=window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let session=CGSessionCopyCurrentDictionary() as? [String:Any],
      (session[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue==true,
      (session[kCGSessionLoginDoneKey as String] as? NSNumber)?.boolValue==true else{
      captureFacts["deferredReason"]="inactive-console";recordCapture(phase:"capture-deferred");return
    }
    let display=CGDirectDisplayID(number.uint32Value)
    let before=window.windowNumber
    let shieldLevel=CGShieldingWindowLevel()
    originalWindowLevel=window.level
    captureFacts["windowLevelBefore"]=window.level.rawValue
    // Keep the existing, already-presenting window above the shield before
    // capture creates it, avoiding a black shield between visible frames.
    window.level=NSWindow.Level(rawValue:Int(shieldLevel)+1)
    captureFacts["windowLevelAfter"]=window.level.rawValue
    let result=CGDisplayCaptureWithOptions(display,.noFill)
    captureFacts["displayID"]=display;captureFacts["captureResult"]=result.rawValue
    captureFacts["windowBefore"]=before;captureFacts["windowAfter"]=window.windowNumber
    captureFacts["windowResourcePreserved"]=before==window.windowNumber
    guard result == .success else{failCapture(reason:"capture-rejected");return}
    capturedDisplay=display
    let shield=CGShieldingWindowID(display)
    captureFacts["shieldingWindowID"]=shield;captureFacts["shieldingWindowLevel"]=shieldLevel
    guard shield != 0 else{failCapture(reason:"shield-unavailable");return}
    guard NSApp.isActive,window.isKeyWindow,
      NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() else{
      suspendCapture(reason:"application-inactive");return
    }
    window.makeKeyAndOrderFront(nil)
    captureFacts.removeValue(forKey:"deferredReason")
    recordCapture(phase:"display-captured")
  }
  private func armCaptureObservers(){
    guard captureObservers.isEmpty else{return}
    captureObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main){[weak self] _ in
        MainActor.assumeIsolated{self?.suspendCapture(reason:"console-inactive")}
      })
    captureObservers.append(NotificationCenter.default.addObserver(
      forName:NSApplication.didResignActiveNotification,object:NSApp,queue:.main){[weak self] _ in
        MainActor.assumeIsolated{self?.suspendCapture(reason:"application-inactive")}
      })
    captureObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main){[weak self] _ in
        MainActor.assumeIsolated{self?.captureDisplay()}
      })
    captureObservers.append(NotificationCenter.default.addObserver(
      forName:NSApplication.didBecomeActiveNotification,object:NSApp,queue:.main){[weak self] _ in
        MainActor.assumeIsolated{self?.captureDisplay()}
      })
    captureObservers.append(NotificationCenter.default.addObserver(
      forName:NSWindow.didBecomeKeyNotification,object:window,queue:.main){[weak self] _ in
        MainActor.assumeIsolated{self?.captureDisplay()}
      })
  }
  private func suspendCapture(reason:String){
    guard exclusive else{return}
    releaseCapture();captureFacts["deferredReason"]=reason
    recordCapture(phase:"capture-suspended")
  }
  private func failCapture(reason:String){
    guard exclusive else{return};exclusive=false
    removeCaptureObservers()
    captureFacts["failure"]=reason
    releaseCapture();recordCapture(phase:"capture-failed")
    onFailure?(LauncherError.unavailable("Ready non ha ottenuto il controllo esclusivo del display. La sessione viene chiusa."))
  }
  private func removeCaptureObservers(){
    for observer in captureObservers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    captureObservers.removeAll()
  }
  private func releaseCapture(){
    if let display=capturedDisplay {
      capturedDisplay=nil
      captureFacts["releaseResult"]=CGDisplayRelease(display).rawValue
      recordCapture(phase:"display-released")
    }
    // The level is also restored if capture failed before a display was owned.
    if let originalWindowLevel{window?.level=originalWindowLevel;self.originalWindowLevel=nil}
  }
  private func restoreCanvasInteraction(){
    if let previousCanvasInteraction{canvas?.interactionEnabled=previousCanvasInteraction;self.previousCanvasInteraction=nil}
  }
  private func recordCapture(phase:String){
    guard let diagnostics else{return}
    var facts=captureFacts
    facts["schema"]=1;facts["phase"]=phase;facts["exclusiveRequested"]=exclusiveRequested
    // Exclusive WindowServer ownership is separate from Metal HUD composition
    // mode and from addPresentedHandler's eventual on-glass observation.
    facts["directDisplayVerified"]=false;facts["onGlassVerified"]=false
    if let data=try?JSONSerialization.data(withJSONObject:facts,options:[.sortedKeys]){
      try?AtomicFile.writePrivate(data,to:diagnostics.appendingPathExtension("display.json"))
    }
  }
  private func finish(_ result:Result<SessionGamePresentation?,Error>){
    guard let callback=pending else{return};pending=nil;removeObservers()
    if case .failure=result{restoreCanvasInteraction()}
    callback(result)
  }
  private func removeObservers(){
    deadline?.cancel();deadline=nil
    for observer in observers{NotificationCenter.default.removeObserver(observer)}
    observers.removeAll()
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
