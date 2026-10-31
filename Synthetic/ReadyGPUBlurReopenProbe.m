// SPDX-License-Identifier: GPL-3.0-only
// Appended to the production shim with only its constructor and Mach ACK replaced.
// Real Objective-C hook dispatch; fake renderer/drawables perform no GPU work.
@interface ReopenRenderer:RHGOverlayBlurRenderer
@property unsigned encodes;
@end
@implementation ReopenRenderer
-(BOOL)encodeOn:(id)command drawable:(id)drawable{(void)command;(void)drawable;self.encodes++;return YES;}
@end
@interface ReopenDrawable:NSObject<CAMetalDrawable>
@property(strong)id<MTLTexture> texture;
@property(strong)CAMetalLayer *layer;
@property CFTimeInterval presentedTime;
@property NSUInteger drawableID;
@property(strong)NSMutableArray *handlers;
-(void)emit:(double)time;
@end
@implementation ReopenDrawable
-(void)addPresentedHandler:(MTLDrawablePresentedHandler)handler{if(!self.handlers)self.handlers=[NSMutableArray new];[self.handlers addObject:[handler copy]];}
-(void)emit:(double)time{self.presentedTime=time;NSArray *handlers=[self.handlers copy];[self.handlers removeAllObjects];for(MTLDrawablePresentedHandler handler in handlers)handler(self);}
-(void)present{[self emit:1];}
-(void)presentAtTime:(double)time{[self emit:time];}
-(void)presentAfterMinimumDuration:(double)time{[self emit:time+1];}
@end
@interface ReopenCommand:NSObject
@property(strong)id drawable;
@property unsigned commits,presents;
-(void)presentDrawable:(id)drawable;
-(void)presentDrawable:(id)drawable atTime:(double)time;
-(void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration;
-(void)commit;
@end
@implementation ReopenCommand
-(void)presentDrawable:(id)drawable{self.drawable=drawable;self.presents++;}
-(void)presentDrawable:(id)drawable atTime:(double)time{(void)time;self.drawable=drawable;self.presents++;}
-(void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration{(void)duration;self.drawable=drawable;self.presents++;}
-(void)commit{self.commits++;}
@end
static void foreignCommit(id self,SEL selector){(void)self;(void)selector;}
#define check(x) do{if(!(x)){fprintf(stderr,"reopen-fixture-line:%d\n",__LINE__);return 3;}checks++;}while(0)
static ReopenRenderer *arm(uint64_t epoch){
 atomic_store(&rhgOverlayEpoch,epoch);atomic_store(&rhgOverlayGPUBlurRequested,true);
 ReopenRenderer *renderer=[ReopenRenderer new];[renderer retargetVisible:YES epoch:epoch time:CACurrentMediaTime()];
 [rhgHookLock lock];rhgOverlayBlurRenderer=renderer;[rhgHookLock unlock];
 return rhgArmOverlayBlurHooks(ReopenCommand.class)?renderer:nil;
}
static void finishClose(uint64_t epoch){
 ReopenRenderer *renderer=(ReopenRenderer*)rhgOverlayBlurRenderer;
 rhgConfigureOverlayGPUBlur(NO,epoch);rhgFinishOverlayBlurClose(epoch,renderer,CACurrentMediaTime()+1);
}
@interface FocusWarpController:NSObject @end
@implementation FocusWarpController
-(void)windowDidBecomeKey:(NSNotification*)notification{(void)notification;if(rhgWarpMouse(CGPointMake(10,10))!=kCGErrorSuccess)abort();fixtureFocusCallbackSeen=true;}
@end
int main(void){@autoreleasepool{
 unsigned checks=0;rhgPrepareHookStorage();
 SEL selectors[]={@selector(presentDrawable:),@selector(presentDrawable:atTime:),@selector(presentDrawable:afterMinimumDuration:),@selector(commit)};
 IMP originals[4];for(unsigned i=0;i<4;i++)originals[i]=class_getMethodImplementation(ReopenCommand.class,selectors[i]);
 for(unsigned cycle=0;cycle<20;cycle++){
  uint64_t epoch=cycle*2+1;ReopenRenderer *renderer=arm(epoch);check(renderer!=nil);
  check(rhgArmOverlayBlurHooks(ReopenCommand.class));
  ReopenCommand *command=[ReopenCommand new];ReopenDrawable *drawable=[ReopenDrawable new];
  switch(cycle%3){case 0:[command presentDrawable:drawable];break;case 1:[command presentDrawable:drawable atTime:1];break;default:[command presentDrawable:drawable afterMinimumDuration:0.01];break;}
  [command commit];check(renderer.encodes==1&&command.commits==1&&command.presents==1);
  [drawable emit:1];check(fixtureAckEpoch==epoch&&fixtureAckCount==cycle+1);
  atomic_store(&rhgOverlayEpoch,epoch+1);atomic_store(&rhgOverlayGPUBlurRequested,false);finishClose(epoch+1);
  for(unsigned i=0;i<4;i++)check(class_getMethodImplementation(ReopenCommand.class,selectors[i])==originals[i]);
  [command presentDrawable:drawable];[command commit];check(renderer.encodes==1&&command.commits==2);
 }
 ReopenRenderer *old=arm(41);check(old!=nil);
 ReopenCommand *oldCommand=[ReopenCommand new];ReopenDrawable *oldDrawable=[ReopenDrawable new];[oldCommand presentDrawable:oldDrawable];[oldCommand commit];
 ReopenCommand *uncommitted=[ReopenCommand new];[uncommitted presentDrawable:[ReopenDrawable new]];
 atomic_store(&rhgOverlayEpoch,42);atomic_store(&rhgOverlayGPUBlurRequested,false);finishClose(42);
 ReopenRenderer *fresh=arm(43);check(fresh!=nil);unsigned acks=fixtureAckCount;
 [oldDrawable emit:1];check(fixtureAckCount==acks&&!atomic_load(&fresh.acknowledgement->sent));
 [uncommitted commit];check(fresh.encodes==0&&uncommitted.commits==1);
 rhgConfigureOverlayGPUBlur(NO,42);check(rhgOverlayBlurRenderer==fresh);
 ReopenCommand *first=[ReopenCommand new];ReopenDrawable *dropped=[ReopenDrawable new];[first presentDrawable:dropped];[first commit];[dropped emit:0];
 check(fixtureAckCount==acks&&!atomic_load(&fresh.acknowledgement->armed));
 ReopenCommand *second=[ReopenCommand new];ReopenDrawable *presented=[ReopenDrawable new];[second presentDrawable:presented];[second commit];[presented emit:1];
 check(fixtureAckCount==acks+1&&fixtureAckEpoch==43&&fresh.encodes==2);
 [presented emit:1];check(fixtureAckCount==acks+1);
 atomic_store(&rhgOverlayEpoch,44);atomic_store(&rhgOverlayGPUBlurRequested,false);finishClose(44);
 ReopenRenderer *animated=arm(45);check(animated!=nil);animated->transition=(RHGOverlayTransition){1,1,0,0};
 double now=CACurrentMediaTime();atomic_store(&rhgOverlayEpoch,46);atomic_store(&rhgOverlayGPUBlurRequested,false);
 [animated retargetVisible:NO epoch:46 time:now];rhgConfigureOverlayGPUBlur(NO,46);
 check(rhgOverlayBlurCommandClass==ReopenCommand.class&&[animated opacityAt:now+.1]>.49&&[animated opacityAt:now+.1]<.51);
 ReopenCommand *fading=[ReopenCommand new];[fading presentDrawable:[ReopenDrawable new]];[fading commit];check(animated.encodes==1);
 double before=[animated opacityAt:now+.08];[animated retargetVisible:YES epoch:47 time:now+.08];atomic_store(&rhgOverlayEpoch,47);atomic_store(&rhgOverlayGPUBlurRequested,true);
 check(fabs([animated opacityAt:now+.08]-before)<.00001);
 rhgFinishOverlayBlurClose(46,animated,now+1);check(rhgOverlayBlurRenderer==animated);
 atomic_store(&rhgOverlayEpoch,48);atomic_store(&rhgOverlayGPUBlurRequested,false);finishClose(48);
 Method commit=class_getInstanceMethod(ReopenCommand.class,@selector(commit));method_setImplementation(commit,(IMP)foreignCommit);
 check(!rhgArmOverlayBlurHooks(ReopenCommand.class));check(method_getImplementation(commit)==(IMP)foreignCommit);
 method_setImplementation(commit,originals[3]);
 for(unsigned i=0;i<4;i++)check(class_getMethodImplementation(ReopenCommand.class,selectors[i])==originals[i]);
 RHGLogicalWindow *window=[RHGLogicalWindow new];rhgWindow=window;rhgFocused=NO;window.visible=YES;
 FocusWarpController *controller=[FocusWarpController new];window.delegate=controller;fixtureInterceptRestore=true;
 rhgDeliverInput((RHGInput){.type=RHG_FOCUS,.keyCode=1,.button=1,.modifiers=100});
 check(fixtureFocusCallbackSeen&&fixtureRestoreCalls==1&&fixtureRestoreEpoch==100&&!rhgRestoringOverlayFocus);
 window.delegate=nil;rhgWindow=nil;
 printf("{\"passed\":true,\"checks\":%u,\"openCloseCycles\":20,\"lateAckRejected\":true,\"droppedPresentationRetried\":true,\"oldCommandSkipped\":true,\"foreignHookPreserved\":true,\"gameGPUOrScreenCaptureUsed\":false}\n",checks);
 return 0;
}}
