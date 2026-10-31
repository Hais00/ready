// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Metal
import QuartzCore

// The display-link target is not used by this owned offscreen renderer probe.
final class MetalCanvas {func renderDisplayTick(){}}
@main struct ReadyChromeMotionProbe {
  @MainActor static func main() throws {
    _=NSApplication.shared;let device=MTLCreateSystemDefaultDevice()!,renderer=try CanvasShellRenderer(device:device)
    let raster=CanvasRaster(width:200,height:100)!
    raster.draw(logicalSize:CGSize(width:200,height:100),scale:1){cg in
      cg.setFillColor(NSColor.red.cgColor);cg.fill(CGRect(x:0,y:0,width:72,height:100))
      cg.setFillColor(NSColor.green.cgColor);cg.fill(CGRect(x:72,y:0,width:128,height:84))
      cg.setFillColor(NSColor.blue.cgColor);cg.fill(CGRect(x:72,y:84,width:128,height:16))
    }
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:200,height:100,mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
    let output=device.makeTexture(descriptor:descriptor)!,layer=CAMetalLayer();layer.device=device
    var checks=[String:Bool]()
    func wait(_ done:()->Bool)throws{let end=Date().addingTimeInterval(5);while !done()&&Date()<end{RunLoop.main.run(until:Date().addingTimeInterval(0.002))};if !done(){throw NSError(domain:"MotionDeadline",code:1)}}
    for step in 0...2 {
      let progress=Float(step)*0.5,motion=SIMD4<Float>(0.36,0.84,progress,1);var done=false,success=false
      let complete:(Bool)->Void={success=$0;done=true}
      let accepted=step==0 ? renderer.submit(raster,target:output,motion:motion,completion:complete):renderer.presentCurrent(layer:layer,target:output,motion:motion,completion:complete)
      try wait{done};checks["gpu-frame-\(step)"]=accepted&&success
      var data=[UInt8](repeating:0,count:200*100*4);output.getBytes(&data,bytesPerRow:800,from:MTLRegionMake2D(0,0,200,100),mipmapLevel:0)
      func pixel(_ x:Int,_ y:Int)->[UInt8]{Array(data[((y*200+x)*4)..<((y*200+x)*4+4)])}
      if step==0{checks["opening-start-is-transparent"]=data.enumerated().allSatisfy{$0.offset%4 != 3 || $0.element==0}}
      if step==1{
        let dock=pixel(18,60),emptyDock=pixel(54,60),header=pixel(110,20),emptyHeader=pixel(110,60)
        checks["dock-moves-left-to-right"]=dock[2]>110&&dock[3]>110&&emptyDock[3]==0
        checks["header-moves-top-to-bottom"]=header[1]>110&&header[3]>110&&emptyHeader[3]==0
      }
      if step==2{checks["open-endpoint-matches-real-ui-geometry"]=pixel(54,60)[2]>240&&pixel(110,60)[1]>240&&pixel(110,90)[0]>240}
    }
    checks["animation-reuses-one-raster-upload"]=renderer.submitted==1
    let curve=CanvasOverlayMotion(from:0,to:1,began:10,duration:0.24)
    checks["same-smoothstep-clock"]=curve.value(at:10)==0&&abs(curve.value(at:10.12)-0.5)<0.000001&&curve.value(at:10.24)>0.99999
    renderer.stop();let compilations=CanvasShellRenderer.pipelineCompilationCount
    let reopened=try CanvasShellRenderer(device:device)
    checks["reopen-reuses-immutable-pipeline-with-zero-textures"]=CanvasShellRenderer.pipelineCompilationCount==compilations && reopened.allocatedBytes==0
    reopened.stop();let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"checks":checks,"count":checks.count,"actualOffscreenCanvasShader":true,"screenCaptureGameOrAccountUsed":false]
    print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    if !checks.values.allSatisfy({$0}){exit(1)}
  }
}
