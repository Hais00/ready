// SPDX-License-Identifier: GPL-3.0-only
// Appended to a private copy of the actual shim with its install constructor
// removed. It exercises real production functions and Mach RPC, with no GPU.
static dispatch_semaphore_t fixtureArrived,fixtureReply;
static _Atomic unsigned fixturePresents;
static BOOL fixtureBadIdentity;
@interface RHGFixtureResidency:NSObject
@property unsigned ends;
@end
@implementation RHGFixtureResidency
-(void)endResidency{self.ends++;}
@end
@interface RHGFixtureBuffer:NSObject
@property(copy)MTLCommandBufferHandler completion;
@property MTLCommandBufferStatus status;
@end
@implementation RHGFixtureBuffer
-(void)addCompletedHandler:(MTLCommandBufferHandler)handler{self.completion=handler;}
-(double)GPUStartTime{return 1;}
-(double)GPUEndTime{return 1.125;}
@end
static void fixtureServer(mach_port_t port){for(;;){@autoreleasepool{
 RHGRequestReceive received={0};if(mach_msg(&received.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof received,port,5000,MACH_PORT_NULL))_exit(82);
 RHGRequest request=received.message;RHGReply reply={0};reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_remote_port=request.h.msgh_remote_port;reply.h.msgh_size=sizeof reply;
 reply.magic=RHG_MAGIC;reply.version=RHG_VERSION;reply.op=request.op;reply.requestID=request.requestID;reply.status=RHG_OK;
 reply.window=4242;reply.width=640;reply.height=360;reply.pixelFormat=80;reply.deviceRegistryID=1;reply.backingScale=2;reply.logicalWidth=320;reply.logicalHeight=180;reply.pointerX=reply.pointerY=.5;
 if(request.op==RHG_PRESENT){atomic_fetch_add(&fixturePresents,1);dispatch_semaphore_signal(fixtureArrived);if(dispatch_semaphore_wait(fixtureReply,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)))_exit(83);reply.frameID=request.frameID+(fixtureBadIdentity?1:0);reply.surfaceID=request.surfaceID;}
 if(mach_msg(&reply.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof reply,0,MACH_PORT_NULL,2000,MACH_PORT_NULL))_exit(84);
}}}
#define require(value) do{if(!(value)){fprintf(stderr,"completion-fixture-line:%d\n",__LINE__);_exit(81);}checks++;}while(0)
int main(int argc,char **argv){@autoreleasepool{
 alarm(10);unsigned checks=0;fixtureBadIdentity=argc==2&&!strcmp(argv[1],"bad-identity");BOOL badGPU=argc==2&&!strcmp(argv[1],"bad-gpu");
 fixtureArrived=dispatch_semaphore_create(0);fixtureReply=dispatch_semaphore_create(0);
 mach_port_t port=0;const char *name=getenv("READY_HOSTED_GAME_SERVICE");
 if(!name||mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)||mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND)||bootstrap_register(bootstrap_port,(char*)name,port))return 85;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{fixtureServer(port);});
 rhgConnect();require(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)==0);
 RHGDrawable *drawable=[RHGDrawable new];drawable.frameID=123;drawable.surfaceID=42;
 RHGFixtureResidency *residency=[RHGFixtureResidency new];if(@available(macOS 15,*))drawable.importedResidency=(id<MTLResidencySet>)residency;
 RHGFixtureBuffer *buffer=[RHGFixtureBuffer new];buffer.status=badGPU?MTLCommandBufferStatusError:MTLCommandBufferStatusCompleted;
 rhgBufferPresent((id<MTLCommandBuffer>)buffer,drawable,RHG_PRESENT_NORMAL,0);
 require(atomic_load(&fixturePresents)==0);require(residency.ends==0);
 dispatch_semaphore_t returned=dispatch_semaphore_create(0);
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{buffer.completion((id<MTLCommandBuffer>)buffer);dispatch_semaphore_signal(returned);});
 require(dispatch_semaphore_wait(fixtureArrived,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 // The host deliberately withholds ACK: the GPU producer must still return.
 require(dispatch_semaphore_wait(returned,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))==0);
 require(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);
 require(residency.ends==1);rhgTryPresent(drawable);require(atomic_load(&fixturePresents)==1);
 dispatch_semaphore_signal(fixtureReply);
 require(dispatch_semaphore_wait(rhgFrameAvailable,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 require(atomic_load(&fixturePresents)==1);require(residency.ends==1);
 // Reverse arrival order: the GPU completed before presentRequested.
 RHGDrawable *late=[RHGDrawable new];late.frameID=124;late.surfaceID=43;late.fenceRegistered=YES;late.gpuComplete=YES;late.gpuCompletedTick=RHGPerfNow();
 rhgTryPresent(late);require(atomic_load(&fixturePresents)==1);
 uint64_t began=mach_continuous_time();rhgRequestPresent(late,RHG_PRESENT_NORMAL,0);
 RHGPerfStats requestDuration={0};RHGPerfInterval(&requestDuration,began,mach_continuous_time());
 require(requestDuration.maxNs<100*NSEC_PER_MSEC);
 require(dispatch_semaphore_wait(fixtureArrived,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 require(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)!=0);dispatch_semaphore_signal(fixtureReply);
 require(dispatch_semaphore_wait(rhgFrameAvailable,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 require(atomic_load(&fixturePresents)==2);
 pthread_mutex_lock(&rhgPerfLock);require(rhgPerformance.rpcTotal[RHG_PRESENT].count==2);require(rhgPerformance.completionToWorker.count==2);pthread_mutex_unlock(&rhgPerfLock);
 rhgPerfReport(2);double end=CACurrentMediaTime()+1;while(atomic_load(&rhgPerfWritePending)&&CACurrentMediaTime()<end)usleep(1000);require(!atomic_load(&rhgPerfWritePending));
 printf("{\"passed\":true,\"count\":%u,\"actualMachRPC\":true,\"GPUCallbacksControlled\":true,\"maximumOutstandingFrames\":1,\"accountOrGameOrUIOrGPUUsed\":false}\n",checks);return 0;
}}
