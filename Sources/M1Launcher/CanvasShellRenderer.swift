// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Metal
import QuartzCore

/// Immutable shader state survives UI texture teardown; the game never keeps
/// a hidden canvas working set solely to avoid recompiling on the next open.
private final class CanvasPipelineCache: @unchecked Sendable {
  static let shared=CanvasPipelineCache()
  private let lock=NSLock()
  private var states=[UInt64:MTLRenderPipelineState](),builds=0
  var compilationCount:Int{lock.lock();defer{lock.unlock()};return builds}
  func value(device:MTLDevice)throws->MTLRenderPipelineState{
    lock.lock();defer{lock.unlock()}
    if let state=states[device.registryID]{return state}
    let library=try device.makeLibrary(source:CanvasShader.source,options:nil),descriptor=MTLRenderPipelineDescriptor()
    descriptor.vertexFunction=library.makeFunction(name:"vertexMain");descriptor.fragmentFunction=library.makeFunction(name:"fragmentMain");descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    let state=try device.makeRenderPipelineState(descriptor:descriptor);states[device.registryID]=state;builds+=1;return state
  }
}

/// Rare chrome updates use immutable uploads. Drawable acquisition/encoding is
/// outside Main; at most two jobs exist, with GPU completion owning resources.
final class CanvasShellRenderer {
  static var pipelineCompilationCount:Int{CanvasPipelineCache.shared.compilationCount}
  private let device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLRenderPipelineState
  private let worker=DispatchQueue(label:"app.ready.canvas-shell",qos:.userInteractive)
  private let lock=NSLock()
  private var stopped=false,generation=0,jobs=0
  private var current:MTLTexture?
  private(set) var submitted=0
  var canSubmit:Bool{lock.lock();defer{lock.unlock()};return !stopped && jobs<2}
  var allocatedBytes:Int{lock.lock();defer{lock.unlock()};return stopped ? 0:(current.map{$0.width*$0.height*4} ?? 0)}
  var inFlight:Int{lock.lock();defer{lock.unlock()};return jobs}
  init(device:MTLDevice)throws{
    self.device=device
    guard let queue=device.makeCommandQueue()else{throw NSError(domain:"CanvasQueue",code:1)};self.queue=queue
    pipeline=try CanvasPipelineCache.shared.value(device:device)
  }
  @discardableResult func submit(_ raster:CanvasRaster,layer:CAMetalLayer,motion:SIMD4<Float> = SIMD4(0,0,1,0),completion:@escaping(Bool)->Void)->Bool{
    submit(raster,target:nil,drawable:{layer.nextDrawable()},motion:motion,completion:completion)
  }
  /// Own UI tests can render the exact shader/queue into a readback texture,
  /// without creating/ordering a window or involving WindowServer pacing.
  @discardableResult func submit(_ raster:CanvasRaster,target:MTLTexture,motion:SIMD4<Float> = SIMD4(0,0,1,0),completion:@escaping(Bool)->Void)->Bool{
    submit(raster,target:target,drawable:{nil},motion:motion,completion:completion)
  }
  @discardableResult func presentCurrent(layer:CAMetalLayer,target:MTLTexture?=nil,motion:SIMD4<Float>,completion:@escaping(Bool)->Void)->Bool{
    lock.lock();guard !stopped,jobs<2,let texture=current else{lock.unlock();return false};jobs+=1;let epoch=generation;lock.unlock()
    enqueue(texture,target:target,drawable:{layer.nextDrawable()},motion:motion,epoch:epoch,completion:completion);return true
  }
  private func submit(_ raster:CanvasRaster,target:MTLTexture?,drawable:@escaping()->CAMetalDrawable?,motion:SIMD4<Float>,completion:@escaping(Bool)->Void)->Bool{
    lock.lock();guard !stopped,jobs<2 else{lock.unlock();return false};jobs+=1;let epoch=generation;lock.unlock()
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:raster.width,height:raster.height,mipmapped:false);descriptor.storageMode = .shared;descriptor.usage = .shaderRead
    guard let texture=device.makeTexture(descriptor:descriptor)else{finish(epoch,success:false,completion:completion);return true}
    texture.replace(region:MTLRegionMake2D(0,0,raster.width,raster.height),mipmapLevel:0,withBytes:raster.data,bytesPerRow:raster.bytesPerRow)
    lock.lock();if !stopped{current=texture};submitted+=1;lock.unlock()
    enqueue(texture,target:target,drawable:drawable,motion:motion,epoch:epoch,completion:completion);return true
  }
  private func enqueue(_ texture:MTLTexture,target:MTLTexture?,drawable:@escaping()->CAMetalDrawable?,motion:SIMD4<Float>,epoch:Int,completion:@escaping(Bool)->Void){
    worker.async{[self]in autoreleasepool{
      lock.lock();let valid = !stopped && epoch==generation;lock.unlock()
      guard valid else{finish(epoch,success:false,completion:completion);return}
      let output=target==nil ? drawable():nil
      lock.lock();let stillValid = !stopped && epoch==generation;lock.unlock()
      guard stillValid else{finish(epoch,success:false,completion:completion);return}
      guard let destination=target ?? output?.texture,destination.width==texture.width,destination.height==texture.height,
        let command=queue.makeCommandBuffer()else{finish(epoch,success:false,completion:completion);return}
      let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=destination;pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
      guard let encoder=command.makeRenderCommandEncoder(descriptor:pass)else{finish(epoch,success:false,completion:completion);return}
      encoder.setRenderPipelineState(pipeline);encoder.setFragmentTexture(texture,index:0);var uniforms=motion;encoder.setFragmentBytes(&uniforms,length:MemoryLayout<SIMD4<Float>>.size,index:0);encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
      command.addCompletedHandler{[self,texture]done in withExtendedLifetime(texture){finish(epoch,success:done.status == .completed,completion:completion)}}
      if let output{command.present(output)};command.commit()
    }}
  }
  private func finish(_ epoch:Int,success:Bool,completion:@escaping(Bool)->Void){
    lock.lock();jobs-=1;let valid = !stopped && epoch==generation;lock.unlock()
    DispatchQueue.main.async{completion(success && valid)}
  }
  func stop(){lock.lock();stopped=true;generation+=1;current=nil;lock.unlock()}
}

final class CanvasDisplayLinkTarget:NSObject {
  weak var canvas:MetalCanvas?
  @objc func tick(_ displayLink:CADisplayLink){canvas?.renderDisplayTick()}
}
