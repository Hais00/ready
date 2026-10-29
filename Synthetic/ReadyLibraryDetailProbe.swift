// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import LauncherCore
import Metal

final class ArtworkFixtureProtocol:URLProtocol {
  static let lock=NSLock()
  static var png=Data(),requests=[String:Int](),inFlight=0,maximum=0
  private var stopped=false
  override class func canInit(with request:URLRequest)->Bool{request.url?.scheme=="https"}
  override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
  override func startLoading(){
    let path=request.url!.path;Self.lock.lock();Self.requests[path,default:0]+=1;Self.inFlight+=1;Self.maximum=max(Self.maximum,Self.inFlight);Self.lock.unlock()
    DispatchQueue.global().asyncAfter(deadline:.now()+0.015){[self]in
      Self.lock.lock();guard !stopped else{Self.lock.unlock();return};stopped=true;Self.inFlight-=1;Self.lock.unlock()
      let status=path.contains("missing") ? 404:200,body=path.contains("invalid") ? Data("not an image".utf8):Self.png
      client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"image/png"])!,cacheStoragePolicy:.notAllowed)
      client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading(){Self.lock.lock();if !stopped{stopped=true;Self.inFlight-=1};Self.lock.unlock()}
  static func count(_ path:String)->Int{lock.lock();defer{lock.unlock()};return requests[path] ?? 0}
}
private final class HiddenLibraryWindow:NSWindow {
  override func makeKeyAndOrderFront(_ sender:Any?){}
  override func orderFront(_ sender:Any?){}
  override func orderBack(_ sender:Any?){}
}
@main struct ReadyLibraryDetailProbe {
  @MainActor static func pump(_ seconds:TimeInterval=0.035){let end=Date().addingTimeInterval(seconds);while Date()<end{RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.002))}}
  @MainActor static func run(_ root:URL)throws{
    var checks=[String:Bool]()
    func check(_ name:String,_ condition:Bool){checks[name]=condition}
    do {
      let defaults=UserDefaults.standard,saved=UserDefaults.standard.volatileDomain(forName:UserDefaults.argumentDomain)
      defer{defaults.setVolatileDomain(saved,forName:UserDefaults.argumentDomain)}
      let expected=root.appendingPathComponent("override-artwork",isDirectory:true)
      defaults.setVolatileDomain(["readyArtworkCacheDirectory":expected.path],forName:UserDefaults.argumentDomain)
      check("default-cache-accepts-private-absolute-override",ArtworkCache.defaultDirectory?.path==expected.standardizedFileURL.path)
      var invalidRejected=true
      for path in ["relative/artwork","/"]{
        defaults.setVolatileDomain(["readyArtworkCacheDirectory":path],forName:UserDefaults.argumentDomain)
        invalidRejected=invalidRejected && ArtworkCache.defaultDirectory==nil
      }
      check("invalid-cache-overrides-disable-disk",invalidRejected)
      defaults.setVolatileDomain(["readyArtworkCacheDirectory":"/private/tmp/../.."],forName:UserDefaults.argumentDomain)
      check("normalized-root-cache-override-disables-disk",ArtworkCache.defaultDirectory==nil)
    }
    let raster=CanvasRaster(width:600,height:900)!;raster.context.setFillColor(NSColor(srgbRed:0.85,green:0.15,blue:0.08,alpha:1).cgColor);raster.context.fill(CGRect(x:0,y:0,width:600,height:900))
    ArtworkFixtureProtocol.png=NSBitmapImageRep(cgImage:raster.context.makeImage()!).representation(using:.png,properties:[:])!
    let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ArtworkFixtureProtocol.self];let session=URLSession(configuration:config)
    let disk=root.appendingPathComponent("artwork",isDirectory:true),cache=ArtworkCache(directory:disk,session:session)
    let good="https://artwork.ready.invalid/good.png",missing="https://artwork.ready.invalid/missing.png"
    var image:CGImage?;let deadline=Date().addingTimeInterval(3)
    while image==nil && Date()<deadline{image=cache.image(addresses:[missing,good],refresh:{});pump()}
    check("failed-artwork-falls-back-without-stuck-request",image != nil && ArtworkFixtureProtocol.count("/missing.png")==1 && ArtworkFixtureProtocol.count("/good.png")==1)
    for _ in 0..<20{_ = cache.image(good,refresh:{})};check("memory-hit-does-not-refetch",ArtworkFixtureProtocol.count("/good.png")==1)
    check("http-file-and-credential-urls-rejected",cache.image("http://artwork.ready.invalid/plain",refresh:{})==nil && cache.image("file:///tmp/private",refresh:{})==nil && cache.image("https://user:pass@artwork.ready.invalid/private",refresh:{})==nil)
    let offline=ArtworkCache(directory:disk,session:session,networkEnabled:false);var diskImage:CGImage?
    let diskDeadline=Date().addingTimeInterval(3);while diskImage==nil && Date()<diskDeadline{diskImage=offline.image(good,refresh:{});pump()}
    check("disk-thumbnail-works-with-network-disabled",diskImage != nil && ArtworkFixtureProtocol.count("/good.png")==1)
    let alias=root.appendingPathComponent("artwork-alias",isDirectory:true);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:disk)
    let aliased=ArtworkCache(directory:alias,session:session,networkEnabled:false);var aliasImage:CGImage?
    for _ in 0..<5{aliasImage=aliased.image(good,refresh:{});pump()}
    check("disk-cache-alias-is-rejected",aliasImage==nil);aliased.purge()
    for i in 0..<20{_ = cache.image("https://artwork.ready.invalid/concurrent\(i).png",refresh:{})}
    pump(0.6);check("artwork-network-concurrency-bounded",ArtworkFixtureProtocol.maximum<=4)
    let late="https://artwork.ready.invalid/late.png";_ = cache.image(late,refresh:{});cache.purge();pump()
    var retry:CGImage?;let retryDeadline=Date().addingTimeInterval(3);while retry==nil && Date()<retryDeadline{retry=cache.image(late,refresh:{});pump()}
    check("purge-cancels-and-allows-fresh-request",retry != nil)
    guard let device=MTLCreateSystemDefaultDevice()else{throw NSError(domain:"NoMetal",code:1)}
    var games=[Game]()
    for i in 0..<60{
      let mac=GameVariant(id:"macOS",platform:.macOS,architecture:i%2==0 ? .arm64:.unknown,installed:i%2==0,verification:"Fixture architecture only")
      let win=GameVariant(id:"windows",platform:.windows)
      var game=Game(id:"fixture-\(i)",store:[Store.steam,.epic,.gog,.amazon][i%4],storeID:String(500000+i),title:String(format:"Fixture Game %03d",i),artworkURL:"https://artwork.ready.invalid/cover\(i).png",variants:[mac,win])
      game.metadata=["shortDescription":.string("Una descrizione sintetica del gioco."),"description":.string("<b>Descrizione</b> sicura. "+String(repeating:"Testo leggibile e proporzionato. ",count:12)),"genres":.array([.string("Avventura"),.string("Azione")]),"developers":.array([.string("Studio sintetico")]),"metadataComplete":.bool(true)]
      games.append(game)
    }
    let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:1240,height:760),device:device,artworkCache:cache);canvas.state.games=games
    defer{canvas.releaseGraphics();cache.purge();offline.purge();session.invalidateAndCancel()}
    func preview(_ name:String)throws{try canvas.writePreview(root.appendingPathComponent(name+".png"))}
    try preview("library-first");pump(0.5);try preview("library-covers")
    if let bitmap=NSBitmapImageRep(data:try Data(contentsOf:root.appendingPathComponent("library-covers.png"))){
      let a=bitmap.colorAt(x:160,y:240)!.usingColorSpace(.sRGB)!,b=bitmap.colorAt(x:350,y:240)!.usingColorSpace(.sRGB)!
      check("installed-artwork-remains-in-color",a.redComponent-a.greenComponent>0.4)
      check("not-installed-artwork-is-grayscale",abs(b.redComponent-b.greenComponent)<0.04 && abs(b.greenComponent-b.blueComponent)<0.04)
    }else{check("installed-artwork-remains-in-color",false);check("not-installed-artwork-is-grayscale",false)}
    let first=canvas.libraryLayoutSnapshot
    check("library-shows-grid-not-horizontal-strip",first.columns>=4 && Set(canvas.interactionSnapshot.hits.filter{$0.id.hasPrefix("game.")}.map{Int($0.rect.minY)}).count>=2)
    check("all-sixty-owned-games-remain-in-model",canvas.visibleGames.count==60 && first.maximum>0)
    check("all-visible-hit-targets-clipped-to-viewport",canvas.interactionSnapshot.hits.filter{$0.id.hasPrefix("game.")}.allSatisfy{first.viewport.contains($0.rect)})
    canvas.scrollLibrary(by:1_000_000);try preview("library-last")
    check("scroll-reaches-last-owned-game",canvas.libraryLayoutSnapshot.offset==canvas.libraryLayoutSnapshot.maximum && canvas.libraryLayoutSnapshot.visibleIDs.contains("fixture-59"))
    canvas.selected=0;canvas.moveLibrarySelection(.down)
    check("grid-controller-down-moves-one-row",canvas.selected==canvas.libraryLayoutSnapshot.columns)
    canvas.moveLibrarySelection(.up);check("grid-controller-up-restores-first-card",canvas.selected==0 && canvas.libraryLayoutSnapshot.offset==0)
    canvas.filter = .steam;try preview("library-steam");check("store-filter-preserves-all-owned-matching-games",canvas.visibleGames.count==15)
    canvas.filter=nil;canvas.query="Fixture Game 059";try preview("library-search");check("search-has-no-stale-scrolled-targets",canvas.visibleGames.count==1 && canvas.libraryLayoutSnapshot.visibleIDs==["fixture-59"] && canvas.libraryLayoutSnapshot.offset==0)
    canvas.query="";canvas.section = .utility;try preview("library-hidden");check("detail-shell-cannot-click-hidden-library-games",!canvas.interactionSnapshot.hits.contains{$0.id.hasPrefix("game.")})
    check("unknown-mac-not-labelled-apple-silicon",MetalCanvas.platformLabels(games[1])==["Mac","Windows"])
    check("verified-installed-mac-and-windows-both-shown",MetalCanvas.platformLabels(games[0])==["Apple Silicon","Windows"])
    var notInstalled=games[0];notInstalled.variants[0].installed=false
    check("uninstalled-arm64-metadata-does-not-claim-verification",MetalCanvas.platformLabels(notInstalled)==["Mac","Windows"])
    var cached=games[0],concrete=cached.variants[0];concrete.id="mac:Fixture.app"
    let availability=GameVariant(id:"macOS",platform:.macOS)
    cached.variants=[concrete,cached.variants[1],availability]
    let originalCached=cached
    let cachedView=GameDetailView(game:cached,artwork:cache,profile:UUID())
    let cachedPicker=cachedView.subviews.compactMap{$0 as?NSPopUpButton}.first!
    let duplicateHidden=cachedPicker.itemArray.compactMap{$0.representedObject as?String}==["mac:Fixture.app","windows"]
    var custom=cached;custom.variants += [GameVariant(id:"custom-intel",platform:.macOS,architecture:.x86_64),GameVariant(id:"custom-launcher",platform:.macOS)]
    cachedView.update(game:custom,jobs:[])
    let customIDs=cachedPicker.itemArray.compactMap{$0.representedObject as?String}
    check("cached-platform-placeholders-hidden-without-dropping-custom-or-model-data",duplicateHidden && customIDs==["mac:Fixture.app","windows","custom-intel","custom-launcher"] && cached==originalCached)
    var explicit=cached;explicit.selectedVariant="macOS"
    let explicitView=GameDetailView(game:explicit,artwork:cache,profile:UUID())
    let explicitPicker=explicitView.subviews.compactMap{$0 as?NSPopUpButton}.first!
    let configuredSelectionKept=explicitPicker.itemArray.contains{($0.representedObject as?String)=="macOS"} && explicitView.selectedVariant?.id=="macOS"
    var beforeInstall=cached;beforeInstall.variants=[cached.variants[1],availability]
    let userView=GameDetailView(game:beforeInstall,artwork:cache,profile:UUID())
    let userPicker=userView.subviews.compactMap{$0 as?NSPopUpButton}.first!
    userPicker.selectItem(at:1);userPicker.sendAction(userPicker.action!,to:userPicker.target);userView.update(game:cached,jobs:[])
    check("explicit-placeholder-selection-remains-visible-and-selectable",configuredSelectionKept && userView.selectedVariant?.id=="macOS" && userPicker.itemArray.contains{($0.representedObject as?String)=="macOS"})
    var artGame=games[0];artGame.metadata?["capsuleURL"] = .string("https://artwork.ready.invalid/capsule_184x69.jpg");artGame.metadata?["iconURL"] = .string("https://artwork.ready.invalid/icon32.jpg");artGame.artworkURL="https://artwork.ready.invalid/icon32.jpg"
    let cardCandidates=GameArtwork.candidates(for:artGame,role:.card),bannerCandidates=GameArtwork.candidates(for:artGame,role:.banner)
    var invalidID=artGame;invalidID.storeID="500000/../private"
    var nonSteam=artGame;nonSteam.store = .epic
    check("steam-artwork-prefers-portrait-hero-and-canonical-app-ids",cardCandidates.first?.hasSuffix("/500000/library_600x900.jpg")==true && bannerCandidates.first?.hasSuffix("/500000/library_hero.jpg")==true && !bannerCandidates.contains("https://artwork.ready.invalid/icon32.jpg") && GameArtwork.candidates(for:invalidID,role:.card).allSatisfy{!$0.contains("steam/apps/")} && GameArtwork.candidates(for:nonSteam,role:.card).first=="https://artwork.ready.invalid/capsule_184x69.jpg")
    let imageBounds=CGRect(x:10,y:20,width:200,height:260),smallRect=GameArtwork.imageRect(imageSize:CGSize(width:32,height:32),in:imageBounds,role:.card),wideRect=GameArtwork.imageRect(imageSize:CGSize(width:184,height:69),in:imageBounds,role:.card)
    check("small-or-low-resolution-artwork-centers-without-upscale",smallRect.size==CGSize(width:32,height:32) && smallRect.midX==imageBounds.midX && smallRect.midY==imageBounds.midY && wideRect.size==CGSize(width:184,height:69) && GameArtwork.shouldAspectFit(imageSize:CGSize(width:32,height:32),role:.banner) && GameArtwork.imageRect(imageSize:.zero,in:imageBounds,role:.icon) == .zero)
    let cachedBannerGame=games[0]
    let bannerDeadline=Date().addingTimeInterval(3)
    while cache.image(for:cachedBannerGame,role:.banner,refresh:{})==nil && Date()<bannerDeadline{pump()};pump(0.15)
    let coldCache=ArtworkCache(directory:disk,session:session,networkEnabled:false)
    let iconDeadline=Date().addingTimeInterval(3)
    while coldCache.image(for:cachedBannerGame,role:.icon,refresh:{})==nil && Date()<iconDeadline{pump()}
    let stableDetail=GameDetailView(game:cachedBannerGame,artwork:coldCache,profile:UUID())
    check("cached-banner-disk-load-does-not-flash-a-different-icon",coldCache.hasCachedImage(gameID:cachedBannerGame.id,role:.banner) && stableDetail.artworkSnapshot.role == .banner && !stableDetail.artworkSnapshot.hasImage)
    pump(0.25);check("cached-banner-appears-after-disk-decode-without-role-switch",stableDetail.artworkSnapshot.role == .banner && stableDetail.artworkSnapshot.hasImage);coldCache.purge()
    let detail=GameDetailView(game:games[0],artwork:cache,profile:UUID())
    let detailWindow=HiddenLibraryWindow(contentRect:detail.frame,styleMask:[.titled],backing:.buffered,defer:false);detailWindow.isReleasedWhenClosed=false;detailWindow.contentView=detail
    defer{detailWindow.close()}
    var playIDs=[String](),installIDs=[String]();detail.onPlay={playIDs.append($0.id)};detail.onInstall={installIDs.append($0.id)}
    for width:CGFloat in [460,752,1092]{
      detail.setFrameSize(NSSize(width:width,height:detail.frame.height));detail.layoutSubtreeIfNeeded();pump();detail.layoutSubtreeIfNeeded()
      check("detail-responsive-\(Int(width))-all-controls-fit",detail.subviews.allSatisfy{$0.isHidden || ($0.frame.minX >= -0.5 && $0.frame.maxX<=width+0.5 && $0.frame.height>0)})
      check("detail-responsive-\(Int(width))-natural-content-height",detail.frame.height>500 && detail.frame.height<1800)
      if let bitmap=detail.bitmapImageRepForCachingDisplay(in:detail.bounds){detail.cacheDisplay(in:detail.bounds,to:bitmap);if let png=bitmap.representation(using:.png,properties:[:]){try png.write(to:root.appendingPathComponent("detail-\(Int(width)).png"))}}
    }
    let labels=detail.subviews.compactMap{($0 as?NSTextField)?.stringValue}.joined(separator:" ")
    check("description-is-plain-text-and-metadata-present",!labels.contains("<b>") && labels.contains("Studio sintetico") && labels.contains("Avventura"))
    let primary=detail.subviews.compactMap{$0 as?NSButton}.first{$0.title=="Gioca"}!;primary.performClick(nil)
    check("installed-selected-variant-plays-exact-choice",playIDs==["macOS"])
    let picker=detail.subviews.compactMap{$0 as?NSPopUpButton}.first!;picker.selectItem(at:1);picker.sendAction(picker.action!,to:picker.target)
    check("windows-version-selector-shows-install-action",detail.selectedVariant?.id=="windows" && detail.detailSnapshot.primaryTitle=="Installa")
    detail.subviews.compactMap{$0 as?NSButton}.first{$0.title=="Installa"}?.performClick(nil)
    check("install-callback-keeps-explicit-platform",installIDs==["windows"])
    let job=SteamDownloadJob(["jobID":UUID().uuidString,"gameID":games[0].storeID,"platform":"windows","state":"running","fraction":0.4,"sequence":2])!
    detail.update(game:games[0],jobs:[job]);pump()
    check("detail-download-progress-is-inline-and-play-disabled",detail.detailSnapshot.primaryTitle=="Download in corso" && !detail.detailSnapshot.primaryEnabled && detail.subviews.compactMap{$0 as?NSProgressIndicator}.contains{!$0.isHidden && $0.doubleValue==0.4})
    detail.update(game:games[0],jobs:[]);detail.setTransferStatus("Download GOG sintetico",fraction:0.3);pump()
    check("other-store-transfer-progress-has-inline-hook",!detail.detailSnapshot.primaryEnabled && detail.subviews.compactMap{$0 as?NSTextField}.contains{$0.stringValue=="Download GOG sintetico"})
    detail.setTransferStatus(nil);pump();check("transfer-error-clear-allows-retry",detail.detailSnapshot.primaryTitle=="Installa" && detail.detailSnapshot.primaryEnabled)
    let viewWindow=HiddenLibraryWindow(contentRect:NSRect(x:0,y:0,width:1240,height:760),styleMask:[.titled],backing:.buffered,defer:false);viewWindow.isReleasedWhenClosed=false;viewWindow.contentView=canvas
    let delegate=AppDelegate();delegate.canvas=canvas;delegate.window=viewWindow;delegate.session=TestSession();delegate.state=canvas.state
    delegate.showGameDetails(id:games[0].id);pump();let presented=delegate.gameDetailView!
    presented.onPlay?(games[0].variants[0]);check("detail-production-extension-routes-play-with-variant",delegate.plays==["fixture-0:macOS"])
    presented.onInstall?(games[0].variants[1]);check("detail-production-extension-download-stays-on-page",delegate.installs==["fixture-0:windows:false"])
    let oldProfile=delegate.state.activeProfile;delegate.state.activeProfile=UUID()
    presented.onPlay?(games[0].variants[0]);presented.onInstall?(games[0].variants[1]);check("stale-profile-cannot-play-or-install",delegate.plays.count==1 && delegate.installs.count==1)
    delegate.refreshGameDetails();check("profile-switch-clears-detail-page",delegate.gameDetailView==nil && delegate.gameDetailID==nil)
    delegate.state.activeProfile=oldProfile;viewWindow.close()
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"fixtureOnly":true,"actualAccountsKeychainOrGamesUsed":false,"globalInputInjected":false,"windowActivated":false,"externalNetworkUsed":false,"previewRoot":root.path]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]));if !checks.values.allSatisfy({$0}){exit(1)}
  }
  static func main(){_ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited);guard CommandLine.arguments.count==2 else{exit(64)};do{try MainActor.assumeIsolated{try run(URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true))}}catch{FileHandle.standardError.write(Data("Owned library UI fixture failed.\n".utf8));exit(1)}}
}
