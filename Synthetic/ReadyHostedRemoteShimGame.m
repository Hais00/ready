// SPDX-License-Identifier: GPL-3.0-only
// Own two-process integration; no account/game, capture/readback, or image copy.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import "ReadyHostedView.h"
static void emit(NSDictionary*v){NSData*d=[NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingSortedKeys error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);fflush(stdout);}
static void stopLoop(void){[NSApp stop:nil];[NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];}
@interface OwnRemoteView:NSView @end
@implementation OwnRemoteView
-(CALayer*)makeBackingLayer{return [CAMetalLayer layer];}
@end
@interface OwnRemoteFirst:NSObject
@property(strong)NSView*cover;
@property unsigned count;
@end
@implementation OwnRemoteFirst @end
static void ownFirstFrame(void*context){OwnRemoteFirst*s=(__bridge OwnRemoteFirst*)context;s.count++;[s.cover removeFromSuperview];}
@interface OwnRemoteFrames:NSObject<CAMetalDisplayLinkDelegate>
@property(strong)id<MTLCommandQueue>queue;
@property(strong)CAMetalDisplayLink*link;
@property(strong)CAMetalLayer*layer;
@property(strong)id<MTL4CommandQueue>queue4;
@property BOOL metal4,nativeControl;
@property unsigned frames,gpuDone,presented,positive;
@property BOOL finished;
@end
@implementation OwnRemoteFrames
-(void)metalDisplayLink:(CAMetalDisplayLink*)link needsUpdate:(CAMetalDisplayLinkUpdate*)update{
 if(self.finished)return;id<CAMetalDrawable>d=update.drawable;if(!d)return;self.frames++;
 MTLRenderPassDescriptor*p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=d.texture;p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;p.colorAttachments[0].clearColor=MTLClearColorMake(.1,.2,.35,1);
 [d addPresentedHandler:^(id<MTLDrawable>value){@synchronized(self){self.presented++;if(value.presentedTime>0)self.positive++;if(self.metal4&&self.presented<=8)emit(@{@"type":@"own-m4-presented",@"callback":@(self.presented),@"positive":@(value.presentedTime>0)});}}];
 if(self.metal4){
  [self.queue4 waitForDrawable:d];
  id<MTL4CommandAllocator>allocator=[self.layer.device newCommandAllocator];id<MTL4CommandBuffer>buffer=[self.layer.device newCommandBuffer];
  if(!allocator||!buffer||!self.layer.residencySet)_exit(34);
  [buffer beginCommandBufferWithAllocator:allocator];[buffer useResidencySet:self.layer.residencySet];
  MTL4RenderPassDescriptor*pass=[MTL4RenderPassDescriptor new];pass.colorAttachments[0].texture=d.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(.1,.2,.35,1);pass.renderTargetWidth=d.texture.width;pass.renderTargetHeight=d.texture.height;pass.defaultRasterSampleCount=1;
  id<MTL4RenderCommandEncoder>encoder=[buffer renderCommandEncoderWithDescriptor:pass];if(!encoder)_exit(35);[encoder endEncoding];[buffer endCommandBuffer];
  MTL4CommitOptions*options=[MTL4CommitOptions new];[options addFeedbackHandler:^(id<MTL4CommitFeedback>feedback){(void)allocator;(void)buffer;(void)d;if(feedback.error){emit(@{@"type":@"own-m4-error",@"code":@(feedback.error.code),@"domain":feedback.error.domain?:@"unavailable"});_exit(36);}@synchronized(self){self.gpuDone++;if(self.gpuDone<=8)emit(@{@"type":@"own-m4-gpu-completed",@"GPUCompleted":@(self.gpuDone),@"gpuTimelineValid":@(feedback.GPUEndTime>0&&feedback.GPUEndTime>=feedback.GPUStartTime)});}}];
  [self.queue4 commit:&buffer count:1 options:options];[self.queue4 signalDrawable:d];if(getenv("OWN_REMOTE_PLAIN_PRESENT"))[d present];else[d presentAfterMinimumDuration:1.0/60.0];
 }else{
  id<MTLCommandBuffer>cb=[self.queue commandBuffer];id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:p];[e endEncoding];
  [cb addCompletedHandler:^(id<MTLCommandBuffer>value){if(value.status!=MTLCommandBufferStatusCompleted)_exit(31);@synchronized(self){self.gpuDone++;}}];
  [cb presentDrawable:d];[cb commit];
 }
 if(self.frames>=48){self.finished=YES;[link invalidate];[link removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];link.delegate=nil;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
   NSDictionary*(*state)(void)=dlsym(RTLD_DEFAULT,"RHGOwnRemoteState");NSDictionary*s=state?state():@{};BOOL(*nativeM4)(id)=dlsym(RTLD_DEFAULT,"RHGOwnRemoteM4QueueNative");BOOL native4=self.nativeControl||!self.metal4||(nativeM4&&nativeM4(self.queue4));BOOL shimOK=self.nativeControl||([s[@"observersRestored"]boolValue]&&[s[@"nativeQueuesUnhooked"]boolValue]&&[s[@"firstSent"]boolValue]);BOOL passed=native4&&shimOK&&self.gpuDone==48&&self.positive>=12;
   emit(@{@"passed":@(passed),@"frames":@(self.frames),@"GPUCompleted":@(self.gpuDone),@"presentedCallbacks":@(self.presented),@"positivePresentedTimes":@(self.positive),@"shim":s,@"nativeDisplayLinkUpdateDrawable":@YES,@"nativeCommandBufferPresentBeforeCommit":@(!self.metal4),@"nativeMetal4WaitCommitSignalMinDuration":@(self.metal4&&!getenv("OWN_REMOTE_PLAIN_PRESENT")),@"nativeMetal4WaitCommitSignal":@(self.metal4),@"nativeMetal4QueueMethodsUnchanged":@(native4),@"explicitImageCopies":@0,@"screenCaptureOrReadback":@NO});stopLoop();
  });
 }
}
@end
int main(int argc,const char**argv){@autoreleasepool{
 if(argc!=4)return 2;BOOL native=!strcmp(argv[1],"native"),guest=!strcmp(argv[1],"guest");[NSApplication sharedApplication];[NSApp setActivationPolicy:guest?NSApplicationActivationPolicyProhibited:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
 if(guest||native){
  NSWindow*w=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,192,144) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];w.releasedWhenClosed=NO;OwnRemoteView*v=[[OwnRemoteView alloc]initWithFrame:NSMakeRect(0,0,192,144)];w.contentView=v;v.wantsLayer=YES;[w makeKeyAndOrderFront:nil];CAMetalLayer*l=(CAMetalLayer*)v.layer;l.device=MTLCreateSystemDefaultDevice();l.drawableSize=CGSizeMake(192,144);l.pixelFormat=MTLPixelFormatBGRA8Unorm;l.opaque=YES;l.framebufferOnly=YES;l.displaySyncEnabled=YES;
  OwnRemoteFrames*f=[OwnRemoteFrames new];f.nativeControl=native;f.layer=l;f.metal4=getenv("OWN_REMOTE_METAL4")&&strcmp(getenv("OWN_REMOTE_METAL4"),"1")==0;if(f.metal4){f.queue4=[l.device newMTL4CommandQueue];if(!f.queue4||!l.residencySet)return 37;[f.queue4 addResidencySet:l.residencySet];}else f.queue=[l.device newCommandQueue];f.link=[[CAMetalDisplayLink alloc]initWithMetalLayer:l];f.link.delegate=f;f.link.preferredFrameLatency=2;f.link.preferredFrameRateRange=CAFrameRateRangeMake(30,60,60);[f.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!f.finished){emit(@{@"passed":@NO,@"failure":@"guest-native-frame-timeout",@"frames":@(f.frames),@"GPUCompleted":@(f.gpuDone),@"positivePresentedTimes":@(f.positive)});_exit(32);}});if(native){[NSApp activateIgnoringOtherApps:YES];[CATransaction flush];}[NSApp run];if(native){[w orderOut:nil];[w close];}return f.positive>=12?0:33;
 }
 // Existing host UI device stands in for Ready's already allocated canvas;
 // RHGHostCreateRemote itself must not allocate another Metal device/layer.
 id<MTLDevice>canvasDevice=MTLCreateSystemDefaultDevice();NSWindow*w=[[NSWindow alloc]initWithContentRect:NSMakeRect(60,60,192,144) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];w.releasedWhenClosed=NO;
 RHGHostRef host=RHGHostCreateRemote((__bridge void*)w,canvasDevice.registryID,argv[2],argv[3]);if(!host)return 40;NSView*v=(__bridge NSView*)RHGHostGetView(host);w.contentView=v;
 NSView*cover=[[NSView alloc]initWithFrame:v.bounds];cover.wantsLayer=YES;cover.layer.backgroundColor=NSColor.blackColor.CGColor;cover.alphaValue=.999;[v addSubview:cover];
 OwnRemoteFirst*first=[OwnRemoteFirst new];first.cover=cover;RHGHostSetFirstFrameCallback(host,(__bridge void*)first,ownFirstFrame);
 [w makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];[CATransaction flush];
 NSTask*t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:@(argv[2])];t.arguments=@[@"guest",@(argv[2]),@(argv[3])];NSMutableDictionary*env=[NSProcessInfo.processInfo.environment mutableCopy];env[@"DYLD_INSERT_LIBRARIES"]=@(getenv("OWN_REMOTE_SHIM"));env[@"READY_HOSTED_GAME_TRANSPORT"]=@"remote-layer";env[@"READY_HOSTED_GAME_SERVICE"]=@(RHGHostService(host));env[@"READY_HOSTED_GAME_NONCE"]=@(RHGHostNonce(host));env[@"MTL_HUD_ENABLED"]=@"0";t.environment=env;NSError*err=nil;if(![t launchAndReturnError:&err])return 41;
 __block BOOL done=NO;NSTimer*timer=[NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer*timer){if(!t.running){done=YES;[timer invalidate];stopLoop();}}];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,13*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!done){[t terminate];_exit(42);}});[NSApp run];[timer invalidate];[t waitUntilExit];RHGHostStop(host);RHGHostDestroy(host);[w orderOut:nil];[w close];BOOL passed=t.terminationStatus==0&&first.count==1;emit(@{@"hostPassed":@(passed),@"firstFrameCallbacks":@(first.count),@"guestExitStatus":@(t.terminationStatus),@"ownTwoProcessProductionTransport":@YES});return passed?0:43;
}}
