// SPDX-License-Identifier: GPL-3.0-only
#import <sys/wait.h>
#import <signal.h>
#import "../Sources/ReadyHostedView/ReadyHostedView.m"
static unsigned released;
@interface RHGRetirementToken:NSObject @end
@implementation RHGRetirementToken
-(void)dealloc{released++;}
@end
static void FillSlots(RHGHost *host){@autoreleasepool{
 host.slots=[NSMutableArray new];
 for(unsigned i=0;i<2;i++){RHGRenderSlot *slot=[RHGRenderSlot new];slot.drawable=(id<CAMetalDrawable>)[RHGRetirementToken new];slot.layer=[CAMetalLayer layer];slot.frameID=i+1;slot.generation=1;[host.slots addObject:slot];}
}}
static int childWriter=-1;
static pid_t LiveChild(void){
 int fds[2];if(pipe(fds))exit(10);pid_t pid=fork();
 if(pid==0){close(fds[1]);if(childWriter>=0)close(childWriter);char byte;while(read(fds[0],&byte,1)<0&&errno==EINTR){};_exit(0);}
 close(fds[0]);if(pid<0){close(fds[1]);exit(12);}childWriter=fds[1];return pid;
}
static void Reap(pid_t pid){if(childWriter>=0){close(childWriter);childWriter=-1;}kill(pid,SIGTERM);while(waitpid(pid,NULL,0)<0&&errno==EINTR){}}
static void Pump(double seconds){double end=CACurrentMediaTime()+seconds;do{@autoreleasepool{[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];}}while(CACurrentMediaTime()<end);}
int main(void){@autoreleasepool{
 alarm(15);NSMutableDictionary *checks=[NSMutableDictionary new];
 pid_t pid=LiveChild();uint64_t sec=0,usec=0;checks[@"authenticatedPeerBirthReadable"]=@(RHGReadPeerBirth(pid,&sec,&usec));
 RHGHost *host=[RHGHost new];host.guestPID=pid;host.guestBirthSeconds=sec;host.guestBirthMicroseconds=usec;FillSlots(host);
 __weak id drawable=host.slots.firstObject.drawable;__weak id layer=host.slots.firstObject.layer;
 unsigned before=released;[host shutdown];host=nil;Pump(.08);
 checks[@"stopRetainsExactlyTwoFramesWhileProducerAlive"]=@(RHGRetiredSlotCount()==2&&released==before&&drawable&&layer);
 checks[@"newHostIsGatedUntilPriorPoolRetires"]=@(RHGHasRetiredPool());
 checks[@"retirementDoesNotTerminateProducer"]=@(kill(pid,0)==0);
 Reap(pid);double deadline=CACurrentMediaTime()+3;while(RHGHasRetiredPool()&&CACurrentMediaTime()<deadline)Pump(.02);Pump(.03);
 checks[@"auditedPeerExitReleasesFramesAndLayerExactlyOnce"]=@(!RHGHasRetiredPool()&&released==before+2&&!drawable&&!layer);
 checks[@"peerAlreadyExitedIsKnownGone"]=@(RHGPeerLifeState(pid,sec,usec)==RHGPeerGone);
 @autoreleasepool{RHGHost *gone=[RHGHost new];gone.guestPID=pid;gone.guestBirthSeconds=sec;gone.guestBirthMicroseconds=usec;FillSlots(gone);[gone shutdown];}
 checks[@"alreadyDeadProducerDoesNotCreateRetirementWatcher"]=@(!RHGHasRetiredPool()&&released==before+4);
 pid_t other=LiveChild();uint64_t s2=0,u2=0;RHGReadPeerBirth(other,&s2,&u2);
 checks[@"reusedNumericPIDCannotMatchEarlierBirth"]=@(RHGPeerLifeState(other,s2+1,u2)==RHGPeerGone&&kill(other,0)==0);Reap(other);
 @autoreleasepool{RHGHost *unknown=[RHGHost new];FillSlots(unknown);[unknown shutdown];}
 Pump(.02);checks[@"unknownPeerIdentityFailsClosedWithBoundedPool"]=@(RHGRetiredSlotCount()==2);
 for(RHGRetiredRenderPool *pool in RHGRetiredPools.allObjects)[pool finish];Pump(.02);
 BOOL passed=YES;for(NSNumber *value in checks.allValues)passed&=value.boolValue;
 NSDictionary *report=@{@"passed":@(passed),@"count":@(checks.count),@"checks":checks,@"actualChildProcessesUsed":@YES,@"realGameAccountOrWindowUsed":@NO,@"GPUWorkAddedByRetirement":@NO};
 NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return passed?0:1;
}}
