// SPDX-License-Identifier: GPL-3.0-only
// Appended to a private constructor-disabled production shim copy.
#include <mach/mach_time.h>
#define CHECK(c) do{if(!(c)){fprintf(stderr,"own-metal4-check:%d\n",__LINE__);return 81;}}while(0)
static BOOL ownComplete(RHGDrawable*d){@synchronized(d){return d.gpuComplete;}}
static BOOL ownWait(BOOL(^condition)(void),double seconds){double end=CACurrentMediaTime()+seconds;while(!condition()&&CACurrentMediaTime()<end){[NSThread sleepForTimeInterval:.001];}return condition();}
static RHGDrawable *ownDrawable(id<MTLDevice>device){RHGDrawable*d=[RHGDrawable new];MTLTextureDescriptor*t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];t.storageMode=MTLStorageModeShared;d.texture=[device newTextureWithDescriptor:t];return d;}
static double ownNs(uint64_t begin,uint64_t end){static mach_timebase_info_data_t b;static dispatch_once_t once;dispatch_once(&once,^{mach_timebase_info(&b);});return (double)(end-begin)*b.numer/b.denom;}
static NSDictionary *ownStats(NSArray<NSNumber*>*values){NSArray*sorted=[values sortedArrayUsingSelector:@selector(compare:)];double total=0;for(NSNumber*n in values)total+=n.doubleValue;return @{ @"count":@(values.count),@"meanNanoseconds":@(total/values.count),@"p50Nanoseconds":sorted[(sorted.count-1)/2],@"p95Nanoseconds":sorted[(NSUInteger)((sorted.count-1)*.95)],@"maximumNanoseconds":sorted.lastObject};}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 64;if(@available(macOS 26.0,*)){}else return 78;const char*mode=argv[1];alarm(25);
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();CHECK(device);
 id<MTL4CommandQueue>queue=[device newMTL4CommandQueue];CHECK(queue);
 RHGMetal4FenceState*state=rhgMetal4FenceState(queue);CHECK(state.event&&state.listener);
 if(!strcmp(mode,"overflow")){state.nextValue=UINT64_MAX;rhgSignalDrawable(queue,@selector(signalDrawable:),ownDrawable(device));return 82;}
 if(!strcmp(mode,"overlap")){[state.pendingValues addObjectsFromArray:@[@1,@2]];rhgSignalDrawable(queue,@selector(signalDrawable:),ownDrawable(device));return 83;}
 unsigned checks=0;id<MTLSharedEvent>firstEvent=state.event;MTLSharedEventListener*firstListener=state.listener;
 id<MTLSharedEvent>gate=[device newSharedEvent];[queue waitForEvent:gate value:1];
 RHGDrawable*blocked=ownDrawable(device);rhgSignalDrawable(queue,@selector(signalDrawable:),blocked);
 [NSThread sleepForTimeInterval:.04];CHECK(!ownComplete(blocked)&&state.pendingValues.count==1);checks++;
 gate.signaledValue=1;CHECK(ownWait(^{return ownComplete(blocked);},3));CHECK(state.pendingValues.count==0&&state.nextValue==1);checks++;
 for(unsigned frame=2;frame<=64;frame++){@autoreleasepool{
  RHGDrawable*d=ownDrawable(device);rhgSignalDrawable(queue,@selector(signalDrawable:),d);
  CHECK(ownWait(^{return ownComplete(d);},3));CHECK(state.event==firstEvent&&state.listener==firstListener&&state.nextValue==frame&&state.pendingValues.count==0&&state.event.signaledValue>=frame);
 }}checks++;
 id<MTLSharedEvent>gateTwo=[device newSharedEvent];[queue waitForEvent:gateTwo value:1];RHGDrawable*first=ownDrawable(device),*second=ownDrawable(device);rhgSignalDrawable(queue,@selector(signalDrawable:),first);rhgSignalDrawable(queue,@selector(signalDrawable:),second);CHECK(state.pendingValues.count==2&&!ownComplete(first)&&!ownComplete(second));gateTwo.signaledValue=1;CHECK(ownWait(^{return (BOOL)(ownComplete(first)&&ownComplete(second));},3));CHECK(state.pendingValues.count==0&&state.nextValue==66);checks++;
 id<MTL4CommandQueue>other=[device newMTL4CommandQueue];RHGMetal4FenceState*otherState=rhgMetal4FenceState(other);
 CHECK(otherState!=state&&otherState.event!=state.event&&otherState.listener!=state.listener);checks++;
 RHGDrawable*otherDrawable=ownDrawable(device);rhgSignalDrawable(other,@selector(signalDrawable:),otherDrawable);CHECK(ownWait(^{return ownComplete(otherDrawable);},3)&&otherState.nextValue==1&&state.nextValue==66);checks++;
 __weak RHGDrawable*weakDrawable=nil;__weak RHGMetal4FenceState*weakState=nil;__weak id<MTL4CommandQueue>weakQueue=nil;
 id<MTLSharedEvent>lifetimeGate=[device newSharedEvent];
 @autoreleasepool{
  id<MTL4CommandQueue>temporary=[device newMTL4CommandQueue];[temporary waitForEvent:lifetimeGate value:1];
  RHGDrawable*d=ownDrawable(device);rhgSignalDrawable(temporary,@selector(signalDrawable:),d);
  weakDrawable=d;weakState=rhgMetal4FenceState(temporary);weakQueue=temporary;
 }
 CHECK(weakDrawable!=nil&&weakState!=nil);checks++;
 lifetimeGate.signaledValue=1;CHECK(ownWait(^{return (BOOL)(weakDrawable==nil);},3));checks++;
 CHECK(ownWait(^{return (BOOL)(weakQueue==nil&&weakState==nil);},3));checks++;
 NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));unsigned ownWindows=0;for(NSDictionary*entry in windows)if([entry[(id)kCGWindowOwnerPID]intValue]==getpid())ownWindows++;CHECK(!ownWindows);checks++;
 NSDictionary*result=@{@"passed":@YES,@"checks":@(checks),@"realMetal4QueueAndSharedEvents":@YES,@"ownedQueueGateWithheldCompletion":@YES,@"sequentialFramesReusingOneEventAndListener":@64,@"perQueueCountersIndependent":@YES,@"pendingDrawableRetainedUntilFence":@YES,@"contextReleasedAfterQueueAndFence":@YES,@"maximumPendingPerQueue":@2,@"gameOrAccountOrUserUIUsed":@NO,@"ownWindowServerWindows":@(ownWindows),@"renderedFrames":@0,@"gameFPSClaimed":@NO,@"twoRealPendingFences":@YES,@"CPUorGameTimingPerformed":@NO};
 NSData*json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return 0;
}}
