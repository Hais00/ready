// SPDX-License-Identifier: GPL-3.0-only
// Constructor-disabled production shim, own Mach server and synthetic drawable.
// This tests control/identity/observer lifetimes, not on-glass rendering.
#define CHECK(c) do{if(!(c)){fprintf(stderr,"own-remote-shim:%d\n",__LINE__);_exit(81);}}while(0)
static _Atomic unsigned ownAttach,ownFirst,ownForbidden;
static _Atomic bool ownFinish;
static dispatch_semaphore_t ownFirstSeen;
static id<CAMetalDrawable> ownDrawable;
@interface OwnRemoteDrawable:NSObject<CAMetalDrawable>
@property(strong)id<MTLTexture> texture;
@property(copy)MTLDrawablePresentedHandler handler;
@property double timestamp;
@property NSUInteger identity;
@end
@implementation OwnRemoteDrawable
-(NSUInteger)drawableID{return _identity?:1;}
-(CFTimeInterval)presentedTime{return _timestamp;}
-(void)addPresentedHandler:(MTLDrawablePresentedHandler)handler{CHECK(!_handler);_handler=handler;}
-(void)present{CHECK(NO);}
-(void)presentAtTime:(CFTimeInterval)value{(void)value;CHECK(NO);}
-(void)presentAfterMinimumDuration:(CFTimeInterval)value{(void)value;CHECK(NO);}
@end
static id ownNativeNext(id object,SEL selector){(void)object;(void)selector;return ownDrawable;}
static id ownNativeUpdate(id object,SEL selector){(void)object;(void)selector;return ownDrawable;}
static id ownForeignNext(id object,SEL selector){(void)object;(void)selector;return ownDrawable;}
static void ownServer(mach_port_t port,BOOL bad,BOOL depth){@autoreleasepool{
 while(!atomic_load(&ownFinish)){
  RHGRequestReceive receive={0};kern_return_t r=mach_msg(&receive.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof receive,port,200,MACH_PORT_NULL);if(r==MACH_RCV_TIMED_OUT)continue;CHECK(r==KERN_SUCCESS);
  RHGRequest q=receive.message;CHECK(q.magic==RHG_MAGIC&&q.version==RHG_VERSION);for(unsigned i=0;i<RHG_NONCE_BYTES;i++)CHECK(q.nonce[i]==0xa1);
  if(q.op==RHG_HELLO)CHECK(q.reserved==RHG_TRANSPORT_REMOTE_LAYER&&q.framesInFlight==0);
  else CHECK(q.reserved==0);
  if(q.op==RHG_REMOTE_ATTACH){CHECK(q.surfaceID!=0);CHECK(atomic_fetch_add(&ownAttach,1)==0);}
  if(q.op==RHG_REMOTE_FIRST_FRAME){CHECK(q.width==4&&q.height==4&&q.deviceRegistryID==ownDrawable.texture.device.registryID);CHECK(atomic_fetch_add(&ownFirst,1)==0);dispatch_semaphore_signal(ownFirstSeen);}
  if(q.op==RHG_ACQUIRE||q.op==RHG_CONFIGURE||q.op==RHG_PRESENT)atomic_fetch_add(&ownForbidden,1);
  RHGReply reply={0};reply.h.msgh_remote_port=q.h.msgh_remote_port;reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_size=sizeof reply;
  reply.magic=RHG_MAGIC;reply.version=RHG_VERSION;reply.op=q.op;reply.requestID=q.requestID+(bad?1:0);reply.status=RHG_OK;
  reply.surfaceID=q.surfaceID;reply.framesInFlight=depth?1:0;reply.window=4242;reply.width=640;reply.height=360;reply.pixelFormat=80;reply.deviceRegistryID=1;reply.backingScale=2;reply.logicalWidth=320;reply.logicalHeight=180;reply.pointerX=reply.pointerY=.5;reply.pointerAssociated=1;
  // Remote mode must accept geometry without surface credits/generation.
  CHECK(mach_msg(&reply.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof reply,0,MACH_PORT_NULL,1000,MACH_PORT_NULL)==KERN_SUCCESS);
 }
}}
int main(int argc,char**argv){@autoreleasepool{
 CHECK(argc==2);alarm(25);BOOL surface=!strcmp(argv[1],"default"),getter=!strcmp(argv[1],"getter")||!strcmp(argv[1],"trace")||!strcmp(argv[1],"trace-file")||!strcmp(argv[1],"trace-freopen"),foreign=!strcmp(argv[1],"foreign"),bad=!strcmp(argv[1],"bad-reply"),depth=!strcmp(argv[1],"bad-depth"),limit=!strcmp(argv[1],"cap128")||!strcmp(argv[1],"trace-cap128"),timeout=!strcmp(argv[1],"timeout"),reuse=!strcmp(argv[1],"reuse-id"),warmup=!strcmp(argv[1],"warmup33");
 if(surface){CHECK(!rhgRemoteLayerMode());puts("{\"passed\":true,\"defaultSurface\":true}");return 0;}
 CHECK(rhgRemoteLayerMode());ownFirstSeen=dispatch_semaphore_create(0);
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();CHECK(device);
 IMP deviceQueue=class_getMethodImplementation(object_getClass(device),@selector(newCommandQueue));
 id<MTLCommandQueue>queue=[device newCommandQueue];CHECK(queue);IMP buffer=class_getMethodImplementation(object_getClass(queue),@selector(commandBuffer));
 id<MTL4CommandQueue>m4=nil;IMP wait=NULL,signal=NULL;if(@available(macOS 26.0,*)){m4=[device newMTL4CommandQueue];wait=class_getMethodImplementation(object_getClass(m4),@selector(waitForDrawable:));signal=class_getMethodImplementation(object_getClass(m4),@selector(signalDrawable:));}
 MTLTextureDescriptor*d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];OwnRemoteDrawable *native=[OwnRemoteDrawable new];native.texture=[device newTextureWithDescriptor:d];CHECK(native.texture);ownDrawable=native;
 Method next=class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable)),update=class_getInstanceMethod(CAMetalDisplayLinkUpdate.class,@selector(drawable));method_setImplementation(next,(IMP)ownNativeNext);method_setImplementation(update,(IMP)ownNativeUpdate);
 mach_port_t port=0;CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)==0);CHECK(mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND)==0);CHECK(bootstrap_register(bootstrap_port,getenv("READY_HOSTED_GAME_SERVICE"),port)==0);
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{ownServer(port,bad,depth);});
 rhgInstall();if(!strcmp(argv[1],"trace-freopen"))CHECK(freopen("/dev/null","w",stderr));rhgConnect();CHECK(!rhgFrameAvailable&&!rhgRenderLock&&!rhgOutstandingFrames&&!rhgAcquireReceive&&rhgFrameDepth==0);
 if(limit){CAMetalLayer*l=[CAMetalLayer layer];l.device=device;for(unsigned i=0;i<RHG_REMOTE_STARTUP_LIMIT;i++){OwnRemoteDrawable*n=[OwnRemoteDrawable new];n.texture=native.texture;ownDrawable=n;CHECK(rhgRemoteNextDrawable(l,@selector(nextDrawable))==n);n.handler(n);}CHECK(atomic_load(&rhgRemoteObserved)==128&&atomic_load(&ownFirst)==0);CHECK(method_getImplementation(next)==(IMP)ownNativeNext&&method_getImplementation(update)==(IMP)ownNativeUpdate);atomic_store(&ownFinish,true);puts("{\"passed\":true,\"startupObserversRestoredAt128\":true,\"noFirstFrameWithoutPositiveTimestamp\":true}");return 0;}
 CHECK(rhgDefaultDevice()==device);(void)rhgAllDevices();CHECK(class_getMethodImplementation(object_getClass(device),@selector(newCommandQueue))==deviceQueue);CHECK(class_getMethodImplementation(object_getClass(queue),@selector(commandBuffer))==buffer);
 if(m4){CHECK(class_getMethodImplementation(object_getClass(m4),@selector(waitForDrawable:))==wait);CHECK(class_getMethodImplementation(object_getClass(m4),@selector(signalDrawable:))==signal);}
 CAMetalLayer *layer=[CAMetalLayer layer];layer.device=device;layer.drawableSize=CGSizeMake(4,4);CALayer*root=[CALayer layer];[root addSublayer:layer];
 id result;
 if(getter){rhgRemoteAttach(layer);result=rhgRemoteUpdateDrawable(nil,@selector(drawable));}else{if(foreign)method_setImplementation(next,(IMP)ownForeignNext);result=rhgRemoteNextDrawable(layer,@selector(nextDrawable));}
 for(unsigned i=0;i<5;i++){CHECK((getter?rhgRemoteUpdateDrawable(nil,@selector(drawable)):rhgRemoteNextDrawable(layer,@selector(nextDrawable)))==native);}CHECK(atomic_load(&rhgRemoteObserved)==1);
 CHECK(result==native&&native.handler);CHECK(rhgRemoteContext.layer==root&&layer.superlayer==root);CHECK(atomic_load(&ownAttach)==1);
 CHECK(atomic_load(&ownFirst)==0);native.handler(native);if(timeout){[NSThread sleepForTimeInterval:16];CHECK(NO);}[NSThread sleepForTimeInterval:.03];CHECK(atomic_load(&ownFirst)==0);CHECK(method_getImplementation(update)==(IMP)rhgRemoteUpdateDrawable);
 if(warmup){for(unsigned i=1;i<32;i++){OwnRemoteDrawable*n=[OwnRemoteDrawable new];n.texture=native.texture;ownDrawable=n;for(unsigned read=0;read<4;read++)CHECK(rhgRemoteNextDrawable(layer,@selector(nextDrawable))==n);n.handler(n);CHECK(atomic_load(&ownFirst)==0);}CHECK(atomic_load(&rhgRemoteObserved)==32);CHECK(method_getImplementation(next)==(IMP)rhgRemoteNextDrawable);}
 OwnRemoteDrawable *positive=reuse?native:[OwnRemoteDrawable new];if(reuse){positive.handler=nil;positive.identity=2;}positive.texture=native.texture;positive.timestamp=1.25;ownDrawable=positive;
 CHECK((getter?rhgRemoteUpdateDrawable(nil,@selector(drawable)):rhgRemoteNextDrawable(layer,@selector(nextDrawable)))==positive);CHECK(positive.handler);for(unsigned i=0;i<5;i++){CHECK((getter?rhgRemoteUpdateDrawable(nil,@selector(drawable)):rhgRemoteNextDrawable(layer,@selector(nextDrawable)))==positive);}CHECK(atomic_load(&rhgRemoteObserved)==(warmup?33:2));positive.handler(positive);
 CHECK(dispatch_semaphore_wait(ownFirstSeen,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 CHECK(method_getImplementation(next)==(foreign?(IMP)ownForeignNext:(IMP)ownNativeNext));CHECK(method_getImplementation(update)==(IMP)ownNativeUpdate);CHECK(class_getMethodImplementation(CAMetalDisplayLink.class,@selector(initWithMetalLayer:))==rhgRemoteOriginalInit);
 [NSThread sleepForTimeInterval:.03];CHECK(atomic_load(&ownFirst)==1&&atomic_load(&ownForbidden)==0);
 if(rhgRemoteTraceEnabled()){CHECK(atomic_load(&rhgPerfOutputFD)>=0);CHECK(fcntl(atomic_load(&rhgPerfOutputFD),F_GETFD)&FD_CLOEXEC);}else CHECK(atomic_load(&rhgPerfOutputFD)<0);
 atomic_store(&ownFinish,true);NSDictionary*report=@{@"passed":@YES,@"actualMachControl":@YES,@"exactDrawableObjectForwarded":@YES,@"zeroCallbackDoesNotNotify":@YES,@"positiveCallbackNotifiesOnce":@YES,@"nativeDeviceQueueMethodsUnchanged":@YES,@"temporaryObserversRestored":@YES,@"foreignHookPreserved":@(foreign),@"gameOwnedLayerTreePreserved":@YES,@"repeatedGetterReadsDeduplicated":@YES,@"drawableIDReuseRecognized":@(reuse),@"positiveAfter32WarmupFrames":@(warmup),@"surfaceTransportRequests":@0,@"frameCreditStructuresAllocated":@NO,@"actualRenderedFrames":@0,@"UIOrGameOrAccountUsed":@NO};NSData*j=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(j.bytes,1,j.length,stdout);fputc('\n',stdout);return 0;
}}
