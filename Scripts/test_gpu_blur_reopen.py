#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual production hook rearm and host epochs; fake GPU encoder and Mach ACK."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
HOST=r'''
#import "ReadyHostedView.m"
#include <assert.h>
@interface EpochHost:RHGHost
@property BOOL eligible;
@end
@implementation EpochHost
-(void)releasePointer{}
-(void)reconcilePointer{}
-(BOOL)foregroundEligible{return self.eligible&&!self.overlayVisible;}
@end
int main(void){@autoreleasepool{
 unsigned count=0;EpochHost*h=[EpochHost new];h.remoteMode=YES;h.firstFrameAnnounced=YES;h.overlayGPUBlurEnabled=YES;h.remoteContextID=12;
 for(unsigned i=0;i<20;i++){
  RHGHostSetOverlayVisible((__bridge RHGHostRef)h,true);assert(h.overlayEpoch==i*2+1);count++;
  RHGInput input=h->inputQueue.events[1];assert(input.type==RHG_OVERLAY_STATE&&input.modifiers==h.overlayEpoch&&input.keyCode==1&&input.button==1);count++;
  RHGRequest request={.surfaceID=12,.frameID=h.overlayEpoch};assert(RHGOverlayBlurReadyAllowed(h,&request));count++;
  request.frameID=h.overlayEpoch-2;assert(!RHGOverlayBlurReadyAllowed(h,&request));count++;
  request.frameID=h.overlayEpoch+2;assert(!RHGOverlayBlurReadyAllowed(h,&request));count++;
  RHGHostSetOverlayVisible((__bridge RHGHostRef)h,true);assert(h.overlayEpoch==i*2+1);count++;
  RHGHostSetOverlayVisible((__bridge RHGHostRef)h,false);request.frameID=h.overlayEpoch;assert(!RHGOverlayBlurReadyAllowed(h,&request));count++;
  assert(h->inputQueue.count==1&&h->inputQueue.events[0].modifiers==h.overlayEpoch&&!h->inputQueue.events[0].keyCode&&!h->inputQueue.events[0].button);count++;
 }
 h.eligible=YES;h.virtualX=.23;h.virtualY=.67;h.virtualAssociated=NO;h.virtualInitialized=YES;h.virtualHideCount=1;
 RHGHostSetOverlayVisible((__bridge RHGHostRef)h,true);
 h.virtualX=.5;h.virtualY=.5;h.virtualAssociated=YES;h.virtualHideCount=0;
 RHGHostSetOverlayVisible((__bridge RHGHostRef)h,false);
 assert(h.virtualX==.23&&h.virtualY==.67&&h.virtualAssociated&&h.virtualInitialized);count++;
 assert(h.virtualHideCount==0&&!h.overlayPointerSnapshotValid);count++;
 RHGReply reply={.op=RHG_POLL};RHGFill(h,&reply);
 assert(reply.eventCount==3&&reply.events[0].type==RHG_OVERLAY_STATE&&reply.events[1].type==RHG_FOCUS&&reply.events[1].keyCode==1);count++;
 assert(reply.events[2].type==RHG_MOUSE_MOVE&&reply.events[2].x==.23&&reply.events[2].y==.67&&!reply.events[2].deltaX&&!reply.events[2].deltaY);count++;
 assert(reply.pointerX==.23&&reply.pointerY==.67);count++;
 assert(reply.events[1].button==1&&reply.events[1].modifiers==42);count++;
 h.view=[[RHGView alloc]initWithFrame:NSMakeRect(0,0,1000,500)];h->pointer.captured=true;
 h.virtualX=.5;h.virtualY=.5;h.virtualAssociated=NO;
 RHGInput motion={.type=RHG_MOUSE_MOVE,.x=.9,.y=.9,.deltaX=10,.deltaY=-5,.timestamp=1};RHGInputQueuePush(&h->resumeInputQueue,motion);
 RHGRequest restore={.frameID=42};assert(RHGRestoreOverlayPointer(h,&restore));count++;
 assert(h.virtualX==.23&&h.virtualY==.67&&!h.virtualAssociated&&h->inputQueue.count==2);count++;
 assert(h->inputQueue.events[1].x==.23&&h->inputQueue.events[1].y==.67&&h->inputQueue.events[1].deltaX==10);count++;
 RHGHostSetOverlayVisible((__bridge RHGHostRef)h,true);RHGHostSetOverlayVisible((__bridge RHGHostRef)h,false);
 h.virtualX=.5;h.virtualY=.5;h.virtualAssociated=YES;RHGInputQueuePush(&h->resumeInputQueue,motion);restore.frameID=44;
 assert(RHGRestoreOverlayPointer(h,&restore)&&fabs(h.virtualX-.24)<1e-9&&fabs(h.virtualY-.66)<1e-9&&h.virtualAssociated);count++;
 restore.frameID=42;assert(!RHGRestoreOverlayPointer(h,&restore));count++;
 h->pointer.captured=false;assert(!RHGApplyVirtualPointerInput(h,&motion)&&fabs(h.virtualX-.24)<1e-9);count++;
 h.pointerInputNotBeforeTime=10;assert(!RHGInputBelongsToCurrentGame(h,RHG_MOUSE_MOVE,9)&&RHGInputBelongsToCurrentGame(h,RHG_MOUSE_MOVE,10));count++;
 assert(!RHGInputBelongsToCurrentGame(h,RHG_SCROLL,9)&&RHGInputBelongsToCurrentGame(h,RHG_KEY_DOWN,9));count++;
 EpochHost*t=[EpochHost new];t.remoteMode=YES;t.firstFrameAnnounced=YES;t.overlayGPUBlurEnabled=YES;t.remoteContextID=12;
 RHGHostSetOverlayVisible((__bridge RHGHostRef)t,true);t.overlayGPUPrepared=YES;
 assert(!RHGStartOverlayTransition(t,YES)&&t.overlayTransitionEpoch==0);count++;
 RHGHostSetOverlayUIReady((__bridge RHGHostRef)t,true);
 RHGOverlayTransition curve={0};uint64_t epoch=0;assert(RHGHostGetOverlayTransition((__bridge RHGHostRef)t,&curve,&epoch)&&epoch==1&&curve.to==1);count++;
 BOOL shared=NO;for(unsigned i=0;i<t->inputQueue.count;i++){RHGInput e=t->inputQueue.events[i];if(e.type==RHG_OVERLAY_ANIMATE)shared=e.timestamp==curve.began&&e.x==curve.from&&e.deltaX==curve.duration&&e.modifiers==epoch;}
 assert(shared);count++;
 t->overlayTransition=(RHGOverlayTransition){0,1,CACurrentMediaTime()-.12,.24};RHGOverlayTransition previous=t->overlayTransition;
 RHGHostRequestOverlayTransition((__bridge RHGHostRef)t,false);assert(t.overlayVisible&&!t.overlayDesiredVisible&&t.overlayEpoch==2&&t->overlayTransition.to==0);count++;
 assert(fabs(t->overlayTransition.from-RHGOverlayTransitionValue(previous,t->overlayTransition.began))<1e-9);count++;
 previous=CACurrentMediaTime()<t->overlayTransition.began?t->overlayPriorTransition:t->overlayTransition;RHGHostRequestOverlayTransition((__bridge RHGHostRef)t,true);assert(t.overlayVisible&&t.overlayEpoch==3&&t->overlayTransition.to==1);count++;
 assert(fabs(t->overlayTransition.from-RHGOverlayTransitionValue(previous,t->overlayTransition.began))<1e-9);count++;
 printf("{\"passed\":true,\"checks\":%u,\"openCloseCycles\":20,\"gameGPUOrScreenCaptureUsed\":false}\n",count);return 0;
}}
'''
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='gpu-blur-reopen-',dir=WORK/'tests'));run.chmod(0o700)
 shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';host=ROOT/'Sources/ReadyHostedView/ReadyHostedView.m';fixture=ROOT/'Synthetic/ReadyGPUBlurReopenProbe.m'
 files=[shim,host,fixture,pathlib.Path(__file__).resolve(),ROOT/'Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h',ROOT/'Sources/ReadyHostedView/include/RHGOverlayTransition.h'];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 source=shim.read_text().replace('__attribute__((constructor))static void rhgInstall(void)','static void rhgInstall(void)')
 start=source.index('static void rhgOverlayBlurAcknowledge(');end=source.index('static NSMutableArray *rhgOverlayBlurDrawables',start)
 stub='static void rhgOverlayBlurAcknowledge(uint32_t contextID,uint64_t epoch){(void)contextID;fixtureAckCount++;fixtureAckEpoch=epoch;}\n'
 source=source[:start]+stub+source[end:]
 marker='static RHGReply rhgExchange(uint32_t operation,RHGRequest fields) {'
 source=source.replace(marker,marker+'\n if(operation==RHG_POINTER_RESTORE&&fixtureInterceptRestore){if(!fixtureFocusCallbackSeen)abort();fixtureRestoreCalls++;fixtureRestoreEpoch=fields.frameID;return (RHGReply){.status=RHG_OK};}',1)
 source='#include <stdint.h>\n#include <stdbool.h>\nstatic unsigned fixtureAckCount,fixtureRestoreCalls;static uint64_t fixtureAckEpoch,fixtureRestoreEpoch;static bool fixtureInterceptRestore,fixtureFocusCallbackSeen;\n'+source+'\n'+fixture.read_text()
 (run/'guest.m').write_text(source);(run/'host.m').write_text(HOST)
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','RHG_','READY_','MTL_','Steam','STEAM'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/gpu-blur-reopen'))
 cases={};guest_command=None
 for case in ['guest','host']:
  command=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(ROOT/'Sources/ReadyHostedView/include'),'-I',str(ROOT/'Sources/ReadyHostedView'),'-I',str(ROOT/'NativeEmbedding'),str(run/(case+'.m')),'-framework','Cocoa','-framework','Metal','-framework','MetalPerformanceShaders','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-lbsm','-o',str(run/case)]
  if case=='guest':guest_command=command.copy()
  r=subprocess.run(command,env=env,capture_output=True,text=True,timeout=90);(run/(case+'-build.log')).write_text(r.stdout+r.stderr)
  if r.returncode:raise RuntimeError(case+' compile '+str(run)+'\n'+r.stderr[-3500:])
  r=subprocess.run([str(run/case)],env=env,capture_output=True,text=True,timeout=15);(run/(case+'-output.log')).write_text(r.stdout+r.stderr)
  if r.returncode:raise RuntimeError(case+' regression '+str(run)+'\n'+r.stderr[-2500:])
  cases[case]=json.loads(r.stdout);assert cases[case]['passed']
 # Restore the old "install only once" defect in the generated fixture. The
 # first activation works; the regression must fail when it tries to reopen.
 legacy=source.replace('IMP original=[rhgOriginals[key] pointerValue];\n        if(!original){','IMP original=[rhgOriginals[key] pointerValue];BOOL firstInstall=!original;\n        if(!original){',1).replace('if(current==original){','if(current==original&&firstInstall){',1)
 assert legacy!=source
 legacy_path=run/'legacy-rearm.m';legacy_path.write_text(legacy)
 command=[str(legacy_path)if x==str(run/'guest.m')else str(run/'legacy-rearm')if x==str(run/'guest')else x for x in guest_command]
 r=subprocess.run(command,env=env,capture_output=True,text=True,timeout=90);(run/'legacy-build.log').write_text(r.stdout+r.stderr)
 if r.returncode:raise RuntimeError('Negative control failed to compile '+r.stderr[-2000:])
 r=subprocess.run([str(run/'legacy-rearm')],env=env,capture_output=True,text=True,timeout=15);(run/'legacy-output.log').write_text(r.stdout+r.stderr)
 assert r.returncode==3,'The reopen regression did not detect the original defect'
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files}
 report={'passed':True,'cases':cases,'detectsOriginalRearmDefect':True,'sourceSHA256':before,'scope':'Real Objective-C method dispatch and production host state logic. Renderer and outgoing Mach ACK are fakes; no game, GPU execution, input, window or capture.'}
 p=run/'report.json';p.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'passed':True,'cases':cases,'report':str(p),'reportSHA256':sha(p)},indent=2))
if __name__=='__main__':main()
