// SPDX-License-Identifier: GPL-3.0-only
// Actual production Mach control server, fake view geometry; no window, GPU, screenshot or input.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "ReadyHostedView.m"
static unsigned checks,callbackCount;static BOOL callbackMain,stopAtCallback;
#define CHECK(v) do{checks++;if(!(v)){fprintf(stderr,"remote-control assertion:%u line:%d\n",checks,__LINE__);return 70;}}while(0)
@interface ControlScreen:NSObject
@property(nonatomic)NSRect frame;
@end
@implementation ControlScreen @end
static id fakeScreens(id object,SEL selector){ControlScreen*s=[ControlScreen new];s.frame=NSMakeRect(0,0,100,100);return @[s];}
@interface ControlWindow:NSObject
@property(nonatomic,strong)ControlScreen*screen;
@property(nonatomic)CGFloat backingScaleFactor;
@property(nonatomic,strong)NSView*contentView;
@end
@implementation ControlWindow
-(NSInteger)windowNumber{return 42;}
-(BOOL)isVisible{return YES;}
-(BOOL)isKeyWindow{return NO;}
-(BOOL)isOnActiveSpace{return YES;}
-(NSWindowOcclusionState)occlusionState{return NSWindowOcclusionStateVisible;}
-(NSRect)convertRectToScreen:(NSRect)rect{return rect;}
@end
@interface ControlLayer:CALayer
@property(nonatomic)uint32_t contextId;
@end
@implementation ControlLayer @end
@interface ControlHost:RHGHost @end
@implementation ControlHost
-(BOOL)foregroundEligible{return NO;}
@end
static void firstFrame(void*context){RHGHost*host=(__bridge RHGHost*)context;callbackCount++;callbackMain=NSThread.isMainThread;if(stopAtCallback)[host shutdown];}
typedef struct{_Atomic bool done;RHGReplyReceive received;kern_return_t status;mach_port_t port;}ControlReply;
static uint64_t requestNumber;
static ControlReply*exchange(RHGHost*host,RHGRequest request,BOOL badNonce){
 ControlReply*box=calloc(1,sizeof*box);atomic_init(&box->done,false);if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&box->port))_exit(80);
 request.h=(mach_msg_header_t){.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE),.msgh_size=sizeof request,.msgh_remote_port=host.port,.msgh_local_port=box->port};request.magic=RHG_MAGIC;request.version=RHG_VERSION;request.requestID=++requestNumber;memcpy(request.nonce,host->nonce,RHG_NONCE_BYTES);if(badNonce)request.nonce[0]^=1;
 if(mach_msg(&request.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof request,0,MACH_PORT_NULL,1000,MACH_PORT_NULL))_exit(81);
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{box->status=mach_msg(&box->received.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof box->received,box->port,4000,MACH_PORT_NULL);atomic_store(&box->done,true);});return box;
}
static BOOL pump(BOOL(^condition)(void)){double end=CACurrentMediaTime()+5;while(!condition()&&CACurrentMediaTime()<end)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];return condition();}
static BOOL answered(ControlReply*reply){return pump(^BOOL{return atomic_load(&reply->done);})&&reply->status==KERN_SUCCESS;}
static void dispose(ControlReply*reply){if(reply->received.message.h.msgh_bits&MACH_MSGH_BITS_COMPLEX)mach_msg_destroy(&reply->received.message.h);mach_port_destroy(mach_task_self(),reply->port);free(reply);}
#define STATUS(req,bad,wanted) do{ControlReply*r=exchange(host,(req),(bad));CHECK(answered(r));CHECK(r->received.message.status==(wanted));CHECK(!(r->received.message.h.msgh_bits&MACH_MSGH_BITS_COMPLEX));dispose(r);}while(0)
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 64;alarm(15);NSString*mode=@(argv[1]);BOOL surface=[mode isEqual:@"surface"],stop=[mode isEqual:@"stop"],trace=[mode isEqual:@"trace"];
 NSString*tracePath=trace?[NSTemporaryDirectory() stringByAppendingPathComponent:[@"remote-control-trace-" stringByAppendingString:NSUUID.UUID.UUIDString]]:nil;
 method_setImplementation(class_getClassMethod(NSScreen.class,@selector(screens)),(IMP)fakeScreens);[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 ControlHost*host=[ControlHost new];if(trace){host.diagnosticFD=open(tracePath.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);CHECK(host.diagnosticFD>=0&&host.remoteTraceEnabled);}host.remoteMode=YES;host.remoteDeviceRegistryID=1;host.remotePixelFormat=MTLPixelFormatBGRA8Unorm;host.pipelineDepth=surface?2:0;
 ControlWindow*window=[ControlWindow new];window.backingScaleFactor=2;window.screen=[ControlScreen new];window.screen.frame=NSMakeRect(0,0,100,100);host.window=(NSWindow*)window;
 host.view=[[RHGView alloc]initWithFrame:NSMakeRect(0,0,50,25)];host.view.owner=host;ControlLayer*layer=[ControlLayer new];host.remoteLayer=(id)layer;
 CHECK(RHGRemoteGeometry(host,YES));CHECK(host.remoteWidth==200&&host.remoteHeight==200);RHGHostResize((__bridge RHGHostRef)host);CHECK(host.remoteWidth==100&&host.remoteHeight==50);CHECK(NSEqualRects(layer.frame,host.view.bounds));
 window.screen.frame=NSMakeRect(0,0,10000,10000);CHECK(!RHGRemoteGeometry(host,YES));CHECK(host.remoteWidth==100&&host.remoteHeight==50);window.screen.frame=NSMakeRect(0,0,100,100);
 host.remoteMode=!surface;CHECK(RHGHostCreateRemote(NULL,1,"unused","unused")==NULL);CHECK(RHGHostCreateRemote((__bridge void*)window,0,"unused","unused")==NULL);
 char exe[PROC_PIDPATHINFO_MAXSIZE]={0};CHECK(proc_pidpath(getpid(),exe,sizeof exe)>0);host.expectedExecutable=@(exe);NSString*expected=host.expectedExecutable;memset(host->nonce,0xb2,RHG_NONCE_BYTES);
 mach_port_t server=MACH_PORT_NULL;CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&server)==KERN_SUCCESS);CHECK(mach_port_insert_right(mach_task_self(),server,server,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS);host.port=server;
 dispatch_group_t serving=dispatch_group_create();dispatch_group_async(serving,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{RHGServe(host);});
 RHGRequest hello={.op=RHG_HELLO,.reserved=surface?RHG_TRANSPORT_SURFACE:RHG_TRANSPORT_REMOTE_LAYER,.framesInFlight=surface?2:0};
 if(!surface){
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123}),NO,RHG_REJECTED);CHECK(host.guestPID==0);
  STATUS(((RHGRequest){.op=RHG_HELLO,.reserved=RHG_TRANSPORT_SURFACE,.framesInFlight=2}),NO,RHG_REJECTED);CHECK(host.guestPID==0&&!host.renderNegotiated);
  STATUS(hello,YES,RHG_REJECTED);CHECK(host.guestPID==0);
  RHGRequest wrongDepth=hello;wrongDepth.framesInFlight=1;STATUS(wrongDepth,NO,RHG_REJECTED);CHECK(host.guestPID==0);
  host.expectedExecutable=@"/nonexistent/own-executable";STATUS(hello,NO,RHG_REJECTED);CHECK(host.guestPID==0);host.expectedExecutable=expected;
 }
 STATUS(hello,NO,RHG_OK);CHECK(host.guestPID==getpid()&&host.guestBirthSeconds&&host.renderNegotiated);
 if(surface){STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123}),NO,RHG_REJECTED);CHECK(layer.contextId==0&&!host.remoteContextID);}
 else{
  CHECK(host.pipelineDepth==0&&host.metal==nil&&host.device==nil&&host.slots.count==0);
  for(unsigned op=RHG_CONFIGURE;op<=RHG_PRESENT;op++){STATUS(((RHGRequest){.op=op}),NO,RHG_UNSUPPORTED);CHECK(!host.acquirePending&&host.slots.count==0);}
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH}),NO,RHG_REJECTED);
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123,.width=8193,.height=1}),NO,RHG_REJECTED);
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123,.width=8192,.height=8192}),NO,RHG_REJECTED);
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123,.width=10}),NO,RHG_REJECTED);
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123,.deviceRegistryID=2}),NO,RHG_REJECTED);
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123,.pixelFormat=UINT32_MAX}),NO,RHG_REJECTED);CHECK(layer.contextId==0);
  host.guestBirthSeconds++;STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123}),NO,RHG_REJECTED);host.guestBirthSeconds--;
  host.expectedExecutable=@"/nonexistent/changed-executable";STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123}),NO,RHG_REJECTED);host.expectedExecutable=expected;
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123,.width=10,.height=20,.pixelFormat=MTLPixelFormatBGRA8Unorm,.deviceRegistryID=1}),NO,RHG_OK);CHECK(layer.contextId==123&&host.remoteContextID==123&&host.remoteWidth==10&&host.remoteHeight==20);
  if(trace){CHECK(host.remoteTraceRows==1);[host traceRemoteStartup:@"too-soon"];CHECK(host.remoteTraceRows==1);for(unsigned i=0;i<10;i++){host.remoteTraceLastAt=0;[host traceRemoteStartup:@"poll"]; }CHECK(host.remoteTraceRows==8);}
  STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=123}),NO,RHG_REJECTED);STATUS(((RHGRequest){.op=RHG_REMOTE_ATTACH,.surfaceID=456}),NO,RHG_REJECTED);CHECK(layer.contextId==123);
  STATUS(((RHGRequest){.op=RHG_REMOTE_FIRST_FRAME,.surfaceID=456}),NO,RHG_REJECTED);CHECK(!host.firstFrameAnnounced);
  STATUS(((RHGRequest){.op=RHG_REMOTE_FIRST_FRAME,.surfaceID=123,.width=9000,.height=1}),NO,RHG_REJECTED);CHECK(!host.firstFrameAnnounced);
  RHGHostSetFirstFrameCallback((__bridge RHGHostRef)host,(__bridge void*)host,firstFrame);stopAtCallback=stop;
  STATUS(((RHGRequest){.op=RHG_REMOTE_FIRST_FRAME,.surfaceID=123}),NO,stop?RHG_STOPPED:RHG_OK);CHECK(callbackCount==1&&callbackMain&&host.firstFrameAnnounced);if(trace){unsigned before=host.remoteTraceRows;host.remoteTraceLastAt=0;[host traceRemoteStartup:@"after-ready"];CHECK(host.remoteTraceRows==before); }
  if(!stop){STATUS(((RHGRequest){.op=RHG_REMOTE_FIRST_FRAME,.surfaceID=123}),NO,RHG_REJECTED);CHECK(callbackCount==1);STATUS(((RHGRequest){.op=RHG_POLL}),NO,RHG_OK);CHECK(host.frames==0&&host.acquires==0&&host.slots.count==0);}
 }
 [host shutdown];CHECK(layer.contextId==0&&host.remoteContextID==0);CHECK(pump(^BOOL{return dispatch_group_wait(serving,DISPATCH_TIME_NOW)==0;}));CHECK(NSApp.windows.count==0);
 if(trace){dispatch_sync(host.diagnosticQueue,^{});NSString*journal=[NSString stringWithContentsOfFile:tracePath encoding:NSUTF8StringEncoding error:nil];unsigned rows=0;for(NSString*line in [journal componentsSeparatedByString:@"\n"]){NSData*data=[line dataUsingEncoding:NSUTF8StringEncoding];NSDictionary*entry=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![entry[@"phase"]isEqual:@"remote-startup-trace"])continue;rows++;NSDictionary*fields=entry[@"startup"];CHECK(fields!=nil&&!fields[@"exceptionName"]);CHECK(fields[@"remoteContextMatches"]!=nil&&[fields[@"remoteContextMatches"]boolValue]);CHECK(fields[@"viewLayerIsRemoteLayer"]!=nil&&![fields[@"viewLayerIsRemoteLayer"]boolValue]);CHECK(fields[@"frontmostIsHost"]!=nil&&fields[@"frontmostIsAttestedGuest"]!=nil);CHECK(entry[@"remoteContextID"]==nil&&fields[@"frontmostPID"]==nil&&fields[@"frontmostName"]==nil);CHECK([fields[@"remoteLayerAncestors"]count]<=6&&[fields[@"directSubviews"]count]<=8);}CHECK(rows==8);[NSFileManager.defaultManager removeItemAtPath:tracePath error:nil]; }
 printf("{\"passed\":true,\"checks\":%u,\"mode\":\"%s\",\"realProductionMachServer\":true,\"GPUWindowCaptureInputGameUsed\":false}\n",checks,argv[1]);return 0;
}}
