// SPDX-License-Identifier: GPL-3.0-only
// Independent ordinary application. No transport, shim detection or host path.
// The exact same signed binary runs once normally and once with DYLD injection.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#import <unistd.h>
#import <sys/resource.h>
static double cpuNow(void){struct rusage r;getrusage(RUSAGE_SELF,&r);return r.ru_utime.tv_sec+r.ru_utime.tv_usec/1e6+r.ru_stime.tv_sec+r.ru_stime.tv_usec/1e6;}
static void emit(NSDictionary*v){NSData*d=[NSJSONSerialization dataWithJSONObject:v options:0 error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);fflush(stdout);}
static NSArray*windows(void){NSArray*all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));NSMutableArray*out=[NSMutableArray new];for(NSDictionary*w in all)if([w[(id)kCGWindowOwnerPID]intValue]==getpid())[out addObject:w[(id)kCGWindowNumber]];return out;}
int main(int argc,char**argv){@autoreleasepool{double cpuStart=cpuNow();
 if(argc!=2)return 64;int frames=atoi(argv[1]);if(frames<1||frames>600)return 64;alarm(40);
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
 NSWindow*w=[[NSWindow alloc]initWithContentRect:NSMakeRect(140,140,640,360) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];w.releasedWhenClosed=NO;w.title=@"Ready NoCopyProxy Lab — ordinary GUEST";
 NSView*v=[[NSView alloc]initWithFrame:NSMakeRect(0,0,640,360)];v.wantsLayer=YES;CAMetalLayer*l=[CAMetalLayer layer];id<MTLDevice>d=MTLCreateSystemDefaultDevice();l.device=d;l.pixelFormat=MTLPixelFormatBGRA8Unorm;l.drawableSize=CGSizeMake(640,360);l.framebufferOnly=YES;v.layer=l;w.contentView=v;[w makeKeyAndOrderFront:nil];
 emit(@{@"type":@"guest-window",@"pid":@(getpid()),@"reportedWindow":@(w.windowNumber),@"windows":windows(),@"appWindowCount":@(NSApp.windows.count),@"logicalClass":NSStringFromClass([w class])});
 id<MTLCommandQueue>q=[d newCommandQueue];NSError*error=nil;id<MTLLibrary>lib=[d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;vertex float4 v(uint i[[vertex_id]]){float2 p[3]={float2(-.7,-.7),float2(.7,-.7),float2(0,.7)};return float4(p[i],0,1);}fragment float4 f(){return float4(.12,.95,.32,1);}" options:nil error:&error];if(!lib)return 65;
 MTLRenderPipelineDescriptor*pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=[lib newFunctionWithName:@"f"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;id<MTLRenderPipelineState>p=[d newRenderPipelineStateWithDescriptor:pd error:&error];if(!p)return 66;
 double gpu=0,start=CACurrentMediaTime();for(int i=0;i<frames;i++){@autoreleasepool{
  id<CAMetalDrawable>drawable=[l nextDrawable];if(!drawable)return 67;MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(.1+.4*(i%60)/60.,.08,.18,1);
  id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:p];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];[cb presentDrawable:drawable];[cb commit];[cb waitUntilCompleted];if(cb.status==MTLCommandBufferStatusError)return 68;gpu+=cb.GPUEndTime-cb.GPUStartTime;
  if(i==0||i%30==0)emit(@{@"type":@"guest-frame",@"frame":@(i),@"surface":@(drawable.texture.iosurface?IOSurfaceGetID(drawable.texture.iosurface):0),@"windows":windows()});
  usleep(16000);
 }}
 usleep(100000);emit(@{@"type":@"guest-done",@"frames":@(frames),@"windows":windows(),@"reportedWindow":@(w.windowNumber),@"renderEncoders":@(frames),@"blitEncoders":@0,@"computeEncoders":@0,@"GPUSeconds":@(gpu),@"elapsedSeconds":@(CACurrentMediaTime()-start),@"CPUSeconds":@(cpuNow()-cpuStart)});[w orderOut:nil];return 0;
}}
