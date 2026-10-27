// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Metal
import QuartzCore
import ImageIO
import LauncherCore

enum CanvasAction { case game(String), store(Store?), profiles, importGame, settings, search, fullscreen, refresh }
struct CanvasHit { let rect:CGRect; let action:CanvasAction }

final class ArtworkCache {
    var images=[String:CGImage](), tasks=[String:URLSessionDataTask]()
    func image(_ address:String?,refresh:@escaping()->Void)->CGImage? {
        guard let address,let url=URL(string:address),url.scheme=="https" else{return nil}
        if let image=images[address]{return image}
        guard tasks[address]==nil else{return nil}
        let task=URLSession.shared.dataTask(with:url){[weak self] data,_,_ in
            guard let data,data.count<10_000_000,let src=CGImageSourceCreateWithData(data as CFData,nil),let cg=CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return}
            DispatchQueue.main.async {guard let self else{return};self.tasks.removeValue(forKey:address);if self.images.count>=18{self.images.removeAll()};self.images[address]=cg;refresh()}
        };tasks[address]=task;task.resume();return nil
    }
    func purge(){tasks.values.forEach{$0.cancel()};tasks.removeAll();images.removeAll()}
}

final class MetalCanvas:NSView {
    let device:MTLDevice
    private var queue:MTLCommandQueue?
    private var pipeline:MTLRenderPipelineState?
    private var texture:MTLTexture?
    private var lastCommand:MTLCommandBuffer?
    private var canvasLayer:CAMetalLayer?
    private let art=ArtworkCache()
    var state=LibraryState.initial()
    var filter:Store?
    var query=""
    var selected=0
    var message=""
    var onAction:((CanvasAction)->Void)?
    private var hits=[CanvasHit]()
    private var suspended=false
    var allocatedTextureBytes:Int { texture.map{$0.width*$0.height*4} ?? 0 }
    override var acceptsFirstResponder:Bool {true}
    override var isFlipped:Bool {true}
    init(frame:NSRect,device:MTLDevice) {
        self.device=device;super.init(frame:frame);wantsLayer=true
        do{try configure()}catch{message=error.localizedDescription}
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    private func configure()throws {
        queue=device.makeCommandQueue()
        let src="""
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vertexMain(uint i [[vertex_id]]) {
          float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
          V o;o.position=float4(p[i],0,1);o.uv=float2((p[i].x+1)*0.5,1-(p[i].y+1)*0.5);return o;
        }
        fragment float4 fragmentMain(V v [[stage_in]],texture2d<float> image [[texture(0)]]) {
          constexpr sampler s(filter::linear,address::clamp_to_edge);return image.sample(s,v.uv);
        }
        """
        let lib=try device.makeLibrary(source:src,options:nil), desc=MTLRenderPipelineDescriptor()
        desc.vertexFunction=lib.makeFunction(name:"vertexMain");desc.fragmentFunction=lib.makeFunction(name:"fragmentMain");desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline=try device.makeRenderPipelineState(descriptor:desc)
        let l=CAMetalLayer();l.device=device;l.pixelFormat = .bgra8Unorm;l.isOpaque=true;l.framebufferOnly=true;l.maximumDrawableCount=2;l.displaySyncEnabled=true;l.colorspace=CGColorSpace(name:CGColorSpace.sRGB)
        layer=l;canvasLayer=l
    }
    var visibleGames:[Game] {state.games.filter{($0.profileIDs==nil || $0.profileIDs!.contains(state.activeProfile)) && (filter==nil || $0.store==filter) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))}.sorted{($0.lastPlayed ?? .distantPast)>($1.lastPlayed ?? .distantPast)}}
    override func layout(){super.layout();redraw()}
    func refresh(){selected=min(selected,max(visibleGames.count-1,0));redraw()}
    func releaseGraphics(){
        suspended=true;lastCommand?.waitUntilCompleted();lastCommand=nil
        texture?.setPurgeableState(.empty);texture=nil;pipeline=nil;queue=nil
        canvasLayer?.device=nil;canvasLayer?.removeFromSuperlayer();canvasLayer=nil;layer=nil;art.purge();hits.removeAll()
    }
    func resumeGraphics(){suspended=false;try? configure();redraw()}
    func redraw(){
        guard !suspended,bounds.width>100,bounds.height>100,let layer=canvasLayer,let queue,let pipeline else{return}
        autoreleasepool {
            let scale=window?.backingScaleFactor ?? 2
            let w=max(Int(bounds.width*scale),1),h=max(Int(bounds.height*scale),1)
            guard w<=8192,h<=8192,let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bitmapFormat:[.alphaFirst,.thirtyTwoBitLittleEndian],bytesPerRow:w*4,bitsPerPixel:32),let bitmapContext=NSGraphicsContext(bitmapImageRep:bitmap) else{return}
            bitmap.size=bounds.size
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:bitmapContext.cgContext,flipped:true)
            // Draw in a stable top-left logical coordinate system.
            bitmapContext.cgContext.scaleBy(x:scale,y:scale);bitmapContext.cgContext.translateBy(x:0,y:bounds.height);bitmapContext.cgContext.scaleBy(x:1,y:-1)
            drawScene(bitmapContext.cgContext)
            NSGraphicsContext.restoreGraphicsState()
            if texture?.width != w || texture?.height != h {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false);d.usage=[.shaderRead];d.storageMode = .shared
                texture=device.makeTexture(descriptor:d)
            }
            guard let texture,let ptr=bitmap.bitmapData else{return}
            // Rendering is event-driven; wait for the previous canvas upload before overwriting shared storage.
            lastCommand?.waitUntilCompleted()
            texture.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:ptr,bytesPerRow:w*4)
            layer.contentsScale=scale;layer.drawableSize=CGSize(width:w,height:h)
            guard let drawable=layer.nextDrawable(),let cmd=queue.makeCommandBuffer() else{return}
            let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
            guard let encoder=cmd.makeRenderCommandEncoder(descriptor:pass) else{return}
            encoder.setRenderPipelineState(pipeline);encoder.setFragmentTexture(texture,index:0);encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
            cmd.present(drawable);cmd.commit();lastCommand=cmd
        }
    }
    private func color(_ hex:Int,_ alpha:CGFloat=1)->NSColor {NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha)}
    private func round(_ rect:CGRect,_ fill:NSColor,radius:CGFloat=12){fill.setFill();NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()}
    private func text(_ s:String,_ rect:CGRect,size:CGFloat=16,bold:Bool=false,color:NSColor = .white){
        let p=NSMutableParagraphStyle();p.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(in:rect,withAttributes:[.font:bold ? NSFont.systemFont(ofSize:size,weight:.semibold):NSFont.systemFont(ofSize:size),.foregroundColor:color,.paragraphStyle:p])
    }
    private func icon(_ name:String,_ rect:CGRect,tint:NSColor = .white){
        guard let image=NSImage(systemSymbolName:name,accessibilityDescription:nil) else{return}
        // Rasterize symbols into the single canvas; no intermediate NSView or compositor sublayer.
        let configuration=NSImage.SymbolConfiguration(paletteColors:[tint])
        let symbol=image.withSymbolConfiguration(configuration) ?? image
        symbol.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
    private func button(_ rect:CGRect,_ symbol:String,_ action:CanvasAction,active:Bool=false){round(rect,color(active ? 0x2a443b:0x24292b));icon(symbol,rect.insetBy(dx:10,dy:10),tint:active ? color(0x98f5b9):.white);hits.append(.init(rect:rect,action:action))}
    private func drawScene(_ cg:CGContext){
        hits.removeAll();let width=bounds.width,height=bounds.height
        cg.setFillColor(color(0x101315).cgColor);cg.fill(bounds)
        let colors=[color(0x2b3a40).cgColor,color(0x171719).cgColor,color(0x121416).cgColor] as CFArray
        if let g=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,0.5,1]){cg.drawLinearGradient(g,start:.init(x:60,y:0),end:.init(x:width,y:height),options:[])}
        cg.setFillColor(color(0x1b2226,0.9).cgColor);cg.fill(CGRect(x:0,y:0,width:70,height:height))
        icon("gamecontroller.fill",CGRect(x:23,y:23,width:24,height:24),tint:color(0x95edb4))
        button(CGRect(x:12,y:71,width:46,height:46),"house.fill",.store(nil),active:filter==nil)
        let symbols=["s.circle","e.circle","g.circle","a.circle"]
        for (i,s) in [Store.steam,.epic,.gog,.amazon].enumerated(){let r=CGRect(x:12,y:132+CGFloat(i)*57,width:46,height:46);button(r,symbols[i],.store(s),active:filter==s)}
        button(CGRect(x:12,y:height-174,width:46,height:46),"person.2",.profiles)
        button(CGRect(x:12,y:height-116,width:46,height:46),"plus",.importGame)
        button(CGRect(x:12,y:height-58,width:46,height:46),"gearshape",.settings)
        let left:CGFloat=112,content=width-left-36
        button(CGRect(x:left,y:22,width:37,height:37),"arrow.clockwise",.refresh)
        text("READY",CGRect(x:left+54,y:32,width:200,height:22),size:12,bold:true,color:color(0xb2c2c1))
        let profile=state.profiles.first{$0.id==state.activeProfile}?.name ?? "Giocatore"
        text(profile,CGRect(x:width-330,y:29,width:180,height:27),size:14,bold:true)
        icon("wifi",CGRect(x:width-137,y:30,width:20,height:20),tint:color(0xced4d3))
        let fmt=DateFormatter();fmt.dateFormat="HH:mm";text(fmt.string(from:Date()),CGRect(x:width-98,y:28,width:64,height:25),size:16,bold:true)
        text(query.isEmpty ? (filter?.title ?? "Riprendi a giocare"):"Risultati per “\(query)”",CGRect(x:left,y:91,width:content,height:36),size:25,bold:true)
        let games=visibleGames,cardWidth=min(184,max(140,(content-48)/4)),cardHeight=cardWidth*1.05
        let count=min(games.count,max(1,Int((content+16)/(cardWidth+16))))
        let first=max(0,min(max(games.count-count,0),selected-count+1))
        for slot in 0..<count {
            let i=first+slot,game=games[i],r=CGRect(x:left+CGFloat(slot)*(cardWidth+16),y:143,width:cardWidth,height:cardHeight)
            round(r,color(0x303d43))
            cg.saveGState();cg.addPath(CGPath(roundedRect:r,cornerWidth:12,cornerHeight:12,transform:nil));cg.clip()
            if let image=art.image(game.artworkURL,refresh:{[weak self] in self?.redraw()}){cg.saveGState();cg.translateBy(x:r.minX,y:r.maxY);cg.scaleBy(x:1,y:-1);cg.draw(image,in:CGRect(origin:.zero,size:r.size));cg.restoreGState()}
            else{icon(game.currentVariant?.platform == .macOS ? "apple.logo":"gamecontroller.fill",r.insetBy(dx:cardWidth*0.32,dy:cardHeight*0.32),tint:color(0x93bab3))}
            cg.setFillColor(color(0x050809,0.85).cgColor);cg.fill(CGRect(x:r.minX,y:r.maxY-61,width:r.width,height:61));cg.restoreGState()
            text(game.title,CGRect(x:r.minX+12,y:r.maxY-50,width:r.width-24,height:25),size:14,bold:true)
            text(game.currentVariant?.title ?? game.store.title,CGRect(x:r.minX+12,y:r.maxY-26,width:r.width-24,height:20),size:10,color:color(0xc1d9d0))
            if i==selected {let outline=NSBezierPath(roundedRect:r.insetBy(dx:-4,dy:-4),xRadius:15,yRadius:15);color(0xb5ffd0).setStroke();outline.lineWidth=2;outline.stroke()}
            hits.append(.init(rect:r,action:.game(game.id)))
        }
        if games.isEmpty {
            let r=CGRect(x:left,y:143,width:content,height:cardHeight)
            round(r,color(0x222b30));icon("plus.circle",CGRect(x:left+23,y:169,width:36,height:36),tint:color(0xa2eec2))
            text("La tua prossima sessione comincia qui",CGRect(x:left+78,y:165,width:content-100,height:32),size:21,bold:true)
            text("Collega uno store o importa un gioco già installato.",CGRect(x:left+78,y:204,width:content-100,height:24),size:15,color:color(0xb5c2c7))
            hits.append(.init(rect:r,action:.importGame))
        }
        let y:CGFloat=143+cardHeight+46
        text("La tua libreria, il tuo modo di giocare",CGRect(x:left,y:y,width:content,height:33),size:23,bold:true)
        let featureWidth=(content-20)/2,fh:CGFloat=min(200,height-y-110)
        if fh>60 {
            for i in 0..<2 {
                let r=CGRect(x:left+CGFloat(i)*(featureWidth+20),y:y+47,width:featureWidth,height:fh)
                round(r,color(i==0 ? 0x1c3a32:0x263547))
                icon(i==0 ? "apple.logo":"display",CGRect(x:r.minX+22,y:r.minY+20,width:36,height:36),tint:color(i==0 ? 0xa3f5b9:0xa9cfff))
                text(i==0 ? "Nativo quando disponibile":"Tutto lo spazio al gioco",CGRect(x:r.minX+22,y:r.maxY-76,width:r.width-40,height:30),size:20,bold:true)
                text(i==0 ? "Scegli Apple Silicon o Windows per ogni titolo.":"Il launcher rilascia le sue risorse grafiche durante la sessione.",CGRect(x:r.minX+22,y:r.maxY-44,width:r.width-40,height:40),size:13,color:color(0xc3d0ce))
                hits.append(.init(rect:r,action:i==0 ? .importGame:.settings))
            }
        }
        text(message.isEmpty ? "← →  Seleziona     Invio  Gioca     Spazio  Opzioni     ⌘F  Cerca     ⌘O  Importa":message,CGRect(x:left,y:height-38,width:content,height:25),size:12,color:color(0xaebcba))
    }
    override func keyDown(with event:NSEvent){
        switch event.keyCode {
        case 123:selected=max(0,selected-1);redraw()
        case 124:selected=min(max(visibleGames.count-1,0),selected+1);redraw()
        case 36,49:if visibleGames.indices.contains(selected){onAction?(.game(visibleGames[selected].id))}
        case 53:if window?.styleMask.contains(.fullScreen)==true{window?.toggleFullScreen(nil)}
        default:super.keyDown(with:event)
        }
    }
    override func mouseDown(with event:NSEvent){let p=convert(event.locationInWindow,from:nil);if let hit=hits.last(where:{$0.rect.contains(p)}){onAction?(hit.action)}}
    func writePreview(_ url:URL)throws {
        // Reuse exactly the scene renderer, without screen capture permissions.
        let w=Int(bounds.width),h=Int(bounds.height)
        guard let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:w*4,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:rep) else{return}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context.cgContext,flipped:true);context.cgContext.translateBy(x:0,y:CGFloat(h));context.cgContext.scaleBy(x:1,y:-1);drawScene(context.cgContext);NSGraphicsContext.restoreGraphicsState()
        if let png=rep.representation(using:.png,properties:[:]){try png.write(to:url)}
    }
}
