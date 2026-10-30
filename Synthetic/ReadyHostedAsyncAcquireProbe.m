// SPDX-License-Identifier: GPL-3.0-only
// Real production Mach server and IOSurface send rights; no Metal device/window.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <stdatomic.h>
static _Atomic mach_port_t fixtureSurfacePort;
static _Atomic kern_return_t fixtureReplyResult;
static _Atomic bool fixtureForceReplyFailure;
static mach_port_t fixtureCreateSurfacePort(IOSurfaceRef surface);
static mach_msg_return_t fixtureMachMessage(mach_msg_header_t*,mach_msg_option_t,mach_msg_size_t,mach_msg_size_t,mach_port_name_t,mach_msg_timeout_t,mach_port_name_t);
#define IOSurfaceCreateMachPort fixtureCreateSurfacePort
#define mach_msg fixtureMachMessage
#import "ReadyHostedView.m"
#undef IOSurfaceCreateMachPort
#undef mach_msg
static mach_port_t fixtureCreateSurfacePort(IOSurfaceRef surface){mach_port_t port=IOSurfaceCreateMachPort(surface);atomic_store(&fixtureSurfacePort,port);return port;}
static mach_msg_return_t fixtureMachMessage(mach_msg_header_t*message,mach_msg_option_t options,mach_msg_size_t send,mach_msg_size_t receive,mach_port_name_t port,mach_msg_timeout_t timeout,mach_port_name_t notify){
 BOOL reply=(options&MACH_SEND_MSG)&&send==sizeof(RHGReply);kern_return_t result=reply&&atomic_load(&fixtureForceReplyFailure)?MACH_SEND_INVALID_DEST:mach_msg(message,options,send,receive,port,timeout,notify);if(reply)atomic_store(&fixtureReplyResult,result);return result;
}
static unsigned checks;
static _Atomic bool fixtureDrained;
#define REQUIRE(v) do{checks++;if(!(v)){fprintf(stderr,"async-acquire assertion:%u line:%d\n",checks,__LINE__);return 70;}}while(0)
@interface AsyncScreen:NSObject @end
@implementation AsyncScreen
-(NSRect)frame{return NSMakeRect(0,0,100,100);}
@end
static id fixtureScreens(id object,SEL selector){(void)object;(void)selector;return @[[AsyncScreen new]];}
@interface AsyncDevice:NSObject @end
@implementation AsyncDevice
-(uint64_t)registryID{return 1;}
@end
@interface AsyncTexture:NSObject
@property(nonatomic,assign)IOSurfaceRef owned;
@end
@implementation AsyncTexture
-(void)setOwned:(IOSurfaceRef)value{if(value)CFRetain(value);if(_owned)CFRelease(_owned);_owned=value;}
-(IOSurfaceRef)iosurface{return _owned;}
-(void)dealloc{if(_owned)CFRelease(_owned);}
@end
@interface AsyncDrawable:NSObject
@property(nonatomic,strong)AsyncTexture*texture;
@property(nonatomic)unsigned presents;
@property(nonatomic)BOOL presentOnMain;
@end
@implementation AsyncDrawable
-(void)present{self.presents++;self.presentOnMain=NSThread.isMainThread;}
@end
@interface AsyncLayer:NSObject
@property(nonatomic)CGSize drawableSize;
@property(nonatomic)MTLPixelFormat pixelFormat;
@property(nonatomic)BOOL displaySyncEnabled;
@property(nonatomic,copy)NSDictionary*developerHUDProperties;
@property(nonatomic,strong)AsyncDrawable*next;
@property(nonatomic,strong)dispatch_semaphore_t entered,gate;
@property(nonatomic)BOOL returnNil,throwOnAcquire;
@property(atomic)BOOL acquiredOnMain;
@end
@implementation AsyncLayer
-(id<CAMetalDrawable>)nextDrawable{self.acquiredOnMain=NSThread.isMainThread;dispatch_semaphore_signal(self.entered);if(dispatch_semaphore_wait(self.gate,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)))return nil;if(self.throwOnAcquire)@throw [NSException exceptionWithName:@"OwnAcquireFailure" reason:nil userInfo:nil];return self.returnNil?nil:(id<CAMetalDrawable>)self.next;}
@end
@interface AsyncHost:RHGHost @end
@implementation AsyncHost
-(BOOL)foregroundEligible{return NO;}
@end
typedef struct{_Atomic bool done;RHGReplyReceive received;kern_return_t status;mach_port_t port;}AsyncReply;
static _Atomic uint64_t fixtureRequest;
static AsyncReply*sendRequest(RHGHost*host,RHGRequest fields,BOOL receive){
 AsyncReply*box=calloc(1,sizeof*box);atomic_init(&box->done,false);if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&box->port))_exit(80);
 fields.h=(mach_msg_header_t){.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE),.msgh_size=sizeof fields,.msgh_remote_port=host.port,.msgh_local_port=box->port};fields.magic=RHG_MAGIC;fields.version=RHG_VERSION;fields.requestID=atomic_fetch_add(&fixtureRequest,1)+1;memcpy(fields.nonce,host->nonce,RHG_NONCE_BYTES);
 if(mach_msg(&fields.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof fields,0,MACH_PORT_NULL,1000,MACH_PORT_NULL))_exit(81);
 if(receive)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{box->status=mach_msg(&box->received.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof box->received,box->port,5000,MACH_PORT_NULL);atomic_store(&box->done,true);});return box;
}
static BOOL pump(BOOL(^condition)(void)){double end=CACurrentMediaTime()+4;while(!condition()&&CACurrentMediaTime()<end)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];return condition();}
static BOOL answered(AsyncReply*reply){return pump(^BOOL{return atomic_load(&reply->done);})&&reply->status==KERN_SUCCESS;}
static void disposeReply(AsyncReply*reply){if(reply->received.message.h.msgh_bits&MACH_MSGH_BITS_COMPLEX)mach_msg_destroy(&reply->received.message.h);if(reply->port)mach_port_destroy(mach_task_self(),reply->port);free(reply);}
static BOOL noRight(mach_port_t port){mach_port_type_t type=0;return mach_port_type(mach_task_self(),port,&type)!=KERN_SUCCESS;}
static AsyncDrawable*drawable(void){AsyncTexture*texture=[AsyncTexture new];IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth:@8,(id)kIOSurfaceHeight:@8,(id)kIOSurfaceBytesPerElement:@4});if(!surface)_exit(82);texture.owned=surface;CFRelease(surface);AsyncDrawable*value=[AsyncDrawable new];value.texture=texture;return value;}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 64;alarm(12);method_setImplementation(class_getClassMethod(NSScreen.class,@selector(screens)),(IMP)fixtureScreens);[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];NSString*mode=[NSString stringWithUTF8String:argv[1]];
 AsyncHost*host=[AsyncHost new];host.view=[[RHGView alloc]initWithFrame:NSMakeRect(0,0,8,8)];host.view.owner=host;host.device=(id<MTLDevice>)[AsyncDevice new];host.configured=YES;host.firstFrameAnnounced=YES;host.pipelineDepth=2;host.configurationGeneration=1;host.frameID=11;
 char executable[PROC_PIDPATHINFO_MAXSIZE]={0};REQUIRE(proc_pidpath(getpid(),executable,sizeof executable)>0);host.expectedExecutable=[NSString stringWithUTF8String:executable];memset(host->nonce,0xa1,RHG_NONCE_BYTES);
 AsyncLayer*layer=[AsyncLayer new];layer.drawableSize=CGSizeMake(8,8);layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.next=drawable();layer.entered=dispatch_semaphore_create(0);layer.gate=dispatch_semaphore_create(0);host.metal=(CAMetalLayer*)layer;__weak AsyncLayer*weakLayer=layer;dispatch_semaphore_t acquireGate=layer.gate;
 mach_port_t server=MACH_PORT_NULL;REQUIRE(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&server)==KERN_SUCCESS);REQUIRE(mach_port_insert_right(mach_task_self(),server,server,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS);host.port=server;
 dispatch_group_t serving=dispatch_group_create();dispatch_group_async(serving,dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{RHGServe(host);});
 AsyncReply*hello=sendRequest(host,(RHGRequest){.op=RHG_HELLO,.framesInFlight=2},YES);REQUIRE(answered(hello)&&hello->received.message.status==RHG_OK);disposeReply(hello);
 AsyncDrawable*old=drawable();if([mode isEqual:@"concurrent"]){RHGRenderSlot*slot=[RHGRenderSlot new];slot.drawable=(id<CAMetalDrawable>)old;slot.layer=host.metal;slot.frameID=10;slot.generation=1;slot.surfaceID=IOSurfaceGetID(old.texture.iosurface);[host.slots addObject:slot];}
 if([mode isEqual:@"unavailable"]||[mode isEqual:@"failed-basic-reply"])layer.returnNil=YES;if([mode isEqual:@"exception"])layer.throwOnAcquire=YES;
 BOOL forcedFailure=[mode isEqual:@"failed-reply"]||[mode isEqual:@"failed-basic-reply"],failedReply=forcedFailure||[mode isEqual:@"abandoned-reply"];AsyncReply*acquire=sendRequest(host,(RHGRequest){.op=RHG_ACQUIRE,.configurationGeneration=1},!failedReply);
 REQUIRE(pump(^BOOL{return host.acquirePending;}));REQUIRE(dispatch_semaphore_wait(layer.entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);REQUIRE(!layer.acquiredOnMain);REQUIRE(host.pendingAcquire!=nil&&RHGPendingAcquisitionCount==1);mach_port_t once=host.pendingAcquire->response.h.msgh_remote_port;REQUIRE(once!=MACH_PORT_NULL);
 if([mode isEqual:@"concurrent"]){
  AsyncReply*config=sendRequest(host,(RHGRequest){.op=RHG_CONFIGURE,.configurationGeneration=1,.width=8,.height=8,.pixelFormat=MTLPixelFormatBGRA8Unorm,.deviceRegistryID=1},YES);REQUIRE(answered(config)&&config->received.message.status==RHG_BUSY);disposeReply(config);REQUIRE(host.configurationGeneration==1);
  AsyncReply*second=sendRequest(host,(RHGRequest){.op=RHG_ACQUIRE,.configurationGeneration=1},YES);REQUIRE(answered(second)&&second->received.message.status==RHG_BUSY);disposeReply(second);
  AsyncReply*done=sendRequest(host,(RHGRequest){.op=RHG_DONE},YES);REQUIRE(answered(done)&&done->received.message.status==RHG_BUSY);disposeReply(done);
  AsyncReply*poll=sendRequest(host,(RHGRequest){.op=RHG_POLL},YES);REQUIRE(answered(poll)&&poll->received.message.status==RHG_OK);disposeReply(poll);
  AsyncReply*present=sendRequest(host,(RHGRequest){.op=RHG_PRESENT,.frameID=10,.surfaceID=IOSurfaceGetID(old.texture.iosurface),.configurationGeneration=1,.gpuSeconds=.001},YES);REQUIRE(answered(present)&&present->received.message.status==RHG_OK);disposeReply(present);REQUIRE(old.presents==1&&old.presentOnMain&&host.slots.count==0&&host.acquirePending);
 }
 if([mode isEqual:@"stop"]){[host shutdown];REQUIRE(answered(acquire)&&acquire->received.message.status==RHG_STOPPED);REQUIRE(host.acquirePending&&RHGHasRetiredPool());REQUIRE(noRight(once));host.metal=nil;layer=nil;REQUIRE(weakLayer!=nil);}
 if([mode isEqual:@"generation"])host.configurationGeneration=2;
 if(failedReply){REQUIRE(mach_port_destroy(mach_task_self(),acquire->port)==KERN_SUCCESS);acquire->port=MACH_PORT_NULL;if(forcedFailure)atomic_store(&fixtureForceReplyFailure,true);}
 dispatch_semaphore_signal(acquireGate);dispatch_async(host.acquireQueue,^{atomic_store(&fixtureDrained,true);});REQUIRE(pump(^BOOL{return atomic_load(&fixtureDrained);}));REQUIRE(!host.acquirePending&&host.pendingAcquire==nil&&RHGPendingAcquisitionCount==0);
 if([mode isEqual:@"stop"])REQUIRE(pump(^BOOL{return weakLayer==nil;})&&!RHGHasRetiredPool());
 if(failedReply){fprintf(stderr,"reply-result:%d once-gone:%d surface-gone:%d\n",atomic_load(&fixtureReplyResult),noRight(once),noRight(atomic_load(&fixtureSurfacePort)));if(forcedFailure)REQUIRE(pump(^BOOL{return atomic_load(&host->stopped);}));REQUIRE(noRight(once));mach_port_t exported=atomic_load(&fixtureSurfacePort);if([mode isEqual:@"failed-basic-reply"])REQUIRE(exported==0);else REQUIRE(exported!=0&&noRight(exported));}
 else{
  REQUIRE(answered(acquire));uint32_t expected=([mode isEqual:@"stop"]?RHG_STOPPED:[mode isEqual:@"generation"]?RHG_REJECTED:([mode isEqual:@"unavailable"]||[mode isEqual:@"exception"])?RHG_UNSUPPORTED:RHG_OK);REQUIRE(acquire->received.message.status==expected);
  if(expected==RHG_OK){REQUIRE(acquire->received.message.frameID==11&&acquire->received.message.configurationGeneration==1&&host.slots.count==1&&host.frameID==12);REQUIRE(acquire->received.message.body.msgh_descriptor_count==1);IOSurfaceRef imported=IOSurfaceLookupFromMachPort(acquire->received.message.port.name);REQUIRE(imported&&IOSurfaceGetID(imported)==IOSurfaceGetID(layer.next.texture.iosurface));if(imported)CFRelease(imported);uint32_t id=acquire->received.message.surfaceID;disposeReply(acquire);acquire=NULL;
   AsyncReply*present=sendRequest(host,(RHGRequest){.op=RHG_PRESENT,.frameID=11,.surfaceID=id,.configurationGeneration=1,.gpuSeconds=.001},YES);REQUIRE(answered(present)&&present->received.message.status==RHG_OK);disposeReply(present);REQUIRE(layer.next.presents==1&&host.slots.count==0);
  }else{REQUIRE(host.slots.count==0&&host.frameID==11);mach_port_t exported=atomic_load(&fixtureSurfacePort);if(exported)REQUIRE(noRight(exported));}
 }
 if(acquire)disposeReply(acquire);[host shutdown];REQUIRE(pump(^BOOL{return dispatch_group_wait(serving,DISPATCH_TIME_NOW)==0;}));REQUIRE(!NSApp.isActive&&NSApp.windows.count==0);
 printf("{\"passed\":true,\"checks\":%u,\"mode\":\"%s\",\"realMachIPC\":true,\"realIOSurfaceRights\":true,\"GPUWindowScreenCaptureGameUsed\":false}\n",checks,argv[1]);return 0;
}}
