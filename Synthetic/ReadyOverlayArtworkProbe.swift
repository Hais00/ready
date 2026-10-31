// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore
import Metal

@main struct ReadyOverlayArtworkProbe {
  @MainActor static func main() throws {
    _=NSApplication.shared
    let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:192,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    NSColor.systemPurple.setFill();NSRect(x:0,y:0,width:128,height:192).fill();NSGraphicsContext.restoreGraphicsState()
    let png=bitmap.representation(using:.png,properties:[:])!,hash=ArtworkIndexStore.hash(png)
    let store=ArtworkIndexStore(root.appendingPathComponent("artwork"));var index=ArtworkDiskIndex()
    let games=(0..<40).map{Game(id:"owned-overlay-\($0)",store:.steam,storeID:String(900000+$0),title:"Owned fixture \($0)")}
    for game in games {
      let candidates=GameArtwork.candidates(for:game,role:.card),address=candidates.first!
      index.urls[address]=ArtworkURLRecord(hash:hash)
      index.roles[game.id+"\u{1f}card"]=ArtworkRoleRecord(gameID:game.id,role:.card,candidates:candidates,preferredURL:address,hash:hash)
    }
    precondition(store.saveObject(png,hash:hash)&&store.save(index))
    let cache=ArtworkCache(directory:root.appendingPathComponent("artwork"),networkEnabled:false)
    let device=MTLCreateSystemDefaultDevice()!
    let window=NSWindow(contentRect:NSRect(x:-8192,y:-8192,width:900,height:620),styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let scale=window.backingScaleFactor,descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:Int(900*scale),height:Int(620*scale),mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
    let canvas=MetalCanvas(frame:NSRect(x:0,y:0,width:900,height:620),device:device,artworkCache:cache,offscreenShellTarget:device.makeTexture(descriptor:descriptor))
    var state=LibraryState.initial();state.games=games;canvas.state=state;window.contentView=canvas
    var checks=[String:Bool]()
    func pump(){RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
    for cycle in 0..<3 {
      cache.beginGameplay();cache.setMaintenanceSuspended(true);canvas.releaseGraphics()
      let blurPasses=canvas.chromeBlurPasses;var prepared=false;canvas.prepareOverlayChrome{prepared=true}
      canvas.gameInterfaceMode=true;canvas.section = .game;cache.resumeForGameInterface();canvas.resumeGraphics()
      let readyEnd=Date().addingTimeInterval(5)
      repeat{canvas.renderDisplayTick();pump()}while !prepared && Date()<readyEnd
      checks["overlay-ui-ready-after-first-gpu-frame-\(cycle)"]=prepared
      checks["overlay-does-not-filter-transparent-chrome-on-cpu-\(cycle)"]=canvas.chromeBlurPasses==blurPasses
      let before=canvas.chromeRasters;var opened=false
      canvas.animateOverlayChrome(start:CACurrentMediaTime()+0.02,from:0,to:1,duration:0.12){opened=true}
      let openEnd=Date().addingTimeInterval(5)
      repeat{canvas.renderDisplayTick();pump()}while !opened && Date()<openEnd
      checks["overlay-chrome-animates-with-cached-raster-\(cycle)"]=opened && canvas.chromeRasters-before<=1
      canvas.section = .library;canvas.resetViewportArtworkMetrics();canvas.restoreInterfaceLibraryArtwork()
      let end=Date().addingTimeInterval(8)
      repeat{canvas.renderDisplayTick();pump()}while Date()<end && (canvas.viewportArtworkSnapshot.entries==0 || canvas.viewportArtworkSnapshot.pending>0)
      let snapshot=canvas.viewportArtworkSnapshot
      checks["overlay-visible-cards-reloaded-and-rasterized-\(cycle)"]=snapshot.entries>0 && snapshot.pending==0 && snapshot.completed==snapshot.entries
      checks["overlay-card-image-resident-\(cycle)"]=cache.hasResidentImage(gameID:games[0].id,role:.card)
      checks["overlay-does-not-load-banner-working-set-\(cycle)"] = !cache.hasResidentImage(gameID:games[0].id,role:.banner)
      var closed=false;canvas.animateOverlayChrome(start:CACurrentMediaTime(),from:1,to:0,duration:0.12){closed=true}
      let closeEnd=Date().addingTimeInterval(5);repeat{canvas.renderDisplayTick();pump()}while !closed && Date()<closeEnd
      checks["overlay-chrome-closing-frame-completes-\(cycle)"]=closed
      canvas.releaseGraphics();cache.beginGameplay();cache.setMaintenanceSuspended(true);canvas.gameInterfaceMode=false
      checks["overlay-close-releases-ui-and-artwork-\(cycle)"]=canvas.allocatedTextureBytes==0 && canvas.gridRenderSnapshot.layerCount==0 && !cache.hasResidentImage(gameID:games[0].id,role:.card)
    }
    window.close()
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"checks":checks,"count":checks.count,"ownProceduralImagesOnly":true,"offscreenUIRendering":true,"networkAccountGameOrScreenCaptureUsed":false]
    print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    if !checks.values.allSatisfy({$0}){exit(1)}
  }
}
