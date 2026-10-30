// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Metal
import LauncherCore
private final class AppearanceArtworkProtocol:URLProtocol{
  static var image=Data()
  override class func canInit(with request:URLRequest)->Bool{request.url?.scheme=="https"}
  override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
  override func startLoading(){client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"image/png"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:Self.image);client?.urlProtocolDidFinishLoading(self)}
  override func stopLoading(){}
}
private final class AppearanceWindow:NSWindow{override func constrainFrameRect(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}}
@main struct ReadyLibraryAppearanceProbe {
  @MainActor static func main()throws {
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    guard let device=MTLCreateSystemDefaultDevice()else{throw NSError(domain:"fixture-metal-unavailable",code:1)}
    let root=URL(fileURLWithPath:CommandLine.arguments[1])
    let raster=CGContext(data:nil,width:600,height:900,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    raster.setFillColor(NSColor.blue.cgColor);raster.fill(CGRect(x:0,y:0,width:600,height:900));raster.setFillColor(NSColor.red.cgColor);raster.fill(CGRect(x:0,y:840,width:600,height:60));raster.setFillColor(NSColor.green.cgColor);raster.fill(CGRect(x:0,y:0,width:600,height:60));AppearanceArtworkProtocol.image=NSBitmapImageRep(cgImage:raster.makeImage()!).representation(using:.png,properties:[:])!
    let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AppearanceArtworkProtocol.self]
    let cache=ArtworkCache(directory:root.appendingPathComponent("cache"),session:URLSession(configuration:config))
    let native=GameVariant(id:"native",platform:.macOS,architecture:.arm64,executable:"/own/fixture",installed:true),windows=GameVariant(id:"windows",platform:.windows)
    var game=Game(id:"fixture",store:.steam,storeID:"480",title:"One readable title",artworkURL:"https://own.invalid/cover.png",variants:[native,windows]);game.metadata=["libraryKind":.string("game"),"description":.string(String(repeating:"Own descriptive content for scrolling. ",count:100))]
    var state=LibraryState.initial();state.games=[game,Game(id:"other",store:.gog,storeID:"123",title:"Uninstalled title",artworkURL:"https://own.invalid/cover.png",variants:[windows])]
    var checks=[String:Bool]()
    func check(_ value:Bool,_ name:String)throws{checks[name]=value;if !value{throw NSError(domain:name,code:1)}}
    func pump(_ seconds:Double=0.08){let end=Date().addingTimeInterval(seconds);while Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))}}
    let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:1000,height:820),device:device,artworkCache:cache)
    canvas.state=state
    for item in state.games{let deadline=Date().addingTimeInterval(3);while cache.image(for:item,role:.card,refresh:{})==nil && Date()<deadline{pump(0.01)}}
    let window=AppearanceWindow(contentRect:canvas.bounds,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=canvas
    defer{canvas.releaseGraphics();window.close()}
    canvas.renderDisplayTick();pump();canvas.renderDisplayTick()
    guard let surface=canvas.subviews.first(where:{$0 is LibraryGridSurface})as?LibraryGridSurface else{throw NSError(domain:"missing-actual-grid",code:1)}
    try check(surface.feedbackGeometry.allSatisfy{surface.documentBounds.contains($0)} && (surface.feedbackGeometry.first?.minY ?? -1) >= 0,"selectionRingFitsPaddedDocumentAtFirstRow")
    let hit=canvas.interactionSnapshot.hits.first{$0.id=="game.fixture"}!
    try check(hit.rect.minY-canvas.libraryLayoutSnapshot.viewport.minY>=LibraryCardMetrics.focusOutset,"firstRowHasViewportRoomForOuterFocusRing")
    try check(abs(hit.rect.height-(hit.rect.width*1.5+42))<0.1,"cardAllocatesCoverAndTitleOnlyHeight")
    let point=canvas.convert(NSPoint(x:hit.rect.midX,y:hit.rect.midY),to:nil)
    let hover=NSEvent.mouseEvent(with:.mouseMoved,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
    canvas.mouseMoved(with:hover);canvas.renderDisplayTick()
    try check(canvas.interactionSnapshot.hover=="game.fixture" && surface.feedbackGeometry.count>=2 && surface.feedbackGeometry.allSatisfy{surface.documentBounds.contains($0)},"actualMouseHoverAndSelectionRingsStayInsidePaddedDocument")

    guard let reference=canvas.makeReferenceRaster(),let image=reference.context.makeImage()else{throw NSError(domain:"actual-card-raster",code:1)}
    let bitmap=NSBitmapImageRep(cgImage:image),coverHeight=hit.rect.width*LibraryCardMetrics.coverRatio
    func sample(_ x:CGFloat,_ y:CGFloat)->NSColor{bitmap.colorAt(x:Int(x),y:Int(y))!.usingColorSpace(.sRGB)!}
    let top=sample(hit.rect.midX,hit.rect.minY+5),bottom=sample(hit.rect.midX,hit.rect.minY+coverHeight-5)
    try check((top.redComponent>0.8 && bottom.greenComponent>0.8)||(top.greenComponent>0.8 && bottom.redComponent>0.8),"portraitCoverEdgeSentinelsRemainVisibleWithoutCropping")
    let second=canvas.interactionSnapshot.hits.first{$0.id=="game.other"}!,gray=sample(second.rect.midX,second.rect.minY+coverHeight/2)
    try check(abs(gray.redComponent-gray.greenComponent)<0.03 && abs(gray.greenComponent-gray.blueComponent)<0.03,"uninstalledCoverRasterRemainsGrayscale")
    let snapshot=canvas.gameplayViewportGames,sortBefore=canvas.visibleGames.map(\.id)
    cache.beginGameplay()
    cache.setMaintenanceSuspended(true)
    canvas.releaseGraphics()
    try check(canvas.allocatedTextureBytes==0 && canvas.gameplayViewportGames.map(\.id)==snapshot.map(\.id),"graphicsReleaseRetainsOnlyViewportModelsAndClearsGPUStorage")
    try check(cache.gameplaySuspended && snapshot.allSatisfy{!cache.hasResidentImage(gameID:$0.id,role:.card)},"gameplayReleasesDecodedCardsAndAllCanvasGPUStorage")
    var restored=false;let returnBegan=ProcessInfo.processInfo.systemUptime
    cache.restoreFirstViewport(games:snapshot){restored=true}
    let returnDeadline=Date().addingTimeInterval(3)
    while !restored && Date()<returnDeadline{pump(0.01)}
    canvas.resumeGraphics();canvas.renderDisplayTick();pump();canvas.renderDisplayTick()
    let returnMilliseconds=(ProcessInfo.processInfo.systemUptime-returnBegan)*1000
    try check(restored && canvas.visibleGames.map(\.id)==sortBefore && canvas.viewportArtworkSnapshot.committedIDs.isSuperset(of:Set(snapshot.map(\.id))),"returnRestoresFirstViewportRealArtworkAndCachedSortBeforeBackgroundWarm")
    try check(returnMilliseconds<500,"ownIndexedDiskViewportReturnCompletesWithoutWaitingForAllArtwork")
    var nextProfileState=state;nextProfileState.activeProfile=UUID();nextProfileState.games=[Game(id:"new-profile",store:.local,storeID:"new",title:"New profile")];canvas.state=nextProfileState
    try check(canvas.gameplayViewportGames.map(\.id)==["new-profile"],"profileChangeCannotRestorePreviousProfileViewportModels")
    canvas.state=state
    canvas.resumeGraphics()
    let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:760,height:620));scroll.drawsBackground=false;scroll.hasVerticalScroller=true
    let detail=GameDetailView(game:game,artwork:cache,profile:state.activeProfile);detail.setFrameSize(NSSize(width:740,height:1000));scroll.documentView=detail
    let dw=AppearanceWindow(contentRect:scroll.frame,styleMask:[.titled],backing:.buffered,defer:false);dw.isReleasedWhenClosed=false;dw.contentView=scroll;defer{dw.close()}
    pump();detail.layoutSubtreeIfNeeded();pump()
    try check(!detail.isOpaque && detail.navigationSnapshot.heroFrame.height>=320,"detailHasTransparentBodyAndMateriallyLargerHero")
    var plays=0,installs=0,options=0,back=0,versions=[String]()
    detail.onPlay={_ in plays+=1};detail.onInstall={_ in installs+=1};detail.onOptions={options+=1};detail.onBack={back+=1};detail.onVariantChanged={versions.append($0.id)}
    _=detail.handleController(.move(.down));try check(detail.navigationSnapshot.focus=="version","controllerFocusesVersionSelector")
    _=detail.handleController(.move(.right));try check(detail.selectedVariant?.id=="windows" && versions==["windows"],"controllerChangesVersionWithoutOpeningPopup")
    _=detail.handleController(.move(.down));_=detail.handleController(.activate);pump()
    try check(installs==1 && plays==0,"controllerPrimaryActivatesSelectedInstallVariant")
    _=detail.handleController(.move(.right));_=detail.handleController(.activate);pump()
    try check(options==1,"controllerReachesAndActivatesOptions")
    let job=SteamDownloadJob(["jobID":UUID().uuidString,"gameID":"480","platform":"windows","state":"running","sequence":1])!
    detail.update(game:game,jobs:[job]);pump();var controls=[String]();detail.onDownloadControl={_,action in controls.append(action)}
    _=detail.handleController(.move(.down));_=detail.handleController(.activate);pump()
    try check(controls==["pause"],"controllerSkipsDisabledPrimaryAndReachesDownloadControl")
    _=detail.handleController(.move(.down));let before=scroll.contentView.bounds.minY;_=detail.handleController(.move(.down));pump()
    try check(detail.navigationSnapshot.focus=="body" && scroll.contentView.bounds.minY>=before,"controllerBodyFocusScrollsLongContent")
    _=detail.handleController(.cancel);try check(back==1,"controllerBackCallsRootNavigationHook")
    detail.updateStorage(variantID:"native",installedBytes:12345);try check(!detail.navigationSnapshot.storageText.contains("Installazione"),"storageForDifferentVariantDoesNotLeakIntoCurrentSelection")
    detail.updateStorage(variantID:"windows",downloadBytes:2_000_000_000,availableBytes:20_000_000_000,location:"Own external disk");pump()
    try check(detail.navigationSnapshot.storageText.contains("Download") && detail.navigationSnapshot.storageText.contains("Own external disk"),"storageContractShowsScopedOptionalValuesWithoutFilesystemReads")
    for width:CGFloat in [460,740,1092]{detail.setFrameSize(NSSize(width:width,height:detail.frame.height));detail.layoutSubtreeIfNeeded();pump();detail.layoutSubtreeIfNeeded();try check(detail.subviews.allSatisfy{$0.isHidden || ($0.frame.minX>=0 && $0.frame.maxX<=width+0.5)},"detailControlsFitWidth\(Int(width))")}
    try check(!NSApp.isActive && !window.isKeyWindow && !dw.isKeyWindow,"ownHiddenWindowsNeverActivate")
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"count":checks.count,"checks":checks,"fixtureOnly":true,"realGameAccountOrLibraryWriteUsed":false,"globalInputInjected":false],options:[.sortedKeys]),as:UTF8.self))
  }
}
