// SPDX-License-Identifier: GPL-3.0-only
// Reads only the explicitly SHA-bound private COPY, never LibraryRepository.load.
import AppKit
import CryptoKit
import Darwin
import LauncherCore
import Metal

private enum CopyPreviewFailure:Error {case invalid}
private final class PublicArtworkPolicy:NSObject,URLSessionTaskDelegate {
  static let lock=NSLock();static var blocked=0,completed=0
  static var detailOnlyAppID:String?
  static func allowed(_ url:URL?)->Bool {
    guard let url,url.scheme?.lowercased()=="https",let host=url.host?.lowercased(),url.user==nil,url.password==nil,url.port==nil || url.port==443 else{return false}
    return host=="steamstatic.com" || host.hasSuffix(".steamstatic.com") || host=="steamcdn-a.akamaihd.net"
  }
  static func allowedRequest(_ url:URL?)->Bool {
    guard allowed(url),let url else{return false}
    guard let id=detailOnlyAppID else{return true}
    return url.path.contains("/apps/"+id+"/") && ["library_600x900.jpg","library_hero.jpg"].contains(url.lastPathComponent)
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){
    if Self.allowedRequest(request.url){completionHandler(request)}else{Self.lock.lock();Self.blocked+=1;Self.lock.unlock();completionHandler(nil)}
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){if Self.allowedRequest(task.originalRequest?.url){Self.lock.lock();Self.completed+=1;Self.lock.unlock()}}
}
private final class RejectNonPublicArtwork:URLProtocol {
  override class func canInit(with request:URLRequest)->Bool{!PublicArtworkPolicy.allowedRequest(request.url)}
  override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
  override func startLoading(){PublicArtworkPolicy.lock.lock();PublicArtworkPolicy.blocked+=1;PublicArtworkPolicy.lock.unlock();client?.urlProtocol(self,didFailWithError:NSError(domain:"ReadyPublicArtworkPolicy",code:1))}
  override func stopLoading(){}
}
private final class CopyPreviewWindow:NSWindow {
  override func makeKeyAndOrderFront(_ sender:Any?){}
  override func orderFront(_ sender:Any?){}
  override func orderBack(_ sender:Any?){}
}
@main struct ReadyLibraryCopyPreview {
  @MainActor static func pump(_ seconds:TimeInterval){let end=Date().addingTimeInterval(seconds);while Date()<end{RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}}
  @MainActor static func run()throws{
    guard CommandLine.arguments.count==2 else{throw CopyPreviewFailure.invalid}
    let configURL=URL(fileURLWithPath:CommandLine.arguments[1])
    let config=try JSONSerialization.jsonObject(with:Data(contentsOf:configURL)) as? [String:Any]
    guard let config,let copy=config["libraryCopy"]as?String,let expectedHash=config["librarySHA256"]as?String,
      let output=config["output"]as?String,let cacheRoot=config["artworkCache"]as?String,let detailID=config["detailStoreID"]as?String,
      let expected=config["expectedCount"]as?Int else{throw CopyPreviewFailure.invalid}
    let fd=open(copy,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw CopyPreviewFailure.invalid}
    let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try?handle.close()}
    var info=stat();guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,info.st_mode&0o077==0,info.st_size<64*1024*1024 else{throw CopyPreviewFailure.invalid}
    let bytes=try handle.readToEnd() ?? Data();let digest=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined();guard digest==expectedHash else{throw CopyPreviewFailure.invalid}
    let state=try JSONDecoder().decode(LibraryState.self,from:bytes)
    let allowNetwork=config["allowPublicArtwork"]as?Bool ?? false
    let detailOnly=config["detailArtworkOnly"]as?Bool ?? false
    PublicArtworkPolicy.detailOnlyAppID=detailOnly ? detailID:nil
    let sessionConfig=URLSessionConfiguration.ephemeral;sessionConfig.protocolClasses=[RejectNonPublicArtwork.self]
    sessionConfig.httpMaximumConnectionsPerHost=2;sessionConfig.httpShouldSetCookies=false;sessionConfig.httpCookieStorage=nil;sessionConfig.urlCredentialStorage=nil
    let policy=PublicArtworkPolicy(),session=URLSession(configuration:sessionConfig,delegate:policy,delegateQueue:nil)
    let artwork=ArtworkCache(directory:URL(fileURLWithPath:cacheRoot,isDirectory:true),session:session,networkEnabled:allowNetwork)
    defer{artwork.purge();session.invalidateAndCancel()}
    guard let device=MTLCreateSystemDefaultDevice()else{throw CopyPreviewFailure.invalid}
    let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:1240,height:760),device:device,artworkCache:artwork);canvas.state=state
    defer{canvas.releaseGraphics()}
    let destination=URL(fileURLWithPath:output,isDirectory:true)
    var checks=[String:Bool](),captures=[String:String]()
    func check(_ name:String,_ condition:Bool){checks[name]=condition}
    func save(_ name:String)throws{
      let path=destination.appendingPathComponent(name+".png");try canvas.writePreview(path)
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
      captures[name+".png"]=SHA256.hash(data:try Data(contentsOf:path)).map{String(format:"%02x",$0)}.joined()
    }
    var highPoster=false,highHero=false,posterPixels=[Int](),heroPixels=[Int]()
    if allowNetwork && detailOnly,let selected=state.games.first(where:{$0.store == .steam && $0.storeID==detailID}) {
      let poster=GameArtwork.candidates(for:selected,role:.card).first{URL(string:$0)?.lastPathComponent=="library_600x900.jpg"}
      let hero=GameArtwork.candidates(for:selected,role:.banner).first{URL(string:$0)?.lastPathComponent=="library_hero.jpg"}
      let until=Date().addingTimeInterval(12)
      while Date()<until && (!highPoster || !highHero){
        if let image=artwork.image(poster,refresh:{}){posterPixels=[image.width,image.height];highPoster=image.width>128 && image.height>image.width && abs(Double(image.width)/Double(image.height)-2.0/3.0)<0.1}
        if let image=artwork.image(hero,refresh:{}){heroPixels=[image.width,image.height];highHero=image.width>=640 && image.width>image.height && image.height>128}
        pump(0.04)
      }
      check("detail-public-standard-poster-decodes-as-portrait-with-useful-pixels",highPoster)
      check("detail-public-standard-hero-decodes-as-wide-banner",highHero)
    }
    let visible=canvas.visibleGames
    check("actual-copy-sha256-matches",true)
    check("active-profile-is-in-model",state.profiles.contains{$0.id==state.activeProfile})
    check("active-profile-visible-count-matches",visible.count==expected)
    check("profile-membership-filter-applied",visible.allSatisfy{$0.profileIDs==nil || $0.profileIDs!.contains(state.activeProfile)})
    try save("library-first");pump(allowNetwork ? 5:0.6);try save("library-first")
    let firstIDs=canvas.libraryLayoutSnapshot.visibleIDs
    check("first-row-contains-actual-sorted-library-first",visible.first.map{firstIDs.contains($0.id)} ?? false)
    canvas.scrollLibrary(by:1_000_000);try save("library-last");pump(allowNetwork ? 5:0.6);try save("library-last")
    check("last-row-contains-actual-sorted-library-last",visible.last.map{canvas.libraryLayoutSnapshot.visibleIDs.contains($0.id)} ?? false)
    canvas.filter = .steam;try save("steam-first");pump(0.2);try save("steam-first")
    let steamCount=canvas.visibleGames.count
    check("steam-filter-count-matches-copy-membership",steamCount==visible.filter{$0.store == .steam}.count)
    guard let stored=state.games.first(where:{$0.store == .steam && $0.storeID==detailID}),
      stored.profileIDs==nil || stored.profileIDs!.contains(state.activeProfile)else{throw CopyPreviewFailure.invalid}
    let game=state.configured(stored),detail=GameDetailView(game:game,artwork:artwork,profile:state.activeProfile)
    var play=0,install=0;detail.onPlay={_ in play+=1};detail.onInstall={_ in install+=1};detail.onOptions={}
    let window=CopyPreviewWindow(contentRect:NSRect(x:-8192,y:-8192,width:1092,height:760),styleMask:[.borderless],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=detail;defer{window.close()}
    detail.setFrameSize(NSSize(width:1092,height:detail.frame.height));detail.layoutSubtreeIfNeeded();pump(allowNetwork ? 5:0.6);detail.layoutSubtreeIfNeeded()
    let picker=detail.subviews.compactMap{$0 as?NSPopUpButton}.first!
    let ids=picker.itemArray.compactMap{$0.representedObject as?String}
    check("detail-picker-has-exactly-two-platform-options",ids.count==2)
    check("detail-picker-preserves-installed-native-apple-silicon",ids.contains{id in game.variants.contains{$0.id==id && $0.platform == .macOS && $0.installed && ($0.architecture == .arm64 || $0.architecture == .universal)}})
    check("detail-picker-preserves-windows-option",ids.contains{id in game.variants.contains{$0.id==id && $0.platform == .windows}})
    check("canonical-mac-placeholder-hidden-only-in-display",!ids.contains("macOS") && stored.variants.contains{$0.id=="macOS"})
    func string(_ key:String)->String?{game.metadata?[key]?.foundation as?String}
    let description=(string("description") ?? string("shortDescription") ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
    check("detail-has-actual-public-description-metadata",!description.isEmpty)
    let banner=string("heroURL") ?? string("bannerURL")
    check("detail-has-public-banner-reference",PublicArtworkPolicy.allowed(banner.flatMap{URL(string:$0)}))
    let actualArtwork=artwork.image(addresses:GameArtwork.candidates(for:game,role:.banner),refresh:{}) != nil
    if let bitmap=detail.bitmapImageRepForCachingDisplay(in:detail.bounds){
      detail.cacheDisplay(in:detail.bounds,to:bitmap)
      guard let png=bitmap.representation(using:.png,properties:[:])else{throw CopyPreviewFailure.invalid}
      let path=destination.appendingPathComponent("detail.png");try png.write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
      captures["detail.png"]=SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined()
    }
    check("play-and-install-callbacks-never-invoked",play==0 && install==0)
    check("own-window-never-visible-key-or-active",!window.isVisible && !window.isKeyWindow && !NSApp.isActive)
    let retained=try Data(contentsOf:URL(fileURLWithPath:copy));check("input-copy-bytes-unchanged",retained==bytes)
    PublicArtworkPolicy.lock.lock();let networkTasks=PublicArtworkPolicy.completed,blocked=PublicArtworkPolicy.blocked;PublicArtworkPolicy.lock.unlock()
    let result:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"modelCount":state.games.count,"activeProfileVisibleCount":visible.count,"steamFilterVisibleCount":steamCount,"expectedCount":expected,"actualModelCopy":true,"librarySHA256":expectedHash,"captures":captures,
      "publicArtworkNetworkEnabled":allowNetwork,"publicNetworkRestrictedToTwoDetailAssets":detailOnly,"portraitPosterDecoded":highPoster,"posterDecodedPixels":posterPixels,"bannerArtworkDecoded":highHero,"bannerDecodedPixels":heroPixels,"taskDelegateCompletionCallbacks":networkTasks,"artworkRequestsBlockedByPolicy":blocked,"detailArtworkAvailable":actualArtwork,
      "userDataBytesModified":false,"accountLoginPerformed":false,"KeychainReadOrWrite":false,"gameOrSteamSDKExecuted":false,"ownershipVerifiedByThisProbe":false,"ownHiddenWindow":true,"windowActivated":false]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]));if !checks.values.allSatisfy({$0}){exit(1)}
  }
  static func main(){alarm(45);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited);do{try MainActor.assumeIsolated{try run()}}catch{FileHandle.standardError.write(Data("private_copy_render_failed\n".utf8));exit(1)}}
}
