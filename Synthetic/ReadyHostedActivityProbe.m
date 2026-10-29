// SPDX-License-Identifier: GPL-3.0-only
// Appended to a private constructor-disabled shim; no game/UI/GPU/account.
static _Atomic unsigned activityBegins,activityEnds;
static BOOL activityOptionsValid=YES,activityBeganOffMain,activityLogEdges;
static id activityMockToken;
static id activityMockBegin(id self,SEL selector,NSActivityOptions options,NSString*reason){
 (void)self;(void)selector;atomic_fetch_add(&activityBegins,1);activityOptionsValid=activityOptionsValid&&options==NSActivityUserInitiatedAllowingIdleSystemSleep&&!(options&NSActivityLatencyCritical)&&!(options&NSActivityIdleSystemSleepDisabled)&&!(options&NSActivityIdleDisplaySleepDisabled)&&[reason isEqualToString:@"Hosted game active in Ready"];
 activityBeganOffMain=!NSThread.isMainThread;activityMockToken=[NSObject new];if(activityLogEdges)fprintf(stderr,"{\"type\":\"fixture-activity-began\"}\n");return activityMockToken;
}
static void activityMockEnd(id self,SEL selector,id token){(void)self;(void)selector;if(token!=activityMockToken)_exit(85);activityMockToken=nil;atomic_fetch_add(&activityEnds,1);if(activityLogEdges)fprintf(stderr,"{\"type\":\"fixture-activity-ended\"}\n");}
static BOOL activityHeld(void){NSLock*l=rhgRenderActivityLock();[l lock];BOOL held=rhgRenderActivityToken!=nil;[l unlock];return held;}
static BOOL activityWait(BOOL(^condition)(void)){double end=CACurrentMediaTime()+3;while(!condition()&&CACurrentMediaTime()<end)usleep(1000);return condition();}
#define CHECK(c) do{if(!(c)){fprintf(stderr,"activity-fixture-check:%d\n",__LINE__);return 81;}}while(0)
static void activityServer(mach_port_t port,BOOL bad,BOOL holdFocus){unsigned polls=0;uint32_t depth=2;for(;;){@autoreleasepool{
 RHGRequestReceive incoming={0};if(mach_msg(&incoming.message.h,MACH_RCV_MSG,0,sizeof incoming,port,MACH_MSG_TIMEOUT_NONE,0))_exit(82);RHGRequest q=incoming.message;RHGReply r={0};r.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);r.h.msgh_remote_port=q.h.msgh_remote_port;r.h.msgh_size=sizeof r;r.magic=RHG_MAGIC;r.version=RHG_VERSION;r.op=q.op;r.requestID=q.requestID;r.status=RHG_OK;if(q.op==RHG_HELLO)depth=q.framesInFlight;r.framesInFlight=depth;r.configurationGeneration=1;r.window=4242;r.width=640;r.height=360;r.pixelFormat=80;r.deviceRegistryID=1;r.backingScale=2;r.logicalWidth=320;r.logicalHeight=180;r.pointerX=r.pointerY=.5;
 if(q.op==RHG_POLL&&polls<3){polls++;r.eventCount=1;r.events[0].type=RHG_FOCUS;r.events[0].keyCode=(polls<=2||holdFocus)?1:0;if(polls==3)usleep(30000);if(bad)r.requestID++;}
 if(q.op==RHG_DONE||q.op==RHG_POINTER_CURSOR)r.status=RHG_STOPPED;
 if(mach_msg(&r.h,MACH_SEND_MSG,sizeof r,0,MACH_PORT_NULL,MACH_MSG_TIMEOUT_NONE,0))_exit(83);
}}}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 64;alarm(10);const char*mode=argv[1];unsigned checks=0;
 if(!strcmp(mode,"actual")){
  dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL began=NO,ended=NO;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{rhgActivityForTrustedFocus((RHGInput){.type=RHG_FOCUS,.keyCode=1});began=activityHeld();rhgActivityForTrustedFocus((RHGInput){.type=RHG_FOCUS,.keyCode=0});ended=!activityHeld();dispatch_semaphore_signal(done);});
  CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0&&began&&ended);printf("{\"passed\":true,\"checks\":1,\"actualOwnProcessActivityBeginEnd\":true,\"gameUIOrAccountUsed\":false}\n");return 0;
 }
 Class type=object_getClass(NSProcessInfo.processInfo);Method begin=class_getInstanceMethod(type,@selector(beginActivityWithOptions:reason:)),end=class_getInstanceMethod(type,@selector(endActivity:));CHECK(begin&&end);method_setImplementation(begin,(IMP)activityMockBegin);method_setImplementation(end,(IMP)activityMockEnd);
 if(!strcmp(mode,"poll")||!strcmp(mode,"bad-reply")||!strcmp(mode,"stop")||!strcmp(mode,"stop-return")){
  activityLogEdges=strcmp(mode,"poll")!=0;mach_port_t port=0;CHECK(!mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port));CHECK(!mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND));CHECK(!bootstrap_register(bootstrap_port,(char*)getenv("READY_HOSTED_GAME_SERVICE"),port));
  BOOL bad=!strcmp(mode,"bad-reply");dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{activityServer(port,bad,!strcmp(mode,"stop")||!strcmp(mode,"stop-return"));});rhgConnect();
  CHECK(activityWait(^BOOL{return atomic_load(&activityBegins)==1;}));checks++;
  CHECK(rhgWindow==nil&&activityBeganOffMain);checks++;
  if(!strcmp(mode,"stop")){rhgExchange(RHG_DONE,(RHGRequest){0});return 84;}
  if(!strcmp(mode,"stop-return")){RHGReply r=rhgExchange(RHG_POINTER_CURSOR,(RHGRequest){.pointerAction=RHG_CURSOR_HIDE});CHECK(r.status==RHG_STOPPED&&!activityHeld());checks++;rhgActivityForTrustedFocus((RHGInput){.type=RHG_FOCUS,.keyCode=1});CHECK(!activityHeld());checks++;}
  CHECK(activityWait(^BOOL{return atomic_load(&activityEnds)==1;}));checks++;
  CHECK(atomic_load(&activityBegins)==1&&!activityHeld()&&activityOptionsValid);checks++;
 }else{
  rhgActivityForTrustedFocus((RHGInput){.type=RHG_MOUSE_MOVE,.keyCode=1});rhgActivityForTrustedFocus((RHGInput){.type=RHG_FOCUS,.keyCode=2});CHECK(!activityHeld()&&!atomic_load(&activityBegins));checks++;
  dispatch_group_t group=dispatch_group_create();for(unsigned i=0;i<20;i++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{rhgActivityForTrustedFocus((RHGInput){.type=RHG_FOCUS,.keyCode=1});});CHECK(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);CHECK(activityHeld()&&atomic_load(&activityBegins)==1&&activityOptionsValid);checks++;
  for(unsigned i=0;i<20;i++)rhgActivityForTrustedFocus((RHGInput){.type=RHG_FOCUS,.keyCode=0});CHECK(!activityHeld()&&atomic_load(&activityEnds)==1);checks++;
  rhgActivityForTrustedFocus((RHGInput){.type=RHG_FOCUS,.keyCode=1});CHECK(activityHeld()&&atomic_load(&activityBegins)==2);checks++;
  if(!strcmp(mode,"close")){RHGLogicalWindow*window=[RHGLogicalWindow alloc];rhgWindow=window;[window close];CHECK(rhgWindow==nil);}else rhgStopRenderActivity();
  CHECK(!activityHeld()&&atomic_load(&activityEnds)==2);checks++;
  rhgActivityForTrustedFocus((RHGInput){.type=RHG_FOCUS,.keyCode=1});rhgStopRenderActivity();CHECK(!activityHeld()&&atomic_load(&activityBegins)==2&&atomic_load(&activityEnds)==2);checks++;
 }
 printf("{\"passed\":true,\"checks\":%u,\"minimumOptions\":true,\"oneIdempotentToken\":true,\"globalPreferencesChanged\":false,\"gameUIOrAccountUsed\":false}\n",checks);return 0;
}}
