// SPDX-License-Identifier: GPL-3.0-only
// The launcher exports its actual drawable storage. No host Metal queue,
// command buffer, encoder, image copy or pixel readback is created here.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <IOSurface/IOSurface.h>
#import <servers/bootstrap.h>
#import <bsm/libbsm.h>
#import <libproc.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>
#import "ReadyHostedView.h"
#import "ReadyHostedGameProtocol.h"
#import "RHGInputMotion.h"
#import "RHGScrollEvent.h"
#import "RHGPerformance.h"
typedef struct {
 RHGPerfStats mainDispatch[RHG_PERF_OPERATIONS],service[RHG_PERF_OPERATIONS];
 RHGPerfStats nextDrawable,presentCall,eligibility,requestedMinimumDuration;
 uint64_t presentModes[3];
 RHGPerfPresentation presentation;
} RHGHostPerformance;
@interface RHGRenderSlot:NSObject
@property(nonatomic,strong)id<CAMetalDrawable> drawable;
@property(nonatomic,strong)CAMetalLayer *layer;
@property uint64_t frameID,generation;
@property uint32_t surfaceID;
@end
@implementation RHGRenderSlot @end
@interface RHGAcquireOperation:NSObject {
@public RHGReply response;
@public uint64_t serviceBegan;
}
@property(nonatomic,strong)CAMetalLayer *layer;
@property(nonatomic)uint64_t generation,frameID;
@end
@implementation RHGAcquireOperation
-(void)dealloc{if(response.h.msgh_remote_port)mach_msg_destroy(&response.h);}
@end
@protocol RHGRemoteLayerHosting <NSObject>
@property(nonatomic)uint32_t contextId;
@end
@class RHGHost;
static void RHGCancelPendingAcquire(RHGHost*host);
@interface RHGView:NSView
@property(nonatomic,weak)RHGHost *owner;
@end
@interface RHGHost:NSObject {
@public uint8_t nonce[RHG_NONCE_BYTES];
@public _Atomic bool stopped;
@public RHGPointerState pointer;
@public RHGInputQueue inputQueue; // Accessed only on the host main thread.
@public RHGInputQueue resumeInputQueue;
@public RHGVirtualPointer overlayPointerSnapshot;
@public RHGVirtualPointer overlayPointerResumeSnapshot;
@public RHGOverlayTransition overlayTransition;
@public RHGOverlayTransition overlayPriorTransition;
@public os_unfair_lock perfLock;
@public RHGHostPerformance performance;
@public _Atomic bool perfWritePending;
@public _Atomic unsigned diagnosticPending;
}
@property(nonatomic,weak)NSWindow *window;
@property(nonatomic,strong)RHGView *view;
@property(nonatomic,strong)CAMetalLayer *metal;
/* Experimental remote transport owns only a CALayerHost, never producer drawables. */
@property(nonatomic,strong)CALayer<RHGRemoteLayerHosting> *remoteLayer;
@property(nonatomic)BOOL remoteMode;
@property(nonatomic)BOOL remoteTraceEnabled;
@property(nonatomic)unsigned remoteTraceRows;
@property(nonatomic)double remoteTraceLastAt;
@property(nonatomic,copy)NSDictionary *remoteStartupSnapshot;
@property(nonatomic)uint32_t remoteContextID,remoteWidth,remoteHeight,remotePixelFormat;
@property(nonatomic)uint64_t remoteDeviceRegistryID;
@property(nonatomic,strong)id<MTLDevice> device;
@property(nonatomic,strong)id<CAMetalDrawable> drawable; // Alias only during present/legacy inspection.
@property(nonatomic,strong)NSMutableArray<RHGRenderSlot*> *slots;
@property(nonatomic,strong)RHGAcquireOperation *pendingAcquire;
@property(nonatomic,strong)dispatch_queue_t acquireQueue;
@property(nonatomic)BOOL acquirePending;
@property(nonatomic)uint32_t pipelineDepth;
@property(nonatomic)uint64_t configurationGeneration;
@property(nonatomic)BOOL renderNegotiated;
@property(nonatomic,copy)NSString *service,*nonceString,*expectedExecutable;
@property(atomic)mach_port_t port;
@property(atomic)pid_t guestPID;
@property(nonatomic)uint64_t guestBirthSeconds,guestBirthMicroseconds;
@property(nonatomic)uint64_t frameID;
@property(nonatomic)uint32_t surfaceID;
@property(nonatomic)NSUInteger frames,acquires,requests;
@property(nonatomic)BOOL inputTraceEnabled;
@property(nonatomic)uint64_t scrollReceived,scrollPreciseReceived,scrollEligibilityDropped,scrollQueued,scrollDelivered;
@property(nonatomic)BOOL configured,metalHUD,lastFocus,firstFrameAnnounced;
@property(nonatomic,assign)RHGHostFirstFrameCallback firstFrameCallback;
@property(nonatomic,assign)void *firstFrameContext;
@property(nonatomic)int diagnosticFD;
@property(nonatomic,strong)NSLock *diagnosticLock;
@property(nonatomic,strong)dispatch_queue_t diagnosticQueue;
@property(nonatomic)BOOL consoleSessionValid,consoleSessionPending;
@property(nonatomic)double consoleSessionChecked;
@property(nonatomic)uint64_t consoleSessionEpoch;
@property(nonatomic)double began;
@property(nonatomic)BOOL overlayVisible;
@property(nonatomic)BOOL overlayGPUBlurEnabled,overlayBlurReady;
@property(nonatomic)BOOL overlayGPUPrepared;
@property(nonatomic)uint64_t overlayEpoch;
@property(nonatomic)uint64_t overlayTransitionEpoch;
@property(nonatomic)BOOL overlayUIReady,overlayDesiredVisible;
@property(nonatomic)BOOL overlayPointerSnapshotValid;
@property(nonatomic)uint64_t pendingPointerRestoreEpoch;
@property(nonatomic)double pointerInputNotBeforeTime;
@property(nonatomic)unsigned resumeMotionTraceBudget,resumeWarpTraceBudget;
@property(nonatomic,copy)NSDictionary *resumeInputTrace;
@property(nonatomic,assign)RHGHostOverlayBlurReadyCallback overlayBlurReadyCallback;
@property(nonatomic,assign)void *overlayBlurReadyContext;
@property(nonatomic,weak)NSView *overlayBlurPlaceholder;
@property(nonatomic)BOOL pointerEnabled,pointerSuspended,pointerFullscreenSuspended,pointerRetryBlocked,virtualAssociated,virtualInitialized,virtualHiddenUntilMove;
@property(nonatomic)uint32_t virtualHideCount;
@property(nonatomic)double virtualX,virtualY;
@property(nonatomic,strong)NSTimer *pointerTimer;
@property(nonatomic,strong)NSMutableArray *pointerObservers;
-(void)record:(NSString*)phase reason:(NSString*)reason;
-(void)traceRemoteStartup:(NSString*)stage;
-(void)input:(NSEvent*)event type:(uint32_t)type;
-(void)shutdown;
-(BOOL)foregroundEligible;
-(BOOL)foregroundWindowEligible;
-(BOOL)readConsoleSessionProof;
-(BOOL)consoleSessionAllowed;
-(void)invalidateConsoleSession;
-(void)refreshConsoleSession;
-(void)perfInterval:(RHGPerfStats*)metric begin:(uint64_t)begin end:(uint64_t)end;
-(void)profileSnapshot;
-(void)observePresentedTime:(double)time;
-(void)writeDiagnostic:(NSData*)line;
-(void)reconcilePointer;
-(void)reconcilePointerWithEligibility:(BOOL)eligible;
-(void)releasePointer;
@end
static BOOL RHGInputBelongsToCurrentGame(RHGHost*host,uint32_t type,double timestamp){
 BOOL pointer=type==RHG_MOUSE_MOVE||type==RHG_MOUSE_DOWN||type==RHG_MOUSE_UP||type==RHG_SCROLL;
 return !pointer||(isfinite(timestamp)&&timestamp>=host.pointerInputNotBeforeTime);
}
static BOOL RHGApplyVirtualPointerInput(RHGHost*host,RHGInput*input){
 BOOL pointer=input->type==RHG_MOUSE_MOVE||input->type==RHG_MOUSE_DOWN||input->type==RHG_MOUSE_UP||input->type==RHG_SCROLL;
 if(!pointer)return YES;
 // An uncaptured physical/Ready coordinate must never become a game position.
 if(!host->pointer.captured)return NO;
 if(input->type==RHG_MOUSE_MOVE){
  RHGVirtualPointer value={host.virtualAssociated,host.virtualInitialized,host.virtualHiddenUntilMove,host.virtualHideCount,host.virtualX,host.virtualY};
  if(!RHGInputPointerMove(&value,input->deltaX,input->deltaY,host.view.bounds.size.width,host.view.bounds.size.height))return NO;
  host.virtualX=value.x;host.virtualY=value.y;host.virtualHiddenUntilMove=value.hiddenUntilMove;
 }
 input->x=host.virtualX;input->y=host.virtualY;return YES;
}
static void RHGTraceResumeInput(RHGHost*host,RHGInput input,NSString*stage,double sourceX,double sourceY,BOOL warp){
 if(!host.inputTraceEnabled)return;
 if(warp){if(!host.resumeWarpTraceBudget)return;host.resumeWarpTraceBudget--;}
 else{if(!host.resumeMotionTraceBudget)return;host.resumeMotionTraceBudget--;}
 host.resumeInputTrace=@{@"eventType":@(input.type),@"timestamp":@(input.timestamp),@"deltaX":@(input.deltaX),@"deltaY":@(input.deltaY),@"sourceX":@(sourceX),@"sourceY":@(sourceY),@"eventX":@(input.x),@"eventY":@(input.y),@"virtualX":@(host.virtualX),@"virtualY":@(host.virtualY),@"associated":@(host.virtualAssociated),@"captured":@(host->pointer.captured),@"restorePending":@(host.pendingPointerRestoreEpoch)};
 [host record:@"input-resume-trace" reason:stage];host.resumeInputTrace=nil;
}
// Retired drawable pools cannot be reused while the authenticated producer may
// still have GPU writes in flight. This path runs only after stop, never per frame.
static BOOL RHGReadPeerBirth(pid_t pid,uint64_t *seconds,uint64_t *microseconds){
 struct proc_bsdinfo info={0};int size=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof info);
 if(size!=sizeof info||!info.pbi_start_tvsec)return NO;
 *seconds=info.pbi_start_tvsec;*microseconds=info.pbi_start_tvusec;return YES;
}
typedef NS_ENUM(uint32_t,RHGPeerLife){RHGPeerUnknown,RHGPeerSame,RHGPeerGone};
static RHGPeerLife RHGPeerLifeState(pid_t pid,uint64_t seconds,uint64_t microseconds){
 if(pid<=0||!seconds)return RHGPeerUnknown;
 struct proc_bsdinfo info={0};errno=0;int size=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof info);
 if(size==sizeof info)return info.pbi_start_tvsec==seconds&&info.pbi_start_tvusec==microseconds?RHGPeerSame:RHGPeerGone;
 return errno==ESRCH||errno==ENOENT?RHGPeerGone:RHGPeerUnknown;
}
@interface RHGRetiredRenderPool:NSObject
@property(nonatomic,strong)NSArray<RHGRenderSlot*> *resources;
@property(nonatomic,strong)dispatch_source_t processExit,timer;
@property(nonatomic)pid_t peer;
@property(nonatomic)uint64_t birthSeconds,birthMicroseconds;
@property(nonatomic)BOOL finished;
-(void)finish;
@end
static NSMutableSet<RHGRetiredRenderPool*> *RHGRetiredPools;
static dispatch_queue_t RHGRetirementQueue(void){
 static dispatch_queue_t queue;static dispatch_once_t once;
 dispatch_once(&once,^{queue=dispatch_queue_create("app.ready.hosted.retired-pools",DISPATCH_QUEUE_SERIAL);});return queue;
}
@implementation RHGRetiredRenderPool
-(void)finish{
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self finish];});return;}
 if(self.finished)return;self.finished=YES;
 if(self.processExit){dispatch_source_cancel(self.processExit);self.processExit=nil;}
 if(self.timer){dispatch_source_cancel(self.timer);self.timer=nil;}
 // The layer is retained by each slot, so releasing retired drawables cannot
 // return their surfaces to any active/new host's pool.
 self.resources=nil;[RHGRetiredPools removeObject:self];
}
@end
static NSUInteger RHGRetiredSlotCount(void){NSUInteger count=0;for(RHGRetiredRenderPool *pool in RHGRetiredPools)count+=pool.resources.count;return count;}
static NSUInteger RHGPendingAcquisitionCount; // Main-owned, including stopped workers until nextDrawable returns.
static BOOL RHGHasRetiredPool(void){return RHGRetiredPools.count>0||RHGPendingAcquisitionCount>0;}
static void RHGRetireRenderSlots(NSArray<RHGRenderSlot*> *slots,pid_t peer,uint64_t seconds,uint64_t microseconds){
 if(!slots.count||RHGPeerLifeState(peer,seconds,microseconds)==RHGPeerGone)return;
 // Normal use has one session. Refuse another host while this bounded pool is
 // awaiting its producer's exit rather than accumulating retained GPU pools.
 if(!RHGRetiredPools)RHGRetiredPools=[NSMutableSet new];
 RHGRetiredRenderPool *pool=[RHGRetiredRenderPool new];pool.resources=[slots copy];pool.peer=peer;pool.birthSeconds=seconds;pool.birthMicroseconds=microseconds;
 [RHGRetiredPools addObject:pool];dispatch_queue_t queue=RHGRetirementQueue();
 if(peer>0){
  pool.processExit=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,(uintptr_t)peer,DISPATCH_PROC_EXIT,queue);
  if(pool.processExit){dispatch_source_set_event_handler(pool.processExit,^{[pool finish];});dispatch_resume(pool.processExit);}
 }
 // Covers an exit during registration/PID reuse; unknown errors conservatively
 // retain the pool. Polling exists only for a stopped, outstanding session.
 pool.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
 dispatch_source_set_timer(pool.timer,dispatch_time(DISPATCH_TIME_NOW,0),250*NSEC_PER_MSEC,25*NSEC_PER_MSEC);
 dispatch_source_set_event_handler(pool.timer,^{if(RHGPeerLifeState(pool.peer,pool.birthSeconds,pool.birthMicroseconds)==RHGPeerGone)[pool finish];});dispatch_resume(pool.timer);
}

