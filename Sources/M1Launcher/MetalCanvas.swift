// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ImageIO
import CoreImage
import LauncherCore
import Metal
import QuartzCore

private final class CanvasRendererBuildTicket {
  private let lock=NSLock();private var cancelled=false
  var active:Bool{lock.lock();defer{lock.unlock()};return !cancelled}
  func cancel(){lock.lock();cancelled=true;lock.unlock()}
}

enum CanvasSection: Equatable, Sendable {
  case library, game, settings, steamAccount, downloads, profiles, utility
}

enum CanvasAction {
  case game(String)
  case gameOptions(String)
  case resumeGame(String)
  case librarySection(Bool)
  case store(Store?)
  case profiles, importGame, settings, search, fullscreen, refresh, steamAccount, downloads
}
struct CanvasHit {
  let id: String
  let rect: CGRect
  let action: CanvasAction
}

final class MetalCanvas: NSView {
  let device: MTLDevice
  private static let chromeBlurContext=CIContext(options:[.useSoftwareRenderer:true,.cacheIntermediates:false])
  private var shellRenderer:CanvasShellRenderer?
  private let returnRendererBuilder:(MTLDevice)throws->CanvasShellRenderer
  private var rendererBuild:CanvasRendererBuildTicket?,graphicsGeneration=UUID()
  private var chromePreview:CALayer?
  private var returnViewportCompletion:(()->Void)?
  private var overlayMotion:CanvasOverlayMotion?,priorOverlayMotion:CanvasOverlayMotion?,overlayMotionGeneration=UUID()
  private var overlayPreparedCompletion:(()->Void)?,overlayMotionCompletion:(()->Void)?
  var graphicsRestoreSnapshot:(suspended:Bool,rendererReady:Bool,cpuChromeVisible:Bool){(suspended,shellRenderer != nil,chromePreview?.contents != nil)}
  private var gridSurface:LibraryGridSurface?
  private let tileCache=LibraryTileCache()
  private var displayLink:CADisplayLink?,linkTarget:CanvasDisplayLinkTarget?
  private var renderDirty=false,drawingChrome=false
  private var lastChromeKey="",cachedShellHits=[CanvasHit]()
  private var cachedProfileGames:[Game]?,cachedVisibleGames:[Game]?
  private var cachedKindCounts:(games:Int,other:Int)?
  private var catalogRevision=UUID(),preparedCatalog:UUID?,lastViewportCatalog:UUID?
  private var lastViewportIDs=[String](),lastAheadIDs=[String]()
  private var scrollDirection=1,lastScrollOffset:CGFloat=0
  private struct PreparedTile{let key:LibraryTileCache.Key;let image:CGImage;let hasArtwork:Bool}
  private var lastViewportModels=[Game]()
  var gameplayViewportGames:[Game]{lastViewportModels.isEmpty ? Array(visibleGames.prefix(12)):lastViewportModels}
  private var previousTiles=[String:PreparedTile](),tileArtwork=[String:(LibraryTileCache.Key,Bool)]()
  private var pendingArtInvalidations=Set<String>(),tileVersions=[String:UInt64]()
  private struct ArtworkEntry{let began:Double,cached:Bool;var ram:Double?;var committed=false}
  private var artworkEntries=[String:ArtworkEntry](),entryCount=0,cachedEntryCount=0,droppedEntries=0
  private var entryRAMms=[Double](),entryTilems=[Double](),cachedEntryTilems=[Double]()
  private var trackingArtworkInvalidations=0
  private var tileRasterMilliseconds=[Double](),largestTileBatch=0
  private var artworkObserver:NSObjectProtocol?
  private var shellHover=CAShapeLayer(),shellFocus=CAShapeLayer()
  private(set) var renderTicks=0,tileBuildTicks=0,chromeRasters=0,chromeBlurPasses=0
  private var cpuFrameTimes=[Double]()
  private let offscreenShellTarget:MTLTexture?
  private var canvasLayer: CAMetalLayer?
  private let art:ArtworkCache
  var artworkCache:ArtworkCache{art}
  private var libraryScroll:CGFloat=0
  private var libraryGridColumns=1
  private var libraryViewport=CGRect.zero
  private var libraryCardStride:CGFloat=1
  private var libraryMaximumScroll:CGFloat=0
  var state = LibraryState.initial(){didSet{cachedProfileGames=nil;cachedVisibleGames=nil;cachedKindCounts=nil;if oldValue.activeProfile != state.activeProfile{lastViewportModels.removeAll()};catalogRevision=UUID()}}
  var showOtherContent=false{didSet{if oldValue != showOtherContent{libraryScroll=0;cachedVisibleGames=nil;lastChromeKey="";redraw()}}}
  var section: CanvasSection = .library {
    didSet {
      guard oldValue != section else { return }
      // Drop stale game targets immediately, including a mouse press started
      // before a page change. Keep navigation focus when it still applies.
      pageTitle=nil
      gridSurface?.isHidden = section != .library
      hits.removeAll(); hoverID = nil; pressedID = nil
      if let id = focusID, !id.hasPrefix("nav.") && !id.hasPrefix("toolbar.") { focusID = nil }
      window?.invalidateCursorRects(for: self)
      redraw()
    }
  }
  var filter: Store?{didSet{if oldValue != filter{libraryScroll=0;cachedProfileGames=nil;cachedVisibleGames=nil;cachedKindCounts=nil}}}
  var query = ""{didSet{if oldValue != query{libraryScroll=0;cachedProfileGames=nil;cachedVisibleGames=nil;cachedKindCounts=nil}}}
  var selected = 0 {
    didSet {
      if oldValue != selected && section == .library {
        focusID = visibleGames.indices.contains(selected) ? "game." + visibleGames[selected].id : nil
        revealSelection()
      }
    }
  }
  var gameInterfaceMode=false{didSet{if oldValue != gameInterfaceMode{canvasLayer?.isOpaque = !gameInterfaceMode;lastChromeKey="";redraw()}}}
  var currentGameName:String?
  var currentGameID:String?
  var message = ""{didSet{if oldValue != message{messageIsError=false}}}
  var messageIsError=false
  var pageTitle:String?
  var runningGames=[ReadyShellRunningGame](){didSet{if oldValue != runningGames{lastChromeKey="";redraw()}}}
  func showErrorNotice(_ value:String){message=value;messageIsError = !value.isEmpty}
  func showStatus(_ value:String){message=value;messageIsError=false}
  var shellSnapshot:ReadyShellSnapshot{ReadyShellSnapshot.make(section:shellDestination,header:section == .game ? currentGameName:pageTitle,profileName:state.profiles.first{$0.id==state.activeProfile}?.name ?? "Giocatore",runningGames:runningGames,error:messageIsError ? message:nil)}
  private var shellDestination:ReadyShellDestination{switch section{case .library,.utility:return .library;case .game:return .game;case .steamAccount:return .friends;case .downloads:return .downloads;case .settings:return .settings;case .profiles:return .profiles}}
  var evaluationMode = false
  var steamStatus = "Steam"
  var steamOnline = false
  var onAction: ((CanvasAction) -> Void)?
  private var hits = [CanvasHit]()
  private var hoverID: String?
  private var pressedID: String?
  private var focusID: String?
  private var pointerLocation: CGPoint?
  private var pointerTracking: NSTrackingArea?
  private var hoverRedrawScheduled = false
  var interactionEnabled = true {
    didSet {
      guard oldValue != interactionEnabled else { return }
      gridSurface?.inputEnabled=interactionEnabled
      hoverID = nil; pressedID = nil
      window?.invalidateCursorRects(for: self)
      redraw()
    }
  }
  private var suspended = false
  var interactionSnapshot: (hover: String?, pressed: String?, focus: String?, hits: [CanvasHit]) { (hoverID, pressedID, focusID, hits) }
  var allocatedTextureBytes:Int{suspended ? 0:(shellRenderer?.allocatedBytes ?? 0)+tileCache.bytes}
  var gridRenderSnapshot:(tileCount:Int,tileBytes:Int,tileBuilds:Int,chromeRasters:Int,renderTicks:Int,layerCount:Int,cpuMilliseconds:[Double],inFlight:Int){(tileCache.count,tileCache.bytes,tileCache.builds,chromeRasters,renderTicks,gridSurface?.tileLayerCount ?? 0,cpuFrameTimes,shellRenderer?.inFlight ?? 0)}
  var libraryLayoutSnapshot:(columns:Int,offset:CGFloat,maximum:CGFloat,viewport:CGRect,visibleIDs:[String]){
    (libraryGridColumns,libraryScroll,libraryMaximumScroll,libraryViewport,hits.compactMap{if case .game(let id)=$0.action{return id};return nil})
  }
  var tileRasterBudgetSnapshot:(largestBatch:Int,rasterMilliseconds:[Double]){(largestTileBatch,tileRasterMilliseconds)}
  var viewportArtworkSnapshot:(entries:Int,cachedEntries:Int,completed:Int,dropped:Int,pending:Int,pendingCached:Int,ramMilliseconds:[Double],tileMilliseconds:[Double],cachedTileMilliseconds:[Double],committedIDs:Set<String>,trackingInvalidations:Int){
    (entryCount,cachedEntryCount,entryTilems.count,droppedEntries,artworkEntries.values.filter{!$0.committed}.count,artworkEntries.values.filter{$0.cached && !$0.committed}.count,entryRAMms,entryTilems,cachedEntryTilems,Set(artworkEntries.filter{$0.value.committed}.keys),trackingArtworkInvalidations)
  }
  func resetViewportArtworkMetrics(){artworkEntries.removeAll();entryCount=0;cachedEntryCount=0;droppedEntries=0;entryRAMms=[];entryTilems=[];cachedEntryTilems=[];trackingArtworkInvalidations=0}
  override var acceptsFirstResponder: Bool { interactionEnabled && !suspended }
  override var isFlipped: Bool { true }
  init(frame: NSRect, device: MTLDevice,artworkCache:ArtworkCache=ArtworkCache(),offscreenShellTarget:MTLTexture?=nil,returnRendererBuilder:@escaping(MTLDevice)throws->CanvasShellRenderer={try CanvasShellRenderer(device:$0)}) {
    self.device = device;self.art=artworkCache;self.offscreenShellTarget=offscreenShellTarget;self.returnRendererBuilder=returnRendererBuilder
    super.init(frame: frame)
    wantsLayer = true
    do { try configure() } catch { message = error.localizedDescription }
    artworkObserver=NotificationCenter.default.addObserver(forName:.readyArtworkChanged,object:art,queue:.main){[weak self] note in
      guard let id=note.userInfo?["gameID"]as?String,note.userInfo?["role"]as?String=="card" else{return}
      self?.invalidateGame(id:id)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  private func configure(asyncRenderer:Bool=false) throws {
    rendererBuild?.cancel();graphicsGeneration=UUID()
    if !asyncRenderer{shellRenderer=try CanvasShellRenderer(device:device)}
    let l = CAMetalLayer()
    // The diagnostic HUD belongs to the hosted game layer, including after
    // this library layer is recreated on return from a session.
    l.developerHUDProperties = ["mode": "disabled"]
    l.device = device
    l.pixelFormat = .bgra8Unorm
    l.isOpaque = !gameInterfaceMode
    l.framebufferOnly = true
    l.maximumDrawableCount = 2
    l.displaySyncEnabled = true
    l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    layer = l
    canvasLayer = l
    for overlay in [shellHover,shellFocus]{overlay.fillColor=NSColor.clear.cgColor;overlay.isHidden=true;l.addSublayer(overlay)}
    if asyncRenderer{
      // Rebuild visible UI immediately after confirmed producer exit. Compiling
      // a new Metal library/pipeline must not block its first grid or disk reads.
      let preview=CALayer();preview.contentsGravity = .resize;preview.frame=bounds
      preview.opacity=Float(overlayMotionValue(at:CACurrentMediaTime()))
      l.insertSublayer(preview,at:0);chromePreview=preview
      // This pipeline has no profile/game data. Only a new graphics lifecycle
      // can obsolete it; a profile change simply redraws current chrome.
      let ticket=CanvasRendererBuildTicket(),epoch=graphicsGeneration,device=self.device,builder=returnRendererBuilder
      rendererBuild=ticket
      DispatchQueue.global(qos:.userInitiated).async{[weak self]in
        guard ticket.active else{return}
        let result=Result{try builder(device)}
        DispatchQueue.main.async{[weak self]in
          guard let self,ticket.active,!self.suspended,self.graphicsGeneration==epoch else{
            if case .success(let renderer)=result{renderer.stop()};return
          }
          self.rendererBuild=nil
          if case .success(let renderer)=result{self.shellRenderer=renderer;self.lastChromeKey="";self.redraw()}
          // A failed optional Metal rebuild leaves the CPU chrome operational.
        }
      }
    }
  }
  var allProfileGames:[Game]{
    if let cachedProfileGames{return cachedProfileGames}
    let result=state.games.map{state.configured($0)}.filter{
      ($0.profileIDs==nil || $0.profileIDs!.contains(state.activeProfile))
        && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.storeID.localizedCaseInsensitiveContains(query))
    }.sorted{
      let a=$0.lastPlayed ?? .distantPast,b=$1.lastPlayed ?? .distantPast
      if a != b{return a>b};let order=LibraryEntryPresentation.title($0).localizedStandardCompare(LibraryEntryPresentation.title($1))
      return order == .orderedSame ? $0.id<$1.id:order == .orderedAscending
    }
    cachedProfileGames=result;return result
  }
  private var categoryCounts:(games:Int,other:Int){if let cachedKindCounts{return cachedKindCounts};let total=allProfileGames.count,other=allProfileGames.filter{LibraryEntryPresentation.isOtherContent($0)}.count;let result=(games:total-other,other:other);cachedKindCounts=result;return result}
  var visibleGames:[Game]{
    if let cachedVisibleGames{return cachedVisibleGames}
    let result=allProfileGames.filter{!LibraryEntryPresentation.isOtherContent($0)}
    cachedVisibleGames=result;return result
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.acceptsMouseMovedEvents = true
    updateTrackingAreas()
    if window==nil{displayLink?.isPaused=true}else{redraw()}
  }
  override func updateTrackingAreas() {
    if let pointerTracking { removeTrackingArea(pointerTracking) }
    let tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
    addTrackingArea(tracking); pointerTracking = tracking
    super.updateTrackingAreas()
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    guard interactionEnabled && !suspended else { return }
    for hit in hits { addCursorRect(hit.rect.intersection(bounds), cursor: .pointingHand) }
  }
  override func becomeFirstResponder() -> Bool { redraw(); return true }
  override func resignFirstResponder() -> Bool { pressedID = nil; redraw(); return true }
  private func hit(at point: CGPoint) -> CanvasHit? {
    guard interactionEnabled && !suspended else { return nil }
    return hits.last { $0.rect.contains(point) }
  }
  private func updatePointer(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    pointerLocation = point
    let next = hit(at: point)?.id
    if next != hoverID { hoverID = next; redraw() }
  }
  override func mouseMoved(with event: NSEvent) { updatePointer(event) }
  override func mouseEntered(with event: NSEvent) { updatePointer(event) }
  override func mouseDragged(with event: NSEvent) { updatePointer(event) }
  override func mouseExited(with event: NSEvent) {
    pointerLocation = nil
    if hoverID != nil { hoverID = nil; redraw() }
  }
  private func registerHit(_ rect: CGRect, hitRect: CGRect? = nil, id: String, action: CanvasAction) {
    hits.append(.init(id: id, rect: hitRect ?? rect, action: action))
    guard interactionEnabled,!drawingChrome else { return }
    if hoverID == id {
      round(rect, color(pressedID == id ? 0x000000 : 0xffffff, pressedID == id ? 0.18 : 0.065))
      let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 12, yRadius: 12)
      color(0xffffff, pressedID == id ? 0.5 : 0.28).setStroke(); border.lineWidth = 1.5; border.stroke()
    }
    if focusID == id && window?.isKeyWindow == true && window?.firstResponder === self {
      let border = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 14, yRadius: 14)
      color(0xb5ffd0).setStroke(); border.lineWidth = 2; border.stroke()
    }
  }
  private func activate(_ hit: CanvasHit) {
    switch hit.action {
    case .game, .gameOptions, .librarySection: guard section == .library else { return }
    default: break
    }
    focusID = hit.id
    if case .game(let id) = hit.action, let index = visibleGames.firstIndex(where: { $0.id == id }) { selected = index }
    onAction?(hit.action)
  }
  override func layout() {
    super.layout()
    redraw()
  }
  func refresh() {
    selected = min(selected, max(visibleGames.count - 1, 0))
    redraw()
  }
  deinit{displayLink?.invalidate();if let artworkObserver{NotificationCenter.default.removeObserver(artworkObserver)}}
  func releaseGraphics(){
    cancelOverlayChromeMotion()
    rendererBuild?.cancel();rendererBuild=nil;graphicsGeneration=UUID();returnViewportCompletion=nil
    suspended=true;renderDirty=false;displayLink?.invalidate();displayLink=nil;linkTarget=nil
    gridSurface?.clear();gridSurface=nil;tileCache.clear();previousTiles.removeAll();tileArtwork.removeAll();tileVersions.removeAll();pendingArtInvalidations.removeAll();artworkEntries.removeAll()
    shellRenderer?.stop();shellRenderer=nil;chromePreview?.contents=nil;chromePreview?.removeFromSuperlayer();chromePreview=nil;canvasLayer?.device=nil;canvasLayer?.removeFromSuperlayer();canvasLayer=nil;layer=nil
    lastChromeKey="";cachedShellHits=[];art.purge();hits=[];hoverID=nil;pressedID=nil;window?.invalidateCursorRects(for:self)
    preparedCatalog=nil;lastViewportCatalog=nil;lastViewportIDs=[];lastAheadIDs=[]
  }
  func resumeGraphics(){if suspended{suspended=false;try?configure(asyncRenderer:true)};redraw()}
  func prepareOverlayChrome(completion:@escaping()->Void){
    overlayMotion=CanvasOverlayMotion(from:0,to:0,began:0,duration:0);priorOverlayMotion=nil;overlayMotionGeneration=UUID()
    overlayPreparedCompletion=completion;overlayMotionCompletion=nil;interactionEnabled=false
    chromePreview?.opacity=0;for child in subviews{child.alphaValue=0};redraw()
  }
  func animateOverlayChrome(start:Double,from:Double,to:Double,duration:Double,completion:@escaping()->Void){
    if let current=overlayMotion,CACurrentMediaTime()>=current.began{priorOverlayMotion=current}
    overlayMotion=CanvasOverlayMotion(from:from,to:to,began:start,duration:duration);overlayMotionGeneration=UUID()
    overlayMotionCompletion=completion;interactionEnabled=false;redraw()
  }
  func cancelOverlayChromeMotion(){
    overlayMotion=nil;priorOverlayMotion=nil;overlayMotionGeneration=UUID();overlayPreparedCompletion=nil;overlayMotionCompletion=nil
    chromePreview?.opacity=1;for child in subviews{child.alphaValue=1}
  }
  private func motionNeedsFrames(at time:Double)->Bool{
    guard let motion=overlayMotion else{return false}
    return time<motion.began+motion.duration || overlayMotionCompletion != nil
  }
  private func overlayMotionValue(at time:Double)->Double{
    guard let motion=overlayMotion else{return 1}
    if time<motion.began,let prior=priorOverlayMotion{return prior.value(at:time)}
    return motion.value(at:time)
  }
  private func overlayChromePresented(generation:UUID,endpoint:Bool){
    if let ready=overlayPreparedCompletion{overlayPreparedCompletion=nil;ready()}
    guard overlayMotionGeneration==generation,endpoint,let done=overlayMotionCompletion else{return}
    overlayMotionCompletion=nil;done()
  }
  /// Opening the real library during play restores only the visible indexed
  /// cards. Do not let an earlier gameplay purge leave viewport demand stale.
  func restoreInterfaceLibraryArtwork(){
    guard gameInterfaceMode,!suspended,section == .library else{return}
    art.resumeForGameInterface();updateGridGeometry()
    let games=indexRange(prefetch:false).map{visibleGames[$0]},epoch=graphicsGeneration
    lastViewportCatalog=nil;lastViewportIDs=[];lastAheadIDs=[]
    art.restoreFirstViewport(games:games){[weak self]in
      guard let self,!self.suspended,self.gameInterfaceMode,self.graphicsGeneration==epoch else{return}
      self.redraw()
    }
  }
  /// Called after the return's priority disk reads. Only visible card stamps
  /// must commit before unrelated catalog/artwork maintenance can resume.
  func restoreVisibleLibrary(completion:@escaping()->Void){
    guard !suspended else{return}
    returnViewportCompletion=completion;redraw();renderDisplayTick()
  }
  private func visibleLibraryRestored(){
    guard let completion=returnViewportCompletion else{return};returnViewportCompletion=nil
    CATransaction.flush()
    let epoch=graphicsGeneration
    DispatchQueue.main.async{[weak self]in guard let self,!self.suspended,self.graphicsGeneration==epoch else{return};completion()}
  }
  /// Input only requests a display tick. It never rasterizes/uploads a canvas.
  func redraw(){
    guard !suspended else{return};renderDirty=true
    guard window != nil else{return}
    if displayLink==nil{let target=CanvasDisplayLinkTarget();target.canvas=self;let link=self.displayLink(target:target,selector:#selector(CanvasDisplayLinkTarget.tick(_:)));link.add(to:.main,forMode:.common);link.isPaused=true;displayLink=link;linkTarget=target}
    displayLink?.isPaused=false
  }
  func invalidateGame(id:String){
    guard !suspended,previousTiles[id] != nil || artworkEntries[id] != nil else{return}
    if let mode=CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()),(mode.rawValue as String)==RunLoop.Mode.eventTracking.rawValue{trackingArtworkInvalidations+=1}
    pendingArtInvalidations.insert(id);redraw()
  }
  private func recordViewportEntries(){
    guard section == .library,!suspended else{return}
    lastViewportModels=indexRange(prefetch:false).map{visibleGames[$0]}
    let ids=Set(lastViewportModels.map(\.id)),now=ProcessInfo.processInfo.systemUptime
    for id in Array(artworkEntries.keys) where !ids.contains(id){if artworkEntries[id]?.committed==false{droppedEntries+=1};artworkEntries.removeValue(forKey:id)}
    for id in ids where artworkEntries[id]==nil{let cached=art.hasCachedImage(gameID:id,role:.card);artworkEntries[id]=ArtworkEntry(began:now,cached:cached);entryCount+=1;if cached{cachedEntryCount+=1}}
  }
  private func recordArtworkRAM(_ id:String){
    guard var entry=artworkEntries[id],entry.ram==nil else{return};let now=ProcessInfo.processInfo.systemUptime;entry.ram=now;artworkEntries[id]=entry
    entryRAMms.append((now-entry.began)*1000);if entryRAMms.count>2048{entryRAMms.removeFirst(entryRAMms.count-2048)}
  }
  private func recordArtworkCommit(_ id:String){
    guard var entry=artworkEntries[id],!entry.committed else{return};entry.committed=true;artworkEntries[id]=entry
    let ms=(ProcessInfo.processInfo.systemUptime-entry.began)*1000;entryTilems.append(ms);if entry.cached{cachedEntryTilems.append(ms)}
    if entryTilems.count>2048{entryTilems.removeFirst(entryTilems.count-2048)};if cachedEntryTilems.count>2048{cachedEntryTilems.removeFirst(cachedEntryTilems.count-2048)}
  }
  private func lookAheadRange()->Range<Int>{
    guard !visibleGames.isEmpty else{return 0..<0}
    let first=max(0,Int(floor(libraryScroll/libraryCardStride))),last=Int(ceil((libraryScroll+libraryViewport.height)/libraryCardStride))
    let lower=max(0,first-(scrollDirection<0 ? 4:1)),upper=max(lower,last+(scrollDirection>0 ? 4:1))
    return min(visibleGames.count,lower*libraryGridColumns)..<min(visibleGames.count,upper*libraryGridColumns)
  }
  private func updateGridGeometry(){
    let content=bounds.width-148,gap:CGFloat=18
    libraryViewport=CGRect(x:105,y:138,width:content+14,height:max(0,bounds.height-194))
    libraryGridColumns=max(1,Int((content+gap)/178))
    let cardWidth=floor((content-gap*CGFloat(libraryGridColumns-1))/CGFloat(libraryGridColumns)),cardHeight=cardWidth*LibraryCardMetrics.coverRatio+LibraryCardMetrics.titleHeight
    libraryCardStride=cardHeight+gap
    let rows=(visibleGames.count+libraryGridColumns-1)/libraryGridColumns
    libraryMaximumScroll=max(0,CGFloat(rows)*libraryCardStride-gap+2*LibraryCardMetrics.edgePadding-libraryViewport.height);libraryScroll=min(max(0,libraryScroll),libraryMaximumScroll)
  }
  private var cardSize:NSSize{let width=floor((bounds.width-148-18*CGFloat(libraryGridColumns-1))/CGFloat(libraryGridColumns));return NSSize(width:width,height:width*LibraryCardMetrics.coverRatio+LibraryCardMetrics.titleHeight)}
  private func indexRange(prefetch:Bool)->Range<Int>{
    guard !visibleGames.isEmpty else{return 0..<0}
    let start=max(0,Int(floor(libraryScroll/libraryCardStride))-(prefetch ? 1:0))
    let end=max(start,Int(ceil((libraryScroll+libraryViewport.height)/libraryCardStride))+(prefetch ? 1:0))
    return min(visibleGames.count,start*libraryGridColumns)..<min(visibleGames.count,end*libraryGridColumns)
  }
  private func cardFrame(_ index:Int)->CGRect{CGRect(x:112+CGFloat(index%libraryGridColumns)*(cardSize.width+18),y:145+CGFloat(index/libraryGridColumns)*libraryCardStride-libraryScroll,width:cardSize.width,height:cardSize.height)}
  private func rebuildInteractiveHits(){
    hits=cachedShellHits.filter{if case .librarySection=$0.action{return section == .library};return section == .library || !$0.id.hasPrefix("empty.")}
    guard section == .library else{return}
    for i in indexRange(prefetch:false){let rect=cardFrame(i).intersection(libraryViewport);if !rect.isEmpty{hits.append(.init(id:"game."+visibleGames[i].id,rect:rect,action:.game(visibleGames[i].id)))}}
    hoverID=pointerLocation.flatMap{hit(at:$0)?.id};window?.invalidateCursorRects(for:self)
  }
  private func chromeKey()->String{
    let minute=Int(Date().timeIntervalSince1970/60),profile=state.profiles.first{$0.id==state.activeProfile}?.name ?? ""
    return [String(describing:bounds.size),String(describing:section),query,profile,messageIsError ? message:"",pageTitle ?? "",runningGames.map{$0.id+":"+$0.title}.joined(separator:"|"),steamStatus,String(steamOnline),String(evaluationMode),String(gameInterfaceMode),currentGameName ?? "",String(visibleGames.count),String(showOtherContent),String(allProfileGames.count),String(categoryCounts.games),String(categoryCounts.other),String(minute)].joined(separator:"|_|")
  }
  /// Called by CADisplayLink on Main. Hidden fixtures call this same entry point.
  func renderDisplayTick(){
    let clock=CACurrentMediaTime(),contentDirty=renderDirty
    guard !suspended,(contentDirty || motionNeedsFrames(at:clock)),bounds.width>100,bounds.height>100 else{displayLink?.isPaused=true;return}
    let began=ProcessInfo.processInfo.systemUptime;renderDirty=false;renderTicks+=1
    let progress=overlayMotionValue(at:clock),motionGeneration=overlayMotionGeneration
    let endpoint=overlayMotion.map{clock >= $0.began+$0.duration} ?? false
    let uniforms=SIMD4<Float>(Float(72/bounds.width),Float(84/bounds.height),Float(progress),overlayMotion==nil ? 0:1)
    if overlayMotion != nil{CATransaction.begin();CATransaction.setDisableActions(true);for child in subviews{child.alphaValue=progress};chromePreview?.opacity=Float(progress);CATransaction.commit()}
    let graphics=graphicsGeneration
    let motionDone:((Bool)->Void) = {[weak self] success in
      guard let self,!self.suspended,self.graphicsGeneration==graphics else{return}
      if success{self.overlayChromePresented(generation:motionGeneration,endpoint:endpoint)}else{self.lastChromeKey="";self.redraw()}
    }
    if !contentDirty {
      if let renderer=shellRenderer,let layer=canvasLayer{
        if !renderer.presentCurrent(layer:layer,target:offscreenShellTarget,motion:uniforms,completion:motionDone){renderDirty=true}
      }else{renderDirty=true}
      displayLink?.isPaused = !renderDirty && !motionNeedsFrames(at:clock);return
    }
    updateGridGeometry();var submittedChrome=false
    let key=chromeKey(),scale=window?.backingScaleFactor ?? 2
    if key != lastChromeKey,let renderer=shellRenderer,renderer.canSubmit,let canvasLayer{
      let w=max(1,Int(bounds.width*scale)),h=max(1,Int(bounds.height*scale))
      if let bitmap=CanvasRaster(width:w,height:h){
        drawingChrome=true;bitmap.draw(logicalSize:bounds.size,scale:scale){drawScene($0)};drawingChrome=false;cachedShellHits=hits
        canvasLayer.contentsScale=scale;canvasLayer.drawableSize=CGSize(width:w,height:h)
        let epoch=graphicsGeneration
        let completion:((Bool)->Void) = {[weak self] success in
          guard let self,!self.suspended,self.graphicsGeneration==epoch else{return}
          if !success{self.lastChromeKey="";self.redraw()}
          else{self.chromePreview?.contents=nil;self.chromePreview?.removeFromSuperlayer();self.chromePreview=nil;self.overlayChromePresented(generation:motionGeneration,endpoint:endpoint)}
        }
        let accepted=offscreenShellTarget.map{renderer.submit(bitmap,target:$0,motion:uniforms,completion:completion)} ?? renderer.submit(bitmap,layer:canvasLayer,motion:uniforms,completion:completion)
        submittedChrome=accepted
        if accepted{lastChromeKey=key;chromeRasters+=1}else{renderDirty=true}
      }
    }else if key != lastChromeKey,shellRenderer==nil,let preview=chromePreview{
      let w=max(1,Int(bounds.width*scale)),h=max(1,Int(bounds.height*scale))
      if let bitmap=CanvasRaster(width:w,height:h){
        drawingChrome=true;bitmap.draw(logicalSize:bounds.size,scale:scale){drawScene($0)};drawingChrome=false;cachedShellHits=hits
        preview.frame=bounds;preview.contentsScale=scale;preview.contents=bitmap.context.makeImage();lastChromeKey=key;chromeRasters+=1
      }
    }else if key != lastChromeKey{renderDirty=true}
    rebuildInteractiveHits()
    if section == .library,!visibleGames.isEmpty{
      if gridSurface==nil{let surface=LibraryGridSurface(canvas:self);surface.didScroll={[weak self]offset in guard let self,!self.suspended else{return};self.scrollDirection=offset>=self.libraryScroll ? 1:-1;self.libraryScroll=min(self.libraryMaximumScroll,max(0,offset));self.pressedID=nil;self.recordViewportEntries();self.rebuildInteractiveHits();self.redraw()};addSubview(surface);gridSurface=surface}
      guard let surface=gridSurface else{return};surface.isHidden=false;surface.inputEnabled=interactionEnabled
      let rows=(visibleGames.count+libraryGridColumns-1)/libraryGridColumns
      surface.configure(frame:libraryViewport,documentSize:NSSize(width:libraryViewport.width,height:CGFloat(rows)*libraryCardStride-18),offset:libraryScroll)
      let visibleRange=indexRange(prefetch:false),visibleIDs=visibleRange.map{visibleGames[$0].id}
      let aheadRange=lookAheadRange(),aheadIDs=aheadRange.filter{!visibleRange.contains($0)}.map{visibleGames[$0].id}
      recordViewportEntries()
      if !gameInterfaceMode,preparedCatalog != catalogRevision{art.prepare(games:state.games.filter{$0.profileIDs==nil || $0.profileIDs!.contains(state.activeProfile)}.map{state.configured($0)});preparedCatalog=catalogRevision}
      if lastViewportCatalog != catalogRevision || lastViewportIDs != visibleIDs || lastAheadIDs != aheadIDs{
        art.prepareViewport(games:aheadRange.map{visibleGames[$0]},visibleGameIDs:visibleIDs,lookAheadGameIDs:aheadIDs)
        lastViewportIDs=visibleIDs;lastAheadIDs=aheadIDs;lastViewportCatalog=catalogRevision
      }
      for id in pendingArtInvalidations{tileVersions[id,default:0]&+=1};pendingArtInvalidations.removeAll()
      // Probe every visible RAM binding independently of the two-tile raster
      // budget, so measurements separate cache publication from tile commit.
      var ramReadyIDs=Set<String>()
      for i in indexRange(prefetch:true){let game=visibleGames[i],id=game.id;if art.image(for:game,role:.card,refresh:{[weak self]in self?.invalidateGame(id:id)}) != nil{ramReadyIDs.insert(id);if visibleRange.contains(i){recordArtworkRAM(id)}}}
      var tiles=[LibraryGridSurface.Tile](),built=0
      let tileRasterBegan=ProcessInfo.processInfo.systemUptime
      let requested=Array(indexRange(prefetch:false))+indexRange(prefetch:true).filter{!indexRange(prefetch:false).contains($0)}
      var images=[Int:CGImage](),prepared=[String:PreparedTile](),realArtworkIDs=Set<String>()
      for i in requested{
        let game=visibleGames[i],size=cardSize,key=LibraryTileCache.Key(title:LibraryEntryPresentation.title(game),store:game.store.rawValue,platforms:Self.platformLabels(game).joined(separator:"|"),installed:game.variants.contains{$0.installed},revision:art.revision(gameID:game.id,role:.card) &+ (tileVersions[game.id] ?? 0),pixelWidth:Int(ceil(size.width*scale)),pixelHeight:Int(ceil(size.height*scale)))
        var image=tileCache.image(id:game.id,key:key),containsArtwork=tileArtwork[game.id].flatMap{$0.0==key ? $0.1:nil} ?? false
        // A different binding can populate a shared content hash without this
        // binding receiving a revision notification. Never keep a placeholder
        // stamp merely because its key is unchanged once real RAM art exists.
        if image != nil,!containsArtwork,ramReadyIDs.contains(game.id){image=nil;renderDirty=true}
        if image==nil,built<6,(built==0 || ProcessInfo.processInfo.systemUptime-tileRasterBegan<0.004),let bitmap=CanvasRaster(width:key.pixelWidth,height:key.pixelHeight){
          bitmap.draw(logicalSize:size,scale:scale){containsArtwork=drawCard($0,game:game,rect:CGRect(origin:.zero,size:size))}
          if let cg=bitmap.context.makeImage(){tileCache.insert(id:game.id,key:key,image:cg);tileArtwork[game.id]=(key,containsArtwork);image=cg;built+=1}
        }
        if image==nil{renderDirty=true;if let previous=previousTiles[game.id],previous.key.title==key.title,previous.key.installed==key.installed,previous.key.pixelWidth==key.pixelWidth,previous.key.pixelHeight==key.pixelHeight{image=previous.image;containsArtwork=previous.hasArtwork}}
        if let image{images[i]=image;prepared[game.id]=PreparedTile(key:key,image:image,hasArtwork:containsArtwork);if containsArtwork{realArtworkIDs.insert(game.id)}}
      }
      previousTiles=prepared
      if built>0{tileBuildTicks+=1;largestTileBatch=max(largestTileBatch,built);tileRasterMilliseconds.append((ProcessInfo.processInfo.systemUptime-tileRasterBegan)*1000);if tileRasterMilliseconds.count>2048{tileRasterMilliseconds.removeFirst(tileRasterMilliseconds.count-2048)}}
      for i in indexRange(prefetch:true){var rect=cardFrame(i);rect.origin.x-=libraryViewport.minX;rect.origin.y+=libraryScroll-libraryViewport.minY;tiles.append(.init(id:visibleGames[i].id,frame:rect,image:images[i],installed:visibleGames[i].variants.contains{$0.installed}))}
      func gameID(_ id:String?)->String?{id.flatMap{$0.hasPrefix("game.") ? String($0.dropFirst(5)):nil}}
      surface.update(tiles,selected:visibleGames.indices.contains(selected) ? visibleGames[selected].id:nil,hovered:gameID(hoverID),focused:gameID(focusID),pressed:gameID(pressedID),showFocus:window?.isKeyWindow==true && window?.firstResponder===self)
      for id in visibleIDs where realArtworkIDs.contains(id){recordArtworkCommit(id)}
      let visibleStamped=visibleRange.allSatisfy{images[$0] != nil}
      if visibleStamped,Set(visibleIDs).intersection(ramReadyIDs).isSubset(of:realArtworkIDs){visibleLibraryRestored()}
    }else{gridSurface?.isHidden=true;visibleLibraryRestored()}
    updateShellFeedback()
    cpuFrameTimes.append((ProcessInfo.processInfo.systemUptime-began)*1000);if cpuFrameTimes.count>4096{cpuFrameTimes.removeFirst(cpuFrameTimes.count-4096)}
    if !submittedChrome,overlayMotion != nil,let renderer=shellRenderer,let layer=canvasLayer{
      if !renderer.presentCurrent(layer:layer,target:offscreenShellTarget,motion:uniforms,completion:motionDone){renderDirty=true}
    }
    displayLink?.isPaused = !renderDirty && !motionNeedsFrames(at:clock)
  }
  private func updateShellFeedback(){
    CATransaction.begin();CATransaction.setDisableActions(true)
    for (overlay,id) in [(shellHover,hoverID),(shellFocus,window?.firstResponder===self ? focusID:nil)]{
      guard interactionEnabled,let id,!id.hasPrefix("game."),let hit=hits.first(where:{$0.id==id})else{overlay.isHidden=true;continue}
      overlay.isHidden=false;overlay.frame=hit.rect;overlay.path=CGPath(roundedRect:overlay.bounds.insetBy(dx:1,dy:1),cornerWidth:10,cornerHeight:10,transform:nil);overlay.strokeColor=NSColor.white.withAlphaComponent(0.35).cgColor;overlay.fillColor=NSColor.white.withAlphaComponent(0.065).cgColor;overlay.lineWidth=1.5
    }
    CATransaction.commit()
  }
  private func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
      blue: CGFloat(hex & 255) / 255, alpha: alpha)
  }
  private func round(_ rect: CGRect, _ fill: NSColor, radius: CGFloat = 12) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
  }
  private func text(
    _ s: String, _ rect: CGRect, size: CGFloat = 16, bold: Bool = false, color: NSColor = .white
  ) {
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byTruncatingTail
    (s as NSString).draw(
      in: rect,
      withAttributes: [
        .font: bold
          ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size),
        .foregroundColor: color, .paragraphStyle: p,
      ])
  }
  private func icon(_ name: String, _ rect: CGRect, tint: NSColor = .white) {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    // Rasterize symbols into the single canvas; no intermediate NSView or compositor sublayer.
    let configuration = NSImage.SymbolConfiguration(paletteColors: [tint])
    let symbol = image.withSymbolConfiguration(configuration) ?? image
    symbol.draw(
      in: CanvasGeometry.aspectFit(symbol.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
  private func button(
    _ rect: CGRect, _ symbol: String, _ action: CanvasAction, id: String, active: Bool = false
  ) {
    round(rect, color(active ? 0x2a443b : 0x24292b))
    icon(symbol, rect.insetBy(dx: 10, dy: 10), tint: active ? color(0x98f5b9) : .white)
    registerHit(rect, hitRect: CanvasGeometry.minimumTarget(rect), id: id, action: action)
  }
  @discardableResult private func drawCard(_ cg:CGContext,game:Game,rect r:CGRect)->Bool{
      var hasArtwork=false
      let coverHeight=r.width*LibraryCardMetrics.coverRatio
      let installed=game.variants.contains{$0.installed}
      round(r,color(installed ? 0x24332f:0x242a2d))
      let cover=CGRect(x:r.minX,y:r.minY,width:r.width,height:coverHeight)
      cg.saveGState();cg.addPath(CGPath(roundedRect:cover,cornerWidth:10,cornerHeight:10,transform:nil));cg.clip()
      if let image=art.image(for:game,role:.card,refresh:{[weak self]in self?.invalidateGame(id:game.id)}){
        hasArtwork=true
        let maximum=max(image.width,image.height)<=128 ? CGFloat(1):CGFloat.greatestFiniteMagnitude
        let scale=min(maximum,min(cover.width/CGFloat(image.width),cover.height/CGFloat(image.height)))
        let size=CGSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
        cg.saveGState();cg.translateBy(x:cover.minX,y:cover.maxY);cg.scaleBy(x:1,y:-1)
        cg.draw(image,in:CGRect(x:(cover.width-size.width)/2,y:(cover.height-size.height)/2,width:size.width,height:size.height));cg.restoreGState()
      }else{
        let hash=game.id.utf8.reduce(0){($0*31+Int($1))&0xffffff}
        cg.setFillColor(color(0x20363a | (hash&0x0f0f0f)).cgColor);cg.fill(cover)
        icon("gamecontroller",CGRect(x:cover.midX-28,y:cover.midY-28,width:56,height:56),tint:color(0xc1d2ce,0.7))
      }
      if !installed{cg.setBlendMode(.saturation);cg.setFillColor(NSColor.gray.cgColor);cg.fill(cover);cg.setBlendMode(.normal);cg.setFillColor(color(0x11171a,0.22).cgColor);cg.fill(cover)}
      cg.restoreGState()
      let mac=game.variants.contains{$0.platform == .macOS},windows=game.variants.contains{$0.platform == .windows}
      let count=(mac ? 1:0)+(windows ? 1:0)
      if count>0 {
        let badge=CGRect(x:cover.maxX-CGFloat(count)*22-10,y:cover.minY+9,width:CGFloat(count)*22+3,height:25)
        round(badge,color(0x101819,0.82),radius:7)
        var x=badge.minX+4
        if mac{icon("apple.logo",CGRect(x:x,y:badge.minY+4,width:17,height:17),tint:color(0xf0f6f3));x+=22}
        if windows{let box=CGRect(x:x+1,y:badge.minY+5,width:15,height:15);color(0xf0f6f3).setFill();for row in 0..<2{for column in 0..<2{CGRect(x:box.minX+CGFloat(column)*8,y:box.minY+CGFloat(row)*8,width:6.5,height:6.5).fill()}}}
      }
      text(LibraryEntryPresentation.title(game),CGRect(x:r.minX+10,y:cover.maxY+10,width:r.width-20,height:23),size:13,bold:true,color:installed ? .white:color(0xc6cdcd))
      return hasArtwork
  }
  private func drawScene(_ cg: CGContext) {
    hits.removeAll()
    let width = bounds.width
    let height = bounds.height
    if gameInterfaceMode {
      cg.clear(bounds)
    }else{
    cg.setFillColor(color(0x101315).cgColor)
    cg.fill(bounds)
    let colors =
      [color(0x2b3a40).cgColor, color(0x171719).cgColor, color(0x121416).cgColor] as CFArray
    if let g = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])
    {
      cg.drawLinearGradient(
        g, start: .init(x: 60, y: 0), end: .init(x: width, y: height), options: [])
    }
    }
    cg.setFillColor(color(0x1b2226, 0.9).cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: 72, height: height))
    // One unified library; store backends never occupy persistent dock slots.
    icon("gamecontroller.fill", CGRect(x:24,y:24,width:24,height:24),tint:color(0x95edb4))
    button(CGRect(x:13,y:72,width:46,height:46),"books.vertical.fill",.store(nil),id:"nav.library",active:section == .library)
    let dockBottom=height-232
    for (index,game) in runningGames.enumerated(){
      let y=132+CGFloat(index)*57
      guard y+46<dockBottom else{break}
      let rect=CGRect(x:13,y:y,width:46,height:46)
      round(rect,color(section == .game && currentGameID==game.id ? 0x2a443b:0x20302c),radius:12)
      if let model=state.games.first(where:{$0.id==game.id}),let image=art.image(for:state.configured(model),role:.icon,refresh:{[weak self]in self?.lastChromeKey="";self?.redraw()}){
        NSGraphicsContext.current?.cgContext.saveGState();NSBezierPath(roundedRect:rect.insetBy(dx:5,dy:5),xRadius:8,yRadius:8).addClip()
        NSGraphicsContext.current?.cgContext.draw(image,in:CanvasGeometry.aspectFit(CGSize(width:image.width,height:image.height),in:rect.insetBy(dx:5,dy:5)));NSGraphicsContext.current?.cgContext.restoreGState()
      }else if let model=state.games.first(where:{$0.id==game.id}),let appIcon=ReadyActiveGameIcon.image(forExecutable:model.currentVariant?.executable){
        appIcon.draw(in:rect.insetBy(dx:5,dy:5),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
      }else{icon("gamecontroller.fill",rect.insetBy(dx:12,dy:12),tint:color(0xb5ffd0))}
      registerHit(rect,id:"nav.running."+game.id,action:.resumeGame(game.id))
    }
    button(CGRect(x:13,y:height-232,width:46,height:46),"person.2",.steamAccount,id:"nav.friends",active:section == .steamAccount)
    button(CGRect(x:13,y:height-174,width:46,height:46),"arrow.down.circle",.downloads,id:"nav.downloads",active:section == .downloads)
    button(CGRect(x:13,y:height-116,width:46,height:46),"plus",.importGame,id:"nav.import")
    button(CGRect(x:13,y:height-58,width:46,height:46),"gearshape",.settings,id:"nav.settings",active:section == .settings)
    let left:CGFloat=112
    let content=width-left-36
    drawSoftChrome(cg,rect:CGRect(x:72,y:0,width:width-72,height:84),top:true)
    cg.saveGState();cg.setShadow(offset:CGSize(width:0,height:2),blur:10,color:color(0x000000,0.45).cgColor)
    text(shellSnapshot.header,CGRect(x:left,y:25,width:content-345,height:34),size:23,bold:true,color:color(0xe9f3ee));cg.restoreGState()
    let profile = state.profiles.first { $0.id == state.activeProfile }?.name ?? "Giocatore"
    text(profile, CGRect(x: width - 330, y: 29, width: 180, height: 27), size: 14, bold: true)
    button(CGRect(x:width - 148,y:21,width:38,height:38),steamOnline ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark",.steamAccount,id:"toolbar.steam.account",active:section == .steamAccount)
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    text(
      fmt.string(from: Date()), CGRect(x: width - 98, y: 28, width: 64, height: 25), size: 16,
      bold: true)
    // AppKit page content is hosted at x112/y88, width-148/height-112.
    // Non-library pages retain only this shell, navigation and a quiet footer.
    guard section == .library else {
      finishScene(left: left, content: content, height: height, libraryHelp: false)
      return
    }
    if !query.isEmpty{text("Risultati per “\(query)”",CGRect(x:left,y:99,width:content-110,height:27),size:18,bold:true)}
    let games=visibleGames
    text("\(games.count) giochi",CGRect(x:width-137,y:104,width:100,height:22),size:12,color:color(0xafc1bc))
    let gap:CGFloat=18
    libraryViewport=CGRect(x:left-7,y:138,width:content+14,height:max(0,height-194))
    libraryGridColumns=max(1,Int((content+gap)/178))
    let cardWidth=floor((content-gap*CGFloat(libraryGridColumns-1))/CGFloat(libraryGridColumns))
    let coverHeight=cardWidth*LibraryCardMetrics.coverRatio,cardHeight=coverHeight+LibraryCardMetrics.titleHeight
    libraryCardStride=cardHeight+gap
    let rows=(games.count+libraryGridColumns-1)/libraryGridColumns
    libraryMaximumScroll=max(0,CGFloat(rows)*libraryCardStride-gap+2*LibraryCardMetrics.edgePadding-libraryViewport.height)
    libraryScroll=min(max(0,libraryScroll),libraryMaximumScroll)
    if drawingChrome && !games.isEmpty{finishScene(left:left,content:content,height:height,libraryHelp:true);return}
    cg.saveGState();cg.clip(to:libraryViewport)
    let firstRow=max(0,Int(floor(libraryScroll/libraryCardStride))),lastRow=Int(ceil((libraryScroll+libraryViewport.height)/libraryCardStride))
    for i in min(games.count,firstRow*libraryGridColumns)..<min(games.count,lastRow*libraryGridColumns){
      let game=games[i]
      let r=CGRect(x:left+CGFloat(i%libraryGridColumns)*(cardWidth+gap),y:145+CGFloat(i/libraryGridColumns)*libraryCardStride-libraryScroll,width:cardWidth,height:cardHeight)
      guard r.intersects(libraryViewport)else{continue}
      drawCard(cg,game:game,rect:r)
      if i==selected{let outline=NSBezierPath(roundedRect:r.insetBy(dx:-3,dy:-3),xRadius:13,yRadius:13);color(0xb5ffd0).setStroke();outline.lineWidth=2;outline.stroke()}
      registerHit(r,hitRect:r.intersection(libraryViewport),id:"game."+game.id,action:.game(game.id))
    }
    cg.restoreGState()
    if libraryMaximumScroll>0{
      let track=CGRect(x:width-24,y:libraryViewport.minY,width:3,height:libraryViewport.height)
      round(track,color(0xffffff,0.07),radius:2)
      let thumbHeight=max(32,track.height*track.height/(track.height+libraryMaximumScroll))
      round(CGRect(x:track.minX,y:track.minY+(track.height-thumbHeight)*libraryScroll/libraryMaximumScroll,width:3,height:thumbHeight),color(0x9bd2b6,0.65),radius:2)
    }
    if games.isEmpty{
      let r=CGRect(x:left,y:145,width:content,height:220);round(r,color(0x222b30))
      icon("gamecontroller",CGRect(x:left+24,y:173,width:38,height:38),tint:color(0xa2eec2))
      text(!query.isEmpty ? "Nessun risultato":"La tua libreria comincia qui",CGRect(x:left+82,y:172,width:content-104,height:32),size:22,bold:true)
      text(!query.isEmpty ? "Prova un titolo o un ID differente.":"Collega uno store per vedere tutti i giochi posseduti, oppure importa un gioco installato.",CGRect(x:left+24,y:237,width:content-48,height:65),size:15,color:color(0xb5c2c7))
      if query.isEmpty{registerHit(r,id:"empty.import",action:.importGame)}
    }
    finishScene(left: left, content: content, height: height, libraryHelp: true)
  }
  private func drawSoftChrome(_ cg:CGContext,rect:CGRect,top:Bool){
    // Blur only our existing UI raster on rare chrome updates. This is not a
    // screenshot or game-frame readback; the suspended canvas never runs it.
    let scale=max(1,abs(cg.ctm.a)),deviceRect=CGRect(x:rect.minX*scale,y:rect.minY*scale,width:rect.width*scale,height:rect.height*scale).integral
    // In hosted mode this raster is transparent behind the chrome; the game
    // already supplies its GPU blur. Filtering transparent pixels changes
    // nothing and used to delay the first overlay frame on the CPU.
    if !gameInterfaceMode,let ownRaster=cg.makeImage(),let crop=ownRaster.cropping(to:deviceRect){
      chromeBlurPasses+=1
      let input=CIImage(cgImage:crop),blurred=input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:12*scale]).cropped(to:input.extent)
      let mask=CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:0,y:input.extent.height),"inputColor0":CIColor(red:top ? 0:0.5,green:top ? 0:0.5,blue:top ? 0:0.5),"inputColor1":CIColor(red:top ? 0.5:0,green:top ? 0.5:0,blue:top ? 0.5:0)])?.outputImage?.cropped(to:input.extent)
      let softened=mask.map{blurred.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:input,kCIInputMaskImageKey:$0])} ?? input
      if let output=Self.chromeBlurContext.createCGImage(softened,from:input.extent){
        cg.saveGState();cg.clip(to:rect);cg.translateBy(x:rect.minX,y:rect.maxY);cg.scaleBy(x:1,y:-1);cg.draw(output,in:CGRect(origin:.zero,size:rect.size));cg.restoreGState()
      }
    }
    let colors=[color(0x0c1114,top ? 0.50:0.0).cgColor,color(0x101719,0.24).cgColor,color(0x0c1114,top ? 0.0:0.50).cgColor] as CFArray
    guard let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,0.5,1])else{return}
    cg.saveGState();cg.clip(to:rect);cg.drawLinearGradient(gradient,start:CGPoint(x:rect.midX,y:rect.minY),end:CGPoint(x:rect.midX,y:rect.maxY),options:[]);cg.restoreGState()
  }

  private func finishScene(left: CGFloat, content: CGFloat, height: CGFloat, libraryHelp: Bool) {
    let nextHover = drawingChrome ? hoverID:pointerLocation.flatMap { hit(at: $0)?.id }
    if nextHover != hoverID {
      hoverID = nextHover
      if !hoverRedrawScheduled {
        hoverRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.hoverRedrawScheduled = false; self.redraw()
        }
      }
    }
    let footer=messageIsError ? message:""
    if !footer.isEmpty {
      drawSoftChrome(NSGraphicsContext.current!.cgContext,rect:CGRect(x:72,y:height-55,width:bounds.width-72,height:55),top:false)
      NSGraphicsContext.current?.cgContext.saveGState();NSGraphicsContext.current?.cgContext.setShadow(offset:CGSize(width:0,height:1),blur:8,color:color(0x000000,0.45).cgColor)
      text(footer,CGRect(x:left,y:height-36,width:content,height:25),size:12,color:color(0xf1b5a6));NSGraphicsContext.current?.cgContext.restoreGState()
    }
  }
  // Controller focus on the persistent shell must never activate hidden games.
  func handleShellController(_ action: ControllerNavigation.Action) {
    guard section != .library, interactionEnabled, !suspended else { return }
    switch action {
    case .move(let direction):
      guard !hits.isEmpty else { return }
      let step = direction == .left || direction == .up ? -1 : 1
      let current = focusID.flatMap { id in hits.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : 0)
      focusID = hits[(current + step + hits.count) % hits.count].id
      redraw()
    case .activate:
      if let id = focusID, let target = hits.first(where: { $0.id == id }) { activate(target) }
    default: break
    }
  }
  override func keyDown(with event: NSEvent) {
    guard interactionEnabled && !suspended else { return }
    switch event.keyCode {
    case 48:
      guard !hits.isEmpty else { return }
      let step = event.modifierFlags.contains(.shift) ? -1 : 1
      let current = focusID.flatMap { id in hits.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : 0)
      focusID = hits[(current + step + hits.count) % hits.count].id; redraw()
    case 123:
      guard section == .library else { return }
      focusID = nil
      selected = max(0, selected - 1)
      revealSelection();redraw()
    case 124:
      guard section == .library else { return }
      focusID = nil
      selected = min(max(visibleGames.count - 1, 0), selected + 1)
      revealSelection();redraw()
    case 125,126:
      guard section == .library else{return}
      focusID=nil;selected=min(max(visibleGames.count-1,0),max(0,selected+(event.keyCode==125 ? libraryGridColumns:-libraryGridColumns)))
      revealSelection();redraw()
    case 36:
      if let id = focusID, let target = hits.first(where: { $0.id == id }) { activate(target); return }
      guard section == .library else { return }
      if visibleGames.indices.contains(selected) { onAction?(.game(visibleGames[selected].id)) }
    case 49:
      if let id = focusID, let target = hits.first(where: { $0.id == id }) {
        if case .game(let gameID) = target.action {
          if section == .library { onAction?(.gameOptions(gameID)) }
        } else { activate(target) }
        return
      }
      guard section == .library else { return }
      if visibleGames.indices.contains(selected) {
        onAction?(.gameOptions(visibleGames[selected].id))
      }
    case 53: if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
    default: super.keyDown(with: event)
    }
  }
  private func revealSelection(){
    let top=CGFloat(selected/max(1,libraryGridColumns))*libraryCardStride
    if top<libraryScroll{libraryScroll=top}
    else if top+libraryCardStride>libraryScroll+libraryViewport.height{libraryScroll=top+libraryCardStride-libraryViewport.height}
    libraryScroll=min(libraryMaximumScroll,max(0,libraryScroll))
  }
  func moveLibrarySelection(_ direction:ControllerNavigation.Direction){
    guard section == .library,interactionEnabled,!suspended else{return}
    let delta:Int
    switch direction{case .left:delta = -1;case .right:delta=1;case .up:delta = -libraryGridColumns;case .down:delta=libraryGridColumns}
    selected=ControllerNavigation.movedSelection(selected,count:visibleGames.count,delta:delta)
    revealSelection();redraw()
  }
  static func platformLabels(_ game:Game)->[String]{
    var labels=[String]()
    if game.variants.contains(where:{$0.platform == .macOS && $0.installed && ($0.architecture == .arm64 || $0.architecture == .universal)}){labels.append("Apple Silicon")}
    else if game.variants.contains(where:{$0.platform == .macOS}){labels.append("Mac")}
    if game.variants.contains(where:{$0.platform == .windows}){labels.append("Windows")}
    return labels
  }
  override func scrollWheel(with event:NSEvent){
    guard section == .library,interactionEnabled,!suspended else{super.scrollWheel(with:event);return}
    let point=convert(event.locationInWindow,from:nil);guard libraryViewport.contains(point)else{return}
    scrollLibrary(by: -event.scrollingDeltaY*(event.hasPreciseScrollingDeltas ? 1:24))
  }
  func scrollLibrary(by amount:CGFloat){
    guard section == .library,interactionEnabled,!suspended,amount.isFinite else{return}
    pressedID=nil;scrollDirection=amount>=0 ? 1:-1;libraryScroll=min(libraryMaximumScroll,max(0,libraryScroll+amount));gridSurface?.setOffset(libraryScroll);recordViewportEntries();rebuildInteractiveHits();redraw()
  }
  override func mouseDown(with event: NSEvent) {
    guard interactionEnabled && !suspended else { return }
    window?.makeFirstResponder(self)
    updatePointer(event)
    pressedID = hit(at: convert(event.locationInWindow, from: nil))?.id
    redraw()
  }
  override func mouseUp(with event: NSEvent) {
    let target = hit(at: convert(event.locationInWindow, from: nil))
    let shouldActivate = pressedID != nil && pressedID == target?.id
    pressedID = nil; updatePointer(event); redraw()
    if shouldActivate, let target { activate(target) }
  }
  override func rightMouseDown(with event: NSEvent) {
    guard section == .library else { return }
    guard let target = hit(at: convert(event.locationInWindow, from: nil)), case .game(let id) = target.action else { return }
    onAction?(.gameOptions(id))
  }
  func writePreview(_ url: URL) throws {
    // Reuse exactly the scene renderer, without screen capture permissions.
    let w = Int(bounds.width)
    let h = Int(bounds.height)
    guard let bitmap = CanvasRaster(width: w, height: h) else { return }
    bitmap.draw(logicalSize: bounds.size, scale: 1) { drawScene($0) }
    guard let image = bitmap.context.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    if let png = rep.representation(using: .png, properties: [:]) { try png.write(to: url) }
  }
  /// Reference and native layer snapshots are for owned UI validation only.
  /// Interactive scrolling never invokes this full-canvas raster path.
  func makeReferenceRaster(scale:CGFloat=1)->CanvasRaster?{
    guard let bitmap=CanvasRaster(width:Int(bounds.width*scale),height:Int(bounds.height*scale))else{return nil}
    bitmap.draw(logicalSize:bounds.size,scale:scale){drawScene($0)};return bitmap
  }
  func writeNativeGridPreview(_ url:URL)throws{
    guard let bitmap=CanvasRaster(width:Int(bounds.width),height:Int(bounds.height))else{return}
    drawingChrome=true;bitmap.draw(logicalSize:bounds.size,scale:1){cg in drawScene(cg);gridSurface?.renderVisible(in:cg)};drawingChrome=false
    if let image=bitmap.context.makeImage(),let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]){try data.write(to:url)}
  }
}
