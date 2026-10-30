// SPDX-License-Identifier: GPL-3.0-only
// Own CPU fixtures. No NSWindow, GPU, accounts or physical input are created.
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <libproc.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <unistd.h>

static _Atomic double fixtureClock=100;
static _Atomic unsigned fixtureSessionReads;
static _Atomic bool fixtureSessionReadOnMain;
static _Atomic bool fixtureSessionAllowed=true;
static _Atomic bool fixtureGateSession;
static dispatch_semaphore_t fixtureAuditEntered,fixtureAuditAllowed;
static double fixtureMediaTime(void){return atomic_load(&fixtureClock);}
static CFDictionaryRef fixtureSessionCopy(void){
 atomic_fetch_add(&fixtureSessionReads,1);
 if(NSThread.isMainThread)atomic_store(&fixtureSessionReadOnMain,true);
 BOOL allowed=atomic_load(&fixtureSessionAllowed);
 if(atomic_load(&fixtureGateSession)){dispatch_semaphore_signal(fixtureAuditEntered);dispatch_semaphore_wait(fixtureAuditAllowed,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));}
 if(!allowed)return NULL;
 return (__bridge_retained CFDictionaryRef)@{(__bridge id)kCGSessionOnConsoleKey:@YES,(__bridge id)kCGSessionLoginDoneKey:@YES,(__bridge id)kCGSessionUserIDKey:@(getuid())};
}

