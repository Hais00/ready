// SPDX-License-Identifier: GPL-3.0-only
// Appended to a private constructor-disabled production shim; own Metal only.
#define CHECK(c) do{if(!(c)){fprintf(stderr,"pipeline-guest-check:%d\n",__LINE__);return 81;}}while(0)
static BOOL pipeWait(BOOL(^condition)(void),double seconds){double end=CACurrentMediaTime()+seconds;while(!condition()&&CACurrentMediaTime()<end)usleep(1000);return condition();}
static BOOL pipeComplete(RHGDrawable*d){@synchronized(d){return d.gpuComplete;}}
static NSDictionary*pipeHost(NSString*root){NSData*d=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"state.json"]];return d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
static RHGReply pipeRaw(uint32_t op,uint64_t frame,uint32_t surface,uint64_t generation){
 mach_port_t receive=0;mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&receive);RHGRequest q={0};q.h=(mach_msg_header_t){.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE),.msgh_size=sizeof q,.msgh_remote_port=rhgPeer,.msgh_local_port=receive};q.magic=RHG_MAGIC;q.version=RHG_VERSION;q.op=op;q.requestID=UINT64_C(1000000)+op;q.frameID=frame;q.surfaceID=surface;q.configurationGeneration=generation;memcpy(q.nonce,rhgNonce,sizeof q.nonce);q.width=64;q.height=64;q.pixelFormat=MTLPixelFormatBGRA8Unorm;q.deviceRegistryID=rhgMetadataSnapshot().deviceRegistryID;
 if(mach_msg(&q.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof q,0,MACH_PORT_NULL,3000,0))_exit(82);RHGReplyReceive r={0};if(mach_msg(&r.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof r,receive,3000,0))_exit(83);mach_port_destroy(mach_task_self(),receive);return r.message;
}
static void pipeRender(id<MTLDevice>d,RHGDrawable*frame,MTLClearColor color,id<MTLSharedEvent>gate){
 id<MTLCommandQueue>q=[d newCommandQueue];id<MTLCommandBuffer>b=[q commandBuffer];if(gate)[b encodeWaitForEvent:gate value:1];MTLRenderPassDescriptor*p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=frame.texture;p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;p.colorAttachments[0].clearColor=color;id<MTLRenderCommandEncoder>e=[b renderCommandEncoderWithDescriptor:p];[e endEncoding];rhgBufferPresent(b,frame,RHG_PRESENT_NORMAL,0);[b commit];
}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=3)return 64;alarm(30);NSString*root=[NSString stringWithUTF8String:argv[1]];BOOL stop=!strcmp(argv[2],"stop");unsigned checks=0;
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();CAMetalLayer*layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.drawableSize=CGSizeMake(16,16);layer.framebufferOnly=NO;layer.displaySyncEnabled=NO;
 RHGDrawable*d0=rhgNextDrawable(layer,@selector(nextDrawable));CHECK(d0.frameID==0&&d0.generation>0&&rhgFrameDepth>=1);checks++;
 id<MTLSharedEvent>gate0=[device newSharedEvent];
 if(rhgFrameDepth==1){
  CHECK(pipeRaw(RHG_ACQUIRE,0,0,d0.generation).status==RHG_BUSY);checks++;
  pipeRender(device,d0,MTLClearColorMake(1,0,0,1),gate0);
  __block RHGDrawable*d1=nil;dispatch_semaphore_t returned=dispatch_semaphore_create(0);dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{d1=rhgNextDrawable(layer,@selector(nextDrawable));dispatch_semaphore_signal(returned);});
  CHECK(dispatch_semaphore_wait(returned,dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_MSEC))!=0);checks++;
  gate0.signaledValue=1;CHECK(dispatch_semaphore_wait(returned,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);CHECK(d1.frameID==1);checks++;
  pipeRender(device,d1,MTLClearColorMake(0,1,0,1),nil);CHECK(pipeWait(^BOOL{[rhgRenderLock lock];BOOL done=rhgOutstandingFrames.count==0;[rhgRenderLock unlock];return done;},3));checks++;
 }else{
  RHGDrawable*d1=rhgNextDrawable(layer,@selector(nextDrawable));CHECK(d1.frameID==1&&d0.surfaceID!=d1.surfaceID&&d0.generation==d1.generation);checks++;
  CHECK(pipeRaw(RHG_ACQUIRE,0,0,d0.generation).status==RHG_BUSY);checks++;
  CHECK(pipeRaw(RHG_CONFIGURE,0,0,d0.generation).status==RHG_BUSY);checks++;
  CHECK(pipeRaw(RHG_PRESENT,d1.frameID,d1.surfaceID,d1.generation).status==RHG_REJECTED);checks++;
  CHECK(pipeRaw(RHG_PRESENT,d0.frameID,d1.surfaceID,d0.generation).status==RHG_REJECTED);checks++;
  CHECK(pipeRaw(RHG_PRESENT,d0.frameID,d0.surfaceID,d0.generation-1).status==RHG_REJECTED);checks++;
  pipeRender(device,d0,MTLClearColorMake(1,0,0,1),gate0);
  if(stop){pipeRender(device,d1,MTLClearColorMake(0,1,0,1),gate0);[@"ready" writeToFile:[root stringByAppendingPathComponent:@"stop-ready"] atomically:YES encoding:NSUTF8StringEncoding error:nil];for(;;)usleep(10000);}
  pipeRender(device,d1,MTLClearColorMake(0,1,0,1),nil);CHECK(pipeWait(^BOOL{return pipeComplete(d1);},3));
  CHECK(!pipeComplete(d0)&&!d1.presentSent&&!d1.residencyEnded&&[pipeHost(root)[@"presents"]count]==0);checks++;
  __block RHGDrawable*d2=nil;dispatch_semaphore_t third=dispatch_semaphore_create(0);dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{d2=rhgNextDrawable(layer,@selector(nextDrawable));dispatch_semaphore_signal(third);});
  CHECK(dispatch_semaphore_wait(third,dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_MSEC))!=0);checks++;
  gate0.signaledValue=1;CHECK(dispatch_semaphore_wait(third,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);CHECK(d2.frameID==2&&d2.generation==d0.generation);checks++;
  CHECK(pipeWait(^BOOL{return [pipeHost(root)[@"presents"]count]>=2;},3));NSArray*first=pipeHost(root)[@"presents"];CHECK([first[0][@"frame"]unsignedLongLongValue]==0&&[first[1][@"frame"]unsignedLongLongValue]==1&&d0.residencyEnded&&d1.residencyEnded);checks++;
  CHECK(pipeRaw(RHG_PRESENT,d0.frameID,d0.surfaceID,d0.generation).status==RHG_REJECTED);checks++;
  id<MTLSharedEvent>gate2=[device newSharedEvent];pipeRender(device,d2,MTLClearColorMake(0,0,1,1),gate2);layer.drawableSize=CGSizeMake(32,32);
  __block RHGDrawable*d3=nil;dispatch_semaphore_t resized=dispatch_semaphore_create(0);dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{d3=rhgNextDrawable(layer,@selector(nextDrawable));dispatch_semaphore_signal(resized);});
  CHECK(dispatch_semaphore_wait(resized,dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_MSEC))!=0);CHECK([pipeHost(root)[@"generation"]unsignedLongLongValue]==d2.generation);checks++;
  gate2.signaledValue=1;CHECK(dispatch_semaphore_wait(resized,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);CHECK(d3.frameID==3&&d3.generation==d2.generation+1&&d3.texture.width==32);checks++;
  CHECK(pipeRaw(RHG_PRESENT,d2.frameID,d2.surfaceID,d2.generation).status==RHG_REJECTED);checks++;
  pipeRender(device,d3,MTLClearColorMake(1,1,0,1),nil);CHECK(pipeWait(^BOOL{[rhgRenderLock lock];BOOL done=rhgOutstandingFrames.count==0;[rhgRenderLock unlock];return done;},3));checks++;
 }
 unsigned credits=0;while(dispatch_semaphore_wait(rhgFrameAvailable,DISPATCH_TIME_NOW)==0)credits++;CHECK(credits==rhgFrameDepth);for(unsigned i=0;i<credits;i++)dispatch_semaphore_signal(rhgFrameAvailable);checks++;
 printf("{\"passed\":true,\"checks\":%u,\"depth\":%u,\"realMetalClearPasses\":true,\"gameAccountOrUserUIUsed\":false}\n",checks,rhgFrameDepth);return 0;
}}
