// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics

enum CanvasGeometry {
  static func drawUpright(_ image:CGImage,in rect:CGRect,context:CGContext){
    context.saveGState();context.translateBy(x:rect.minX,y:rect.maxY);context.scaleBy(x:1,y:-1)
    context.draw(image,in:CGRect(origin:.zero,size:rect.size));context.restoreGState()
  }
  static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
    scaled(size, in: rect, fill: false)
  }
  static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
    scaled(size, in: rect, fill: true)
  }
  private static func scaled(_ size: CGSize, in rect: CGRect, fill: Bool) -> CGRect {
    guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return .zero }
    let x = rect.width / size.width, y = rect.height / size.height
    let scale = fill ? max(x, y) : min(x, y)
    let result = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: rect.midX - result.width / 2, y: rect.midY - result.height / 2,
                  width: result.width, height: result.height)
  }
  static func minimumTarget(_ rect: CGRect, size: CGFloat = 44) -> CGRect {
    CGRect(x: rect.midX - max(rect.width, size) / 2, y: rect.midY - max(rect.height, size) / 2,
           width: max(rect.width, size), height: max(rect.height, size))
  }
}

/// The byte contract shared by scene preview and Metal upload is BGRA8.
/// No NSBitmapImageRep memory-layout assumption is used by the renderer.
final class CanvasRaster {
  let width: Int, height: Int, bytesPerRow: Int
  let data: UnsafeMutableRawPointer
  let context: CGContext
  init?(width: Int, height: Int) {
    guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
    self.width = width; self.height = height; bytesPerRow = width * 4
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info),
      let pixels = context.data else { return nil }
    self.context = context; self.data = pixels
  }
  func draw(logicalSize: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) {
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: logicalSize.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    body(context)
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()
  }
}

struct CanvasOverlayMotion {
  var from:Double,to:Double,began:Double,duration:Double
  func value(at time:Double)->Double{
    guard duration>0 else{return to}
    let t=max(0,min(1,(time-began)/duration)),p=t*t*(3-2*t)
    return from+(to-from)*p
  }
}
enum CanvasShader {
  static let source = """
      #include <metal_stdlib>
      using namespace metal;
      struct V { float4 position [[position]]; float2 uv; };
      vertex V vertexMain(uint i [[vertex_id]]) {
        float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
        V o;o.position=float4(p[i],0,1);o.uv=float2((p[i].x+1)*0.5,1-(p[i].y+1)*0.5);return o;
      }
      fragment float4 fragmentMain(V v [[stage_in]],texture2d<float> image [[texture(0)]],constant float4 &motion [[buffer(0)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);float2 uv=v.uv;
        if(motion.w>.5){
          if(uv.x<motion.x){if(uv.x>=motion.x*motion.z)return float4(0);uv.x+=motion.x*(1-motion.z);}
          else if(uv.y<motion.y){if(uv.y>=motion.y*motion.z)return float4(0);uv.y+=motion.y*(1-motion.z);}
        }
        float4 color=image.sample(s,uv);return motion.w>.5?color*motion.z:color;
      }
      """
}