static int fixtureBlockedFD=-1;
static dispatch_semaphore_t fixtureWriteEntered,fixtureProducerReturned,fixtureQueuedRecords,fixtureWriteAllowed,fixtureWriteCompleted;
static _Atomic bool fixtureWriteOnMain,fixtureProducerBeatBlockedSink,fixtureFirstWrite;
static ssize_t(*fixtureOriginalWrite)(int,const void*,size_t)=write;
static ssize_t fixtureWrite(int fd,const void*bytes,size_t count){
 if(fd!=fixtureBlockedFD)return fixtureOriginalWrite(fd,bytes,count);
 if(NSThread.isMainThread)atomic_store(&fixtureWriteOnMain,true);
 bool expected=false;
 if(!atomic_compare_exchange_strong(&fixtureFirstWrite,&expected,true))return fixtureOriginalWrite(fd,bytes,count);
 dispatch_semaphore_signal(fixtureWriteEntered);
 dispatch_semaphore_wait(fixtureWriteAllowed,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
 ssize_t result=fixtureOriginalWrite(fd,bytes,count);
 dispatch_semaphore_signal(fixtureWriteCompleted);return result;
}

// Substitute only the read-only console provider, clock and owned diagnostic
// sink in this private compilation. All host producer/control logic is real.
#define CACurrentMediaTime fixtureMediaTime
#define CGSessionCopyCurrentDictionary fixtureSessionCopy
#define write fixtureWrite
#import "../Sources/ReadyHostedView/ReadyHostedView.m"
#undef write
#undef CGSessionCopyCurrentDictionary
#undef CACurrentMediaTime

@interface HotFixtureApp:NSObject
@property BOOL active;
@end
@implementation HotFixtureApp
-(BOOL)isActive{return self.active;}
@end
@interface HotFixtureWindow:NSObject
@property BOOL key,onSpace,miniaturized,visible;
@end
@implementation HotFixtureWindow
-(BOOL)isKeyWindow{return self.key;}
-(BOOL)isOnActiveSpace{return self.onSpace;}
-(BOOL)isMiniaturized{return self.miniaturized;}
-(NSWindowOcclusionState)occlusionState{return self.visible?NSWindowOcclusionStateVisible:0;}
-(NSInteger)windowNumber{return 7;}
-(CGFloat)backingScaleFactor{return 1;}
-(NSRect)convertRectToScreen:(NSRect)rect{return rect;}
@end
@interface HotFixtureView:NSObject
@property(nonatomic,weak)HotFixtureWindow *window;
@property BOOL hidden;
@end
@implementation HotFixtureView
-(BOOL)isHiddenOrHasHiddenAncestor{return self.hidden;}
-(NSRect)bounds{return NSMakeRect(0,0,640,480);}
-(NSRect)convertRect:(NSRect)rect toView:(NSView*)view{(void)view;return rect;}
@end
@interface HotFixtureProcess:NSObject
@property pid_t processIdentifier;
@end
@implementation HotFixtureProcess @end
@interface HotFixtureWorkspace:NSObject
@property(nonatomic,strong)HotFixtureProcess *frontmostApplication;
@end
@implementation HotFixtureWorkspace @end
static HotFixtureWorkspace *fixtureWorkspace;
static id fixtureSharedWorkspace(id type,SEL selector){(void)type;(void)selector;return fixtureWorkspace;}
@interface HotFixtureScreen:NSObject @end
@implementation HotFixtureScreen
-(NSRect)frame{return NSMakeRect(0,0,1920,1080);}
@end
static id fixtureScreens(id type,SEL selector){(void)type;(void)selector;return @[[HotFixtureScreen new]];}

static NSMutableDictionary<NSString*,NSNumber*> *fixtureChecks;
static void check(BOOL passed,NSString*name){fixtureChecks[name]=@(passed);if(!passed){fprintf(stderr,"failed: %s\n",name.UTF8String);exit(1);}}
static void pumpUntil(BOOL(^condition)(void)){
 double end=[NSDate timeIntervalSinceReferenceDate]+2;
 while(!condition()&&[NSDate timeIntervalSinceReferenceDate]<end)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
 check(condition(),@"boundedMainCallbackCompletion");
}

int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 64;fixtureChecks=[NSMutableDictionary new];
 NSString *root=[NSString stringWithUTF8String:argv[1]];
 NSApplication *previous=NSApp;HotFixtureApp *app=[HotFixtureApp new];app.active=YES;NSApp=(id)app;
 HotFixtureWindow *window=[HotFixtureWindow new];window.key=YES;window.onSpace=YES;window.visible=YES;
 HotFixtureView *view=[HotFixtureView new];view.window=window;
 fixtureWorkspace=[HotFixtureWorkspace new];fixtureWorkspace.frontmostApplication=[HotFixtureProcess new];fixtureWorkspace.frontmostApplication.processIdentifier=getpid();
 Method workspaceMethod=class_getClassMethod(NSWorkspace.class,@selector(sharedWorkspace));IMP originalWorkspace=method_setImplementation(workspaceMethod,(IMP)fixtureSharedWorkspace);
 Method screensMethod=class_getClassMethod(NSScreen.class,@selector(screens));IMP originalScreens=method_setImplementation(screensMethod,(IMP)fixtureScreens);
 RHGHost *host=[RHGHost new];host.window=(id)window;host.view=(id)view;
 check(![host foregroundEligible]&&atomic_load(&fixtureSessionReads)==0,@"unauditedSessionFailsClosedWithoutMainSystemQuery");
 for(unsigned i=0;i<1000;i++)[host refreshConsoleSession];
 pumpUntil(^BOOL{return !host.consoleSessionPending;});
 check(host.consoleSessionValid&&[host foregroundEligible]&&atomic_load(&fixtureSessionReads)==1&&!atomic_load(&fixtureSessionReadOnMain),@"auditCoalescesAndRunsConsoleProviderOffMain");
 unsigned before=atomic_load(&fixtureSessionReads);
 for(unsigned i=0;i<1000;i++){RHGReply reply={0};reply.op=RHG_POLL;RHGFill(host,&reply);[host input:nil type:RHG_MOUSE_MOVE];}
 check(atomic_load(&fixtureSessionReads)==before&&[host foregroundEligible],@"thousandActualPollFillsAndMouseGatesDoNotQueryConsole");
 app.active=NO;check(![host foregroundEligible],@"appResignationRevokesEvenWithFreshConsoleProof");app.active=YES;
 window.key=NO;check(![host foregroundEligible],@"keyResignationRevokesEvenWithFreshConsoleProof");window.key=YES;
 window.onSpace=NO;check(![host foregroundEligible],@"leavingSpaceRevokesEvenWithFreshConsoleProof");window.onSpace=YES;
 fixtureWorkspace.frontmostApplication.processIdentifier=getpid()+1;check(![host foregroundEligible],@"differentForegroundAppRevokesImmediately");fixtureWorkspace.frontmostApplication.processIdentifier=getpid();
 window.visible=NO;check(![host foregroundEligible],@"occlusionRevokesEvenWithFreshConsoleProof");window.visible=YES;
 view.hidden=YES;check(![host foregroundEligible],@"hiddenHostRevokesEvenWithFreshConsoleProof");view.hidden=NO;
 host.overlayVisible=YES;check(![host foregroundEligible],@"overlayRevokesEvenWithFreshConsoleProof");host.overlayVisible=NO;
 host.pointerFullscreenSuspended=YES;check(![host foregroundEligible],@"fullscreenTransitionRevokesImmediately");host.pointerFullscreenSuspended=NO;
 check([host foregroundEligible]&&atomic_load(&fixtureSessionReads)==before,@"freshWindowGatesStayIndependentOfConsoleAudit");
 atomic_store(&fixtureClock,100.36);check(![host foregroundEligible]&&atomic_load(&fixtureSessionReads)==before,@"expiredConsoleProofFailsClosedWithoutMainQuery");
 [host refreshConsoleSession];pumpUntil(^BOOL{return !host.consoleSessionPending;});check([host foregroundEligible],@"freshAuditRestoresExpiredConsoleProof");
 [host invalidateConsoleSession];check(![host foregroundEligible],@"sessionInvalidationRevokesBeforeAnotherAudit");
 atomic_store(&fixtureSessionAllowed,false);[host refreshConsoleSession];pumpUntil(^BOOL{return !host.consoleSessionPending;});check(!host.consoleSessionValid&&![host foregroundEligible],@"missingConsoleSessionProofStaysFailClosed");
 fixtureAuditEntered=dispatch_semaphore_create(0);fixtureAuditAllowed=dispatch_semaphore_create(0);atomic_store(&fixtureSessionAllowed,true);atomic_store(&fixtureGateSession,true);
 [host invalidateConsoleSession];[host refreshConsoleSession];check(dispatch_semaphore_wait(fixtureAuditEntered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,@"controlledAuditEntered");
 [host invalidateConsoleSession];atomic_store(&fixtureSessionAllowed,false);dispatch_semaphore_signal(fixtureAuditAllowed);
 unsigned priorReads=atomic_load(&fixtureSessionReads);pumpUntil(^BOOL{return atomic_load(&fixtureSessionReads)>priorReads;});
 check(!host.consoleSessionValid&&![host foregroundEligible],@"stalePositiveAuditCannotUndoLaterSessionInvalidation");
 dispatch_semaphore_signal(fixtureAuditAllowed);pumpUntil(^BOOL{return !host.consoleSessionPending;});atomic_store(&fixtureGateSession,false);
 check(!host.consoleSessionValid&&!atomic_load(&fixtureSessionReadOnMain),@"replacementAuditUsesCurrentConsoleStateOffMain");
 atomic_store(&host->stopped,true);before=atomic_load(&fixtureSessionReads);[host refreshConsoleSession];check(!host.consoleSessionPending&&atomic_load(&fixtureSessionReads)==before,@"stoppedHostCannotStartAnotherAudit");atomic_store(&host->stopped,false);

 fixtureWriteEntered=dispatch_semaphore_create(0);fixtureProducerReturned=dispatch_semaphore_create(0);fixtureQueuedRecords=dispatch_semaphore_create(0);fixtureWriteAllowed=dispatch_semaphore_create(0);fixtureWriteCompleted=dispatch_semaphore_create(0);
 NSString *path=[root stringByAppendingPathComponent:@"owned-diagnostic.jsonl"];
 fixtureBlockedFD=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fixtureBlockedFD<0)return 65;host.diagnosticFD=fixtureBlockedFD;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  BOOL entered=dispatch_semaphore_wait(fixtureWriteEntered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0;
  BOOL returned=entered&&dispatch_semaphore_wait(fixtureProducerReturned,dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC))==0;
  atomic_store(&fixtureProducerBeatBlockedSink,returned);dispatch_semaphore_wait(fixtureQueuedRecords,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));dispatch_semaphore_signal(fixtureWriteAllowed);
 });
 [host record:@"own-fixture-diagnostic" reason:nil];dispatch_semaphore_signal(fixtureProducerReturned);
 for(unsigned i=0;i<256;i++)[host record:@"own-fixture-backlog" reason:nil];
 check(atomic_load(&host->diagnosticPending)<=64,@"blockedDiagnosticBacklogHasHardBound");dispatch_semaphore_signal(fixtureQueuedRecords);
 check(dispatch_semaphore_wait(fixtureWriteCompleted,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,@"ownedDiagnosticEventuallyWritten");
 check(atomic_load(&fixtureProducerBeatBlockedSink)&&!atomic_load(&fixtureWriteOnMain),@"blockedDiagnosticSinkCannotBlockMainProducer");
 dispatch_sync(host.diagnosticQueue,^{});check(atomic_load(&host->diagnosticPending)==0,@"diagnosticCreditsReturnAfterOwnedWriterDrains");
 NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];NSArray *rows=[[text componentsSeparatedByString:@"\n"]filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString*row,NSDictionary*bindings){(void)bindings;return row.length>0;}]];
 check(rows.count==64,@"stalledWriterDropsExcessRecordsRatherThanRetainingUnboundedWork");
 NSDictionary *line=[NSJSONSerialization JSONObjectWithData:[rows.firstObject dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];check([line[@"phase"]isEqual:@"own-fixture-diagnostic"],@"asyncDiagnosticPreservesActualRecordPayload");
 host.diagnosticFD=-1;close(fixtureBlockedFD);fixtureBlockedFD=-1;
 method_setImplementation(workspaceMethod,originalWorkspace);method_setImplementation(screensMethod,originalScreens);NSApp=previous;
 NSDictionary *report=@{@"passed":@YES,@"count":@(fixtureChecks.count),@"checks":fixtureChecks,@"realWindowCreated":@NO,@"GPUAccountGameOrPhysicalInputUsed":@NO,@"globalUIStateChanged":@NO};
 NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
 }return 0;}
