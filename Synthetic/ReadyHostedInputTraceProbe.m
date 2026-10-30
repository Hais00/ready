// SPDX-License-Identifier: GPL-3.0-only
// Own synthetic NSEvents and host-owned journal only; no physical input/window.
#import "ReadyHostedView.m"
@interface InputTraceEvent:NSEvent @end
@implementation InputTraceEvent
-(NSEventModifierFlags)modifierFlags{return 0;}
-(NSTimeInterval)timestamp{return 123.25;}
-(NSPoint)locationInWindow{return NSMakePoint(1,1);}
-(NSInteger)buttonNumber{return 0;}
-(NSInteger)clickCount{return 0;}
-(CGFloat)deltaX{return .025;}
-(CGFloat)deltaY{return -.05;}
-(CGFloat)scrollingDeltaX{return .25;}
-(CGFloat)scrollingDeltaY{return -.5;}
-(BOOL)hasPreciseScrollingDeltas{return YES;}
-(BOOL)isDirectionInvertedFromDevice{return NO;}
-(NSEventPhase)phase{return NSEventPhaseChanged;}
-(NSEventPhase)momentumPhase{return NSEventPhaseNone;}
-(CGEventRef)CGEvent{return NULL;}
@end
@interface InputTraceHost:RHGHost
@property BOOL allowed;
@end
@implementation InputTraceHost
-(BOOL)foregroundEligible{return self.allowed;}
@end
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=3)return 64;alarm(10);[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 BOOL trace=!strcmp(argv[2],"on");unsigned checks=0;
 #define REQUIRE(value) do{checks++;if(!(value)){fprintf(stderr,"input-trace assertion %u\n",checks);return 70;}}while(0)
 NSString*path=[NSString stringWithUTF8String:argv[1]];InputTraceHost*host=[InputTraceHost new];
 host.diagnosticFD=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);REQUIRE(host.diagnosticFD>=0);
 REQUIRE(host.inputTraceEnabled==trace);host.firstFrameAnnounced=YES;host.view=[[RHGView alloc]initWithFrame:NSMakeRect(0,0,100,100)];host.view.owner=host;
 InputTraceEvent*event=[InputTraceEvent new];host.allowed=NO;[host.view scrollWheel:event];
 REQUIRE(host->inputQueue.count==0);REQUIRE(host.scrollReceived==(trace?1:0));REQUIRE(host.scrollEligibilityDropped==(trace?1:0));
 host.allowed=YES;for(unsigned i=0;i<33;i++)[host.view scrollWheel:event];
 REQUIRE(host->inputQueue.count==33);REQUIRE(host.scrollQueued==(trace?33:0));REQUIRE(host.scrollPreciseReceived==(trace?34:0));
 unsigned delivered=0;do{RHGReply reply={.op=RHG_POLL};RHGFill(host,&reply);for(unsigned i=0;i<reply.eventCount;i++)if(reply.events[i].type==RHG_SCROLL)delivered++;}while(host->inputQueue.count);
 REQUIRE(delivered==33);REQUIRE(host.scrollDelivered==(trace?33:0));
 // Real AppKit event classes reject getters which our earlier mocked event
 // implemented unconditionally. These events are constructed, never posted.
 for(unsigned precise=0;precise<2;precise++){
  CGEventRef raw=CGEventCreateScrollWheelEvent2(NULL,precise?kCGScrollEventUnitPixel:kCGScrollEventUnitLine,2,4,0,0);REQUIRE(raw!=NULL);
  if(precise)CGEventSetIntegerValueField(raw,kCGScrollWheelEventScrollPhase,kCGScrollPhaseChanged);
  NSEvent*real=[NSEvent eventWithCGEvent:raw];CFRelease(raw);REQUIRE(real!=nil);REQUIRE(real.hasPreciseScrollingDeltas==(BOOL)precise);
  NSString*exception=nil;@try{[host.view scrollWheel:real];}@catch(NSException*x){exception=x.name;fprintf(stderr,"real-wheel exception=%s\n",x.name.UTF8String);}
  REQUIRE(exception==nil);REQUIRE(host->inputQueue.count==1);RHGReply reply={.op=RHG_POLL};RHGFill(host,&reply);
  REQUIRE(reply.eventCount==1&&reply.events[0].type==RHG_SCROLL);RHGInput packed=reply.events[0];
  REQUIRE(packed.button==0&&packed.clickCount==0&&packed.scrollPrecise==precise);
  REQUIRE(packed.scrollingDeltaY==real.scrollingDeltaY);
 }
 struct{CGEventType type;uint32_t wire;CGMouseButton button;BOOL clicks;}mouseCases[]={
  {kCGEventLeftMouseDown,RHG_MOUSE_DOWN,kCGMouseButtonLeft,YES},{kCGEventLeftMouseUp,RHG_MOUSE_UP,kCGMouseButtonLeft,YES},
  {kCGEventRightMouseDown,RHG_MOUSE_DOWN,kCGMouseButtonRight,YES},{kCGEventRightMouseUp,RHG_MOUSE_UP,kCGMouseButtonRight,YES},
  {kCGEventMouseMoved,RHG_MOUSE_MOVE,kCGMouseButtonLeft,NO},{kCGEventLeftMouseDragged,RHG_MOUSE_MOVE,kCGMouseButtonLeft,NO},
  {kCGEventRightMouseDragged,RHG_MOUSE_MOVE,kCGMouseButtonRight,NO},{kCGEventOtherMouseDragged,RHG_MOUSE_MOVE,(CGMouseButton)4,NO}};
 for(unsigned i=0;i<sizeof mouseCases/sizeof*mouseCases;i++){
  CGEventRef raw=CGEventCreateMouseEvent(NULL,mouseCases[i].type,CGPointMake(2,3),mouseCases[i].button);REQUIRE(raw!=NULL);
  CGEventSetDoubleValueField(raw,kCGMouseEventDeltaX,.5);CGEventSetDoubleValueField(raw,kCGMouseEventDeltaY,-1.25);
  if(mouseCases[i].clicks)CGEventSetIntegerValueField(raw,kCGMouseEventClickState,2);
  NSEvent*real=[NSEvent eventWithCGEvent:raw];CFRelease(raw);REQUIRE(real!=nil);
  NSString*exception=nil;@try{
   switch(mouseCases[i].type){
    case kCGEventLeftMouseDown:[host.view mouseDown:real];break;
    case kCGEventLeftMouseUp:[host.view mouseUp:real];break;
    case kCGEventRightMouseDown:[host.view rightMouseDown:real];break;
    case kCGEventRightMouseUp:[host.view rightMouseUp:real];break;
    case kCGEventMouseMoved:[host.view mouseMoved:real];break;
    case kCGEventLeftMouseDragged:[host.view mouseDragged:real];break;
    case kCGEventRightMouseDragged:[host.view rightMouseDragged:real];break;
    case kCGEventOtherMouseDragged:[host.view otherMouseDragged:real];break;
    default:REQUIRE(NO);
   }
  }@catch(NSException*x){exception=x.name;fprintf(stderr,"real-pointer exception=%s\n",x.name.UTF8String);}
  REQUIRE(exception==nil);RHGInput packed={0};REQUIRE(RHGInputQueuePop(&host->inputQueue,&packed,1)==1);REQUIRE(packed.type==mouseCases[i].wire);
  REQUIRE(packed.button==(uint32_t)mouseCases[i].button);REQUIRE(packed.clickCount==(mouseCases[i].clicks?2:0));
  if(mouseCases[i].wire==RHG_MOUSE_MOVE){REQUIRE(packed.deltaX==real.deltaX&&packed.deltaY==real.deltaY);}
  else REQUIRE(packed.deltaX==0&&packed.deltaY==0);
 }
 [host shutdown];dispatch_sync(host.diagnosticQueue,^{});
 NSString*text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];REQUIRE(text.length>0);
 NSMutableArray*rows=[NSMutableArray new];unsigned checkpoints=0;
 for(NSString*line in [text componentsSeparatedByString:@"\n"]){if(!line.length)continue;NSDictionary*row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];REQUIRE([row isKindOfClass:NSDictionary.class]);[rows addObject:row];if([row[@"phase"]isEqual:@"input-scroll"])checkpoints++;
  for(NSString*key in @[@"x",@"y",@"deltaX",@"deltaY",@"scrollingDeltaX",@"scrollingDeltaY",@"characters",@"text",@"nonce",@"account",@"token"])REQUIRE(row[key]==nil);
 }
 NSDictionary*last=rows.lastObject;REQUIRE([last[@"phase"]isEqual:@"stopped"]);
 if(trace){REQUIRE(checkpoints>=4&&checkpoints<=6);REQUIRE([last[@"scrollReceived"]unsignedLongLongValue]==36);REQUIRE([last[@"scrollPreciseReceived"]unsignedLongLongValue]==35);REQUIRE([last[@"scrollEligibilityDropped"]unsignedLongLongValue]==1);REQUIRE([last[@"scrollQueued"]unsignedLongLongValue]==35);REQUIRE([last[@"scrollDelivered"]unsignedLongLongValue]==35);}
 else{REQUIRE(checkpoints==0);REQUIRE(last[@"scrollReceived"]==nil&&last[@"inputTraceEnabled"]==nil);}
 REQUIRE(!NSApp.isActive&&NSApp.windows.count==0);
 printf("{\"passed\":true,\"checks\":%u,\"traceEnabled\":%s,\"realUnpostedScrollEvents\":2,\"realUnpostedPointerEvents\":8,\"physicalInputOrGameOrWindowUsed\":false}\n",checks,trace?"true":"false");return 0;
}}