/// Symbols are captured on Main once, before a card request leaves the UI thread.
struct LibraryCardSymbols {
  let controller:CGImage?,mac:CGImage?
  init(){
    func raster(_ name:String,_ tint:NSColor)->CGImage?{
      guard let symbol=NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[tint])),let raster=CanvasRaster(width:112,height:112)else{return nil}
      raster.draw(logicalSize:CGSize(width:56,height:56),scale:2){_ in symbol.draw(in:CanvasGeometry.aspectFit(symbol.size,in:CGRect(x:0,y:0,width:56,height:56)),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)}
      return raster.context.makeImage()
    }
    controller=raster("gamecontroller",NSColor(white:0.817,alpha:0.7));mac=raster("apple.logo",NSColor(white:0.96,alpha:1))
  }
}
/// Pure card snapshot. Workers never touch NSView, catalog state or ArtworkCache.
struct LibraryCardContent {
  let title:String,installed:Bool,macOS:Bool,windows:Bool,placeholderSeed:Int
  let artwork:CGImage?,symbols:LibraryCardSymbols
  private func color(_ hex:Int,_ alpha:CGFloat=1)->NSColor{
    let gray=(0.2126*CGFloat((hex>>16)&255)+0.7152*CGFloat((hex>>8)&255)+0.0722*CGFloat(hex&255))/255
    return NSColor(srgbRed:gray,green:gray,blue:gray,alpha:alpha)
  }
  private func round(_ rect:CGRect,_ fill:NSColor,radius:CGFloat=12){fill.setFill();NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()}
  private func icon(_ name:String,_ rect:CGRect,tint:NSColor){
    guard let image=name=="apple.logo" ? symbols.mac:symbols.controller,let cg=NSGraphicsContext.current?.cgContext else{return}
    CanvasGeometry.drawUpright(image,in:CanvasGeometry.aspectFit(CGSize(width:image.width,height:image.height),in:rect),context:cg)
  }
  private func text(_ value:String,_ rect:CGRect,size:CGFloat,bold:Bool,color:NSColor){
    let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
    (value as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold:.regular),.foregroundColor:color,.paragraphStyle:paragraph])
  }
  func draw(in cg:CGContext,rect r:CGRect){
      let coverHeight=r.width*LibraryCardMetrics.coverRatio
      round(r,color(installed ? 0x24332f:0x242a2d))
      let cover=CGRect(x:r.minX,y:r.minY,width:r.width,height:coverHeight)
      cg.saveGState();cg.addPath(CGPath(roundedRect:cover,cornerWidth:10,cornerHeight:10,transform:nil));cg.clip()
      if let image=artwork{
        let maximum=max(image.width,image.height)<=128 ? CGFloat(1):CGFloat.greatestFiniteMagnitude
        let scale=min(maximum,min(cover.width/CGFloat(image.width),cover.height/CGFloat(image.height)))
        let size=CGSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
        cg.saveGState();cg.translateBy(x:cover.minX,y:cover.maxY);cg.scaleBy(x:1,y:-1)
        cg.draw(image,in:CGRect(x:(cover.width-size.width)/2,y:(cover.height-size.height)/2,width:size.width,height:size.height));cg.restoreGState()
      }else{
        let hash=placeholderSeed
        cg.setFillColor(color(0x20363a | (hash&0x0f0f0f)).cgColor);cg.fill(cover)
        icon("gamecontroller",CGRect(x:cover.midX-28,y:cover.midY-28,width:56,height:56),tint:color(0xc1d2ce,0.7))
      }
      if !installed{cg.setBlendMode(.saturation);cg.setFillColor(NSColor.gray.cgColor);cg.fill(cover);cg.setBlendMode(.normal);cg.setFillColor(color(0x11171a,0.22).cgColor);cg.fill(cover)}
      cg.restoreGState()
      let mac=macOS
      let count=(mac ? 1:0)+(windows ? 1:0)
      if count>0 {
        let badge=CGRect(x:cover.maxX-CGFloat(count)*22-10,y:cover.minY+9,width:CGFloat(count)*22+3,height:25)
        round(badge,color(0x101819,0.82),radius:7)
        var x=badge.minX+4
        if mac{icon("apple.logo",CGRect(x:x,y:badge.minY+4,width:17,height:17),tint:color(0xf0f6f3));x+=22}
        if windows{let box=CGRect(x:x+1,y:badge.minY+5,width:15,height:15);color(0xf0f6f3).setFill();for row in 0..<2{for column in 0..<2{CGRect(x:box.minX+CGFloat(column)*8,y:box.minY+CGFloat(row)*8,width:6.5,height:6.5).fill()}}}
      }
      text(title,CGRect(x:r.minX+10,y:cover.maxY+10,width:r.width-20,height:23),size:13,bold:true,color:installed ? .white:color(0xc6cdcd))
  }
}
