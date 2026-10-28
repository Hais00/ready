// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Metal

@main struct ReadyCanvasRenderingProbe {
  static func pixel(_ data: UnsafeMutableRawPointer) -> [Int] {
    (0..<4).map { Int(data.load(fromByteOffset: $0, as: UInt8.self)) }
  }
  static func main() throws {
    _ = NSApplication.shared
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let raster = CanvasRaster(width: 8, height: 8) else { throw NSError(domain: "CanvasProbe", code: 1) }
    let original = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bitmapFormat: [.alphaFirst, .thirtyTwoBitLittleEndian],
      bytesPerRow: 32, bitsPerPixel: 32)!
    let legacyContext = NSGraphicsContext(bitmapImageRep: original)!.cgContext
    let dark = NSColor(srgbRed: 16/255, green: 19/255, blue: 21/255, alpha: 1).cgColor
    legacyContext.setFillColor(dark); legacyContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    raster.context.setFillColor(dark); raster.context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let sourcePixel = pixel(raster.data)
    guard sourcePixel == [21,19,16,255] else { throw NSError(domain: "CanvasProbe", code: 2) }
    let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
    inputDescriptor.storageMode = .shared; inputDescriptor.usage = .shaderRead
    let input = device.makeTexture(descriptor: inputDescriptor)!
    input.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: raster.data, bytesPerRow: raster.bytesPerRow)
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
    targetDescriptor.storageMode = .shared; targetDescriptor.usage = [.renderTarget, .shaderRead]
    let target = device.makeTexture(descriptor: targetDescriptor)!
    let library = try device.makeLibrary(source: CanvasShader.source, options: nil)
    let config = MTLRenderPipelineDescriptor(); config.vertexFunction = library.makeFunction(name: "vertexMain"); config.fragmentFunction = library.makeFunction(name: "fragmentMain"); config.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: config)
    let command = queue.makeCommandBuffer()!, pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(input, index: 0); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    var gpu = [UInt8](repeating: 0, count: 8*8*4)
    gpu.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0) }
    let gpuPixel = gpu.prefix(4).map(Int.init)
    guard command.status == .completed, gpuPixel == sourcePixel else { throw NSError(domain: "CanvasProbe", code: 3) }
    var geometry = [[String: Any]]()
    for name in ["gamecontroller.fill", "person.2", "wifi", "apple.logo", "display"] {
      let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
      let rect = CanvasGeometry.aspectFit(symbol.size, in: CGRect(x: 0, y: 0, width: 36, height: 36))
      let preserved = abs(rect.width/rect.height - symbol.size.width/symbol.size.height) < 0.0001
      guard preserved, rect.width <= 36.001, rect.height <= 36.001 else { throw NSError(domain: "CanvasProbe", code: 4) }
      geometry.append(["symbol":name,"intrinsicWidth":symbol.size.width,"intrinsicHeight":symbol.size.height,"drawWidth":rect.width,"drawHeight":rect.height,"aspectPreserved":preserved])
    }
    let result: [String: Any] = ["passed":true,"legacyBitmapInfo":legacyContext.bitmapInfo.rawValue,"legacyAlphaInfo":legacyContext.alphaInfo.rawValue,"legacyRawPixel":pixel(original.bitmapData!),"explicitBitmapInfo":raster.context.bitmapInfo.rawValue,"explicitAlphaInfo":raster.context.alphaInfo.rawValue,"expectedBGRA":[21,19,16,255],"sourceBGRA":sourcePixel,"gpuBGRA":gpuPixel,"actualMetalRoundtrip":true,"symbols":geometry,"screenCaptureVerified":false]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
  }
}
