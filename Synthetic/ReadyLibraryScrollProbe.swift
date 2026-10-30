// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import LauncherCore
import Metal
private final class ScrollFixtureWindow:NSWindow {
  override func constrainFrameRect(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
  override func makeKeyAndOrderFront(_ sender:Any?){}
  override func orderBack(_ sender:Any?){}
}
@main struct ReadyLibraryScrollProbe {
  @MainActor static func pump(_ duration:TimeInterval=0.004){let end=Date().addingTimeInterval(duration);while Date()<end{RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.001))}}
  static func percentile(_ values:[Double],_ p:Double)->Double{let a=values.sorted();return a.isEmpty ? 0:a[min(a.count-1,Int(ceil(Double(a.count)*p))-1)]}
  @MainActor static func run(_ configURL:URL)throws{
    let config=try JSONSerialization.jsonObject(with:Data(contentsOf:configURL))as![String:Any]
    let root=URL(fileURLWithPath:config["output"]as!String),copy=URL(fileURLWithPath:config["libraryCopy"]as!String)
    let data=try Data(contentsOf:copy),expected=config["librarySHA256"]as!String
    guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==expected else{throw NSError(domain:"CopyHash",code:1)}
    let state=try JSONDecoder().decode(LibraryState.self,from:data)
    guard let device=MTLCreateSystemDefaultDevice()else{throw NSError(domain:"Metal",code:1)}
    let window=ScrollFixtureWindow(contentRect:NSRect(x:-8192,y:-8192,width:1240,height:760),styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let scale=window.backingScaleFactor,targetDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:Int(1240*scale),height:Int(760*scale),mipmapped:false);targetDescriptor.storageMode = .shared;targetDescriptor.usage=[.renderTarget,.shaderRead]
    let target=device.makeTexture(descriptor:targetDescriptor)!,cache=ArtworkCache(directory:URL(fileURLWithPath:config["artworkCache"]as!String),networkEnabled:false)
    let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:1240,height:760),device:device,artworkCache:cache,offscreenShellTarget:target);canvas.state=state;window.contentView=canvas
    defer{canvas.releaseGraphics();window.close()}
    canvas.refresh();for _ in 0..<100{canvas.renderDisplayTick();pump()}
    var checks=[String:Bool]();func check(_ name:String,_ value:Bool){checks[name]=value}
    check("all-profile-owned-records-preserved",canvas.allProfileGames.count==(config["expectedCount"]as?Int))
    let gamesCount=canvas.visibleGames.count;let otherCount=canvas.allProfileGames.filter{LibraryEntryPresentation.isOtherContent($0)}.count
    check("unified-game-view-excludes-preserved-other-records",gamesCount+otherCount==canvas.allProfileGames.count)
    canvas.showOtherContent=false;canvas.refresh();for _ in 0..<50{canvas.renderDisplayTick();pump()}
    try canvas.writePreview(root.appendingPathComponent("reference.png"));try canvas.writeNativeGridPreview(root.appendingPathComponent("native.png"))
    let reference=NSBitmapImageRep(data:try Data(contentsOf:root.appendingPathComponent("reference.png")))!,native=NSBitmapImageRep(data:try Data(contentsOf:root.appendingPathComponent("native.png")))!
    let viewport=canvas.libraryLayoutSnapshot.viewport
    var error=0.0,samples=0,changed=0
    for y in stride(from:Int(viewport.minY)+8,to:Int(viewport.maxY)-8,by:7){for x in stride(from:Int(viewport.minX)+8,to:Int(viewport.maxX)-20,by:7){
      let a=reference.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!,b=native.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!
      let delta=abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)
      error+=Double(delta)/3;samples+=1;if delta>0.15{changed+=1}
    }}
    let meanDifference=error/Double(max(1,samples))
    check("native-layer-output-matches-reference-colors-and-geometry",meanDifference<0.035)
    check("native-grid-has-only-bounded-visible-prefetch-layers",canvas.gridRenderSnapshot.layerCount<=canvas.libraryLayoutSnapshot.columns*5)
    var referenceTimes=[Double]()
    for _ in 0..<90{canvas.scrollLibrary(by:4);let t=ProcessInfo.processInfo.systemUptime;_ = canvas.makeReferenceRaster(scale:scale);referenceTimes.append((ProcessInfo.processInfo.systemUptime-t)*1000)}
    canvas.selected=0;canvas.refresh();for _ in 0..<30{canvas.renderDisplayTick();pump()}
    let before=canvas.gridRenderSnapshot
    var cachedTimes=[Double]()
    for _ in 0..<180{let t=ProcessInfo.processInfo.systemUptime;canvas.scrollLibrary(by:2);canvas.renderDisplayTick();cachedTimes.append((ProcessInfo.processInfo.systemUptime-t)*1000);pump(0.001)}
    let after=canvas.gridRenderSnapshot
    check("wheel-scroll-does-not-rasterize-or-upload-shell",after.chromeRasters==before.chromeRasters)
    check("tile-raster-work-is-limited-to-six-with-time-budget",after.tileBuilds-before.tileBuilds<=6*(after.renderTicks-before.renderTicks))
    check("cached-scroll-main-cpu-p95-below-full-raster-reference",percentile(cachedTimes,0.95)<percentile(referenceTimes,0.95))
    check("tile-cache-respects-count-and-byte-limits",after.tileCount<=96 && after.tileBytes<=64*1024*1024)
    check("shell-buffer-jobs-never-exceed-two",after.inFlight<=2)
    let targetHit=canvas.interactionSnapshot.hits.first{$0.id.hasPrefix("game.")}!
    let point=NSPoint(x:targetHit.rect.midX,y:targetHit.rect.midY),event=NSEvent.mouseEvent(with:.mouseMoved,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
    let hoverBefore=canvas.gridRenderSnapshot;canvas.mouseMoved(with:event);canvas.renderDisplayTick();let hoverAfter=canvas.gridRenderSnapshot
    check("hover-updates-layer-without-card-or-shell-raster",hoverAfter.tileBuilds==hoverBefore.tileBuilds && hoverAfter.chromeRasters==hoverBefore.chromeRasters && canvas.interactionSnapshot.hover==targetHit.id)
    canvas.scrollLibrary(by:1_000_000);for _ in 0..<30{canvas.renderDisplayTick();pump()}
    check("native-scroll-reaches-last-visible-record",canvas.visibleGames.last.map{canvas.libraryLayoutSnapshot.visibleIDs.contains($0.id)}==true)
    check("hit-targets-remain-clipped-to-scrolled-viewport",canvas.interactionSnapshot.hits.filter{$0.id.hasPrefix("game.")}.allSatisfy{canvas.libraryLayoutSnapshot.viewport.contains($0.rect)})
    canvas.section = .settings;canvas.renderDisplayTick()
    check("page-change-removes-game-hit-targets",!canvas.interactionSnapshot.hits.contains{$0.id.hasPrefix("game.")})
    canvas.releaseGraphics();check("release-detaches-grid-and-clears-caches",canvas.allocatedTextureBytes==0 && canvas.gridRenderSnapshot.tileCount==0 && canvas.gridRenderSnapshot.layerCount==0)
    check("own-window-never-activated",!NSApp.isActive && !window.isKeyWindow && !window.isVisible)
    check("input-copy-bytes-unchanged",try Data(contentsOf:copy)==data)
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"actualModelCopy":true,"ownedCount":canvas.allProfileGames.count,"gamesCount":gamesCount,"otherCount":otherCount,"referenceCPUms":["median":percentile(referenceTimes,0.5),"p95":percentile(referenceTimes,0.95),"max":referenceTimes.max() ?? 0],"cachedScrollCPUms":["median":percentile(cachedTimes,0.5),"p95":percentile(cachedTimes,0.95),"max":cachedTimes.max() ?? 0],"parityMeanRGBDifference":meanDifference,"paritySamples":samples,"parityChangedSamples":changed,"tileBytes":after.tileBytes,"tileCount":after.tileCount,"tileBuildsDuringScroll":after.tileBuilds-before.tileBuilds,"chromeRastersDuringScroll":after.chromeRasters-before.chromeRasters,"UIOnly":true,"windowActivated":false,"networkEnabled":false,"accountKeychainOrGameUsed":false,"gamePerformanceBenchmarkUsed":false,"uiScrollProfilingPerformed":true,"onScreenSmoothnessVerified":false]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]));if !checks.values.allSatisfy({$0}){exit(1)}
  }
  static func main(){alarm(90);_=NSApplication.shared;NSApp.setActivationPolicy(.prohibited);do{try MainActor.assumeIsolated{try run(URL(fileURLWithPath:CommandLine.arguments[1]))}}catch{FileHandle.standardError.write(Data("owned_scroll_fixture_failed\n".utf8));exit(1)}}
}
