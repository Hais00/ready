// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import LauncherCore
private enum ArtworkCheck:Error{case failed(String)}
private final class ImageProtocol:URLProtocol {
  private static let lock=NSLock()
  static var imageA=Data(),imageB=Data()
  private static var callsValue=[(String,String?,String?)](),active=0,peak=0
  private static var changed=false,same200=false,failedPaths=Set<String>()
  static func clear(){lock.lock();callsValue.removeAll();peak=0;lock.unlock()}
  static func responseMode(changed:Bool=false,same200:Bool=false,failedPaths:Set<String>=[]){lock.lock();self.changed=changed;self.same200=same200;self.failedPaths=failedPaths;lock.unlock()}
  static var calls:[(String,String?,String?)]{lock.lock();defer{lock.unlock()};return callsValue}
  static var maximum:Int{lock.lock();defer{lock.unlock()};return peak}
  override class func canInit(with request:URLRequest)->Bool{request.url?.host=="artwork.invalid"}
  override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
  override func startLoading(){
    let path=request.url!.path
    Self.lock.lock();Self.active+=1;Self.peak=max(Self.peak,Self.active);Self.callsValue.append((path,request.value(forHTTPHeaderField:"If-None-Match"),request.value(forHTTPHeaderField:"If-Modified-Since")));let changed=Self.changed,same200=Self.same200,failed=Self.failedPaths.contains(path);Self.lock.unlock()
    DispatchQueue.global().asyncAfter(deadline:.now()+((path.hasPrefix("/20/") || path.hasPrefix("/21/")) ? 0.8:0.015)){[self]in
      let missing=path.contains("missing"),blue=changed && path.contains("new-banner"),etag=blue ? "\"blue\"":"\"red\""
      let status=failed ? 503:missing ? 404:(!same200 && self.request.value(forHTTPHeaderField:"If-None-Match")==etag ? 304:200)
      let response=HTTPURLResponse(url:self.request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"image/png","ETag":etag,"Last-Modified":"Wed, 28 Oct 2026 12:00:00 GMT"])!
      Self.lock.lock();Self.active-=1;Self.lock.unlock()
      self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
      if status==200{self.client?.urlProtocol(self,didLoad:blue ? Self.imageB:Self.imageA)}
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading(){}
}
@main struct ReadyArtworkIndexProbe {
  @MainActor static func main()throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),directory=root.appendingPathComponent("cache")
    func png(_ blue:Bool)->Data{let context=CGContext(data:nil,width:400,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;context.setFillColor((blue ? NSColor.blue:NSColor.red).cgColor);context.fill(CGRect(x:0,y:0,width:400,height:200));return NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!}
    ImageProtocol.imageA=png(false);ImageProtocol.imageB=png(true)
    let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ImageProtocol.self];let session=URLSession(configuration:config)
    var checks=[String:Bool](),notices=[[String:Any]](),timings=[String:Double]()
    func check(_ value:Bool,_ label:String)throws{checks[label]=value;if !value{throw ArtworkCheck.failed(label)}}
    func spin(_ condition:()->Bool)throws{let end=Date().addingTimeInterval(10);while !condition() && Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))};if !condition(){throw ArtworkCheck.failed("deadline")}}
    func settle(_ delay:Double=0.2){let end=Date().addingTimeInterval(delay);while Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005))}}
    func game(_ number:Int,missing:Bool=false)->Game{var g=Game(id:"local:\(number)",store:.local,storeID:String(number),title:"Own image fixture");let base="https://artwork.invalid/\(number)/"+(missing ? "missing-":"");g.artworkURL=base+"card.png";g.metadata=["capsuleURL":.string(base+"card.png"),"heroURL":.string(base+"banner.png"),"bannerURL":.string(base+"banner.png"),"iconURL":.string(base+"icon.png")];return g}
    func disk(_ directory:URL)->ArtworkDiskIndex?{guard let data=try?Data(contentsOf:directory.appendingPathComponent("index.json"))else{return nil};return try?JSONDecoder().decode(ArtworkDiskIndex.self,from:data)}
    let games=(1...4).map{game($0)},cache=ArtworkCache(directory:directory,session:session)
    let observer=NotificationCenter.default.addObserver(forName:.readyArtworkChanged,object:cache,queue:.main){note in notices.append(note.userInfo as? [String:Any] ?? [:])};defer{NotificationCenter.default.removeObserver(observer)}
    cache.prepare(games:games,visibleGameIDs:[games[2].id])
    try spin{disk(directory)?.roles.values.filter{$0.hash != nil}.count==12}
    try check(ImageProtocol.calls.count==12 && ImageProtocol.maximum<=5,"initialPrepareDownloadsAllCardsIconsAndBannersWithBoundedConcurrency")
    try check(cache.image(for:games[2],role:.card,refresh:{}) != nil && cache.image(for:games[2],role:.banner,refresh:{})==nil,"viewportPredecodesCardsWithoutPullingLargeBannersIntoScrollRAM")
    let preparedIndex=disk(directory)!
    try check(preparedIndex.roles.values.allSatisfy{record in
      let size=record.role == .icon ? 128:record.role == .card ? 512:2048
      return record.hash.map{FileManager.default.fileExists(atPath:directory.appendingPathComponent($0+"-\(size).png").path)} ?? false
    },"allPreparedRolesHaveIndexedDiskThumbnailsBeforeAnyDetailClick")
    let first=games[0]
    try spin{cache.image(for:first,role:.banner,refresh:{}) != nil}
    let before=cache.image(for:first,role:.banner,refresh:{})!,beforeIdentity=ObjectIdentifier(before)
    let countBefore=ImageProtocol.calls.count;cache.prepare(games:games);settle()
    try check(ImageProtocol.calls.count==countBefore,"repeatedStartupPrepareNeverInvalidatesPositiveCache")
    let oldIndex=disk(directory)!,oldRevision=cache.revision(gameID:first.id,role:.banner)
    notices.removeAll();ImageProtocol.clear();cache.revalidate(game:first);cache.revalidate(game:first)
    try spin{ImageProtocol.calls.count>=3};settle()
    try check(Set(ImageProtocol.calls.map{$0.0}).contains("/1/icon.png") && Set(ImageProtocol.calls.map{$0.0}).contains("/1/banner.png") && ImageProtocol.calls.allSatisfy{$0.1=="\"red\"" && $0.2 != nil},"detailChecksIconAndBannerWithConditionalValidators")
    try check(ImageProtocol.calls.count==3,"sameDetailRevalidationCoalescesWhileAlreadyInFlight")
    try check(notices.isEmpty && cache.revision(gameID:first.id,role:.banner)==oldRevision && ObjectIdentifier(cache.image(for:first,role:.banner,refresh:{})!)==beforeIdentity,"HTTP304PreservesImageIdentityAndEmitsNoChangeNotification")
    ImageProtocol.responseMode(same200:true);ImageProtocol.clear();cache.revalidate(game:first);try spin{ImageProtocol.calls.count>=3};settle()
    try check(notices.isEmpty && ObjectIdentifier(cache.image(for:first,role:.banner,refresh:{})!)==beforeIdentity,"HTTP200UnchangedContentHashPreservesMemoryAndNotifications")
    var updated=first;updated.metadata?["heroURL"] = .string("https://artwork.invalid/1/new-banner.png");updated.metadata?["bannerURL"] = .string("https://artwork.invalid/1/new-banner.png")
    ImageProtocol.responseMode(changed:true);ImageProtocol.clear();cache.prepare(games:[updated]);settle()
    try check(ImageProtocol.calls.isEmpty && ObjectIdentifier(cache.image(for:updated,role:.banner,refresh:{})!)==beforeIdentity,"changedSourceURLsDoNotInvalidateGoodBindingOutsideDetail")
    cache.revalidate(game:updated);try spin{notices.contains{($0["gameID"]as?String)==first.id && ($0["role"]as?String)=="banner" && ($0["changed"]as?Bool)==true}};settle()
    try check(notices.count==1 && notices[0]["gameID"]as?String==first.id && notices[0]["role"]as?String=="banner" && ObjectIdentifier(cache.image(for:updated,role:.banner,refresh:{})!) != beforeIdentity,"changedDetailContentPublishesOnlySpecificGameAsset")
    try spin{disk(directory)?.roles.values.first{$0.gameID==first.id && $0.role == .banner}?.preferredURL=="https://artwork.invalid/1/new-banner.png"}
    let current=disk(directory)!,indexed=current.roles.values.first{$0.gameID==first.id && $0.role == .banner}!
    try check(indexed.hash != oldIndex.roles.values.first{$0.gameID==first.id && $0.role == .banner}?.hash && current.urls[indexed.preferredURL!]?.etag=="\"blue\"","durableRoleIndexBindsPreferredURLContentHashAndETag")
    var reordered=updated;reordered.metadata?["heroURL"] = .string("https://artwork.invalid/1/alternative-background.png")
    notices.removeAll();ImageProtocol.clear();cache.revalidate(game:reordered);settle(0.4)
    try check(!ImageProtocol.calls.contains{$0.0.contains("alternative-background")} && ImageProtocol.calls.contains{$0.0=="/1/new-banner.png"} && notices.isEmpty && ObjectIdentifier(cache.image(for:reordered,role:.banner,refresh:{})!)==ObjectIdentifier(cache.image(for:updated,role:.banner,refresh:{})!),"metadataReorderingKeepsSelectedBannerInsteadOfSwitchingToAnotherImage")
    ImageProtocol.responseMode(changed:true,failedPaths:["/1/new-banner.png"]);ImageProtocol.clear();cache.revalidate(game:reordered);settle(0.4)
    try check(!ImageProtocol.calls.contains{$0.0.contains("alternative-background")} && notices.isEmpty && disk(directory)?.roles.values.first{$0.gameID==first.id && $0.role == .banner}?.hash==indexed.hash,"selectedBannerFailureNeverSubstitutesAnAvailableDifferentBackground")
    ImageProtocol.responseMode(changed:true)
    var unavailable=updated;unavailable.artworkURL="https://artwork.invalid/1/missing-card.png"
    unavailable.metadata?["capsuleURL"] = .string(unavailable.artworkURL!)
    unavailable.metadata?["iconURL"] = .string("https://artwork.invalid/1/missing-icon.png")
    unavailable.metadata?["heroURL"] = .string("https://artwork.invalid/1/missing-banner.png")
    unavailable.metadata?["bannerURL"] = .string("https://artwork.invalid/1/missing-banner.png")
    notices.removeAll();let goodIdentity=ObjectIdentifier(cache.image(for:updated,role:.banner,refresh:{})!)
    cache.revalidate(game:unavailable);settle(0.5)
    try check(notices.isEmpty && ObjectIdentifier(cache.image(for:updated,role:.banner,refresh:{})!)==goodIdentity && disk(directory)?.roles.values.first{$0.gameID==first.id && $0.role == .banner}?.hash==indexed.hash,"detailHTTPFailuresPreservePreviouslyDecodedGoodAssetAndBinding")
    cache.purge();ImageProtocol.clear();notices.removeAll();cache.prepare(games:games);cache.prepare(games:games);settle()
    try check(ImageProtocol.calls.isEmpty && notices.isEmpty && cache.image(for:games[3],role:.banner,refresh:{})==nil,"backgroundPrepareDoesNotDecodeEvictedRAMOrEmitLoadedChurn")
    cache.purge();ImageProtocol.clear();let offline=ArtworkCache(directory:directory,session:session,networkEnabled:false);offline.prepare(games:[updated]+Array(games.dropFirst()))
    try spin{GameArtwork.Role.allCases.allSatisfy{offline.image(for:updated,role:$0,refresh:{}) != nil}}
    try check(ImageProtocol.calls.isEmpty,"newOfflineInstanceReadsIndexedDiskAndPredecodesWithoutNetwork")
    cache.purge();ImageProtocol.clear()
    let missingHash=indexed.hash!
    try FileManager.default.removeItem(at:directory.appendingPathComponent(missingHash+".asset"))
    try FileManager.default.removeItem(at:directory.appendingPathComponent(missingHash+"-2048.png"))
    try spin{cache.image(for:updated,role:.banner,refresh:{}) != nil}
    try check(ImageProtocol.calls.contains{$0.0=="/1/new-banner.png" && $0.1==nil},"missingIndexedBytesRecoverByUnconditionalFetchWithoutDeletingGoodBindings")
    let bad=game(99,missing:true),badDir=root.appendingPathComponent("negative"),negative=ArtworkCache(directory:badDir,session:session)
    negative.prepare(games:[bad]);try spin{(disk(badDir)?.urls.values.filter{$0.negativeStatus==404}.count ?? 0)>=3};settle();let negativeCount=ImageProtocol.calls.count
    for _ in 0..<15{negative.prefetch(game:bad);_=negative.image(for:bad,role:.banner,refresh:{})};settle()
    try check(ImageProtocol.calls.count==negativeCount,"negative404DoesNotRetryOnDrawPrepareOrPrefetch")
    negative.purge();let negativeRestart=ArtworkCache(directory:badDir,session:session);negativeRestart.prepare(games:[bad]);settle(0.4)
    try check(ImageProtocol.calls.count==negativeCount,"negative404PersistsAcrossRestartWithoutTTLRetry")
    negativeRestart.revalidate(game:bad);try spin{ImageProtocol.calls.count>negativeCount};settle()
    try check(ImageProtocol.calls.filter{$0.0=="/99/missing-icon.png"}.count>1 && ImageProtocol.calls.filter{$0.0=="/99/missing-banner.png"}.count>1,"onlyDetailExplicitlyRetriesBothNegativeIconAndBanner")
    cache.purge();ImageProtocol.clear();cache.prepare(games:[game(20),game(21)])
    try spin{ImageProtocol.calls.count>=2}
    let cacheReadStart=Date()
    try spin{cache.image(for:updated,role:.banner,refresh:{}) != nil}
    try check(Date().timeIntervalSince(cacheReadStart)<0.4,"indexedDiskHitDoesNotWaitBehindSlowBackgroundDownloads")
    settle(1.0)
    var sameAsset=game(30);sameAsset.metadata?["heroURL"] = .string("https://artwork.invalid/30/new-banner.png");sameAsset.metadata?["bannerURL"] = .string("https://artwork.invalid/30/new-banner.png")
    ImageProtocol.responseMode();cache.prefetch(game:sameAsset);try spin{cache.image(for:sameAsset,role:.banner,refresh:{}) != nil};settle()
    let sameBefore=ObjectIdentifier(cache.image(for:sameAsset,role:.banner,refresh:{})!);notices.removeAll();ImageProtocol.responseMode(changed:true);cache.revalidate(game:sameAsset)
    try spin{notices.contains{($0["gameID"]as?String)==sameAsset.id && ($0["role"]as?String)=="banner" && ($0["changed"]as?Bool)==true}}
    try check(ObjectIdentifier(cache.image(for:sameAsset,role:.banner,refresh:{})!) != sameBefore,"selectedBannerStillUpdatesWhenBytesAtTheSameURLActuallyChange")
    var steam=game(31);steam.store = .steam;steam.storeID="31";steam.metadata?["heroURL"] = .string("https://artwork.invalid/store-background.png")
    try check(GameArtwork.candidates(for:steam,role:.banner).first=="https://cdn.akamai.steamstatic.com/steam/apps/31/library_hero.jpg","steamLibraryHeroPriorityDoesNotDependOnStoreBackgroundMetadata")
    let priorityDir=root.appendingPathComponent("priority"),priorityCache=ArtworkCache(directory:priorityDir,session:session)
    ImageProtocol.clear();priorityCache.prepare(games:[game(20),game(21)]);try spin{ImageProtocol.calls.count>=2}
    let visible=game(60),coldStarted=Date();priorityCache.prepareViewport(games:[visible],visibleGameIDs:[visible.id],lookAheadGameIDs:[])
    try spin{priorityCache.image(for:visible,role:.card,refresh:{}) != nil};let coldMilliseconds=Date().timeIntervalSince(coldStarted)*1000
    timings["firstDownloadVisibleMilliseconds"]=coldMilliseconds
    try check(coldMilliseconds<400 && ImageProtocol.calls.contains{$0.0=="/60/card.png"},"visibleColdCardDoesNotWaitForSlowBackgroundDownloadSlots")
    settle(1.0);priorityCache.purge();ImageProtocol.clear()
    let warmStarted=Date();priorityCache.prepareViewport(games:[visible],visibleGameIDs:[visible.id],lookAheadGameIDs:[])
    let warmEnd=Date().addingTimeInterval(2)
    while priorityCache.image(for:visible,role:.card,refresh:{})==nil && Date()<warmEnd{_=RunLoop.main.run(mode:.eventTracking,before:Date().addingTimeInterval(0.005))}
    let warmMilliseconds=Date().timeIntervalSince(warmStarted)*1000;timings["cachedCardEventTrackingMilliseconds"]=warmMilliseconds
    try check(priorityCache.image(for:visible,role:.card,refresh:{}) != nil && warmMilliseconds<300 && ImageProtocol.calls.isEmpty,"cachedCardPublishesDuringContinuousEventTrackingWithoutNetwork")
    let writeEntered=DispatchSemaphore(value:0),writeRelease=DispatchSemaphore(value:0),writeLock=NSLock();var blockOnce=true
    let blocked=ArtworkCache(directory:priorityDir,session:session,networkEnabled:false,backgroundWriteGate:{
      writeLock.lock();let shouldBlock=blockOnce;blockOnce=false;writeLock.unlock()
      if shouldBlock{writeEntered.signal();_=writeRelease.wait(timeout:.now()+5)}
    })
    try spin{blocked.hasCachedImage(gameID:visible.id,role:.card)}
    blocked.prepare(games:[game(61)]);var entered=false
    try spin{if !entered{entered=writeEntered.wait(timeout:.now()) == .success};return entered}
    let blockedStarted=Date(),blockedEnd=Date().addingTimeInterval(2)
    while blocked.image(for:visible,role:.card,refresh:{})==nil && Date()<blockedEnd{_=RunLoop.main.run(mode:.eventTracking,before:Date().addingTimeInterval(0.005))}
    let blockedMilliseconds=Date().timeIntervalSince(blockedStarted)*1000;timings["cachedCardWhileIndexWriterBlockedMilliseconds"]=blockedMilliseconds
    let bypassed=blocked.image(for:visible,role:.card,refresh:{}) != nil;writeRelease.signal()
    try check(bypassed && blockedMilliseconds<300,"cachedViewportReadBypassesBlockedIndexWriterAndStillPublishesInTrackingMode");blocked.purge();settle()
    let failedDir=root.appendingPathComponent("failed-index"),failedStore=ArtworkIndexStore(failedDir,beforeWrite:{$0 != "index.json"})
    let failedCache=ArtworkCache(directory:failedDir,session:session,indexStore:failedStore),recoverGame=game(62)
    failedCache.prepare(games:[recoverGame]);try spin{GameArtwork.Role.allCases.allSatisfy{failedCache.image(for:recoverGame,role:$0,refresh:{}) != nil}};settle(0.5);failedCache.purge()
    let primaryPublicationFailed = !FileManager.default.fileExists(atPath:failedDir.appendingPathComponent("index.json").path)
    ImageProtocol.clear();let recoveredCache=ArtworkCache(directory:failedDir,session:session,networkEnabled:false);recoveredCache.prefetch(game:recoverGame)
    try spin{GameArtwork.Role.allCases.allSatisfy{recoveredCache.image(for:recoverGame,role:$0,refresh:{}) != nil}}
    try check(ImageProtocol.calls.isEmpty && primaryPublicationFailed,"failedIndexPublicationRetainsRecoverableCachedAssetsWithoutRefetch")
    recoveredCache.purge();priorityCache.purge()
    let indexMode=(try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("index.json").path)[.posixPermissions]as!NSNumber).intValue
    try check(indexMode==0o600 && (try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions]as!NSNumber).intValue==0o700,"indexAndDirectoryRemainOwnerPrivate")
    let sentinel=directory.appendingPathComponent("unrelated-cache-file");try Data("keep".utf8).write(to:sentinel)
    offline.purge();try check((try Data(contentsOf:sentinel))==Data("keep".utf8) && FileManager.default.fileExists(atPath:directory.appendingPathComponent("index.json").path),"purgeDoesNotScanDeleteOrEvictDiskEntries")
    let unsafe=root.appendingPathComponent("unsafe"),outside=root.appendingPathComponent("outside");try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try FileManager.default.createSymbolicLink(at:unsafe,withDestinationURL:outside)
    let store=ArtworkIndexStore(unsafe);store.save(ArtworkDiskIndex())
    try check(!FileManager.default.fileExists(atPath:outside.appendingPathComponent("index.json").path),"aliasedCacheDirectoryCannotReceiveIndexWrites")
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"fixtureOnly":true,"realNetworkAccountKeychainGameOrWindowUsed":false,"timings":timings]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
  }
}
