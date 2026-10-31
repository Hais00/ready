// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreFoundation
import CryptoKit
import Darwin
import LauncherCore
import Metal

private final class PausedBackgroundWriter {
  let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
  private let lock=NSLock();private var once=false
  func wait(){lock.lock();let block = !once;once=true;lock.unlock();if block{entered.signal();release.wait()}}
}
private final class ArtworkLatencyWindow:NSWindow {
  override func makeKeyAndOrderFront(_ sender:Any?){}
  override func orderBack(_ sender:Any?){}
}
@main struct ReadyViewportArtworkProbe {
  @MainActor static func pump(_ mode:RunLoop.Mode,_ seconds:TimeInterval){CFRunLoopRunInMode(CFRunLoopMode(rawValue:mode.rawValue as CFString),seconds,false)}
  static func p95(_ data:[Double])->Double{let a=data.sorted();return a.isEmpty ? 0:a[min(a.count-1,Int(ceil(Double(a.count)*0.95))-1)]}
  @MainActor static func run(_ configURL:URL)throws{
    let config=try JSONSerialization.jsonObject(with:Data(contentsOf:configURL))as![String:Any],root=URL(fileURLWithPath:config["output"]as!String)
    let input=URL(fileURLWithPath:config["libraryCopy"]as!String),bytes=try Data(contentsOf:input)
    guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==config["librarySHA256"]as?String else{throw NSError(domain:"Copy",code:1)}
    let state=try JSONDecoder().decode(LibraryState.self,from:bytes)
    CFRunLoopAddCommonMode(CFRunLoopGetMain(),CFRunLoopMode(rawValue:RunLoop.Mode.eventTracking.rawValue as CFString))
    guard let device=MTLCreateSystemDefaultDevice()else{throw NSError(domain:"Metal",code:1)}
    let baseline=config["baseline"]as?Bool ?? false
    var checks=[String:Bool](),results=[[String:Any]](),baselineStarvation=false
    for (number,mode) in [RunLoop.Mode.default,.eventTracking].enumerated(){
      let gate=PausedBackgroundWriter(),cache=ArtworkCache(directory:URL(fileURLWithPath:(config["cacheCopies"]as![String])[number]),networkEnabled:false,backgroundWriteGate:{gate.wait()})
      let window=ArtworkLatencyWindow(contentRect:NSRect(x:-8192,y:-8192,width:1240,height:760),styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
      let scale=window.backingScaleFactor,descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:Int(1240*scale),height:Int(760*scale),mipmapped:false);descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:1240,height:760),device:device,artworkCache:cache,offscreenShellTarget:device.makeTexture(descriptor:descriptor));canvas.state=state;window.contentView=canvas
      defer{gate.release.signal();canvas.releaseGraphics();window.close()}
      var trigger=Game(id:"owned-ui-write-gate-"+String(number),store:.local,storeID:"write-gate",title:"Synthetic cache metadata only")
      trigger.metadata=["libraryKind":.string("tool")];cache.prepare(games:[trigger])
      var writerBlocked=false;let until=Date().addingTimeInterval(2)
      while !baseline && !writerBlocked && Date()<until{writerBlocked=gate.entered.wait(timeout:.now()) == .success;pump(.default,0.005)}
      if !baseline{checks["writer-gate-held-"+String(number)]=writerBlocked}
      canvas.refresh();for _ in 0..<70{canvas.renderDisplayTick();pump(.default,0.008)}
      canvas.resetViewportArtworkMetrics()
      canvas.scrollLibrary(by:canvas.libraryLayoutSnapshot.maximum*(number==0 ? 0.53:0.79))
      let started=ProcessInfo.processInfo.systemUptime
      // No default-mode pumping occurs after the tracking viewport entry.
      repeat{canvas.renderDisplayTick();pump(mode,1.0/60.0)}while ProcessInfo.processInfo.systemUptime-started<0.9 && canvas.viewportArtworkSnapshot.pending>0
      let snapshot=canvas.viewportArtworkSnapshot,tag=number==0 ? "default":"tracking"
      if !baseline {
        checks["all-cached-visible-cards-have-real-art-tile-"+tag]=snapshot.cachedEntries>0 && snapshot.cachedTileMilliseconds.count==snapshot.cachedEntries && snapshot.pendingCached==0
        checks["all-indexed-positive-entry-latencies-recorded-"+tag]=snapshot.cachedTileMilliseconds.count==snapshot.cachedEntries
      }else if number==1{baselineStarvation=snapshot.entries>0 && snapshot.pending>0 && snapshot.trackingInvalidations==0}
      checks["no-full-shell-raster-on-new-cached-row-"+tag]=canvas.gridRenderSnapshot.chromeRasters<=2 // One clock-minute rollover is legitimate chrome work.
      if number==1 && !baseline{checks["artwork-publication-serviced-during-event-tracking"]=snapshot.trackingInvalidations>0}
      checks["tile-resource-bound-"+tag]=canvas.gridRenderSnapshot.tileBytes<=64*1024*1024
      checks["hidden-window-never-active-"+tag] = !NSApp.isActive && !window.isKeyWindow && !window.isVisible
      results.append(["mode":tag,"entries":snapshot.entries,"cachedEligibleEntries":snapshot.cachedEntries,"completedWithActualArtwork":snapshot.completed,"dropped":snapshot.dropped,"pending":snapshot.pending,"entryToRAMP95ms":p95(snapshot.ramMilliseconds),"entryToArtworkTileP95ms":p95(snapshot.tileMilliseconds),"cachedEntryToArtworkTileP95ms":p95(snapshot.cachedTileMilliseconds),"maxTileLatencyMs":snapshot.tileMilliseconds.max() ?? 0,"trackingPublicationCallbacks":snapshot.trackingInvalidations,"backgroundIndexWriterBlockedDuringMeasurement":writerBlocked,"tileCommitMeans":"actual CGImage artwork included in immutable card tile assigned to visible CALayer; not on-glass timestamp"])
      if !baseline {
        let workers=canvas.tileWorkerSnapshot
        checks["card-composition-never-blocks-main-"+tag]=workers.rasters>0 && workers.mainThreadRasters==0
        checks["card-composition-workers-bounded-to-two-"+tag]=workers.maximumRunning<=2
        canvas.resetViewportArtworkMetrics()
        for _ in 0..<60{canvas.scrollLibrary(by:48);canvas.renderDisplayTick();pump(mode,1.0/60)}
        for _ in 0..<6 where canvas.viewportArtworkSnapshot.pendingCached>0{canvas.renderDisplayTick();pump(mode,1.0/60)}
        let predictive=canvas.viewportArtworkSnapshot
        checks["predictive-cached-row-artwork-p95-under100ms-"+tag]=predictive.entries>0 && predictive.cachedTileMilliseconds.count==predictive.cachedEntries && p95(predictive.cachedTileMilliseconds)<100
        if predictive.pending>0{
          let current=Set(canvas.libraryLayoutSnapshot.visibleIDs),done=predictive.committedIDs
          let remaining=canvas.visibleGames.filter{current.contains($0.id) && !done.contains($0.id)}
          let diagnostics=remaining.map{game -> [String:Any] in
            let ram=cache.image(for:game,role:.card,refresh:{}) != nil
            return ["indexedPositive":cache.hasCachedImage(gameID:game.id,role:.card),"ramAvailable":ram,"revision":cache.revision(gameID:game.id,role:.card)]
          }
          results.append(["mode":tag+"-pending-diagnostics","count":diagnostics.count,"states":diagnostics])
        }
        checks["card-composition-remains-off-main-during-fast-scroll-"+tag]=canvas.tileWorkerSnapshot.mainThreadRasters==0 && canvas.tileWorkerSnapshot.maximumRunning<=2
        results.append(["mode":tag+"-predictive-continuous-scroll","entries":predictive.entries,"cachedEligibleEntries":predictive.cachedEntries,"completedWithActualArtwork":predictive.completed,"ramSamples":predictive.ramMilliseconds.count,"pending":predictive.pending,"entryToRAMP95ms":p95(predictive.ramMilliseconds),"entryToArtworkTileP95ms":p95(predictive.tileMilliseconds),"maxTileLatencyMs":predictive.tileMilliseconds.max() ?? 0,"tileRasterP95ms":p95(canvas.tileRasterBudgetSnapshot.rasterMilliseconds),"largestTileBatch":canvas.tileRasterBudgetSnapshot.largestBatch,"backgroundIndexWriterBlockedDuringMeasurement":writerBlocked])
      }
      if baseline && number==1 {
        let end=ProcessInfo.processInfo.systemUptime+2
        repeat{canvas.renderDisplayTick();pump(.default,1.0/60)}while canvas.viewportArtworkSnapshot.pending>0 && ProcessInfo.processInfo.systemUptime<end
        let resumed=canvas.viewportArtworkSnapshot
        checks["old-publication-resumes-after-default-mode-return"]=resumed.completed==resumed.entries && resumed.pending==0
        results.append(["mode":"tracking-after-default-resume","entries":resumed.entries,"completedWithActualArtwork":resumed.completed,"entryToArtworkTileP95ms":p95(resumed.tileMilliseconds),"trackingPublicationCallbacks":resumed.trackingInvalidations])
      }
      gate.release.signal();canvas.releaseGraphics();window.close();pump(.default,0.05)
      if !baseline{checks["late-card-completions-cannot-repopulate-released-graphics-"+tag]=canvas.allocatedTextureBytes==0 && canvas.gridRenderSnapshot.tileCount==0 && canvas.tileWorkerSnapshot.pending==0}
    }
    if !baseline {
      let directory=root.appendingPathComponent("shared-hash-fixture",isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
      let bitmap=CanvasRaster(width:128,height:192)!;bitmap.context.setFillColor(NSColor.systemGreen.cgColor);bitmap.context.fill(CGRect(x:0,y:0,width:128,height:192))
      let png=NSBitmapImageRep(cgImage:bitmap.context.makeImage()!).representation(using:.png,properties:[:])!,hash=ArtworkIndexStore.hash(png),store=ArtworkIndexStore(directory),address="https://fixture.invalid/shared-content.png"
      _=store.saveObject(png,hash:hash);store.saveThumbnail(png,hash:hash,size:512)
      var index=ArtworkDiskIndex()
      var a=Game(id:"shared-a",store:.local,storeID:"shared-a",title:"Shared A",artworkURL:address,variants:[GameVariant(id:"windows",platform:.windows)])
      var b=a;b.id="shared-b";b.storeID="shared-b";b.title="Shared B"
      for game in [a,b]{var record=ArtworkRoleRecord(gameID:game.id,role:.card,candidates:[address]);record.hash=hash;record.preferredURL=address;index.roles[game.id+"\u{1f}card"]=record}
      index.urls[address]=ArtworkURLRecord(hash:hash);_=store.save(index)
      let cache=ArtworkCache(directory:directory,networkEnabled:false),window=ArtworkLatencyWindow(contentRect:NSRect(x:-8192,y:-8192,width:1240,height:760),styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
      let scale=window.backingScaleFactor,d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:Int(1240*scale),height:Int(760*scale),mipmapped:false);d.storageMode = .shared;d.usage=[.renderTarget,.shaderRead]
      let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:1240,height:760),device:device,artworkCache:cache,offscreenShellTarget:device.makeTexture(descriptor:d));var state=LibraryState.initial();state.games=[a,b];canvas.state=state;canvas.query="Shared A";window.contentView=canvas;canvas.refresh()
      for _ in 0..<45{canvas.renderDisplayTick();pump(.default,0.006)}
      let before=cache.revision(gameID:b.id,role:.card),ram=cache.image(for:b,role:.card,refresh:{}) != nil
      canvas.query="Shared B";canvas.refresh()
      let tiles=Mirror(reflecting:canvas).children.first{$0.label=="tileCache"}!.value as!LibraryTileCache
      let columns=canvas.libraryLayoutSnapshot.columns,width=floor((1240-148-18*CGFloat(columns-1))/CGFloat(columns)),height=width*LibraryCardMetrics.coverRatio+LibraryCardMetrics.titleHeight
      let key=LibraryTileCache.Key(title:b.title,store:b.store.rawValue,platforms:"Windows",installed:false,revision:before,pixelWidth:Int(ceil(width*scale)),pixelHeight:Int(ceil(height*scale)))
      // Reproduce a cached placeholder left by an earlier cancelled binding.
      // The other binding populated the shared hash, without a B revision event.
      tiles.insert(id:b.id,key:key,image:bitmap.context.makeImage()!)
      let sharedEnd=ProcessInfo.processInfo.systemUptime+0.4
      repeat{canvas.renderDisplayTick();pump(.default,0.005)}while !canvas.viewportArtworkSnapshot.committedIDs.contains(b.id) && ProcessInfo.processInfo.systemUptime<sharedEnd
      checks["shared-hash-RAM-hit-replaces-placeholder-without-binding-revision"]=ram && cache.revision(gameID:b.id,role:.card)==before && canvas.viewportArtworkSnapshot.committedIDs.contains(b.id)
      canvas.releaseGraphics();window.close()
    }
    checks["library-copy-bytes-unchanged"] = (try Data(contentsOf:input))==bytes
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"results":results,"actualModelCopy":true,"baseline":baseline,"baselineTrackingStarvationObserved":baselineStarvation,"networkEnabled":false,"accountKeychainGameOrGameBenchmarkUsed":false,"windowActivated":false,"onScreenImageLatencyVerified":false,"trackingModeRegisteredCommon":true]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]));if !checks.values.allSatisfy({$0}){exit(1)}
  }
  static func main(){alarm(30);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited);do{try MainActor.assumeIsolated{try run(URL(fileURLWithPath:CommandLine.arguments[1]))}}catch{FileHandle.standardError.write(Data("owned_viewport_artwork_fixture_failed\n".utf8));exit(1)}}
}
