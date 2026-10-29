// SPDX-License-Identifier: GPL-3.0-only
// Own unactivated offscreen transport fixture. No Steam/game/account operations.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <sys/resource.h>
#import <unistd.h>
#import "ReadyHostedView.h"
static CAMetalLayer *observedLayer;
static IMP originalNext,originalPresent;
static char acquiredFrameKey;
static NSMutableArray *acquisitions,*presentations,*censuses;
static uint32_t hostWindow;
static double began;
@interface LoadingFixture:NSObject
@property(strong)NSView *overlay;
@property NSUInteger calls;
@property(strong)NSMutableArray *records;
@end
@implementation LoadingFixture @end
static void firstFrame(void *context){
 LoadingFixture*state=(__bridge LoadingFixture*)context;state.calls++;
 NSDictionary*present=presentations.lastObject;
 NSMutableDictionary*record=[@{@"calls":@(state.calls),@"mainThread":@(NSThread.isMainThread),@"acquisitionsAlreadyObserved":@(acquisitions.count),@"presentCallsAlreadyObserved":@(presentations.count),@"layerPresentsWithTransaction":@(observedLayer.presentsWithTransaction),@"loadingHadSuperview":@((BOOL)(state.overlay.superview!=nil)),@"loadingLayerIsMetal":@([state.overlay.layer isKindOfClass:CAMetalLayer.class]),@"surfaceID":present[@"surfaceID"]?:@0,@"frame":present[@"frame"]?:@(-1),@"elapsedSeconds":@(CACurrentMediaTime()-began)}mutableCopy];
 // Only exchange the existing UI view tree. No GPU wait, queue or pixel access.
 [state.overlay removeFromSuperview];record[@"loadingRemoved"]=@((BOOL)(state.overlay.superview==nil&&state.overlay.layer.superlayer==nil));[state.records addObject:record];
}
static NSDictionary *usage(void){struct rusage r;getrusage(RUSAGE_SELF,&r);return @{@"CPUSeconds":@(r.ru_utime.tv_sec+r.ru_utime.tv_usec/1e6+r.ru_stime.tv_sec+r.ru_stime.tv_usec/1e6),@"maxResidentBytes":@(r.ru_maxrss)};}
static NSDictionary *census(pid_t guest){NSArray*all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));NSMutableArray*h=[NSMutableArray new],*g=[NSMutableArray new];for(NSDictionary*w in all){int pid=[w[(id)kCGWindowOwnerPID]intValue];if(pid!=getpid()&&pid!=guest)continue;NSDictionary*v=@{@"id":w[(id)kCGWindowNumber],@"onscreen":w[(id)kCGWindowIsOnscreen]?:@NO,@"bounds":w[(id)kCGWindowBounds]?:@{}};[(pid==getpid()?h:g)addObject:v];}return @{@"queryAvailable":@(all!=nil),@"hostWindows":h,@"guestWindows":g,@"hostIsActive":@(NSApp.isActive),@"elapsedSeconds":@(CACurrentMediaTime()-began)};}
static void recordPresent(id self,SEL selector){NSDictionary*frame=objc_getAssociatedObject(self,&acquiredFrameKey);double start=CACurrentMediaTime();((void(*)(id,SEL))originalPresent)(self,selector);if(frame){NSMutableDictionary*v=[frame mutableCopy];v[@"callMilliseconds"]=@((CACurrentMediaTime()-start)*1000);v[@"presentsWithTransaction"]=@(observedLayer.presentsWithTransaction);[presentations addObject:v];}}
static id nextDrawable(CAMetalLayer*self,SEL selector){double start=CACurrentMediaTime();id<CAMetalDrawable>drawable=((id(*)(id,SEL))originalNext)(self,selector);if(self!=observedLayer)return drawable;IOSurfaceRef surface=drawable.texture.iosurface;NSDictionary*entry=@{@"frame":@(acquisitions.count),@"surfaceID":@(surface?IOSurfaceGetID(surface):0),@"drawableID":@(drawable?drawable.drawableID:0),@"width":@(drawable.texture.width),@"height":@(drawable.texture.height),@"callMilliseconds":@((CACurrentMediaTime()-start)*1000),@"window":@(hostWindow)};[acquisitions addObject:entry];if(drawable){objc_setAssociatedObject(drawable,&acquiredFrameKey,entry,OBJC_ASSOCIATION_RETAIN_NONATOMIC);if(!originalPresent){Method m=class_getInstanceMethod([drawable class],@selector(present));originalPresent=method_setImplementation(m,(IMP)recordPresent);}}return drawable;}
@interface TransportOffscreenWindow:NSWindow @end
@implementation TransportOffscreenWindow
-(NSRect)constrainFrameRect:(NSRect)rect toScreen:(NSScreen*)screen{(void)screen;return rect;}
@end
static void pump(void){@autoreleasepool{CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.001,false);for(unsigned n=0;n<16;n++){NSEvent*e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];if(!e)break;[NSApp sendEvent:e];}[NSApp updateWindows];}}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=6)return 64;alarm(65);NSString*guest=[NSString stringWithUTF8String:argv[1]],*shim=[NSString stringWithUTF8String:argv[2]],*root=[NSString stringWithUTF8String:argv[3]];BOOL hud=atoi(argv[4])!=0;int frames=atoi(argv[5]);if(frames<1||frames>600)return 64;
 began=CACurrentMediaTime();NSDictionary*cpuBefore=usage();acquisitions=[NSMutableArray new];presentations=[NSMutableArray new];censuses=[NSMutableArray new];
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
 NSWindow*window=[[TransportOffscreenWindow alloc]initWithContentRect:NSMakeRect(-8192,-8192,640,360) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];window.releasedWhenClosed=NO;window.title=@"Ready Hosted Transport — OFFSCREEN FIXTURE";
 NSString*diagnostic=[root stringByAppendingPathComponent:@"host-diagnostic.jsonl"];
 RHGHostRef host=RHGHostCreate((__bridge void*)window,hud,guest.fileSystemRepresentation,diagnostic.fileSystemRepresentation);if(!host)return 65;
 NSView*view=(__bridge NSView*)RHGHostGetView(host);observedLayer=(CAMetalLayer*)view.layer;hostWindow=RHGHostWindowNumber(host);
 NSView*container=[[NSView alloc]initWithFrame:NSMakeRect(0,0,640,360)];container.wantsLayer=YES;window.contentView=container;view.frame=container.bounds;[container addSubview:view];
 LoadingFixture*loading=[LoadingFixture new];loading.records=[NSMutableArray new];loading.overlay=[[NSView alloc]initWithFrame:container.bounds];loading.overlay.wantsLayer=YES;loading.overlay.layer.backgroundColor=NSColor.darkGrayColor.CGColor;[container addSubview:loading.overlay positioned:NSWindowAbove relativeTo:view];
 BOOL loadingInitiallyAbove=container.subviews.lastObject==loading.overlay&&!loading.overlay.hidden;
 RHGHostSetFirstFrameCallback(host,(__bridge void*)loading,firstFrame);
 Method next=class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable));originalNext=method_setImplementation(next,(IMP)nextDrawable);
 [window setFrameOrigin:NSMakePoint(-8192,-8192)];[window orderBack:nil];
 NSTask*task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:guest];task.arguments=@[[NSString stringWithFormat:@"%d",frames]];task.currentDirectoryURL=[NSURL fileURLWithPath:root];
 NSMutableDictionary*environment=[NSMutableDictionary new];NSDictionary*inherited=NSProcessInfo.processInfo.environment;for(NSString*key in @[@"HOME",@"USER",@"LOGNAME",@"PATH",@"TMPDIR",@"LANG",@"LC_ALL"]){if(inherited[key])environment[key]=inherited[key];}
 environment[@"DYLD_INSERT_LIBRARIES"]=shim;environment[@"READY_HOSTED_GAME_SERVICE"]=[NSString stringWithUTF8String:RHGHostService(host)];environment[@"READY_HOSTED_GAME_NONCE"]=[NSString stringWithUTF8String:RHGHostNonce(host)];environment[@"MTL_HUD_ENABLED"]=@"0";environment[@"MTL_HUD_LOG_ENABLED"]=@"0";task.environment=environment;
 NSString*outPath=[root stringByAppendingPathComponent:@"guest-stdout.jsonl"],*errPath=[root stringByAppendingPathComponent:@"guest-stderr.jsonl"];
 [[NSFileManager defaultManager]createFileAtPath:outPath contents:nil attributes:@{NSFilePosixPermissions:@0600}];[[NSFileManager defaultManager]createFileAtPath:errPath contents:nil attributes:@{NSFilePosixPermissions:@0600}];NSFileHandle*out=[NSFileHandle fileHandleForWritingAtPath:outPath],*err=[NSFileHandle fileHandleForWritingAtPath:errPath];task.standardOutput=out;task.standardError=err;task.standardInput=[NSFileHandle fileHandleWithNullDevice];
 NSError*error=nil;BOOL launched=[task launchAndReturnError:&error];if(!launched){RHGHostDestroy(host);[window close];return 66;}
 pid_t child=task.processIdentifier;double deadline=CACurrentMediaTime()+45,nextCensus=0;BOOL timedOut=NO,focusViolation=NO;
 while(task.running){pump();double now=CACurrentMediaTime();if(RHGHostGuestPID(host)&&now>=nextCensus){[censuses addObject:census(child)];nextCensus=now+0.2;}if(NSApp.isActive||window.isKeyWindow){focusViolation=YES;[task terminate];}if(now>deadline){timedOut=YES;[task terminate];break;}}
 if(task.running){double stop=CACurrentMediaTime()+2;while(task.running&&CACurrentMediaTime()<stop)pump();}
 if(task.running){RHGHostStop(host);return 67;}
 [task waitUntilExit];[out closeFile];[err closeFile];int status=task.terminationStatus;
 [censuses addObject:census(child)];RHGHostStop(host);double finish=CACurrentMediaTime()+0.1;while(CACurrentMediaTime()<finish)pump();RHGHostDestroy(host);observedLayer=nil;[window orderOut:nil];[window close];
 NSDictionary*cpuAfter=usage();NSDictionary*report=@{@"schema":@1,@"fixtureOnly":@YES,@"guestExit":@(status),@"guestTerminationReason":@(task.terminationReason),@"framesRequested":@(frames),@"hudRequested":@(hud),@"hostWindow":@(hostWindow),@"focusViolation":@(focusViolation),@"timedOut":@(timedOut),@"elapsedSeconds":@(CACurrentMediaTime()-began),@"CPUSeconds":@([cpuAfter[@"CPUSeconds"]doubleValue]-[cpuBefore[@"CPUSeconds"]doubleValue]),@"maxResidentBytes":cpuAfter[@"maxResidentBytes"],@"acquisitions":acquisitions,@"presentations":presentations,@"censuses":censuses,@"pixelReadbacks":@0,@"harnessCommandQueues":@0,@"harnessCommandBuffers":@0,@"hostDiagnostic":diagnostic,@"loadingInitiallyAbove":@(loadingInitiallyAbove),@"firstFrameCallbackCount":@(loading.calls),@"firstFrameCallbacks":loading.records,@"loadingStillAttached":@((BOOL)(loading.overlay.superview!=nil)),@"onGlassVerified":@NO,@"gameOrAccountExecuted":@NO,@"HUDVisualVerified":@NO};
 NSData*data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];[data writeToFile:[root stringByAppendingPathComponent:@"harness-report.json"]atomically:NO];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return status==0&&!timedOut&&!focusViolation?0:1;
}}
