#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile production host methods with controlled eligibility; no UI/GPU/CG mutations."""
import hashlib,json,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
SOURCE=r'''
#import "ReadyHostedView.m"
#include <assert.h>
@interface EligibilityHost:RHGHost
@property BOOL testEligible;
@property BOOL testWindowEligible;
@property unsigned eligibilityCalls,releases;
@end
@implementation EligibilityHost
-(BOOL)foregroundEligible{self.eligibilityCalls++;return self.testEligible;}
-(BOOL)foregroundWindowEligible{return self.testWindowEligible;}
-(void)releasePointer{self.releases++;self->pointer.captured=false;self->pointer.detached=false;self->pointer.hidden=false;}
@end
@interface LocalKey:NSObject
@end
@implementation LocalKey
-(NSEventModifierFlags)modifierFlags{return 0;}
-(NSTimeInterval)timestamp{return 1;}
-(unsigned short)keyCode{return 0;}
-(NSString*)charactersIgnoringModifiers{return @"";}
@end
static void arm(EligibilityHost*h){h.pointerEnabled=YES;h.firstFrameAnnounced=YES;h.virtualInitialized=YES;h.testEligible=YES;h->pointer.captured=true;h.eligibilityCalls=h.releases=0;}
int main(void){@autoreleasepool{setenv("RHG_PERF_PROFILE","1",1);unsigned count=0;EligibilityHost*h=[EligibilityHost new];arm(h);
 uint32_t operations[]={RHG_HELLO,RHG_CONFIGURE,RHG_ACQUIRE,RHG_PRESENT,RHG_DONE,RHG_POINTER_WARP,RHG_POINTER_ASSOCIATE,RHG_POINTER_CURSOR};
 for(unsigned i=0;i<sizeof operations/sizeof*operations;i++){RHGReply reply={.op=operations[i]};RHGFill(h,&reply);assert(!h.eligibilityCalls&&!h.releases&&h->pointer.captured);}count++;
 RHGReply reply={.op=RHG_POLL};RHGFill(h,&reply);assert(h.eligibilityCalls==1&&!h.releases&&reply.pointerCaptured&&reply.eventCount==2&&reply.events[0].type==RHG_FOCUS&&reply.events[0].keyCode==1&&reply.events[1].type==RHG_MOUSE_MOVE&&!reply.events[1].deltaX&&!reply.events[1].deltaY);count++;
 reply=(RHGReply){.op=RHG_POLL};RHGFill(h,&reply);assert(h.eligibilityCalls==2&&!h.releases&&!reply.eventCount);count++;
 arm(h);LocalKey*event=[LocalKey new];[h input:(NSEvent*)event type:RHG_KEY_UP];assert(h.eligibilityCalls==1&&!h.releases&&h->inputQueue.count==1&&h->inputQueue.events[0].type==RHG_KEY_UP);count++;
 h.testEligible=NO;[h input:(NSEvent*)event type:RHG_KEY_UP];assert(h.eligibilityCalls==2&&h.releases==1&&!h->pointer.captured&&h->inputQueue.count==1);count++;
 h.eligibilityCalls=h.releases=0;h->pointer.captured=true;reply=(RHGReply){.op=RHG_POLL};RHGFill(h,&reply);
 assert(h.eligibilityCalls==1&&h.releases==1&&!reply.pointerCaptured&&reply.eventCount==1&&reply.events[0].type==RHG_FOCUS&&!reply.events[0].keyCode&&!h->inputQueue.count);count++;
 arm(h);[h reconcilePointer];assert(h.eligibilityCalls==1&&!h.releases);h.testEligible=NO;[h reconcilePointer];assert(h.eligibilityCalls==2&&h.releases==1&&!h->pointer.captured);count++;
 arm(h);h.firstFrameAnnounced=NO;[h input:(NSEvent*)event type:RHG_KEY_UP];assert(h.eligibilityCalls==1&&h.releases==1&&!h->inputQueue.count);count++;
 arm(h);h.pointerEnabled=NO;[h reconcilePointer];assert(!h.eligibilityCalls&&h.releases==1);count++;
 RHGHost*measured=[RHGHost new];atomic_store(&measured->stopped,true);
 assert(![measured foregroundEligible]&&measured->performance.eligibility.count==1);count++;
 atomic_store(&measured->stopped,false);measured.pointerSuspended=YES;
 assert(![measured foregroundEligible]&&measured->performance.eligibility.count==2);count++;
 h.testEligible=NO;h.testWindowEligible=YES;h.overlayVisible=NO;
 assert(RHGVirtualPointerPolicyAllowed(h));count++;
 h.testWindowEligible=NO;assert(!RHGVirtualPointerPolicyAllowed(h));count++;
 h.overlayVisible=YES;assert(RHGVirtualPointerPolicyAllowed(h));count++;
 printf("{\"passed\":true,\"count\":%u,\"physicalCGCalls\":0,\"accountOrGameUsed\":false}\n",count);return 0;
}}
'''
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-eligibility-cpu-',dir=WORK/'tests'));run.chmod(0o700)
 paths=[ROOT/'Sources/ReadyHostedView/ReadyHostedView.m',ROOT/'Sources/ReadyHostedView/RHGInputMotion.h',ROOT/'Sources/ReadyHostedView/include/RHGPerformance.h',ROOT/'Sources/ReadyHostedView/include/ReadyHostedView.h',ROOT/'Sources/ReadyHostedView/RHGPointerState.h',ROOT/'Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h',pathlib.Path(__file__).resolve()]
 digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
 before={str(p.relative_to(ROOT)):digest(p)for p in paths}
 source=run/'eligibility.m';source.write_text(SOURCE);binary=run/'probe'
 result=subprocess.run(['clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(ROOT/'Sources/ReadyHostedView'),'-I',str(ROOT/'Sources/ReadyHostedView/include'),str(source),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-lbsm','-o',str(binary)],capture_output=True,text=True)
 (run/'build.log').write_text(result.stdout+result.stderr)
 if result.returncode:raise RuntimeError(result.stderr[-6000:])
 result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
 if result.returncode:raise RuntimeError(result.stderr[-3000:])
 report=json.loads(result.stdout);assert before=={str(p.relative_to(ROOT)):digest(p)for p in paths};report['sourceHashes']=before
 (run/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({**report,'report':str(run/'report.json')}))
if __name__=='__main__':main()
