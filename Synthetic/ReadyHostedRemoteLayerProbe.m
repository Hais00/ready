// SPDX-License-Identifier: GPL-3.0-only
// Research only: private system QuartzCore selectors declared from runtime metadata.
// No Apple implementation code, framework binary or source is copied into this fixture.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <sys/stat.h>
@interface CAContext:NSObject
+(void)setAllowsCGSConnections:(BOOL)allowed;
+(instancetype)remoteContextWithOptions:(NSDictionary*)options;
@property(nonatomic,strong)CALayer*layer;
@property(nonatomic,readonly)uint32_t contextId;
-(void)invalidate;
@end
@interface CALayerHost:CALayer
@property(nonatomic,assign)uint32_t contextId;
@end
@interface RemoteHostView:NSView
@end
@implementation RemoteHostView
-(CALayer*)makeBackingLayer{return [NSClassFromString(@"CALayerHost") new];}
@end
static void writeJSON(NSDictionary*json,NSString*path){NSData*d=[NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];[d writeToFile:path atomically:YES];chmod(path.fileSystemRepresentation,0600);}
static NSDictionary*readJSON(NSString*path){NSData*d=[NSData dataWithContentsOfFile:path];return d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
static void emit(NSDictionary*json){NSData*d=[NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);}
static void stopLoop(void){[NSApp stop:nil];NSEvent*e=[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];[NSApp postEvent:e atStart:NO];}
@interface RemoteNativeDriver:NSObject<CAMetalDisplayLinkDelegate>
@property(nonatomic,strong)id<MTLCommandQueue>queue;
@property(nonatomic,strong)CAMetalDisplayLink*link;
@property(nonatomic,strong)NSMutableArray*times;
@property(nonatomic,strong)NSMutableArray*surfaceIDs;
@property(nonatomic,copy)NSString*root;
@property(nonatomic,copy)void(^finish)(NSDictionary*);
@property(nonatomic)unsigned submitted,callbacks,gpuDone;
@property(nonatomic)BOOL firstGPU,firstPresented,notified,failed,positiveOnly;
@property(nonatomic)unsigned startupObservedDrawables;
@property(nonatomic)double firstStamp,began;
@property(nonatomic,copy)NSString*actualUpdateClass;
@property(nonatomic)BOOL updateUsesBaseDrawableGetter;
@end
@implementation RemoteNativeDriver
-(void)notifyFirstIfReady{
 if(self.notified||!self.firstPresented||(self.positiveOnly?self.firstStamp<=0:!self.firstGPU))return;self.notified=YES;
 writeJSON(@{@"firstGPUComplete":@YES,@"firstPresentedHandlerFired":@YES,@"firstPresentedTime":@(self.firstStamp),@"GPUCompletionUsedAsGate":@(!self.positiveOnly),@"startupObservedDrawables":@(self.startupObservedDrawables)},[self.root stringByAppendingPathComponent:@"first-native-frame"]);
}
-(void)finishIfReady{
 if(self.callbacks<48||self.gpuDone<48)return;self.link.paused=YES;[self.link removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];self.link.delegate=nil;[self.link invalidate];
 BOOL monotonic=YES;for(NSUInteger i=1;i<self.times.count;i++)if([self.times[i]doubleValue]<=[self.times[i-1]doubleValue])monotonic=NO;
 self.finish(@{@"passed":@(!self.failed&&self.notified&&self.times.count>=12&&monotonic),@"nativeDrawableFrames":@(self.submitted),@"displayLinkCallbacks":@(self.submitted),@"presentCallbacks":@(self.callbacks),@"actualPresentedFrames":@(self.times.count),@"presentedTimes":self.times,@"surfaceIDs":self.surfaceIDs,@"nativeCAMetalDisplayLink":@YES,@"actualDisplayLinkClass":NSStringFromClass(object_getClass(self.link)),@"actualUpdateClass":self.actualUpdateClass?:@"",@"updateUsesBaseDrawableGetter":@(self.updateUsesBaseDrawableGetter),@"preferredFrameLatency":@2,@"preferredRangeMinimum":@30,@"preferredRangeMaximum":@60,@"preferredRangePreferred":@60,@"nativeCommandBufferPresentationBeforeCommit":@YES,@"firstGPUComplete":@(self.firstGPU),@"firstPresentedHandlerFired":@(self.firstPresented),@"firstPresentedTime":@(self.firstStamp),@"oneShotFirstFrameNotification":@(self.notified),@"positiveOnlyHandoff":@(self.positiveOnly),@"GPUCompletionUsedAsGate":@(!self.positiveOnly),@"startupObservedDrawables":@(self.startupObservedDrawables),@"monotonicPresentedTime":@(monotonic),@"elapsedSeconds":@(CACurrentMediaTime()-self.began),@"explicitGPUOrCPUImageCopies":@0,@"textureImports":@0,@"perFrameApplicationIPC":@0});
}
-(void)metalDisplayLink:(CAMetalDisplayLink*)link needsUpdate:(CAMetalDisplayLinkUpdate*)update{
 if(self.submitted>=48){link.paused=YES;return;}
 unsigned index=self.submitted++;if(index==0){self.actualUpdateClass=NSStringFromClass(object_getClass(update));self.updateUsesBaseDrawableGetter=class_getMethodImplementation(object_getClass(update),@selector(drawable))==class_getMethodImplementation(NSClassFromString(@"CAMetalDisplayLinkUpdate"),@selector(drawable));}id<CAMetalDrawable>d=update.drawable;
 if(d.texture.iosurface)[self.surfaceIDs addObject:@(IOSurfaceGetID(d.texture.iosurface))];
 MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=d.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(.12,.16+(.02*(index%3)),.25,1);
 id<MTLCommandBuffer>cb=[self.queue commandBuffer];id<MTLRenderCommandEncoder>encoder=[cb renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];
 __weak RemoteNativeDriver*weak=self;
 [d addPresentedHandler:^(id<MTLDrawable>value){double stamp=value.presentedTime;dispatch_async(dispatch_get_main_queue(),^{RemoteNativeDriver*strong=weak;if(!strong)return;strong.callbacks++;if(stamp>0)[strong.times addObject:@(stamp)];if(strong.positiveOnly){if(index<8&&!strong.notified){strong.startupObservedDrawables++;if(stamp>0){strong.firstPresented=YES;strong.firstStamp=stamp;[strong notifyFirstIfReady];}}}else if(index==0){strong.startupObservedDrawables=1;strong.firstPresented=YES;strong.firstStamp=stamp;[strong notifyFirstIfReady];}[strong finishIfReady];});}];
 [cb addCompletedHandler:^(id<MTLCommandBuffer>value){BOOL good=value.status==MTLCommandBufferStatusCompleted;dispatch_async(dispatch_get_main_queue(),^{RemoteNativeDriver*strong=weak;if(!strong)return;strong.gpuDone++;if(!good)strong.failed=YES;if(index==0){strong.firstGPU=good;[strong notifyFirstIfReady];}[strong finishIfReady];});}];
 // Preserve real update.drawable and native display-link queue scheduling.
 // Explicit presentAtTime is forbidden for CAMetalDisplayLink-provided drawables.
 [cb presentDrawable:d];[cb commit];
}
@end
static int guestDisplayLink(NSString*root,BOOL positiveOnly){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];[NSApp finishLaunching];
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();Class cls=NSClassFromString(@"CAContext");[cls setAllowsCGSConnections:NO];
 NSString* __unsafe_unretained const*option=(NSString* __unsafe_unretained const*)dlsym(RTLD_DEFAULT,"kCAContextCIFilterBehavior");
 CAContext*context=[cls remoteContextWithOptions:option?@{*option:@"ignore"}:@{}];
 CAMetalLayer*layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;layer.opaque=YES;layer.frame=CGRectMake(0,0,192,144);layer.drawableSize=CGSizeMake(192,144);layer.maximumDrawableCount=3;layer.allowsNextDrawableTimeout=YES;layer.displaySyncEnabled=YES;context.layer=layer;[CATransaction flush];
 if(!device||!context||!context.contextId)return 20;
 writeJSON(@{@"contextId":@(context.contextId),@"guestPID":@(getpid()),@"guestWindowCount":@(NSApp.windows.count)},[root stringByAppendingPathComponent:@"context.json"]);
 RemoteNativeDriver*driver=[RemoteNativeDriver new];driver.positiveOnly=positiveOnly;driver.queue=[device newCommandQueue];driver.times=[NSMutableArray new];driver.surfaceIDs=[NSMutableArray new];driver.root=root;
 __block BOOL done=NO;__block NSDictionary*report=nil;
 driver.finish=^(NSDictionary*result){NSMutableDictionary*full=[result mutableCopy];full[@"guestPID"]=@(getpid());full[@"guestWindowCount"]=@(NSApp.windows.count);full[@"contextId"]=@(context.contextId);full[@"passed"]=@([result[@"passed"]boolValue]&&NSApp.windows.count==0);report=full;writeJSON(full,[root stringByAppendingPathComponent:@"guest-result.json"]);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{context.layer=nil;[CATransaction flush];[context invalidate];done=YES;stopLoop();});};
 __block BOOL started=NO;
 NSTimer*poll=[NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer*t){if(started||![NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"host-attached"]])return;started=YES;[t invalidate];driver.began=CACurrentMediaTime();driver.link=[[CAMetalDisplayLink alloc]initWithMetalLayer:layer];driver.link.delegate=driver;driver.link.preferredFrameLatency=2;driver.link.preferredFrameRateRange=CAFrameRateRangeMake(30,60,60);driver.link.paused=NO;[driver.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];if(positiveOnly)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!done&&!driver.notified){report=@{@"passed":@NO,@"failure":@"first-positive-startup-deadline",@"startupObservedDrawables":@(driver.startupObservedDrawables),@"GPUCompletionUsedAsGate":@NO};writeJSON(report,[root stringByAppendingPathComponent:@"guest-result.json"]);driver.link.paused=YES;[driver.link removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];driver.link.delegate=nil;[driver.link invalidate];context.layer=nil;[context invalidate];done=YES;stopLoop();}});}];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!done){writeJSON(@{@"passed":@NO,@"failure":@"displaylink-overall-deadline",@"submitted":@(driver.submitted),@"callbacks":@(driver.callbacks),@"gpuDone":@(driver.gpuDone),@"firstGPUComplete":@(driver.firstGPU),@"firstPresentedHandlerFired":@(driver.firstPresented),@"firstPresentedTime":@(driver.firstStamp),@"guestWindowCount":@(NSApp.windows.count)},[root stringByAppendingPathComponent:@"guest-result.json"]);[driver.link invalidate];context.layer=nil;[context invalidate];_exit(21);}});
 [NSApp run];[poll invalidate];return [report[@"passed"]boolValue]?0:22;
}}
static int guest(NSString*root){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];[NSApp finishLaunching];
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue>queue=[device newCommandQueue];
 Class cls=NSClassFromString(@"CAContext");if(!device||!queue||!cls)return 10;
 [cls setAllowsCGSConnections:NO];NSString* __unsafe_unretained const*option=(NSString* __unsafe_unretained const*)dlsym(RTLD_DEFAULT,"kCAContextCIFilterBehavior");
 CAContext*context=[cls remoteContextWithOptions:option?@{*option:@"ignore"}:@{}];
 if(!context||!context.contextId)return 11;
 CAMetalLayer*layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;layer.opaque=YES;
 layer.frame=CGRectMake(0,0,192,144);layer.drawableSize=CGSizeMake(192,144);layer.maximumDrawableCount=3;layer.allowsNextDrawableTimeout=YES;layer.displaySyncEnabled=YES;layer.presentsWithTransaction=NO;
 context.layer=layer;[CATransaction flush];
 writeJSON(@{@"contextId":@(context.contextId),@"guestPID":@(getpid()),@"guestWindowCount":@(NSApp.windows.count)},[root stringByAppendingPathComponent:@"context.json"]);
 __block BOOL started=NO,done=NO;__block NSDictionary*report=nil;
 __block NSTimer*poll=nil;
 poll=[NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer*t){
  if(started||![NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"host-attached"]])return;
  started=YES;[t invalidate];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
   NSMutableArray*times=[NSMutableArray new];NSMutableArray*surfaceIDs=[NSMutableArray new];unsigned frames=0,callbacks=0;NSString*failure=nil;double began=CACurrentMediaTime();
   for(unsigned i=0;i<48&&!failure;i++){@autoreleasepool{
    id<CAMetalDrawable>d=[layer nextDrawable];if(!d){failure=@"nextDrawable-timeout";break;}
    IOSurfaceRef surface=d.texture.iosurface;if(surface)[surfaceIDs addObject:@(IOSurfaceGetID(surface))];
    MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=d.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(.08+(.02*(i%3)),.16,.26,1);
    id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLRenderCommandEncoder>encoder=[cb renderCommandEncoderWithDescriptor:pass];if(!encoder){failure=@"native-render-encoder-unavailable";break;}[encoder endEncoding];
    dispatch_semaphore_t shown=dispatch_semaphore_create(0);__block double stamp=0;
    [d addPresentedHandler:^(id<MTLDrawable>value){stamp=value.presentedTime;dispatch_semaphore_signal(shown);}];
    // Genuine native queue presentation registered BEFORE commit, without wrapper or host RPC.
    [cb presentDrawable:d afterMinimumDuration:1.0/60.0];[cb commit];[cb waitUntilCompleted];
    if(cb.status!=MTLCommandBufferStatusCompleted){failure=@"native-gpu-command-failed";break;}
    if(dispatch_semaphore_wait(shown,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))){failure=@"presented-handler-timeout";break;}
    callbacks++;if(stamp>0)[times addObject:@(stamp)];frames++;
   }}
   BOOL monotonic=YES;for(NSUInteger i=1;i<times.count;i++)if([times[i]doubleValue]<=[times[i-1]doubleValue])monotonic=NO;
   dispatch_async(dispatch_get_main_queue(),^{
    NSUInteger windows=NSApp.windows.count;BOOL passed=!failure&&frames==48&&times.count>=12&&monotonic&&windows==0;
    report=@{@"passed":@(passed),@"guestPID":@(getpid()),@"guestWindowCount":@(windows),@"contextId":@(context.contextId),@"nativeDrawableFrames":@(frames),@"presentCallbacks":@(callbacks),@"actualPresentedFrames":@(times.count),@"presentedTimes":times,@"surfaceIDs":surfaceIDs,@"monotonicPresentedTime":@(monotonic),@"elapsedSeconds":@(CACurrentMediaTime()-began),@"failure":failure?:@"",@"nativeCommandBufferPresentationBeforeCommit":@YES,@"textureImports":@0,@"explicitGPUOrCPUImageCopies":@0,@"perFrameApplicationIPC":@0};
    writeJSON(report,[root stringByAppendingPathComponent:@"guest-result.json"]);context.layer=nil;[context invalidate];done=YES;stopLoop();
   });
  }});
 }];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!done){writeJSON(@{@"passed":@NO,@"failure":@"guest-overall-deadline",@"guestWindowCount":@(NSApp.windows.count)},[root stringByAppendingPathComponent:@"guest-result.json"]);context.layer=nil;[context invalidate];_exit(12);}});
 [NSApp run];return [report[@"passed"]boolValue]?0:13;
}}
int main(int argc,const char**argv){@autoreleasepool{
 umask(077);if(argc!=4)return 2;NSString*mode=@(argv[1]),*root=@(argv[2]),*binary=@(argv[3]);if([mode isEqual:@"guest"])return guest(root);if([mode hasPrefix:@"guest-link"])return guestDisplayLink(root,[mode containsString:@"positive"]);
 BOOL linkMode=[mode containsString:@"link"];float coverOpacity=[mode containsString:@"translucent"]?.95f:([mode containsString:@"almost"]?.999f:1.f);
 Class contextClass=NSClassFromString(@"CAContext"),hostClass=NSClassFromString(@"CALayerHost");
 if(!contextClass||!hostClass||![contextClass respondsToSelector:@selector(remoteContextWithOptions:)]||![hostClass instancesRespondToSelector:@selector(setContextId:)]){emit(@{@"passed":@NO,@"failure":@"private-selectors-unavailable"});return 3;}
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
 NSWindow*window=[[NSWindow alloc]initWithContentRect:NSMakeRect(80,80,192,144) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];window.title=@"Ready own remote-layer regression";window.releasedWhenClosed=NO;
 NSView*container=[[NSView alloc]initWithFrame:NSMakeRect(0,0,192,144)];container.wantsLayer=YES;window.contentView=container;
 RemoteHostView*view=[[RemoteHostView alloc]initWithFrame:container.bounds];[container addSubview:view];view.wantsLayer=YES;
 NSView*cover=nil;if(linkMode){cover=[[NSView alloc]initWithFrame:container.bounds];cover.wantsLayer=YES;cover.layer.backgroundColor=NSColor.blackColor.CGColor;cover.layer.opaque=YES;cover.layer.opacity=coverOpacity;[container addSubview:cover];}
 CALayerHost*host=(CALayerHost*)view.layer;host.frame=view.bounds;host.opaque=YES;
 [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];[CATransaction flush];
 NSTask*task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:binary];task.arguments=@[linkMode?([mode containsString:@"positive"]?@"guest-link-positive":@"guest-link"):@"guest",root,binary];
 NSString*outPath=[root stringByAppendingPathComponent:@"guest.stdout.log"],*errPath=[root stringByAppendingPathComponent:@"guest.stderr.log"];
 [[NSData data]writeToFile:outPath atomically:NO];[[NSData data]writeToFile:errPath atomically:NO];task.standardOutput=[NSFileHandle fileHandleForWritingAtPath:outPath];task.standardError=[NSFileHandle fileHandleForWritingAtPath:errPath];NSError*error=nil;
 if(![task launchAndReturnError:&error]){[window close];emit(@{@"passed":@NO,@"failure":@"guest-start-failed",@"errorCode":@(error.code)});return 4;}
 __block BOOL attached=NO,finished=NO,coverRemoved=NO;__block uint32_t installedID=0;__block BOOL visible=NO;__block NSDictionary*guestReport=nil;
 NSTimer*timer=[NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer*t){
  if(!attached){NSDictionary*context=readJSON([root stringByAppendingPathComponent:@"context.json"]);uint32_t cid=[context[@"contextId"]unsignedIntValue];
   if(cid){installedID=cid;host.contextId=cid;[CATransaction flush];attached=YES;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{visible=window.visible&&(window.occlusionState&NSWindowOcclusionStateVisible)!=0;writeJSON(@{@"attachedContextId":@(host.contextId),@"hostWindowVisible":@(visible)},[root stringByAppendingPathComponent:@"host-attached"]);});}
  }
  if(linkMode&&!coverRemoved&&[NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"first-native-frame"]]){[cover removeFromSuperview];[CATransaction flush];coverRemoved=YES;}
  if(!task.running){guestReport=readJSON([root stringByAppendingPathComponent:@"guest-result.json"]);finished=YES;[t invalidate];stopLoop();}
 }];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,14*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!finished){[task terminate];[window orderOut:nil];_exit(14);}});
 [NSApp run];[timer invalidate];[task waitUntilExit];NSUInteger hostWindows=NSApp.windows.count;BOOL passed=(!linkMode||coverRemoved)&&hostWindows==1&&attached&&visible&&installedID==[guestReport[@"contextId"]unsignedIntValue]&&[guestReport[@"passed"]boolValue]&&task.terminationStatus==0;
 host.contextId=0;[window orderOut:nil];view.layer=nil;[window close];
 emit(@{@"passed":@(passed),@"hostPID":@(getpid()),@"hostOnlyWindowCount":@(hostWindows),@"hostWindowWasVisible":@(visible),@"nativeDisplayLinkMode":@(linkMode),@"initialLoadingCoverOpacity":@(linkMode?coverOpacity:0),@"loadingCoverRemovedAfterFirstFrameObserver":@(coverRemoved),@"hostUsedCALayerHost":@([host isKindOfClass:hostClass]),@"hostCreatedMetalDevice":@NO,@"attachedRemoteContextId":@(installedID),@"guest":guestReport?:@{},@"guestExitStatus":@(task.terminationStatus),@"privateSystemAPIPrototype":@YES,@"screenCaptureReadbackOrInputUsed":@NO,@"explicitImageCopiesOrPerFrameAppIPC":@NO});return passed?0:5;
}}
