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
    let iconRaster=CanvasRaster(width:32,height:32)!
    iconRaster.draw(logicalSize:CGSize(width:32,height:32),scale:1){cg in
      cg.setFillColor(NSColor.red.cgColor);cg.fill(CGRect(x:0,y:0,width:32,height:16))
      cg.setFillColor(NSColor.blue.cgColor);cg.fill(CGRect(x:0,y:16,width:32,height:16))
    }
    let iconPNG=NSBitmapImageRep(cgImage:iconRaster.context.makeImage()!).representation(using:.png,properties:[:])!,iconHash=ArtworkIndexStore.hash(iconPNG)
    let iconCandidates=GameArtwork.candidates(for:games[0],role:.icon)
    index.roles[games[0].id+"\u{1f}icon"]=ArtworkRoleRecord(gameID:games[0].id,role:.icon,candidates:iconCandidates,preferredURL:iconCandidates.first!,hash:iconHash)
    precondition(store.saveObject(iconPNG,hash:iconHash)&&store.save(index))
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
      if let grid=canvas.subviews.first(where:{$0 is LibraryGridSurface})as?LibraryGridSurface {
        let viewport=canvas.libraryLayoutSnapshot.viewport,chrome=canvas.layer?.sublayers?.first{$0.name=="Ready.chrome"}
        checks["catalog-uses-full-window-height-\(cycle)"]=viewport.minY==0&&viewport.height==canvas.bounds.height&&grid.frame==viewport
        checks["chrome-composes-above-catalog-\(cycle)"]=(chrome?.zPosition ?? -1)>(grid.layer?.zPosition ?? 0)
        canvas.interactionEnabled=true;canvas.scrollLibrary(by:-100000);canvas.renderDisplayTick();pump()
        let originBefore=grid.documentView?.layer?.convert(CGPoint.zero,to:canvas.layer)
        let offsetBefore=grid.offset
        canvas.scrollLibrary(by:150);canvas.renderDisplayTick();pump()
        let originAfter=grid.documentView?.layer?.convert(CGPoint.zero,to:canvas.layer)
        checks["native-scroll-layer-transform-follows-offset-\(cycle)"]=originBefore != nil && originAfter != nil && abs(abs(originAfter!.y-originBefore!.y)-abs(grid.offset-offsetBefore))<0.5
        checks["cards-can-scroll-under-header-\(cycle)"]=grid.visibleTileFrames.contains{$0.minY<84&&$0.maxY>0}
        canvas.scrollLibrary(by:100000);for _ in 0..<5{canvas.renderDisplayTick();pump()}
        checks["no-empty-footer-band-blocks-cards-\(cycle)"]=grid.visibleTileFrames.contains{$0.maxY>canvas.bounds.height-55}&&canvas.interactionSnapshot.hits.contains{if case .game=$0.action{return $0.rect.maxY>canvas.bounds.height-55};return false}
      }
      var closed=false;canvas.animateOverlayChrome(start:CACurrentMediaTime(),from:1,to:0,duration:0.12){closed=true}
      let closeEnd=Date().addingTimeInterval(5);repeat{canvas.renderDisplayTick();pump()}while !closed && Date()<closeEnd
      checks["overlay-chrome-closing-frame-completes-\(cycle)"]=closed
      canvas.releaseGraphics();cache.beginGameplay();cache.setMaintenanceSuspended(true);canvas.gameInterfaceMode=false
      checks["overlay-close-releases-ui-and-artwork-\(cycle)"]=canvas.allocatedTextureBytes==0 && canvas.gridRenderSnapshot.layerCount==0 && !cache.hasResidentImage(gameID:games[0].id,role:.card)
    }
    cache.resumeForGameInterface();canvas.gameInterfaceMode=true;canvas.section = .game;canvas.runningGames=[];canvas.resumeGraphics()
    let neutral=canvas.makeReferenceRaster(scale:1)!;let image=NSBitmapImageRep(cgImage:neutral.context.makeImage()!);var colored=0
    for y in stride(from:0,to:image.pixelsHigh,by:7){for x in stride(from:0,to:image.pixelsWide,by:7){if let c=image.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),abs(c.redComponent-c.greenComponent)>0.01||abs(c.greenComponent-c.blueComponent)>0.01{colored+=1}}}
    checks["interface-palette-is-grayscale"]=colored==0
    checks["dock-starts-at-top-with-library"]=canvas.interactionSnapshot.hits.first{$0.id=="nav.library"}?.rect.minY==20
    canvas.runningGames=[ReadyShellRunningGame(id:games[0].id,title:games[0].title)]
    let iconEnd=Date().addingTimeInterval(5);repeat{_ = cache.image(for:games[0],role:.icon,refresh:{});pump()}while !cache.hasResidentImage(gameID:games[0].id,role:.icon)&&Date()<iconEnd
    let iconView=NSBitmapImageRep(cgImage:canvas.makeReferenceRaster(scale:1)!.context.makeImage()!)
    let top=iconView.colorAt(x:36,y:91)!.usingColorSpace(.sRGB)!,bottom=iconView.colorAt(x:36,y:115)!.usingColorSpace(.sRGB)!
    checks["cached-running-game-icon-is-upright"]=top.redComponent>0.8&&top.blueComponent<0.2&&bottom.blueComponent>0.8&&bottom.redComponent<0.2
    canvas.releaseGraphics()
    window.close()
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"checks":checks,"count":checks.count,"ownProceduralImagesOnly":true,"offscreenUIRendering":true,"networkAccountGameOrScreenCaptureUsed":false]
    print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    if !checks.values.allSatisfy({$0}){exit(1)}
  }
}
