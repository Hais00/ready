// SPDX-License-Identifier: GPL-3.0-only
// Public Metal/NSSecureCoding only. No window, capture, private API or port extraction.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <sys/stat.h>
#import <unistd.h>
static void emit(NSDictionary*value){NSData*d=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);}
static BOOL finished(id<MTLCommandBuffer>cb,dispatch_semaphore_t signal,double seconds){return dispatch_semaphore_wait(signal,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)))==0&&cb.status==MTLCommandBufferStatusCompleted;}
static id<MTLCommandBuffer>signalGPU(id<MTLCommandQueue>queue,id<MTLSharedEvent>event,uint64_t value){id<MTLCommandBuffer>cb=[queue commandBuffer];[cb encodeSignalEvent:event value:value];[cb commit];return cb;}
static int child(NSString*root){@autoreleasepool{
 NSString*archive=[root stringByAppendingPathComponent:@"event.archive"];NSError*error=nil;MTLSharedEventHandle*handle=nil;
 @try{handle=[NSKeyedUnarchiver unarchivedObjectOfClass:MTLSharedEventHandle.class fromData:[NSData dataWithContentsOfFile:archive] error:&error];}
 @catch(NSException*e){emit(@{@"passed":@NO,@"stage":@"child-unarchive",@"exceptionName":e.name});return 2;}
 if(!handle){emit(@{@"passed":@NO,@"stage":@"child-unarchive",@"errorCode":@(error.code)});return 2;}
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();id<MTLSharedEvent>event=nil;
 @try{event=[device newSharedEventWithHandle:handle];}@catch(NSException*e){emit(@{@"passed":@NO,@"stage":@"child-import",@"exceptionName":e.name});return 2;}
 if(!event){emit(@{@"passed":@NO,@"stage":@"child-import"});return 2;}
 id<MTLCommandQueue>queue=[device newCommandQueue];dispatch_semaphore_t done=dispatch_semaphore_create(0);id<MTLCommandBuffer>wait=[queue commandBuffer];
 [wait encodeWaitForEvent:event value:2];[wait addCompletedHandler:^(id<MTLCommandBuffer>b){dispatch_semaphore_signal(done);}];[wait commit];
 BOOL blocked=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC))!=0;
 if(!blocked){emit(@{@"passed":@NO,@"stage":@"child-wait-not-blocked"});return 2;}
 NSString*marker=[root stringByAppendingPathComponent:@"child-blocked"];[[NSData data]writeToFile:marker atomically:NO];chmod(marker.fileSystemRepresentation,0600);
 BOOL released=finished(wait,done,3);if(!released){event.signaledValue=2;[wait waitUntilCompleted];emit(@{@"passed":@NO,@"stage":@"child-gpu-wait-not-released",@"actualBlockedGPUWait":@YES});return 2;}
 id<MTLCommandBuffer>ack=signalGPU(queue,event,3);[ack waitUntilCompleted];BOOL good=ack.status==MTLCommandBufferStatusCompleted;
 emit(@{@"passed":@(good),@"childPID":@(getpid()),@"actualBlockedGPUWait":@YES,@"parentGPUSignalReleasedWait":@YES,@"childGPUAcknowledgment":@(good)});return good?0:2;
}}
int main(int argc,const char**argv){@autoreleasepool{
 umask(077);if(argc!=4)return 3;NSString*mode=@(argv[1]);NSString*root=@(argv[2]);NSString*binary=@(argv[3]);if([mode isEqual:@"child"])return child(root);
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();id<MTLSharedEvent>event=[device newSharedEvent];
 if(!device||!event){emit(@{@"probeCompleted":@YES,@"archiveCrossProcessSupported":@NO,@"stage":@"shared-event-unavailable"});return 0;}
 // Positive control: a genuinely blocked GPU wait is released by a separate queue's GPU signal.
 id<MTLCommandQueue>waitQueue=[device newCommandQueue],signalQueue=[device newCommandQueue];
 dispatch_semaphore_t done=dispatch_semaphore_create(0);id<MTLCommandBuffer>wait=[waitQueue commandBuffer];
 [wait encodeWaitForEvent:event value:1];[wait addCompletedHandler:^(id<MTLCommandBuffer>b){dispatch_semaphore_signal(done);}];[wait commit];
 BOOL blocked=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))!=0;
 id<MTLCommandBuffer>localSignal=signalGPU(signalQueue,event,1);[localSignal waitUntilCompleted];BOOL control=blocked&&finished(wait,done,2)&&localSignal.status==MTLCommandBufferStatusCompleted;
 if(!control){event.signaledValue=1;emit(@{@"probeCompleted":@YES,@"archiveCrossProcessSupported":@NO,@"stage":@"local-gpu-control-failed"});return 1;}
 MTLSharedEventHandle*handle=[event newSharedEventHandle];NSError*error=nil;NSData*archive=nil;
 @try{archive=[NSKeyedArchiver archivedDataWithRootObject:handle requiringSecureCoding:YES error:&error];}
 @catch(NSException*e){emit(@{@"probeCompleted":@YES,@"archiveCrossProcessSupported":@NO,@"localBlockedGPUControlPassed":@YES,@"stage":@"standard-secure-archive",@"exceptionName":e.name,@"childStarted":@NO,@"publicAPIsOnly":@YES});return 0;}
 if(!archive){emit(@{@"probeCompleted":@YES,@"archiveCrossProcessSupported":@NO,@"localBlockedGPUControlPassed":@YES,@"stage":@"standard-secure-archive",@"errorCode":@(error.code),@"childStarted":@NO,@"publicAPIsOnly":@YES});return 0;}
 NSString*file=[root stringByAppendingPathComponent:@"event.archive"];BOOL written=[archive writeToFile:file options:NSDataWritingAtomic error:&error];chmod(file.fileSystemRepresentation,0600);
 if(!written){emit(@{@"probeCompleted":@YES,@"archiveCrossProcessSupported":@NO,@"stage":@"private-file-write",@"errorCode":@(error.code)});return 1;}
 NSTask*task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:binary];task.arguments=@[@"child",root,binary];NSPipe*out=[NSPipe pipe],*err=[NSPipe pipe];task.standardOutput=out;task.standardError=err;
 if(![task launchAndReturnError:&error]){emit(@{@"probeCompleted":@YES,@"archiveCrossProcessSupported":@NO,@"stage":@"child-start",@"errorCode":@(error.code)});return 1;}
 NSString*marker=[root stringByAppendingPathComponent:@"child-blocked"];BOOL ready=NO;
 for(unsigned i=0;i<300;i++){if([NSFileManager.defaultManager fileExistsAtPath:marker]){ready=YES;break;}if(!task.running)break;usleep(10000);}
 BOOL acknowledged=NO;if(ready){id<MTLCommandBuffer>signal=signalGPU(signalQueue,event,2);[signal waitUntilCompleted];acknowledged=[event waitUntilSignaledValue:3 timeoutMS:3000]&&signal.status==MTLCommandBufferStatusCompleted;}
 if(task.running&&!ready)[task terminate];[task waitUntilExit];NSData*childData=[out.fileHandleForReading readDataToEndOfFile];NSDictionary*childReport=[NSJSONSerialization JSONObjectWithData:childData options:0 error:nil];
 [NSFileManager.defaultManager removeItemAtPath:file error:nil];[NSFileManager.defaultManager removeItemAtPath:marker error:nil];
 BOOL supported=ready&&acknowledged&&task.terminationStatus==0&&[childReport[@"passed"]boolValue];
 emit(@{@"probeCompleted":@YES,@"archiveCrossProcessSupported":@(supported),@"localBlockedGPUControlPassed":@YES,@"stage":@"actual-two-process-gpu-timeline",@"parentPID":@(getpid()),@"childStarted":@YES,@"child":childReport?:@{},@"parentObservedChildGPUSignal":@(acknowledged),@"publicAPIsOnly":@YES});return 0;
}}
