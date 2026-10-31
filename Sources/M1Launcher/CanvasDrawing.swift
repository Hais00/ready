// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics

enum CanvasGeometry {
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
