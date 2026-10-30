// SPDX-License-Identifier: GPL-3.0-only
// Actual private Mach transactions; GPU completion is controlled, with no GPU/UI.
#define CHECK(c) do{if(!(c)){fprintf(stderr,"own-rpc-lanes:%d\n",__LINE__);_exit(81);}}while(0)
static dispatch_semaphore_t ownAcquireArrived,ownReleaseAcquire,ownAcquireReturned,ownPresentArrived,ownPresentACK;
static _Atomic unsigned ownPresents;
static _Atomic bool ownAcquireDone;
static const char *ownMode;
static mach_port_t ownSurface;
static uint64_t ownAcquireID,ownPresentID;
@interface RPCLaneBuffer:NSObject
@property(copy)MTLCommandBufferHandler completion;
@property MTLCommandBufferStatus status;
@end
@implementation RPCLaneBuffer
-(void)addCompletedHandler:(MTLCommandBufferHandler)handler{self.completion=handler;}
-(double)GPUStartTime{return 1;}
-(double)GPUEndTime{return 1.01;}
@end
static BOOL ownWait(BOOL(^condition)(void)){double end=CACurrentMediaTime()+2;while(!condition()&&CACurrentMediaTime()<end)usleep(1000);return condition();}
static void ownReply(RHGRequest request,BOOL acquire,BOOL accepted){
    RHGReply reply={0};reply.h.msgh_remote_port=request.h.msgh_remote_port;reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_size=sizeof reply;
    reply.magic=RHG_MAGIC;reply.version=RHG_VERSION;reply.op=request.op;reply.requestID=request.requestID;reply.status=accepted?RHG_OK:RHG_REJECTED;
    if((acquire&&!strcmp(ownMode,"bad-acquire-id"))||(!acquire&&request.op==RHG_PRESENT&&!strcmp(ownMode,"bad-present-id")))reply.requestID++;
    reply.configurationGeneration=1;reply.framesInFlight=2;reply.window=4242;reply.width=reply.height=4;reply.pixelFormat=80;reply.deviceRegistryID=1;reply.backingScale=1;reply.logicalWidth=reply.logicalHeight=4;
    reply.pointerAssociated=1;reply.pointerX=acquire?.1:.9;reply.pointerY=acquire?.2:.8;reply.pointerHideCount=acquire?2:17;reply.cocoaOriginX=acquire?100:10;reply.cocoaOriginY=acquire?200:20;
    if(request.op==RHG_PRESENT){reply.frameID=request.frameID;reply.surfaceID=request.surfaceID;}
    if(acquire&&accepted){
        reply.frameID=1;reply.surfaceID=43;
        if(strcmp(ownMode,"bad-descriptor")){reply.h.msgh_bits|=MACH_MSGH_BITS_COMPLEX;reply.body.msgh_descriptor_count=1;reply.port=(mach_msg_port_descriptor_t){.name=ownSurface,.disposition=MACH_MSG_TYPE_COPY_SEND,.type=MACH_MSG_PORT_DESCRIPTOR};}
    }
    CHECK(mach_msg(&reply.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,reply.h.msgh_size,0,MACH_PORT_NULL,2000,MACH_PORT_NULL)==KERN_SUCCESS);
}
static void ownServer(mach_port_t port){for(;;){@autoreleasepool{
    RHGRequestReceive incoming={0};CHECK(mach_msg(&incoming.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof incoming,port,5000,MACH_PORT_NULL)==KERN_SUCCESS);RHGRequest request=incoming.message;
    uint8_t expected[RHG_NONCE_BYTES];memset(expected,0xa1,sizeof expected);BOOL accepted=request.magic==RHG_MAGIC&&request.version==RHG_VERSION&&!memcmp(request.nonce,expected,sizeof expected);
    if(!accepted){ownReply(request,NO,NO);continue;}
    if(request.op==RHG_ACQUIRE){
        ownAcquireID=request.requestID;dispatch_semaphore_signal(ownAcquireArrived);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{CHECK(dispatch_semaphore_wait(ownReleaseAcquire,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);ownReply(request,YES,YES);});
    }else if(request.op==RHG_PRESENT){
        ownPresentID=request.requestID;CHECK(request.frameID==0&&request.surfaceID==42&&request.configurationGeneration==1);atomic_fetch_add(&ownPresents,1);dispatch_semaphore_signal(ownPresentArrived);CHECK(dispatch_semaphore_wait(ownPresentACK,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);ownReply(request,NO,YES);
    }else{CHECK(request.op==RHG_POLL);ownReply(request,NO,YES);}
}}}
static int ownCompare(const void *a,const void *b){uint64_t x=*(const uint64_t*)a,y=*(const uint64_t*)b;return x<y?-1:x>y?1:0;}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;alarm(10);ownMode=argv[1];BOOL shared=!strcmp(ownMode,"shared"),positive=shared||!strcmp(ownMode,"independent");
    if(!strcmp(ownMode,"request-overflow")){atomic_store(&rhgRequestID,UINT64_MAX);(void)rhgNextRequestID();return 82;}
    uint64_t storage[256],*ids=storage;dispatch_apply(256,dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^(size_t index){ids[index]=rhgNextRequestID();});qsort(ids,256,sizeof ids[0],ownCompare);for(unsigned i=1;i<256;i++)CHECK(ids[i]>ids[i-1]);
    mach_port_t port=MACH_PORT_NULL;CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)==KERN_SUCCESS);CHECK(mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS);rhgPeer=port;
    CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&rhgReceive)==KERN_SUCCESS);CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&rhgAcquireReceive)==KERN_SUCCESS);CHECK(rhgReceive!=rhgAcquireReceive);
    CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&ownSurface)==KERN_SUCCESS);CHECK(mach_port_insert_right(mach_task_self(),ownSurface,ownSurface,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS);memset(rhgNonce,0xa1,sizeof rhgNonce);
    rhgFrameDepth=2;rhgConfigurationGeneration=1;rhgNextExpectedFrameID=0;rhgFrameAvailable=dispatch_semaphore_create(0);rhgRenderLock=[NSLock new];rhgOutstandingFrames=[NSMutableArray new];
    ownAcquireArrived=dispatch_semaphore_create(0);ownReleaseAcquire=dispatch_semaphore_create(0);ownAcquireReturned=dispatch_semaphore_create(0);ownPresentArrived=dispatch_semaphore_create(0);ownPresentACK=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{ownServer(port);});
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{RHGReply reply=rhgExchange(RHG_ACQUIRE,(RHGRequest){.configurationGeneration=1});CHECK(reply.frameID==1&&reply.surfaceID==43);mach_port_deallocate(mach_task_self(),reply.port.name);atomic_store(&ownAcquireDone,true);dispatch_semaphore_signal(ownAcquireReturned);});
    CHECK(dispatch_semaphore_wait(ownAcquireArrived,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);RHGReply poll={0};BOOL polled=rhgTryPoll(&poll);CHECK(polled==!shared);
    RHGDrawable *drawable=[RHGDrawable new];drawable.frameID=0;drawable.surfaceID=42;drawable.generation=1;rhgRegisterDrawable(drawable);RPCLaneBuffer *buffer=[RPCLaneBuffer new];buffer.status=MTLCommandBufferStatusNotEnqueued;rhgBufferPresent((id<MTLCommandBuffer>)buffer,drawable,RHG_PRESENT_NORMAL,0);
    CHECK(atomic_load(&ownPresents)==0&&dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);
    if(!strcmp(ownMode,"bad-nonce"))rhgNonce[0]^=1;
    buffer.status=MTLCommandBufferStatusCompleted;buffer.completion((id<MTLCommandBuffer>)buffer);
    if(shared){CHECK(dispatch_semaphore_wait(ownPresentArrived,dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_MSEC))!=0);CHECK(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);dispatch_semaphore_signal(ownReleaseAcquire);CHECK(dispatch_semaphore_wait(ownAcquireReturned,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);}
    CHECK(dispatch_semaphore_wait(ownPresentArrived,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);CHECK(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);CHECK(ownAcquireID!=ownPresentID);
    dispatch_semaphore_signal(ownPresentACK);CHECK(dispatch_semaphore_wait(rhgFrameAvailable,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);CHECK(atomic_load(&ownPresents)==1);
    if(!shared){CHECK(!atomic_load(&ownAcquireDone));dispatch_semaphore_signal(ownReleaseAcquire);CHECK(dispatch_semaphore_wait(ownAcquireReturned,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);}
    CHECK(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);CHECK(ownWait(^{[rhgRenderLock lock];BOOL empty=rhgOutstandingFrames.count==0;[rhgRenderLock unlock];return empty;}));
    RHGWindowMetadata metadata=rhgMetadataSnapshot();CHECK(metadata.cocoaX==10&&metadata.cocoaY==20);os_unfair_lock_lock(&rhgPointerLocationLock);NSPoint pointer=rhgPointerScreenLocation;os_unfair_lock_unlock(&rhgPointerLocationLock);CHECK(fabs(pointer.x-13.6)<.0001&&fabs(pointer.y-20.8)<.0001&&atomic_load(&rhgVirtualHideCount)==17);
    CHECK(positive);printf("{\"passed\":true,\"splitAcquireLane\":%s,\"controlPollContinuesDuringAcquire\":%s,\"presentACKBeforeAcquireReturned\":%s,\"globalRequestIDsUnique\":true,\"noCreditBeforeGPUCompletion\":true,\"noCreditBeforeACK\":true,\"exactOneCredit\":true,\"lateAcquireCannotRewindPointerOrGeometry\":true,\"actualMachIPC\":true,\"GPUOrUIOrGameUsed\":false}\n",shared?"false":"true",polled?"true":"false",shared?"false":"true");return 0;
}}
