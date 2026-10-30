// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "RHGScrollEvent.h"
static unsigned ownRawHide,ownRawShow,ownAppKitHide,ownAppKitShow;
static CGError OwnRawHide(CGDirectDisplayID display){(void)display;ownRawHide++;return 0;}
static CGError OwnRawShow(CGDirectDisplayID display){(void)display;ownRawShow++;return 0;}
static void OwnAppKitHide(id type,SEL selector){(void)type;(void)selector;ownAppKitHide++;}
static void OwnAppKitShow(id type,SEL selector){(void)type;(void)selector;ownAppKitShow++;}
// A regression must never touch the user's real cursor from this own fixture.
#define CGDisplayHideCursor OwnRawHide
#define CGDisplayShowCursor OwnRawShow
// Including the production implementation exposes only private collaborators in
// this separate executable. No activation/window/GPU/cursor mutation is used.
#import "../Sources/ReadyHostedView/ReadyHostedView.m"
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"own-scroll-check:%d\n",__LINE__);return 1;}checks++;}while(0)
@interface ScrollFixtureEvent:NSEvent
@property CGEventRef raw;
@end
@implementation ScrollFixtureEvent
-(NSEventType)type{return NSEventTypeScrollWheel;}
-(CGFloat)deltaX{return .0125;}-(CGFloat)deltaY{return -.0375;}
-(CGFloat)scrollingDeltaX{return .125;}-(CGFloat)scrollingDeltaY{return -.375;}
-(BOOL)hasPreciseScrollingDeltas{return YES;}-(BOOL)isDirectionInvertedFromDevice{return YES;}
-(NSEventPhase)phase{return NSEventPhaseChanged;}-(NSEventPhase)momentumPhase{return NSEventPhaseBegan;}
-(CGEventRef)CGEvent{return self.raw;}
-(NSPoint)locationInWindow{return NSMakePoint(10,20);}-(NSEventModifierFlags)modifierFlags{return NSEventModifierFlagShift;}
-(NSTimeInterval)timestamp{return 123.25;}-(NSInteger)buttonNumber{return 0;}-(NSInteger)clickCount{return 0;}
@end
@interface ScrollFixtureHost:RHGHost
@end
@implementation ScrollFixtureHost
-(BOOL)foregroundEligible{return !self.overlayVisible;}
-(void)reconcilePointerWithEligibility:(BOOL)eligible{(void)eligible;}
-(void)reconcilePointer{}
@end
int main(void){@autoreleasepool{unsigned checks=0;
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 CGEventRef raw=CGEventCreateScrollWheelEvent2(NULL,kCGScrollEventUnitPixel,2,0,0,0);
 CGEventSetDoubleValueField(raw,kCGScrollWheelEventFixedPtDeltaAxis1,-.375);CGEventSetDoubleValueField(raw,kCGScrollWheelEventFixedPtDeltaAxis2,.125);
 CGEventSetIntegerValueField(raw,kCGScrollWheelEventScrollPhase,kCGScrollPhaseChanged);CGEventSetIntegerValueField(raw,kCGScrollWheelEventMomentumPhase,kCGMomentumScrollPhaseBegin);
 CGEventSetIntegerValueField(raw,kCGScrollWheelEventPointDeltaAxis1,-1);CGEventSetIntegerValueField(raw,kCGScrollWheelEventPointDeltaAxis2,1);
 ScrollFixtureEvent *event=[ScrollFixtureEvent new];event.raw=raw;
 RHGInput packed={.type=RHG_SCROLL};REQUIRE(RHGCaptureScrollEvent(event,&packed));
 REQUIRE(packed.deltaY==-.0375&&packed.scrollingDeltaY==-.375&&packed.scrollingDeltaX==.125);
 REQUIRE(packed.scrollPrecise==1&&packed.scrollInverted==1&&packed.scrollPhase==NSEventPhaseChanged&&packed.scrollMomentumPhase==NSEventPhaseBegan);
 CGEventRef rebuilt=RHGCreateScrollEvent(&packed);REQUIRE(rebuilt!=NULL);
 fprintf(stderr,"own fixed packed=%g rebuilt=%g point=%lld line=%lld\n",packed.scrollFixedY,CGEventGetDoubleValueField(rebuilt,kCGScrollWheelEventFixedPtDeltaAxis1),(long long)CGEventGetIntegerValueField(rebuilt,kCGScrollWheelEventPointDeltaAxis1),(long long)CGEventGetIntegerValueField(rebuilt,kCGScrollWheelEventDeltaAxis1));
 REQUIRE(fabs(CGEventGetDoubleValueField(rebuilt,kCGScrollWheelEventFixedPtDeltaAxis1)-packed.scrollFixedY)<1e-9);
 REQUIRE(CGEventGetIntegerValueField(rebuilt,kCGScrollWheelEventPointDeltaAxis1)==-1&&CGEventGetIntegerValueField(rebuilt,kCGScrollWheelEventIsContinuous)==1);
 REQUIRE(CGEventGetIntegerValueField(rebuilt,kCGScrollWheelEventScrollPhase)==kCGScrollPhaseChanged&&CGEventGetIntegerValueField(rebuilt,kCGScrollWheelEventMomentumPhase)==kCGMomentumScrollPhaseBegin);
 ScrollFixtureHost *host=[ScrollFixtureHost new];host.firstFrameAnnounced=YES;host.view=[[RHGView alloc]initWithFrame:NSMakeRect(0,0,100,100)];host.view.owner=host;
 Class cursor=object_getClass(NSCursor.class);Method hide=class_getInstanceMethod(cursor,@selector(hide)),show=class_getInstanceMethod(cursor,@selector(unhide));
 IMP originalHide=method_setImplementation(hide,(IMP)OwnAppKitHide),originalShow=method_setImplementation(show,(IMP)OwnAppKitShow);
 REQUIRE(RHGHide(NULL)==0&&ownAppKitHide==1&&ownRawHide==0);host->pointer.hidden=true;host->pointer.captured=true;
 for(unsigned i=0;i<100;i++)[host input:event type:RHG_SCROLL];
 NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:.05];while(limit.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
 REQUIRE(ownAppKitHide==1&&ownAppKitShow==0&&ownRawHide==0&&ownRawShow==0);
 RHGInputQueueClear(&host->inputQueue);RHGHostSetOverlayVisible((__bridge RHGHostRef)host,true);
 REQUIRE(ownAppKitShow==1&&!host->pointer.hidden&&!host->pointer.captured);RHGHostSetOverlayVisible((__bridge RHGHostRef)host,false);RHGInputQueueClear(&host->inputQueue);
 method_setImplementation(hide,originalHide);method_setImplementation(show,originalShow);
 [host input:event type:RHG_SCROLL];RHGInput result[8]={0};REQUIRE(RHGInputQueuePop(&host->inputQueue,result,8)==1&&result[0].scrollingDeltaY==-.375&&result[0].timestamp==123.25);
 event.raw=raw;RHGHostRef handle=(__bridge RHGHostRef)host;
 [host input:event type:RHG_SCROLL];RHGHostSetOverlayVisible(handle,true);
 REQUIRE(host.overlayVisible&&RHGInputQueuePop(&host->inputQueue,result,8)==1&&result[0].type==RHG_FOCUS&&result[0].keyCode==0);
 [host input:event type:RHG_SCROLL];REQUIRE(host->inputQueue.count==0);
 RHGHostSetOverlayVisible(handle,false);[host input:event type:RHG_SCROLL];REQUIRE(RHGInputQueuePop(&host->inputQueue,result,8)==2&&result[0].type==RHG_FOCUS&&result[1].type==RHG_SCROLL);
 REQUIRE(!NSApp.isActive&&NSApp.windows.count==0);
 CFRelease(raw);CFRelease(rebuilt);
 printf("{\"passed\":true,\"count\":%u,\"physicalCursorOrInputPosted\":false,\"windowOrGameOrAccountUsed\":false}\n",checks);return 0;
}}