static RHGHost *RHGPointerOwner;
static int32_t RHGAssociate(bool connected,void*context){(void)context;return CGAssociateMouseAndMouseCursorPosition(connected);}
// AppKit must own the hide too: a raw CG hide leaves its cursor bookkeeping
// unaware and gesture dispatch can restore the arrow over the anchored point.
// Exactly one hide/unhide pair belongs to a capture; never show/hide per packet.
static int32_t RHGHide(void*context){(void)context;[NSCursor hide];return kCGErrorSuccess;}
static int32_t RHGShow(void*context){(void)context;[NSCursor unhide];return kCGErrorSuccess;}
static int32_t RHGAnchor(void*context){
 RHGHost*host=(__bridge RHGHost*)context;NSRect rect=[host.window convertRectToScreen:[host.view convertRect:host.view.bounds toView:nil]];
 NSPoint cursor=NSEvent.mouseLocation;
 RHGPointerAnchorPlan plan=RHGPlanPointerAnchor(cursor.x,cursor.y,rect.origin.x,rect.origin.y,rect.size.width,rect.size.height);
 if(!plan.valid)return kCGErrorIllegalArgument;
 // Disassociation already freezes the physical point. Warping an in-window
 // point to the center contaminated the first NSEvent delta after the overlay.
 if(host.inputTraceEnabled)[host record:@"pointer-anchor" reason:plan.warp?@"moved-into-game-window":@"kept-current-position"];
 if(!plan.warp)return kCGErrorSuccess;
 CGPoint point=CGPointMake(plan.x,NSMaxY(NSScreen.screens.firstObject.frame)-plan.y);
 return CGWarpMouseCursorPosition(point);
}
static RHGPointerOps RHGOps(RHGHost*host){return (RHGPointerOps){RHGAssociate,RHGHide,RHGShow,RHGAnchor,(__bridge void*)host};}
static void RHGMainSync(dispatch_block_t block){if(NSThread.isMainThread)block();else dispatch_sync(dispatch_get_main_queue(),block);}
static BOOL RHGInputTraceEnabled(void){static BOOL enabled;static dispatch_once_t once;dispatch_once(&once,^{const char*value=getenv("RHG_INPUT_TRACE");enabled=value&&strcmp(value,"1")==0;});return enabled;}
static BOOL RHGRemoteTraceEnabled(void){const char*value=getenv("RHG_REMOTE_TRACE");return value&&strcmp(value,"1")==0;}
static id RHGTraceNumber(double value){return isfinite(value)?@(value):NSNull.null;}
static NSArray*RHGTraceRect(CGRect rect){return @[RHGTraceNumber(rect.origin.x),RHGTraceNumber(rect.origin.y),RHGTraceNumber(rect.size.width),RHGTraceNumber(rect.size.height)];}
static NSDictionary*RHGTraceLayer(CALayer*layer){return @{@"frame":RHGTraceRect(layer.frame),@"bounds":RHGTraceRect(layer.bounds),@"opacity":RHGTraceNumber(layer.opacity),@"hidden":@(layer.hidden),@"masksToBounds":@(layer.masksToBounds),@"contentsScale":RHGTraceNumber(layer.contentsScale)};}
static BOOL RHGFormat(uint32_t format){return format==MTLPixelFormatBGRA8Unorm||format==MTLPixelFormatBGRA8Unorm_sRGB||format==MTLPixelFormatRGBA8Unorm||format==MTLPixelFormatRGBA8Unorm_sRGB||format==MTLPixelFormatRGB10A2Unorm||format==MTLPixelFormatRGBA16Float;}
@implementation RHGView
-(CALayer*)makeBackingLayer{return self.owner.remoteMode?[NSClassFromString(@"CALayerHost") new]:[super makeBackingLayer];}
-(BOOL)acceptsFirstResponder{return YES;}
-(BOOL)isOpaque{return YES;}
-(BOOL)isFlipped{return YES;}
-(void)updateTrackingAreas{for(NSTrackingArea*t in self.trackingAreas)[self removeTrackingArea:t];[self addTrackingArea:[[NSTrackingArea alloc]initWithRect:self.bounds options:NSTrackingMouseMoved|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil]];[super updateTrackingAreas];}
-(void)keyDown:(NSEvent*)e{[self.owner input:e type:RHG_KEY_DOWN];}
-(void)keyUp:(NSEvent*)e{[self.owner input:e type:RHG_KEY_UP];}
-(void)flagsChanged:(NSEvent*)e{[self.owner input:e type:RHG_FLAGS];}
-(void)mouseMoved:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_MOVE];}
-(void)mouseDragged:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_MOVE];}
-(void)rightMouseDragged:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_MOVE];}
-(void)otherMouseDragged:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_MOVE];}
-(void)mouseDown:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_DOWN];}
-(void)mouseUp:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_UP];}
-(void)rightMouseDown:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_DOWN];}
-(void)rightMouseUp:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_UP];}
-(void)otherMouseDown:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_DOWN];}
-(void)otherMouseUp:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_UP];}
-(void)scrollWheel:(NSEvent*)e{[self.owner input:e type:RHG_SCROLL];}
@end
@implementation RHGHost
-(instancetype)init{if((self=[super init])){atomic_init(&stopped,false);atomic_init(&perfWritePending,false);atomic_init(&diagnosticPending,0);perfLock=(os_unfair_lock)OS_UNFAIR_LOCK_INIT;_diagnosticFD=-1;_diagnosticLock=[NSLock new];_diagnosticQueue=dispatch_queue_create("app.ready.hosted.diagnostics",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));_acquireQueue=dispatch_queue_create("app.ready.hosted.acquire",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));_slots=[NSMutableArray new];_pipelineDepth=RHG_MAX_FRAMES_IN_FLIGHT;_configurationGeneration=1;_pointerObservers=[NSMutableArray new];_virtualAssociated=YES;_virtualX=_virtualY=.5;_began=CACurrentMediaTime();_inputTraceEnabled=RHGInputTraceEnabled();_remoteTraceEnabled=RHGRemoteTraceEnabled();}return self;}
-(void)dealloc{[_pointerTimer invalidate];for(NSArray*pair in _pointerObservers)[pair[0]removeObserver:pair[1]];if(_diagnosticFD>=0)close(_diagnosticFD);if(_port)mach_port_destroy(mach_task_self(),_port);}
-(void)record:(NSString*)phase reason:(NSString*)reason{
 if(self.diagnosticFD<0)return;
 if(atomic_fetch_add(&diagnosticPending,1)>=64){atomic_fetch_sub(&diagnosticPending,1);return;}
 NSMutableDictionary*v=[@{@"schema":@1,@"phase":phase,@"elapsedMilliseconds":@((CACurrentMediaTime()-self.began)*1000),@"hostPID":@(getpid()),@"guestPID":@(self.guestPID),@"window":@(self.window.windowNumber),@"frames":@(self.frames),@"acquires":@(self.acquires),@"requests":@(self.requests),@"hostCommandQueues":@0,@"hostCommandBuffers":@0,@"hostEncoders":@0,@"applicationSurfaceCopies":@0,@"pixelReadbacks":@0,@"metalHUDRequested":@(self.metalHUD),@"presentsWithTransaction":@(self.metal.presentsWithTransaction)}mutableCopy];
 if(reason)v[@"reason"]=reason;
 if(self.resumeInputTrace)v[@"input"]=self.resumeInputTrace;
 if([phase hasPrefix:@"overlay-"])v[@"overlayEpoch"]=@(self.overlayEpoch);
 if([phase isEqualToString:@"overlay-transition"]){v[@"transitionStart"]=@(self->overlayTransition.began);v[@"transitionDuration"]=@(self->overlayTransition.duration);v[@"transitionFrom"]=@(self->overlayTransition.from);v[@"transitionTo"]=@(self->overlayTransition.to);}
 if([phase isEqualToString:@"pointer-overlay-restored"]){v[@"overlayEpoch"]=@(self.overlayEpoch);v[@"virtualPointerX"]=@(self.virtualX);v[@"virtualPointerY"]=@(self.virtualY);v[@"virtualAssociated"]=@(self.virtualAssociated);}
 if(self.inputTraceEnabled){v[@"inputTraceEnabled"]=@YES;v[@"scrollReceived"]=@(self.scrollReceived);v[@"scrollPreciseReceived"]=@(self.scrollPreciseReceived);v[@"scrollEligibilityDropped"]=@(self.scrollEligibilityDropped);v[@"scrollQueued"]=@(self.scrollQueued);v[@"scrollDelivered"]=@(self.scrollDelivered);}
 v[@"outstandingFrames"]=@(self.slots.count);v[@"maximumFramesInFlight"]=@(self.pipelineDepth);
 v[@"pendingAcquire"]=@(self.acquirePending);v[@"remoteLayerTransport"]=@(self.remoteMode);
 if(self.remoteContextID&&![phase isEqualToString:@"remote-startup-trace"])v[@"remoteContextID"]=@(self.remoteContextID);
 if([phase isEqualToString:@"remote-startup-trace"]&&self.remoteStartupSnapshot)v[@"startup"]=self.remoteStartupSnapshot;
 if(self.surfaceID)v[@"surfaceID"]=@(self.surfaceID);
 v[@"pointerEnabled"]=@(self.pointerEnabled);v[@"pointerCaptured"]=@(self->pointer.captured);v[@"pointerCleanupPending"]=@(self->pointer.detached||self->pointer.hidden);
 v[@"pointerError"]=@(self->pointer.error);
 v[@"pointerAnchored"]=@(self->pointer.anchored);
 if([phase hasPrefix:@"pointer-"]){v[@"cursorVisibleReported"]=@(CGCursorIsVisible());v[@"cursorVisibilityQueryDeprecated"]=@YES;}
 NSDictionary *snapshot=[v copy];__weak RHGHost *weak=self;
 dispatch_async(self.diagnosticQueue,^{@autoreleasepool{
  RHGHost *host=weak;if(!host)return;
  @try{NSData*d=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:nil];if(d){NSMutableData*line=[d mutableCopy];[line appendBytes:"\n" length:1];[host writeDiagnostic:line];}}
  @finally{atomic_fetch_sub(&host->diagnosticPending,1);}
 }});
}
// Opt-in bounded startup diagnostics only. All AppKit/layer reads stay on Main;
// serialization and writes use the existing bounded asynchronous journal.
-(void)traceRemoteStartup:(NSString*)stage{
 if(!self.remoteMode||!self.remoteTraceEnabled||self.diagnosticFD<0||self.firstFrameAnnounced||!self.remoteContextID||atomic_load(&stopped)||self.remoteTraceRows>=8)return;
 double now=CACurrentMediaTime();if(self.remoteTraceRows&&now-self.remoteTraceLastAt<.1)return;
 self.remoteTraceLastAt=now;self.remoteTraceRows++;
 @try{
  NSMutableArray*ancestors=[NSMutableArray new];CALayer*node=self.remoteLayer;
  for(unsigned depth=0;node&&depth<6;depth++,node=node.superlayer)[ancestors addObject:RHGTraceLayer(node)];
  NSMutableArray*subviews=[NSMutableArray new];NSArray<NSView*>*children=self.view.subviews;
  for(NSUInteger i=0;i<MIN((NSUInteger)8,children.count);i++){
   NSView*child=children[i];[subviews addObject:@{@"alphaValue":RHGTraceNumber(child.alphaValue),@"hidden":@(child.hidden),@"hiddenByAncestor":@(child.isHiddenOrHasHiddenAncestor),@"frame":RHGTraceRect(child.frame),@"hasLayer":@(child.layer!=nil),@"layer":child.layer?RHGTraceLayer(child.layer):@{}}];
  }
  pid_t foreground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  self.remoteStartupSnapshot=@{@"row":@(self.remoteTraceRows),@"stage":stage,@"viewWindowMatches":@(self.view.window==self.window),@"windowContentIsView":@(self.window.contentView==self.view),@"viewLayerIsRemoteLayer":@(self.view.layer==self.remoteLayer),@"viewLayerIsCALayerHost":@([self.view.layer isKindOfClass:NSClassFromString(@"CALayerHost")]),@"remoteContextMatches":@(self.remoteLayer.contextId==self.remoteContextID),@"viewAlphaValue":RHGTraceNumber(self.view.alphaValue),@"viewHidden":@(self.view.hidden),@"viewHiddenByAncestor":@(self.view.isHiddenOrHasHiddenAncestor),@"viewFrame":RHGTraceRect(self.view.frame),@"viewBounds":RHGTraceRect(self.view.bounds),@"remoteLayerAncestors":ancestors,@"ancestorChainTruncated":@(node!=nil),@"directSubviews":subviews,@"subviewsTruncated":@(children.count>8),@"windowVisible":@(self.window.visible),@"windowKey":@(self.window.isKeyWindow),@"windowOnActiveSpace":@(self.window.isOnActiveSpace),@"windowOcclusionVisible":@((self.window.occlusionState&NSWindowOcclusionStateVisible)!=0),@"applicationActive":@(NSApp.isActive),@"frontmostIsHost":@(foreground==getpid()),@"frontmostIsAttestedGuest":@(self.guestPID>0&&foreground==self.guestPID)};
  [self record:@"remote-startup-trace" reason:nil];self.remoteStartupSnapshot=nil;
 }@catch(NSException*exception){self.remoteStartupSnapshot=@{@"row":@(self.remoteTraceRows),@"stage":stage,@"exceptionName":exception.name};[self record:@"remote-startup-trace" reason:@"diagnostic-unavailable"];self.remoteStartupSnapshot=nil;}
}
-(void)writeDiagnostic:(NSData*)line{
 [self.diagnosticLock lock];const uint8_t*b=line.bytes;size_t offset=0;
 while(offset<line.length){ssize_t n=write(self.diagnosticFD,b+offset,line.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0)break;offset+=(size_t)n;}
 [self.diagnosticLock unlock];
}
-(void)perfInterval:(RHGPerfStats*)metric begin:(uint64_t)begin end:(uint64_t)end{
 if(!begin)return;os_unfair_lock_lock(&perfLock);RHGPerfInterval(metric,begin,end);os_unfair_lock_unlock(&perfLock);
}
-(void)observePresentedTime:(double)time{
 os_unfair_lock_lock(&perfLock);RHGPerfObservePresentation(&performance.presentation,time);os_unfair_lock_unlock(&perfLock);
}
-(void)profileSnapshot{
 if(!RHGPerfProfileEnabled()||atomic_exchange(&perfWritePending,true))return;
 os_unfair_lock_lock(&perfLock);RHGHostPerformance snapshot=performance;os_unfair_lock_unlock(&perfLock);
 NSUInteger frameCount=self.frames;BOOL usesTransaction=self.metal.presentsWithTransaction,displaySync=self.metal.displaySyncEnabled;
 double elapsedMilliseconds=(CACurrentMediaTime()-self.began)*1000;pid_t guestPID=self.guestPID;
 static dispatch_queue_t writer;static dispatch_once_t once;
 dispatch_once(&once,^{writer=dispatch_queue_create("app.ready.hosted.host-perf-writer",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));});
 dispatch_async(writer,^{@autoreleasepool{
  NSMutableDictionary *operations=[NSMutableDictionary new];
  for(unsigned op=0;op<RHG_PERF_OPERATIONS;op++)if(snapshot.service[op].count){operations[RHGPerfOperationName(op)]=@{@"mainDispatchWait":RHGPerfStatsJSON(&snapshot.mainDispatch[op]),@"service":RHGPerfStatsJSON(&snapshot.service[op])};}
  NSDictionary *value=@{@"type":@"hosted-host-performance",@"schema":@1,@"presentCalls":@(frameCount),@"elapsedMilliseconds":@(elapsedMilliseconds),@"hostPID":@(getpid()),@"guestPID":@(guestPID),@"unit":@"nanoseconds",@"clock":@"mach_continuous_time",@"quantiles":@"log2-bucket-upper-bounds",@"maximumOutstandingFrames":@(self.pipelineDepth),@"hostLayerDisplaySyncEnabled":@(displaySync),@"nextDrawableOffMain":@YES,@"operations":operations,
   @"nextDrawable":RHGPerfStatsJSON(&snapshot.nextDrawable),@"presentCall":RHGPerfStatsJSON(&snapshot.presentCall),@"foregroundEligibility":RHGPerfStatsJSON(&snapshot.eligibility),@"displayPresentation":RHGPerfPresentationJSON(&snapshot.presentation),@"presentModeCounts":@{@"normal":@(snapshot.presentModes[RHG_PRESENT_NORMAL]),@"atTime":@(snapshot.presentModes[RHG_PRESENT_AT_TIME]),@"minimumDuration":@(snapshot.presentModes[RHG_PRESENT_MIN_DURATION])},@"requestedMinimumDuration":RHGPerfStatsJSON(&snapshot.requestedMinimumDuration),@"hostGPUCommandBuffers":@0,@"applicationSurfaceCopies":@0,@"hostCommandQueues":@0,@"hostCommandBuffers":@0,@"hostEncoders":@0,@"pixelReadbacks":@0,@"presentsWithTransaction":@(usesTransaction)};
  NSData *json=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
  if(json&&json.length<=65536){NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];[self writeDiagnostic:line];}
  atomic_store(&self->perfWritePending,false);
 }});
}
-(BOOL)foregroundWindowEligible {
 if(atomic_load(&stopped)||self.overlayVisible||self.pointerSuspended||self.pointerFullscreenSuspended||!self.window||self.view.window!=self.window||self.view.isHiddenOrHasHiddenAncestor||!NSApp.isActive||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=getpid()||!self.window.isKeyWindow||!self.window.isOnActiveSpace||self.window.isMiniaturized||!(self.window.occlusionState&NSWindowOcclusionStateVisible))return NO;
 if(self.guestPID>0){char path[PROC_PIDPATHINFO_MAXSIZE]={0};if(proc_pidpath(self.guestPID,path,sizeof path)<=0||strcmp(path,self.expectedExecutable.fileSystemRepresentation))return NO;}
 return YES;
}
-(BOOL)readConsoleSessionProof {
 CFDictionaryRef session=CGSessionCopyCurrentDictionary();if(!session)return NO;
 CFTypeRef console=CFDictionaryGetValue(session,kCGSessionOnConsoleKey),login=CFDictionaryGetValue(session,kCGSessionLoginDoneKey),user=CFDictionaryGetValue(session,kCGSessionUserIDKey);
 int32_t uid=-1;BOOL valid=console==kCFBooleanTrue&&login==kCFBooleanTrue&&user&&CFGetTypeID(user)==CFNumberGetTypeID()&&CFNumberGetValue(user,kCFNumberSInt32Type,&uid)&&uid==(int32_t)getuid();CFRelease(session);return valid;
}
-(BOOL)consoleSessionAllowed {
 double age=CACurrentMediaTime()-self.consoleSessionChecked;
 return self.consoleSessionValid&&age>=0&&age<=.35;
}
-(void)invalidateConsoleSession {self.consoleSessionEpoch++;self.consoleSessionValid=NO;self.consoleSessionChecked=0;}
-(void)refreshConsoleSession {
 if(atomic_load(&stopped)||self.consoleSessionPending)return;
 self.consoleSessionPending=YES;uint64_t epoch=self.consoleSessionEpoch;__weak RHGHost *weak=self;
 static dispatch_queue_t audits;static dispatch_once_t once;
 dispatch_once(&once,^{audits=dispatch_queue_create("app.ready.hosted.console-audit",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));});
 dispatch_async(audits,^{@autoreleasepool{
  RHGHost *host=weak;if(!host)return;BOOL valid=[host readConsoleSessionProof];double checked=CACurrentMediaTime();
  dispatch_async(dispatch_get_main_queue(),^{RHGHost *current=weak;if(!current)return;current.consoleSessionPending=NO;
   if(atomic_load(&current->stopped))return;
   if(current.consoleSessionEpoch!=epoch){[current refreshConsoleSession];return;}
   current.consoleSessionValid=valid;current.consoleSessionChecked=checked;[current reconcilePointer];
  });
 }});
}
-(BOOL)foregroundEligible {
 uint64_t began=RHGPerfNow();@try{return [self foregroundWindowEligible]&&[self consoleSessionAllowed];}
 @finally{[self perfInterval:&performance.eligibility begin:began end:RHGPerfNow()];}
}
-(void)releasePointer {
 BOOL owned=self->pointer.detached||self->pointer.hidden;int32_t previousError=self->pointer.error;
 RHGPointerRelease(&self->pointer,RHGOps(self));
 if(owned&&(!self->pointer.error||previousError!=self->pointer.error))[self record:self->pointer.error?@"pointer-release-failed":@"pointer-released" reason:nil];
 if(!self->pointer.detached&&!self->pointer.hidden&&RHGPointerOwner==self)RHGPointerOwner=nil;
 if(atomic_load(&stopped)&&!self->pointer.detached&&!self->pointer.hidden){[self.pointerTimer invalidate];self.pointerTimer=nil;}
}
-(void)reconcilePointer {
 [self reconcilePointerWithEligibility:self.pointerEnabled&&self.firstFrameAnnounced&&[self foregroundEligible]];
}
-(void)reconcilePointerWithEligibility:(BOOL)eligible {
 BOOL allowed=self.pointerEnabled&&self.firstFrameAnnounced&&eligible;
 if(!allowed){self.pointerRetryBlocked=NO;[self releasePointer];return;}
 if(self.pointerRetryBlocked){if(self->pointer.detached||self->pointer.hidden)[self releasePointer];return;}
 if(RHGPointerOwner&&RHGPointerOwner!=self){[RHGPointerOwner releasePointer];if(RHGPointerOwner)return;}
 if(!self.virtualInitialized){NSPoint p=[self.view convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];self.virtualX=fmax(0,fmin(1,p.x/fmax(1,self.view.bounds.size.width)));self.virtualY=fmax(0,fmin(1,p.y/fmax(1,self.view.bounds.size.height)));self.virtualInitialized=YES;}
 BOOL was=self->pointer.captured;RHGPointerReconcile(&self->pointer,RHGOps(self),true);
 if(self->pointer.detached||self->pointer.hidden)RHGPointerOwner=self;
 if(!was&&self->pointer.captured){
  [self record:@"pointer-captured" reason:nil];
 }else if(!was&&self->pointer.error){self.pointerRetryBlocked=YES;[self record:@"pointer-capture-failed" reason:nil];}
}
-(void)input:(NSEvent*)e type:(uint32_t)type{
 BOOL traceWheel=self.inputTraceEnabled&&type==RHG_SCROLL;
 if(traceWheel){self.scrollReceived++;if(e.hasPreciseScrollingDeltas)self.scrollPreciseReceived++;}
 BOOL eligible=[self foregroundEligible];[self reconcilePointerWithEligibility:eligible];
 if(!RHGInputBelongsToCurrentGame(self,type,e.timestamp)){
  if(type==RHG_MOUSE_MOVE)RHGTraceResumeInput(self,(RHGInput){.type=type,.timestamp=e.timestamp,.deltaX=e.deltaX,.deltaY=e.deltaY},@"discarded-before-resume",0,0,NO);return;
 }
 if(!self.firstFrameAnnounced||!eligible){if(traceWheel){self.scrollEligibilityDropped++;if(self.scrollReceived==1||self.scrollReceived%32==0)[self record:@"input-scroll" reason:@"eligibility-dropped"];}return;}RHGInput input={0};input.type=type;input.modifiers=e.modifierFlags;input.timestamp=e.timestamp;
 if(type==RHG_KEY_DOWN||type==RHG_KEY_UP||type==RHG_FLAGS){input.keyCode=e.keyCode;input.repeat=type==RHG_KEY_DOWN&&e.isARepeat;NSData*text=[((type==RHG_FLAGS?@"":e.charactersIgnoringModifiers)?:@"")dataUsingEncoding:NSUTF8StringEncoding];input.charactersLength=(uint32_t)MIN(sizeof input.characters,text.length);if(input.charactersLength)memcpy(input.characters,text.bytes,input.charactersLength);}
 else{NSPoint p=[self.view convertPoint:e.locationInWindow fromView:nil];input.x=self.view.bounds.size.width>0?p.x/self.view.bounds.size.width:0;input.y=self.view.bounds.size.height>0?p.y/self.view.bounds.size.height:0;
  // AppKit raises for clickCount on a genuine NSScrollWheel event. Read only
  // fields applicable to this event kind; scroll deltas are captured below.
  if(type==RHG_MOUSE_DOWN||type==RHG_MOUSE_UP){input.button=(uint32_t)e.buttonNumber;input.clickCount=(uint32_t)MAX(0,e.clickCount);}
  else if(type==RHG_MOUSE_MOVE){input.deltaX=e.deltaX;input.deltaY=e.deltaY;
   if(e.type==NSEventTypeRightMouseDragged)input.button=1;
   else if(e.type==NSEventTypeOtherMouseDragged){CGEventRef raw=e.CGEvent;input.button=raw?(uint32_t)CGEventGetIntegerValueField(raw,kCGMouseEventButtonNumber):2;}
  }
 }
 if(type==RHG_SCROLL && !RHGCaptureScrollEvent(e,&input)){[self record:@"input-rejected" reason:@"invalid-scroll-input"];return;}
 double sourceX=input.x,sourceY=input.y;
 if(self.pendingPointerRestoreEpoch){
  if(!RHGInputQueuePush(&self->resumeInputQueue,input)){[self record:@"input-rejected" reason:@"resume-input-queue-overflow"];[self shutdown];}
  if(type==RHG_MOUSE_MOVE)RHGTraceResumeInput(self,input,@"held",sourceX,sourceY,NO);return;
 }
 if(!RHGApplyVirtualPointerInput(self,&input))return;
 if(type==RHG_MOUSE_MOVE)RHGTraceResumeInput(self,input,@"delivered",sourceX,sourceY,NO);
 if(!RHGInputQueuePush(&self->inputQueue,input)){
  // A bounded queue must not silently lose a release and leave held controls.
  [self record:@"input-rejected" reason:@"input-control-queue-overflow"];[self shutdown];
 }else if(traceWheel){self.scrollQueued++;if(self.scrollReceived==1||self.scrollReceived%32==0)[self record:@"input-scroll" reason:@"queued"];
 }
 // Capture was reconciled before delivery. A post-scroll show/hide repair
 // itself exposes the cursor and accumulates run-loop work during a gesture.
}
-(void)shutdown{
 if(atomic_exchange(&stopped,true))return;
 RHGCancelPendingAcquire(self);
 if(self.remoteMode){self.remoteLayer.contextId=0;self.remoteContextID=0;}
 self.pointerEnabled=NO;[self releasePointer];
 for(id pair in self.pointerObservers){[[pair objectAtIndex:0]removeObserver:[pair objectAtIndex:1]];}[self.pointerObservers removeAllObjects];
 self.firstFrameCallback=NULL;self.firstFrameContext=NULL;
 [self record:@"stopped" reason:nil];
 mach_port_t port=self.port;self.port=MACH_PORT_NULL;if(port)mach_port_destroy(mach_task_self(),port);
 NSArray<RHGRenderSlot*> *retired=[self.slots copy];[self.slots removeAllObjects];
 RHGRetireRenderSlots(retired,self.guestPID,self.guestBirthSeconds,self.guestBirthMicroseconds);
 self.drawable=nil;self.metal.developerHUDProperties=@{@"mode":@"disabled"};
}
@end
static BOOL RHGQueuePointerSync(RHGHost*host){
 RHGInput input={0};input.type=RHG_MOUSE_MOVE;input.x=host.virtualX;input.y=host.virtualY;input.timestamp=CACurrentMediaTime();
 if(RHGInputQueuePush(&host->inputQueue,input))return YES;
 [host record:@"input-rejected" reason:@"pointer-sync-queue-overflow"];[host shutdown];return NO;
}
static void RHGFill(RHGHost*host,RHGReply*reply){
 // Rendering does not revalidate physical pointer ownership. Input/POLL,
 // enabled changes, notifications and the independent timer do so freshly.
 BOOL focus=NO;
 if(reply->op==RHG_POLL){focus=[host foregroundEligible];[host reconcilePointerWithEligibility:focus];}
 reply->framesInFlight=host.pipelineDepth;reply->configurationGeneration=host.configurationGeneration;
 reply->magic=RHG_MAGIC;reply->version=RHG_VERSION;reply->window=(uint32_t)host.window.windowNumber;
 if(host.remoteMode){reply->width=host.remoteWidth;reply->height=host.remoteHeight;reply->pixelFormat=host.remotePixelFormat;reply->deviceRegistryID=host.remoteDeviceRegistryID;}
 else{reply->width=(uint32_t)host.metal.drawableSize.width;reply->height=(uint32_t)host.metal.drawableSize.height;reply->pixelFormat=(uint32_t)host.metal.pixelFormat;reply->deviceRegistryID=host.device.registryID;}reply->backingScale=host.window.backingScaleFactor;
 reply->pointerCaptured=host->pointer.captured;reply->pointerAssociated=host.virtualAssociated;reply->pointerHideCount=host.virtualHideCount;reply->pointerHiddenUntilMove=host.virtualHiddenUntilMove;reply->pointerError=host->pointer.error;
 reply->logicalWidth=host.view.bounds.size.width;reply->logicalHeight=host.view.bounds.size.height;
 reply->pointerX=host.virtualX;reply->pointerY=host.virtualY;
 NSRect screenRect=[host.window convertRectToScreen:[host.view convertRect:host.view.bounds toView:nil]];
 reply->quartzOriginX=screenRect.origin.x;reply->quartzOriginY=NSMaxY(NSScreen.screens.firstObject.frame)-NSMaxY(screenRect);reply->cocoaOriginX=screenRect.origin.x;reply->cocoaOriginY=screenRect.origin.y;
 if(reply->op==RHG_POLL)[host traceRemoteStartup:@"poll"];
 if(reply->op!=RHG_POLL||reply->eventCount)return;
 if(focus!=host.lastFocus){RHGInput change={0};change.type=RHG_FOCUS;change.keyCode=focus?1:0;change.timestamp=CACurrentMediaTime();if(!focus){RHGInputQueueClear(&host->inputQueue);RHGInputQueueClear(&host->resumeInputQueue);}
  if(focus&&host.pendingPointerRestoreEpoch==host.overlayEpoch&&host.pendingPointerRestoreEpoch){change.button=1;change.modifiers=host.pendingPointerRestoreEpoch;}
  if(!RHGInputQueuePush(&host->inputQueue,change)){[host record:@"input-rejected" reason:@"input-control-queue-overflow"];[host shutdown];}
  else if(focus)RHGQueuePointerSync(host);
  host.lastFocus=focus;}
 reply->eventCount=RHGInputQueuePop(&host->inputQueue,reply->events,RHG_MAX_EVENTS);
 if(host.inputTraceEnabled){uint64_t previous=host.scrollDelivered;for(unsigned i=0;i<reply->eventCount;i++)if(reply->events[i].type==RHG_SCROLL)host.scrollDelivered++;if(host.scrollDelivered!=previous&&(previous==0||previous/32!=host.scrollDelivered/32))[host record:@"input-scroll" reason:@"poll-delivered"];}
}
static void RHGConfigureLayer(RHGHost*host,const RHGRequest*q,RHGReply*reply){
 uint64_t pixels=(uint64_t)q->width*q->height;
 if(host.slots.count||host.drawable||host.acquirePending){reply->status=RHG_BUSY;return;}
 if(q->configurationGeneration!=host.configurationGeneration){reply->status=RHG_REJECTED;return;}
 if(!q->width||!q->height||q->width>8192||q->height>8192||pixels>33554432||!RHGFormat(q->pixelFormat)||q->deviceRegistryID!=host.device.registryID||q->displaySyncEnabled>1){reply->status=RHG_UNSUPPORTED;return;}
 BOOL sync=q->displaySyncEnabled!=0;
 if(host.configured&&host.metal.pixelFormat==q->pixelFormat&&host.metal.drawableSize.width==q->width&&host.metal.drawableSize.height==q->height&&host.metal.displaySyncEnabled==sync){reply->displaySyncEnabled=host.metal.displaySyncEnabled?1:0;return;}
 if(host.configurationGeneration==UINT64_MAX){reply->status=RHG_UNSUPPORTED;return;}host.configurationGeneration++;
 host.metal.pixelFormat=(MTLPixelFormat)q->pixelFormat;host.metal.drawableSize=CGSizeMake(q->width,q->height);host.metal.displaySyncEnabled=sync;host.configured=YES;
 RHGFill(host,reply);reply->displaySyncEnabled=host.metal.displaySyncEnabled?1:0;[host record:@"configured" reason:nil];
}
/* Remote layer metadata is bounded independently of native CA buffering. The
 * context ID is accepted only after this server's nonce/executable/UID/PID-birth
 * attestation; it is not treated as authority to create arbitrary host windows. */
