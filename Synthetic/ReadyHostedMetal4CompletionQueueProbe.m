// SPDX-License-Identifier: GPL-3.0-only
// Appended to a private constructor-disabled copy of the production shim.
// Own event-only Metal4 queue and private Mach endpoint; no rendering or UI.
#define CHECK(c) do{if(!(c)){fprintf(stderr,"own-metal4-completion-queue:%d\n",__LINE__);_exit(81);}}while(0)
static dispatch_semaphore_t ownHostArrived,ownHostAck,ownLaneEntered,ownLaneRelease;
static _Atomic unsigned ownPresents;
static BOOL ownComplete(RHGDrawable *drawable){@synchronized(drawable){return drawable.gpuComplete;}}
static BOOL ownWait(BOOL(^condition)(void),double seconds){
    double end=CACurrentMediaTime()+seconds;
    while(!condition()&&CACurrentMediaTime()<end)[NSThread sleepForTimeInterval:.001];
    return condition();
}
static void ownServer(mach_port_t port,id<MTLDevice>device){@autoreleasepool{
    RHGRequestReceive received={0};CHECK(mach_msg(&received.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof received,port,5000,MACH_PORT_NULL)==KERN_SUCCESS);
    RHGRequest request=received.message;
    CHECK(request.magic==RHG_MAGIC&&request.version==RHG_VERSION&&request.op==RHG_PRESENT&&request.frameID==0&&request.surfaceID==42&&request.configurationGeneration==1);
    CHECK(!memcmp(request.nonce,rhgNonce,sizeof rhgNonce));atomic_fetch_add(&ownPresents,1);dispatch_semaphore_signal(ownHostArrived);
    CHECK(dispatch_semaphore_wait(ownHostAck,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);
    RHGReply reply={0};reply.h.msgh_remote_port=request.h.msgh_remote_port;reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_size=sizeof reply;
    reply.magic=RHG_MAGIC;reply.version=RHG_VERSION;reply.status=RHG_OK;reply.op=RHG_PRESENT;reply.requestID=request.requestID;
    reply.frameID=0;reply.surfaceID=42;reply.configurationGeneration=1;reply.framesInFlight=2;
    reply.window=4242;reply.width=reply.height=4;reply.logicalWidth=reply.logicalHeight=4;reply.backingScale=1;reply.pixelFormat=MTLPixelFormatBGRA8Unorm;reply.deviceRegistryID=device.registryID;
    reply.pointerX=reply.pointerY=.5;reply.pointerAssociated=1;
    CHECK(mach_msg(&reply.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,reply.h.msgh_size,0,MACH_PORT_NULL,2000,MACH_PORT_NULL)==KERN_SUCCESS);
}}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;if(@available(macOS 26.0,*)){}else return 78;alarm(15);
    BOOL independent=!strcmp(argv[1],"independent"),shared=!strcmp(argv[1],"shared");CHECK(independent||shared);
    id<MTLDevice>device=MTLCreateSystemDefaultDevice();CHECK(device);id<MTL4CommandQueue>queue=[device newMTL4CommandQueue];CHECK(queue);
    RHGMetal4FenceState *state=rhgMetal4FenceState(queue);CHECK(state.event&&state.listener);
    CHECK((state.listener.dispatchQueue!=rhgPresentationWorker())==independent);
    rhgFrameDepth=2;rhgConfigurationGeneration=1;rhgNextExpectedFrameID=0;rhgFrameAvailable=dispatch_semaphore_create(0);rhgRenderLock=[NSLock new];rhgOutstandingFrames=[NSMutableArray new];memset(rhgNonce,0xa1,sizeof rhgNonce);
    mach_port_t server=MACH_PORT_NULL;CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&server)==KERN_SUCCESS);CHECK(mach_port_insert_right(mach_task_self(),server,server,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS);rhgPeer=server;
    CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&rhgReceive)==KERN_SUCCESS);
    ownHostArrived=dispatch_semaphore_create(0);ownHostAck=dispatch_semaphore_create(0);ownLaneEntered=dispatch_semaphore_create(0);ownLaneRelease=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{ownServer(server,device);});
    dispatch_async(rhgPresentationWorker(),^{dispatch_semaphore_signal(ownLaneEntered);CHECK(dispatch_semaphore_wait(ownLaneRelease,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);});
    CHECK(dispatch_semaphore_wait(ownLaneEntered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];descriptor.storageMode=MTLStorageModeShared;
    RHGDrawable *drawable=[RHGDrawable new];drawable.texture=[device newTextureWithDescriptor:descriptor];CHECK(drawable.texture);drawable.frameID=0;drawable.surfaceID=42;drawable.generation=1;rhgRegisterDrawable(drawable);
    id<MTLSharedEvent>gpuGate=[device newSharedEvent];CHECK(gpuGate);[queue waitForEvent:gpuGate value:1];
    rhgSignalDrawable(queue,@selector(signalDrawable:),drawable);rhgRequestPresent(drawable,RHG_PRESENT_NORMAL,0);
    [NSThread sleepForTimeInterval:.025];CHECK(!ownComplete(drawable));CHECK(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);CHECK(atomic_load(&ownPresents)==0);
    gpuGate.signaledValue=1;
    // Wait on the real GPU timeline first. A blocked CPU callback must not be
    // misreported as an uncompleted GPU fence in the historical shared case.
    CHECK([state.event waitUntilSignaledValue:1 timeoutMS:2000]);
    BOOL completedWhileLaneHeld=ownWait(^{return ownComplete(drawable);},independent?1:.1);
    CHECK(completedWhileLaneHeld==independent);CHECK(atomic_load(&ownPresents)==0);CHECK(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);
    dispatch_semaphore_signal(ownLaneRelease);CHECK(dispatch_semaphore_wait(ownHostArrived,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);
    CHECK(ownComplete(drawable)&&drawable.presentSent&&atomic_load(&ownPresents)==1);CHECK(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);
    dispatch_semaphore_signal(ownHostAck);CHECK(dispatch_semaphore_wait(rhgFrameAvailable,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
    CHECK(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);CHECK(ownWait(^{[rhgRenderLock lock];BOOL empty=rhgOutstandingFrames.count==0;[rhgRenderLock unlock];return empty;},1));
    NSDictionary *report=@{@"passed":@YES,@"independentCompletionQueue":@(independent),@"realGPUFenceReached":@YES,@"callbackCompletedWhilePresentLaneBlocked":@(completedWhileLaneHeld),@"noPresentBeforeLaneReleased":@YES,@"noCreditBeforeFence":@YES,@"noCreditBeforePresentACK":@YES,@"exactOnePresentAndCredit":@YES,@"eventOnlyMetal4Queue":@YES,@"renderedFrames":@0,@"UIOrGameOrAccountUsed":@NO};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return 0;
}}
