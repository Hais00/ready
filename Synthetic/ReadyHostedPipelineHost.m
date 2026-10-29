// SPDX-License-Identifier: GPL-3.0-only
#import "ReadyHostedView.m"
#import <objc/runtime.h>
static RHGHost *pipeObserved;
static IMP pipeOriginalPresent;
static NSMutableArray *pipePresents;
static NSString *pipeRoot;
static unsigned pipeMaximumSlots;
static BOOL pipeCallbackStopped;
static void pipeStopFirstFrame(void*context){pipeCallbackStopped=YES;RHGHostStop((RHGHostRef)context);}
static void pipeState(void){
 pipeMaximumSlots=MAX(pipeMaximumSlots,(unsigned)pipeObserved.slots.count);
 NSDictionary*v=@{@"slots":@(pipeObserved.slots.count),@"maxSlots":@(pipeMaximumSlots),@"generation":@(pipeObserved.configurationGeneration),@"acquires":@(pipeObserved.acquires),@"presents":[pipePresents copy]};NSData*d=[NSJSONSerialization dataWithJSONObject:v options:0 error:nil];[d writeToFile:[pipeRoot stringByAppendingPathComponent:@"state.json"] atomically:YES];
}
static void pipePresent(id<CAMetalDrawable>drawable,SEL selector){
 RHGRenderSlot*slot=pipeObserved.slots.firstObject;IOSurfaceRef surface=drawable.texture.iosurface;uint8_t pixel[4]={0};if(surface&&IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL)==kIOReturnSuccess){void*bytes=IOSurfaceGetBaseAddress(surface);if(bytes)memcpy(pixel,bytes,4);IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);}
 [pipePresents addObject:@{@"frame":@(slot.frameID),@"generation":@(slot.generation),@"surface":@(slot.surfaceID),@"pixel":@[@(pixel[0]),@(pixel[1]),@(pixel[2]),@(pixel[3])]}];((void(*)(id,SEL))pipeOriginalPresent)(drawable,selector);pipeState();
}
static IMP pipeOriginalNext;
static id pipeNext(CAMetalLayer*layer,SEL selector){id drawable=((id(*)(id,SEL))pipeOriginalNext)(layer,selector);if(layer==pipeObserved.metal&&drawable&&!pipeOriginalPresent){Method m=class_getInstanceMethod(object_getClass(drawable),@selector(present));pipeOriginalPresent=method_setImplementation(m,(IMP)pipePresent);}return drawable;}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=5)return 64;alarm(35);NSString*guest=[NSString stringWithUTF8String:argv[1]];pipeRoot=[NSString stringWithUTF8String:argv[2]];BOOL stop=!strcmp(argv[4],"stop");
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 NSWindow*window=[[NSWindow alloc]initWithContentRect:NSMakeRect(-2000,-2000,32,32) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];[window setReleasedWhenClosed:NO];[window orderBack:nil];
 RHGHostRef ref=RHGHostCreate((__bridge void*)window,false,guest.fileSystemRepresentation,[[pipeRoot stringByAppendingPathComponent:@"host.jsonl"]fileSystemRepresentation]);if(!ref)return 65;pipeObserved=(__bridge RHGHost*)ref;pipePresents=[NSMutableArray new];window.contentView=pipeObserved.view;
 if(!strcmp(argv[4],"callback-stop"))RHGHostSetFirstFrameCallback(ref,ref,pipeStopFirstFrame);
 Method next=class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable));pipeOriginalNext=method_setImplementation(next,(IMP)pipeNext);
 NSTask*task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:guest];task.arguments=@[pipeRoot,[NSString stringWithUTF8String:argv[4]]];task.currentDirectoryURL=[NSURL fileURLWithPath:pipeRoot];NSMutableDictionary*env=[NSProcessInfo.processInfo.environment mutableCopy];env[@"READY_HOSTED_GAME_SERVICE"]=pipeObserved.service;env[@"READY_HOSTED_GAME_NONCE"]=pipeObserved.nonceString;env[@"READY_HOSTED_FRAMES_IN_FLIGHT"]=[NSString stringWithUTF8String:argv[3]];env[@"MTL_HUD_ENABLED"]=@"0";env[@"RHG_PERF_PROFILE"]=@"0";task.environment=env;
 NSPipe*out=[NSPipe pipe],*error=[NSPipe pipe];task.standardOutput=out;task.standardError=error;NSError*failure=nil;if(![task launchAndReturnError:&failure])return 66;BOOL violation=NO,stopped=NO;double end=CACurrentMediaTime()+25;
 while(task.running&&CACurrentMediaTime()<end){@autoreleasepool{
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];pipeState();
  if(NSApp.isActive||window.isKeyWindow){violation=YES;[task terminate];break;}
  if(stop&&!stopped&&[[NSFileManager defaultManager]fileExistsAtPath:[pipeRoot stringByAppendingPathComponent:@"stop-ready"]]){stopped=YES;RHGHostStop(ref);}
 }}
 if(task.running){[task terminate];return 67;}[task waitUntilExit];
 NSData*o=[out.fileHandleForReading readDataToEndOfFile],*e=[error.fileHandleForReading readDataToEndOfFile];[o writeToFile:[pipeRoot stringByAppendingPathComponent:@"guest.json"] atomically:YES];[e writeToFile:[pipeRoot stringByAppendingPathComponent:@"guest.stderr"] atomically:YES];
 RHGHostStop(ref);double drain=CACurrentMediaTime()+.4;while(CACurrentMediaTime()<drain)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
 NSDictionary*result=@{@"guestExit":@(task.terminationStatus),@"focusViolation":@(violation),@"maximumSlots":@(pipeMaximumSlots),@"presentations":pipePresents,@"remainingSlots":@(pipeObserved.slots.count),@"hostQueues":@0,@"hostCommandBuffers":@0,@"hostEncoders":@0,@"hostCopies":@0,@"testOnlyCPUReadbacks":@(pipePresents.count),@"stopDuringPendingGPU":@(stopped),@"stoppedFromFirstFrameCallback":@(pipeCallbackStopped),@"gameOrAccountUsed":@NO};[[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]writeToFile:[pipeRoot stringByAppendingPathComponent:@"report.json"] atomically:YES];RHGHostDestroy(ref);pipeObserved=nil;[window orderOut:nil];[window close];return 0;
}}