static BOOL RHGRemoteMetadataValid(RHGHost*host,const RHGRequest*q){
 if(q->remoteTextureFlags&~(RHG_REMOTE_TEXTURE_SHADER_READABLE|RHG_REMOTE_TEXTURE_FRAMEBUFFER_ONLY))return NO;
 if(q->op!=RHG_REMOTE_FIRST_FRAME&&q->remoteTextureFlags)return NO;
 if((q->remoteTextureFlags&(RHG_REMOTE_TEXTURE_SHADER_READABLE|RHG_REMOTE_TEXTURE_FRAMEBUFFER_ONLY))==(RHG_REMOTE_TEXTURE_SHADER_READABLE|RHG_REMOTE_TEXTURE_FRAMEBUFFER_ONLY))return NO;
 if((q->width==0)!=(q->height==0))return NO;
 if(q->width&&(q->width>8192||q->height>8192||(uint64_t)q->width*q->height>33554432))return NO;
 if(q->pixelFormat&&!RHGFormat(q->pixelFormat))return NO;
 if(q->deviceRegistryID&&q->deviceRegistryID!=host.remoteDeviceRegistryID)return NO;
 return YES;
}
static void RHGAdoptRemoteMetadata(RHGHost*host,const RHGRequest*q){
 if(q->width){host.remoteWidth=q->width;host.remoteHeight=q->height;}
 if(q->pixelFormat)host.remotePixelFormat=q->pixelFormat;
}
static BOOL RHGRemoteGeometry(RHGHost*host,BOOL initial){
 CGFloat scale=host.window.backingScaleFactor;NSSize logical=initial?host.window.screen.frame.size:host.view.bounds.size;
 double width=ceil(logical.width*scale),height=ceil(logical.height*scale);
 if(!isfinite(width)||!isfinite(height)||!isfinite(scale)||scale<=0||width<1||height<1||width>8192||height>8192||width*height>33554432)return NO;
 host.remoteWidth=(uint32_t)width;host.remoteHeight=(uint32_t)height;
 host.remoteLayer.frame=host.view.bounds;host.remoteLayer.contentsScale=scale;return YES;
}
static void RHGSendReply(RHGHost*host,RHGReply*reply){
 if(!reply->h.msgh_remote_port)return;
 kern_return_t sent=mach_msg(&reply->h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,reply->h.msgh_size,0,MACH_PORT_NULL,2000,MACH_PORT_NULL);
 if(sent!=KERN_SUCCESS){
  // The failed message still owns its destination send-once right and any
  // exported surface descriptor. Destroy both, including non-complex replies.
  mach_msg_destroy(&reply->h);
  dispatch_async(dispatch_get_main_queue(),^{[host record:@"peer-lost" reason:nil];[host shutdown];});
 }
 reply->h.msgh_remote_port=MACH_PORT_NULL;
}
static void RHGCancelPendingAcquire(RHGHost*host){
 RHGAcquireOperation*operation=host.pendingAcquire;if(!operation||!operation->response.h.msgh_remote_port)return;
 RHGReply stopped=operation->response;operation->response.h.msgh_remote_port=MACH_PORT_NULL;stopped.status=RHG_STOPPED;
 // Cancellation must not sit behind the blocked acquisition worker.
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{RHGReply reply=stopped;RHGSendReply(host,&reply);});
}
static BOOL RHGAcquireAsync(RHGHost*host,const RHGRequest*q,RHGReply*reply,uint64_t serviceBegan){
 if(!host.configured){reply->status=RHG_UNSUPPORTED;return NO;}
 if(q->configurationGeneration!=host.configurationGeneration){reply->status=RHG_REJECTED;return NO;}
 if(host.acquirePending||host.slots.count>=host.pipelineDepth){reply->status=RHG_BUSY;return NO;}
 if(host.frameID==UINT64_MAX){reply->status=RHG_UNSUPPORTED;return NO;}
 if(!reply->h.msgh_remote_port){reply->status=RHG_REJECTED;return NO;}
 RHGAcquireOperation*operation=[RHGAcquireOperation new];operation.layer=host.metal;operation.generation=host.configurationGeneration;operation.frameID=host.frameID;
 operation->response=*reply;operation->serviceBegan=serviceBegan;reply->h.msgh_remote_port=MACH_PORT_NULL;
 host.pendingAcquire=operation;host.acquirePending=YES;RHGPendingAcquisitionCount++;
 dispatch_async(host.acquireQueue,^{@autoreleasepool{
  id<CAMetalDrawable>drawable=nil;mach_port_t surfacePort=MACH_PORT_NULL;uint32_t surfaceID=0,status=RHG_OK;
  uint64_t began=RHGPerfNow();
  @try{
   drawable=[operation.layer nextDrawable];
   IOSurfaceRef surface=drawable.texture.iosurface;
   if(!surface)status=RHG_UNSUPPORTED;
   else{surfaceID=IOSurfaceGetID(surface);if(!surfaceID)status=RHG_REJECTED;
    else{surfacePort=IOSurfaceCreateMachPort(surface);if(!surfacePort)status=RHG_UNSUPPORTED;}}
  }@catch(NSException*exception){(void)exception;status=RHG_UNSUPPORTED;}
  [host perfInterval:&host->performance.nextDrawable begin:began end:RHGPerfNow()];
  __block RHGReply completed={0};__block mach_port_t ownedSurface=surfacePort;
  RHGMainSync(^{
   BOOL current=host.pendingAcquire==operation;
   if(current){host.pendingAcquire=nil;host.acquirePending=NO;}
   if(RHGPendingAcquisitionCount)RHGPendingAcquisitionCount--;
   completed=operation->response;operation->response.h.msgh_remote_port=MACH_PORT_NULL;
   if(!completed.h.msgh_remote_port)return; // Stop already consumed the one reply right.
   if(atomic_load(&host->stopped)){completed.status=RHG_STOPPED;return;}
   if(!current||host.configurationGeneration!=operation.generation||host.metal!=operation.layer||host.frameID!=operation.frameID){completed.status=RHG_REJECTED;return;}
   if(status!=RHG_OK){completed.status=status;[host record:@"rejected" reason:@"drawable-acquisition-unavailable"];return;}
   if(host.slots.count>=host.pipelineDepth){completed.status=RHG_BUSY;return;}
   for(RHGRenderSlot*held in host.slots)if(held.surfaceID==surfaceID){completed.status=RHG_REJECTED;return;}
   RHGRenderSlot*slot=[RHGRenderSlot new];slot.drawable=drawable;slot.layer=operation.layer;slot.surfaceID=surfaceID;slot.frameID=host.frameID++;slot.generation=operation.generation;
   [host.slots addObject:slot];host.surfaceID=slot.surfaceID;host.acquires++;
   RHGFill(host,&completed);completed.frameID=slot.frameID;completed.surfaceID=slot.surfaceID;completed.configurationGeneration=slot.generation;
   completed.h.msgh_bits|=MACH_MSGH_BITS_COMPLEX;completed.body.msgh_descriptor_count=1;
   completed.port=(mach_msg_port_descriptor_t){.name=ownedSurface,.disposition=MACH_MSG_TYPE_MOVE_SEND,.type=MACH_MSG_PORT_DESCRIPTOR};ownedSurface=MACH_PORT_NULL;
  });
  if(ownedSurface)mach_port_deallocate(mach_task_self(),ownedSurface);
  [host perfInterval:&host->performance.service[RHG_ACQUIRE] begin:operation->serviceBegan end:RHGPerfNow()];
  RHGSendReply(host,&completed);
 }});
 return YES;
}
static BOOL RHGOverlayBlurReadyAllowed(RHGHost*host,const RHGRequest*q){
 return host.remoteMode&&host.overlayVisible&&host.overlayGPUBlurEnabled&&host.firstFrameAnnounced
  &&host.remoteContextID&&q->surfaceID==host.remoteContextID&&q->frameID==host.overlayEpoch&&host.overlayEpoch;
}
static BOOL RHGStartOverlayTransition(RHGHost*host,BOOL visible){
 if(!host.overlayVisible||!host.overlayGPUBlurEnabled||!host.firstFrameAnnounced)return NO;
 if(visible&&(!host.overlayGPUPrepared||!host.overlayUIReady||!host.overlayDesiredVisible))return NO;
 if(visible&&host.overlayTransitionEpoch==host.overlayEpoch&&host->overlayTransition.to==1)return NO;
 if(!visible||(host.overlayTransitionEpoch==host.overlayEpoch&&host->overlayTransition.to==0)){
  if(host.overlayEpoch==UINT64_MAX){[host shutdown];return NO;}host.overlayEpoch++;
 }
 host.overlayDesiredVisible=visible;
 double now=CACurrentMediaTime(),start=now+0.016;
 RHGOverlayTransition previous=now<host->overlayTransition.began?host->overlayPriorTransition:host->overlayTransition;
 double from=RHGOverlayTransitionValue(previous,start);host->overlayPriorTransition=previous;
 host->overlayTransition=(RHGOverlayTransition){from,visible?1:0,start,0.24};host.overlayTransitionEpoch=host.overlayEpoch;
 RHGInput animation={0};animation.type=RHG_OVERLAY_ANIMATE;animation.modifiers=host.overlayEpoch;animation.keyCode=visible?1:0;animation.timestamp=start;animation.x=from;animation.deltaX=.24;
 if(!RHGInputQueuePush(&host->inputQueue,animation)){[host shutdown];return NO;}
 [host.overlayBlurPlaceholder removeFromSuperview];host.overlayBlurPlaceholder=nil;
 if(host.overlayBlurReadyCallback)host.overlayBlurReadyCallback(host.overlayBlurReadyContext);
 [host record:@"overlay-transition" reason:visible?@"opening":@"closing"];return YES;
}
static BOOL RHGVirtualPointerPolicyAllowed(RHGHost*host){
 // Virtual bookkeeping never grants physical capture. Do not reject a menu's
 // one-shot association change solely because the async console proof aged.
 return host.overlayVisible||[host foregroundWindowEligible];
}
static BOOL RHGRestoreOverlayPointer(RHGHost*host,const RHGRequest*q){
 if(host.overlayVisible||!host.pendingPointerRestoreEpoch||q->frameID!=host.pendingPointerRestoreEpoch||q->frameID!=host.overlayEpoch)return NO;
 RHGVirtualPointer saved=host->overlayPointerResumeSnapshot;
 host.virtualX=saved.x;host.virtualY=saved.y;host.virtualInitialized=saved.initialized;
 // Association belongs to the game's current menu/camera mode. Replaying the
 // pre-overlay mode here could integrate the first delta twice or freeze it.
 host.pendingPointerRestoreEpoch=0;RHGQueuePointerSync(host);
 RHGInput inputs[RHG_INPUT_QUEUE_CAPACITY];uint32_t count=RHGInputQueuePop(&host->resumeInputQueue,inputs,RHG_INPUT_QUEUE_CAPACITY);
 for(uint32_t i=0;i<count;i++){
  double x=inputs[i].x,y=inputs[i].y;
  if(RHGApplyVirtualPointerInput(host,&inputs[i])){
   if(inputs[i].type==RHG_MOUSE_MOVE)RHGTraceResumeInput(host,inputs[i],@"replayed",x,y,NO);
   if(!RHGInputQueuePush(&host->inputQueue,inputs[i])){[host shutdown];return NO;}
  }
 }
 [host record:@"pointer-overlay-restored" reason:@"after-game-focus-callbacks"];return YES;
}
static void RHGServe(RHGHost*host){
 while(!atomic_load(&host->stopped)){@autoreleasepool{
  RHGRequestReceive incoming={0};mach_port_t port=host.port;if(!port)break;
  mach_msg_option_t options=MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
  kern_return_t result=mach_msg(&incoming.message.h,options,0,sizeof incoming,port,50,MACH_PORT_NULL);
  if(result==MACH_RCV_TIMED_OUT)continue;if(result!=KERN_SUCCESS)break;
  RHGRequest*q=&incoming.message;__block RHGReply reply={0};__block BOOL deferred=NO;
  reply.h.msgh_remote_port=q->h.msgh_remote_port;reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_size=sizeof reply;reply.op=q->op;reply.requestID=q->requestID;
  if(q->h.msgh_size!=sizeof(RHGRequest)||(q->h.msgh_bits&MACH_MSGH_BITS_COMPLEX)){mach_msg_destroy(&q->h);continue;}
  mach_msg_audit_trailer_t*t=(void*)((uint8_t*)q+round_msg(q->h.msgh_size));
  BOOL valid=q->magic==RHG_MAGIC&&q->version==RHG_VERSION&&t->msgh_trailer_type==MACH_MSG_TRAILER_FORMAT_0&&t->msgh_trailer_size>=sizeof(*t)&&audit_token_to_euid(t->msgh_audit)==geteuid()&&timingsafe_bcmp(q->nonce,host->nonce,RHG_NONCE_BYTES)==0;
  pid_t pid=valid?audit_token_to_pid(t->msgh_audit):0;
  if(valid&&host.guestPID==0){char path[PROC_PIDPATHINFO_MAXSIZE]={0};valid=q->op==RHG_HELLO&&q->reserved==(host.remoteMode?RHG_TRANSPORT_REMOTE_LAYER:RHG_TRANSPORT_SURFACE)&&(host.remoteMode?q->framesInFlight==0:(q->framesInFlight>=1&&q->framesInFlight<=RHG_MAX_FRAMES_IN_FLIGHT))&&proc_pidpath(pid,path,sizeof path)>0&&host.expectedExecutable.length&&strcmp(path,host.expectedExecutable.fileSystemRepresentation)==0;if(valid){uint64_t seconds=0,microseconds=0;valid=RHGReadPeerBirth(pid,&seconds,&microseconds);if(valid){host.guestBirthSeconds=seconds;host.guestBirthMicroseconds=microseconds;host.guestPID=pid;}}}
  valid=valid&&pid>0&&host.guestPID==pid;
  if(valid&&(q->op==RHG_REMOTE_ATTACH||q->op==RHG_REMOTE_FIRST_FRAME||q->op==RHG_REMOTE_BLUR_READY||q->op==RHG_REMOTE_BLUR_PREPARED)){
   char path[PROC_PIDPATHINFO_MAXSIZE]={0};valid=host.remoteMode&&RHGPeerLifeState(pid,host.guestBirthSeconds,host.guestBirthMicroseconds)==RHGPeerSame&&proc_pidpath(pid,path,sizeof path)>0&&strcmp(path,host.expectedExecutable.fileSystemRepresentation)==0;
  }
  if(!valid){reply.status=RHG_REJECTED;reply.magic=RHG_MAGIC;reply.version=RHG_VERSION;}
  else {uint64_t dispatchBegan=RHGPerfNow();RHGMainSync(^{
   uint64_t serviceBegan=RHGPerfNow();unsigned perfOp=q->op<RHG_PERF_OPERATIONS?q->op:0;
   [host perfInterval:&host->performance.mainDispatch[perfOp] begin:dispatchBegan end:serviceBegan];
   @try{
   host.requests++;RHGFill(host,&reply);
   if(atomic_load(&host->stopped)){reply.status=RHG_STOPPED;return;}
   if(q->op==RHG_HELLO){
    if(q->reserved!=(host.remoteMode?RHG_TRANSPORT_REMOTE_LAYER:RHG_TRANSPORT_SURFACE)){reply.status=RHG_REJECTED;return;}
    if(host.remoteMode){if(q->framesInFlight!=0){reply.status=RHG_REJECTED;return;}host.pipelineDepth=0;host.renderNegotiated=YES;reply.framesInFlight=0;[host record:@"guest-connected" reason:@"remote-layer"];return;}
    if(q->framesInFlight<1||q->framesInFlight>RHG_MAX_FRAMES_IN_FLIGHT||(host.renderNegotiated&&q->framesInFlight!=host.pipelineDepth)){reply.status=RHG_REJECTED;return;}
    host.pipelineDepth=q->framesInFlight;host.renderNegotiated=YES;reply.framesInFlight=host.pipelineDepth;[host record:@"guest-connected" reason:nil];
   }else if(!host.renderNegotiated){reply.status=RHG_REJECTED;return;}
   else if(q->op==RHG_POLL){}
   else if(host.remoteMode&&(q->op==RHG_CONFIGURE||q->op==RHG_ACQUIRE||q->op==RHG_PRESENT)){reply.status=RHG_UNSUPPORTED;return;}
   else if(q->op==RHG_REMOTE_ATTACH){
    if(!host.remoteMode||!host.remoteLayer||!q->surfaceID||host.remoteContextID||!RHGRemoteMetadataValid(host,q)){reply.status=RHG_REJECTED;return;}
    host.remoteLayer.contextId=q->surfaceID;host.remoteContextID=q->surfaceID;RHGAdoptRemoteMetadata(host,q);RHGFill(host,&reply);reply.surfaceID=host.remoteContextID;[host record:@"remote-layer-attached" reason:nil];[host traceRemoteStartup:@"attach"];
   }else if(q->op==RHG_REMOTE_FIRST_FRAME){
    if(!host.remoteMode||!host.remoteContextID||q->surfaceID!=host.remoteContextID||host.firstFrameAnnounced||!RHGRemoteMetadataValid(host,q)){reply.status=RHG_REJECTED;return;}
    RHGAdoptRemoteMetadata(host,q);host.firstFrameAnnounced=YES;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    if(host.firstFrameCallback)host.firstFrameCallback(host.firstFrameContext);
    [CATransaction commit];
    if(atomic_load(&host->stopped)){reply.status=RHG_STOPPED;return;}
    RHGFill(host,&reply);reply.surfaceID=host.remoteContextID;
    NSString *textureReason=q->remoteTextureFlags&RHG_REMOTE_TEXTURE_SHADER_READABLE?@"source-texture-shader-readable":q->remoteTextureFlags&RHG_REMOTE_TEXTURE_FRAMEBUFFER_ONLY?@"source-texture-framebuffer-only":@"source-texture-not-readable";
    [host record:@"remote-first-frame-transition" reason:textureReason];
   }else if(q->op==RHG_REMOTE_BLUR_PREPARED){
    if(!RHGOverlayBlurReadyAllowed(host,q)){reply.status=RHG_REJECTED;return;}
    host.overlayGPUPrepared=YES;[host record:@"overlay-gpu-prepared" reason:@"pipeline-and-hooks-ready"];
    RHGStartOverlayTransition(host,YES);RHGFill(host,&reply);reply.surfaceID=host.remoteContextID;
   }else if(q->op==RHG_REMOTE_BLUR_READY){
    if(!RHGOverlayBlurReadyAllowed(host,q)){reply.status=RHG_REJECTED;return;}
    if(!host.overlayBlurReady){host.overlayBlurReady=YES;[host record:@"overlay-gpu-blur-ready" reason:@"first-presented-frame"];}
    RHGStartOverlayTransition(host,YES);RHGFill(host,&reply);reply.surfaceID=host.remoteContextID;
   }else if(q->op==RHG_CONFIGURE){
    RHGConfigureLayer(host,q,&reply);
   }else if(q->op==RHG_ACQUIRE){
    deferred=RHGAcquireAsync(host,q,&reply,serviceBegan);
   }else if(q->op==RHG_PRESENT){
    RHGRenderSlot*slot=host.slots.firstObject;
    if(!slot||q->frameID!=slot.frameID||q->surfaceID!=slot.surfaceID||q->configurationGeneration!=slot.generation||slot.generation!=host.configurationGeneration||!isfinite(q->presentTime)||!isfinite(q->gpuSeconds)||q->gpuSeconds<0||q->gpuSeconds>600){reply.status=RHG_REJECTED;return;}
    host.drawable=slot.drawable;host.surfaceID=slot.surfaceID;
    if(q->presentMode>RHG_PRESENT_MIN_DURATION){reply.status=RHG_UNSUPPORTED;return;}
    if(RHGPerfProfileEnabled()){
      os_unfair_lock_lock(&host->perfLock);
      host->performance.presentModes[q->presentMode]++;
      if(q->presentMode==RHG_PRESENT_MIN_DURATION&&q->presentTime>=0&&q->presentTime<=600)
        RHGPerfAddNanoseconds(&host->performance.requestedMinimumDuration,(uint64_t)(q->presentTime*1e9));
      os_unfair_lock_unlock(&host->perfLock);
      __weak RHGHost *weak=host;
      [host.drawable addPresentedHandler:^(id<MTLDrawable>displayed){[weak observePresentedTime:displayed.presentedTime];}];
    }
    BOOL transition=!host.firstFrameAnnounced&&host.firstFrameCallback!=NULL;
    if(transition){[CATransaction begin];[CATransaction setDisableActions:YES];host.metal.presentsWithTransaction=YES;}
    if(!host.firstFrameAnnounced){
      __weak RHGHost*weakHost=host;
      [host.drawable addPresentedHandler:^(id<MTLDrawable> displayed){
        CFTimeInterval timestamp=displayed.presentedTime;
        dispatch_async(dispatch_get_main_queue(),^{[weakHost record:@"first-presentation-result" reason:timestamp>0?@"on-glass-timestamp":@"skipped-no-display-timestamp"];});
      }];
    }
    uint64_t presentBegan=RHGPerfNow();
    if(q->presentMode==RHG_PRESENT_NORMAL)[host.drawable present];
    else if(q->presentMode==RHG_PRESENT_AT_TIME)[host.drawable presentAtTime:q->presentTime];
    else [host.drawable presentAfterMinimumDuration:q->presentTime];
    [host perfInterval:&host->performance.presentCall begin:presentBegan end:RHGPerfNow()];
    if(transition){
      host.firstFrameAnnounced=YES;
      // This callback can only exchange views/flags. No GPU wait or display
      // capture is performed inside the first presentation transaction.
      host.firstFrameCallback(host.firstFrameContext);
      [CATransaction commit];host.metal.presentsWithTransaction=NO;
      [host record:@"first-gpu-complete-transition" reason:nil];
    }else host.firstFrameAnnounced=YES;
    // The public first-frame callback may stop/destroy its owned presentation.
    // Retirement then owns the cleared slots; never remove from that empty list
    // or acknowledge a frame as belonging to a still-live host.
    if(atomic_load(&host->stopped)){reply.status=RHG_STOPPED;return;}
    if(host.slots.firstObject!=slot){reply.status=RHG_REJECTED;return;}
    reply.frameID=slot.frameID;reply.surfaceID=slot.surfaceID;reply.configurationGeneration=slot.generation;host.frames++;
    if(host.frames==1||(RHGPerfProfileEnabled()&&host.frames%120==0))[host record:@"present-call" reason:nil];host.drawable=nil;[host.slots removeObjectAtIndex:0];
   }else if(q->op==RHG_POINTER_RESTORE){
    if(!RHGRestoreOverlayPointer(host,q)){reply.status=RHG_REJECTED;return;}RHGFill(host,&reply);
   }else if(q->op==RHG_POINTER_ASSOCIATE||q->op==RHG_POINTER_WARP||q->op==RHG_POINTER_CURSOR){
    // Focus-loss callbacks may change virtual cursor policy while Ready's UI
    // owns input. They never authorize a physical warp or pointer capture.
    if(!RHGVirtualPointerPolicyAllowed(host)){reply.status=RHG_REJECTED;reply.pointerError=kCGErrorInvalidOperation;return;}
    RHGVirtualPointer virtual={host.virtualAssociated,host.virtualInitialized,host.virtualHiddenUntilMove,host.virtualHideCount,host.virtualX,host.virtualY};
    int32_t error=RHGVirtualPointerRequest(&virtual,q->op,q->pointerAction,q->pointerX,q->pointerY,true);
    if(error){reply.status=RHG_REJECTED;reply.pointerError=error;return;}
    BOOL associationChanged=host.virtualAssociated!=virtual.associated;
    BOOL policyChanged=associationChanged||host.virtualHideCount!=virtual.hideCount||host.virtualHiddenUntilMove!=virtual.hiddenUntilMove;
    if(q->op==RHG_POINTER_WARP||host.virtualAssociated!=virtual.associated)RHGInputQueueBarrier(&host->inputQueue);
    host.virtualAssociated=virtual.associated;host.virtualInitialized=virtual.initialized;host.virtualHiddenUntilMove=virtual.hiddenUntilMove;host.virtualHideCount=virtual.hideCount;host.virtualX=virtual.x;host.virtualY=virtual.y;
    if(q->op==RHG_POINTER_WARP)RHGTraceResumeInput(host,(RHGInput){.type=q->op,.x=q->pointerX,.y=q->pointerY,.timestamp=CACurrentMediaTime()},@"guest-warp",q->pointerX,q->pointerY,YES);
    if(associationChanged&&virtual.associated&&!host.overlayVisible&&!host.pendingPointerRestoreEpoch)RHGQueuePointerSync(host);
    [host reconcilePointer];RHGFill(host,&reply);reply.pointerError=0;if(policyChanged)[host record:@"pointer-virtual-policy" reason:host.firstFrameAnnounced&&host.pointerEnabled?@"physical-owner-independent":@"physical-capture-deferred"];
   }else if(q->op==RHG_DONE){if(host.slots.count||host.acquirePending){reply.status=RHG_BUSY;return;}host.pointerEnabled=NO;[host releasePointer];[host record:@"guest-done" reason:nil];host.drawable=nil;}
   else reply.status=RHG_UNSUPPORTED;
   }@finally{
    if(!deferred)[host perfInterval:&host->performance.service[perfOp] begin:serviceBegan end:RHGPerfNow()];
    if(q->op==RHG_PRESENT&&reply.status==RHG_OK&&host.frames>0&&host.frames%120==0)[host profileSnapshot];
   }
  });}
  if(!deferred)RHGSendReply(host,&reply);
 }}
}
static RHGHostRef RHGHostCreateCommon(void*windowPointer,bool hud,bool remote,uint64_t existingDeviceRegistryID,const char*expectedExecutable,const char*diagnosticPath){
 if(!NSThread.isMainThread||!windowPointer||!expectedExecutable||!diagnosticPath||RHGHasRetiredPool()||(remote&&(!existingDeviceRegistryID||![NSClassFromString(@"CALayerHost") instancesRespondToSelector:@selector(setContextId:)])))return NULL;
 NSWindow*window=(__bridge NSWindow*)windowPointer;RHGHost*host=[RHGHost new];host.window=window;host.expectedExecutable=[NSString stringWithUTF8String:expectedExecutable];host.metalHUD=hud;host.remoteMode=remote;host.remoteDeviceRegistryID=existingDeviceRegistryID;host.remotePixelFormat=MTLPixelFormatBGRA8Unorm;if(remote)host.pipelineDepth=0;
 host.diagnosticFD=open(diagnosticPath,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(host.diagnosticFD<0)return NULL;
 if(!remote){host.device=MTLCreateSystemDefaultDevice();if(!host.device)return NULL;}
 host.service=[@RHG_SERVICE_PREFIX stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];arc4random_buf(host->nonce,sizeof host->nonce);NSMutableString*hex=[NSMutableString new];for(unsigned i=0;i<RHG_NONCE_BYTES;i++)[hex appendFormat:@"%02x",host->nonce[i]];host.nonceString=hex;
 RHGView*view=[[RHGView alloc]initWithFrame:window.contentView.bounds];view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;view.owner=host;view.wantsLayer=YES;host.view=view;
 if(remote){host.remoteLayer=(CALayer<RHGRemoteLayerHosting>*)view.layer;host.remoteLayer.opaque=YES;if(!RHGRemoteGeometry(host,YES))return NULL;}else{
 CAMetalLayer*layer=[CAMetalLayer layer];layer.device=host.device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;layer.opaque=YES;layer.backgroundColor=NSColor.blackColor.CGColor;layer.contentsScale=window.backingScaleFactor;layer.drawableSize=CGSizeMake(MAX(1,view.bounds.size.width*window.backingScaleFactor),MAX(1,view.bounds.size.height*window.backingScaleFactor));layer.maximumDrawableCount=3;layer.allowsNextDrawableTimeout=YES;view.layer=layer;layer.presentsWithTransaction=NO;host.metal=layer;
 if(hud)layer.developerHUDProperties=@{@"mode":@"main",@"MTL_HUD_ENABLED":@1,@"MTL_HUD_DISABLE_MENU_BAR":@1,@"MTL_HUD_ALIGNMENT":@"topleft",@"MTL_HUD_ELEMENTS":@"device,layersize,fps,framenumber,frameinterval,frameintervalgraph,presentdelay"};
 }
 __weak RHGHost *weak=host;
 [host refreshConsoleSession];
 host.pointerTimer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer*t){(void)t;[weak refreshConsoleSession];[weak reconcilePointer];}];
 [NSRunLoop.mainRunLoop addTimer:host.pointerTimer forMode:NSRunLoopCommonModes];
 NSNotificationCenter *normal=NSNotificationCenter.defaultCenter,*workspace=NSWorkspace.sharedWorkspace.notificationCenter;
 for(NSNotificationName name in @[NSApplicationWillResignActiveNotification,NSApplicationWillTerminateNotification,NSWindowWillExitFullScreenNotification,NSWindowWillCloseNotification]){
  id token=[normal addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){RHGHost*h=weak;if(!h)return;if(n.object!=NSApp&&n.object!=h.window)return;[h invalidateConsoleSession];if([n.name isEqualToString:NSWindowWillExitFullScreenNotification])h.pointerFullscreenSuspended=YES;else h.pointerSuspended=YES;[h releasePointer];}];[host.pointerObservers addObject:@[normal,token]];
 }
 for(NSNotificationName name in @[NSApplicationDidBecomeActiveNotification,NSWindowDidBecomeKeyNotification,NSWindowDidResignKeyNotification,NSWindowDidChangeOcclusionStateNotification,NSWindowDidEnterFullScreenNotification]){
  id token=[normal addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){RHGHost*h=weak;if(!h)return;if(n.object!=NSApp&&n.object!=h.window)return;[h invalidateConsoleSession];[h refreshConsoleSession];if([n.name isEqualToString:NSWindowDidEnterFullScreenNotification])h.pointerFullscreenSuspended=NO;if([n.name isEqualToString:NSApplicationDidBecomeActiveNotification]||[n.name isEqualToString:NSWindowDidBecomeKeyNotification])h.pointerSuspended=NO;[h reconcilePointer];}];[host.pointerObservers addObject:@[normal,token]];
 }
 for(NSNotificationName name in @[NSWorkspaceSessionDidResignActiveNotification,NSWorkspaceScreensDidSleepNotification,NSWorkspaceActiveSpaceDidChangeNotification,NSWorkspaceSessionDidBecomeActiveNotification,NSWorkspaceScreensDidWakeNotification]){
  id token=[workspace addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){RHGHost*h=weak;if(!h)return;[h invalidateConsoleSession];if(n.name==NSWorkspaceSessionDidResignActiveNotification||n.name==NSWorkspaceScreensDidSleepNotification){h.pointerSuspended=YES;[h releasePointer];}else{h.pointerSuspended=NO;[h refreshConsoleSession];[h reconcilePointer];}}];[host.pointerObservers addObject:@[workspace,token]];
 }
 mach_port_t port=MACH_PORT_NULL;if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)!=KERN_SUCCESS)return NULL;host.port=port;
 if(mach_port_insert_right(mach_task_self(),host.port,host.port,MACH_MSG_TYPE_MAKE_SEND)!=KERN_SUCCESS||bootstrap_register(bootstrap_port,(char*)host.service.UTF8String,host.port)!=KERN_SUCCESS)return NULL;
 [host record:@"host-ready" reason:nil];dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{RHGServe(host);dispatch_async(dispatch_get_main_queue(),^{[host shutdown];host.view.owner=nil;host.view=nil;host.metal=nil;host.remoteLayer=nil;});});return (__bridge_retained RHGHostRef)host;
}
RHGHostRef RHGHostCreate(void*window,bool hud,const char*expectedExecutable,const char*diagnosticPath){return RHGHostCreateCommon(window,hud,false,0,expectedExecutable,diagnosticPath);}
RHGHostRef RHGHostCreateRemote(void*window,uint64_t existingDeviceRegistryID,const char*expectedExecutable,const char*diagnosticPath){return RHGHostCreateCommon(window,false,true,existingDeviceRegistryID,expectedExecutable,diagnosticPath);}
void*RHGHostGetView(RHGHostRef ref){return ref?(__bridge void*)((__bridge RHGHost*)ref).view:NULL;}
const char*RHGHostService(RHGHostRef ref){return ref?((__bridge RHGHost*)ref).service.UTF8String:NULL;}
const char*RHGHostNonce(RHGHostRef ref){return ref?((__bridge RHGHost*)ref).nonceString.UTF8String:NULL;}
void RHGHostSetFirstFrameCallback(RHGHostRef ref,void*context,RHGHostFirstFrameCallback callback){if(ref)RHGMainSync(^{RHGHost*host=(__bridge RHGHost*)ref;host.firstFrameContext=context;host.firstFrameCallback=callback;});}
void RHGHostSetPointerEnabled(RHGHostRef ref,bool enabled){if(ref)RHGMainSync(^{RHGHost*host=(__bridge RHGHost*)ref;if(host.pointerEnabled!=enabled)host.pointerRetryBlocked=NO;if(enabled&&(host.window.styleMask&NSWindowStyleMaskFullScreen)&&host.window.isOnActiveSpace)host.pointerFullscreenSuspended=NO;host.pointerEnabled=enabled;[host reconcilePointer];});}
void RHGHostSetOverlayVisible(RHGHostRef ref,bool visible){if(ref)RHGMainSync(^{
 RHGHost*host=(__bridge RHGHost*)ref;if(host.overlayVisible==visible)return;
 if(host.overlayEpoch==UINT64_MAX){[host shutdown];return;}
 host.overlayEpoch++;host.overlayVisible=visible;host.overlayBlurReady=NO;host.overlayGPUPrepared=NO;
 host.overlayDesiredVisible=visible;host.overlayUIReady=NO;
 if(visible){
  host.pendingPointerRestoreEpoch=0;
  RHGInputQueueClear(&host->resumeInputQueue);
  host->overlayPointerSnapshot=(RHGVirtualPointer){host.virtualAssociated,host.virtualInitialized,host.virtualHiddenUntilMove,host.virtualHideCount,host.virtualX,host.virtualY};host.overlayPointerSnapshotValid=YES;
 }else if(host.overlayPointerSnapshotValid){
  // AppKit may deliver queued UI motion after replacing the content view.
  // Such events predate this game-input generation and must not move it.
  host.pointerInputNotBeforeTime=CACurrentMediaTime();
  if(host.inputTraceEnabled){host.resumeMotionTraceBudget=16;host.resumeWarpTraceBudget=6;}
  host->overlayPointerResumeSnapshot=host->overlayPointerSnapshot;host.pendingPointerRestoreEpoch=host.overlayEpoch;
  host.virtualX=host->overlayPointerSnapshot.x;host.virtualY=host->overlayPointerSnapshot.y;
  host.virtualInitialized=host->overlayPointerSnapshot.initialized;
  // Hide/show operations still balance across native focus callbacks. Restore
  // only game position, never overwrite the current association/hide policy.
  host.overlayPointerSnapshotValid=NO;
 }
 RHGInputQueueClear(&host->inputQueue);
 RHGInput focus={0};focus.type=RHG_FOCUS;focus.timestamp=CACurrentMediaTime();
 RHGInput state={0};state.type=RHG_OVERLAY_STATE;state.keyCode=visible?1:0;
 state.button=visible&&host.overlayGPUBlurEnabled?1:0;state.modifiers=host.overlayEpoch;state.timestamp=focus.timestamp;
 if((visible&&!RHGInputQueuePush(&host->inputQueue,focus))||!RHGInputQueuePush(&host->inputQueue,state)){
  [host record:@"input-rejected" reason:@"overlay-state-queue-overflow"];[host shutdown];return;
 }
 host.lastFocus=NO;if(visible)[host releasePointer];else{[host.overlayBlurPlaceholder removeFromSuperview];host.overlayBlurPlaceholder=nil;[host reconcilePointer];}
 [host record:@"overlay-state" reason:visible?@"opened":@"closed"];
});}
void RHGHostSetOverlayGPUBlurEnabled(RHGHostRef ref,bool enabled){if(ref)RHGMainSync(^{((__bridge RHGHost*)ref).overlayGPUBlurEnabled=enabled;});}
void RHGHostSetOverlayBlurReadyCallback(RHGHostRef ref,void*context,RHGHostOverlayBlurReadyCallback callback){if(ref)RHGMainSync(^{RHGHost*h=(__bridge RHGHost*)ref;h.overlayBlurReadyContext=context;h.overlayBlurReadyCallback=callback;});}
void RHGHostSetOverlayBlurPlaceholderView(RHGHostRef ref,void*view){if(ref)RHGMainSync(^{RHGHost*h=(__bridge RHGHost*)ref;h.overlayBlurPlaceholder=view?(__bridge NSView*)view:nil;});}
void RHGHostSetOverlayUIReady(RHGHostRef ref,bool ready){if(ref)RHGMainSync(^{RHGHost*h=(__bridge RHGHost*)ref;h.overlayUIReady=ready;if(ready){[h record:@"overlay-ui-ready" reason:@"cached-ui-frame-ready"];RHGStartOverlayTransition(h,YES);}});}
void RHGHostRequestOverlayTransition(RHGHostRef ref,bool visible){if(ref)RHGMainSync(^{RHGHost*h=(__bridge RHGHost*)ref;h.overlayDesiredVisible=visible;RHGStartOverlayTransition(h,visible);});}
bool RHGHostGetOverlayTransition(RHGHostRef ref,RHGOverlayTransition*transition,uint64_t*epoch){
 if(!ref||!transition||!epoch||!NSThread.isMainThread)return false;RHGHost*h=(__bridge RHGHost*)ref;
 if(!h.overlayTransitionEpoch||h.overlayTransitionEpoch!=h.overlayEpoch)return false;*transition=h->overlayTransition;*epoch=h.overlayEpoch;return true;
}
bool RHGHostPointerCaptured(RHGHostRef ref){return ref&&NSThread.isMainThread?((__bridge RHGHost*)ref)->pointer.captured:false;}
void RHGHostStop(RHGHostRef ref){if(ref)RHGMainSync(^{[((__bridge RHGHost*)ref)shutdown];});}
void RHGHostDestroy(RHGHostRef ref){if(ref){RHGHostStop(ref);CFRelease((CFTypeRef)ref);}}
void RHGHostResize(RHGHostRef ref){if(ref)RHGMainSync(^{RHGHost*host=(__bridge RHGHost*)ref;if(host.remoteMode){RHGRemoteGeometry(host,NO);return;}host.metal.contentsScale=host.window.backingScaleFactor;if(!host.configured)host.metal.drawableSize=CGSizeMake(MAX(1,host.view.bounds.size.width*host.window.backingScaleFactor),MAX(1,host.view.bounds.size.height*host.window.backingScaleFactor));});}
uint32_t RHGHostWindowNumber(RHGHostRef ref){return ref?(uint32_t)((__bridge RHGHost*)ref).window.windowNumber:0;}
int32_t RHGHostGuestPID(RHGHostRef ref){return ref?((__bridge RHGHost*)ref).guestPID:0;}
