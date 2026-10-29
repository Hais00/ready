/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RHG_SCROLL_EVENT_H
#define RHG_SCROLL_EVENT_H
#include "ReadyHostedGameProtocol.h"
#include <math.h>
#include <stdbool.h>
static inline bool RHGScrollInputValid(const RHGInput *input){
 return input->scrollPrecise<=1&&input->scrollInverted<=1&&!(input->scrollPhase&~63u)&&!(input->scrollMomentumPhase&~63u)
  &&isfinite(input->scrollingDeltaX)&&isfinite(input->scrollingDeltaY)&&isfinite(input->scrollFixedX)&&isfinite(input->scrollFixedY)
  &&fabs(input->scrollingDeltaX)<1000000&&fabs(input->scrollingDeltaY)<1000000&&fabs(input->scrollFixedX)<32768&&fabs(input->scrollFixedY)<32768;
}
#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
static inline bool RHGCaptureScrollEvent(NSEvent *event,RHGInput *input){
 input->deltaX=event.deltaX;input->deltaY=event.deltaY;
 input->scrollingDeltaX=event.scrollingDeltaX;input->scrollingDeltaY=event.scrollingDeltaY;
 input->scrollPrecise=event.hasPreciseScrollingDeltas;input->scrollInverted=event.isDirectionInvertedFromDevice;
 input->scrollPhase=(uint32_t)event.phase;input->scrollMomentumPhase=(uint32_t)event.momentumPhase;
 CGEventRef cg=event.CGEvent;
 input->scrollFixedX=cg?CGEventGetDoubleValueField(cg,kCGScrollWheelEventFixedPtDeltaAxis2):input->scrollingDeltaX;
 input->scrollFixedY=cg?CGEventGetDoubleValueField(cg,kCGScrollWheelEventFixedPtDeltaAxis1):input->scrollingDeltaY;
 input->scrollLineX=cg?CGEventGetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis2):0;
 input->scrollLineY=cg?CGEventGetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis1):0;
 input->scrollPointX=cg?CGEventGetIntegerValueField(cg,kCGScrollWheelEventPointDeltaAxis2):0;
 input->scrollPointY=cg?CGEventGetIntegerValueField(cg,kCGScrollWheelEventPointDeltaAxis1):0;
 input->scrollCGPhase=cg?(uint32_t)CGEventGetIntegerValueField(cg,kCGScrollWheelEventScrollPhase):0;
 input->scrollCGMomentumPhase=cg?(uint32_t)CGEventGetIntegerValueField(cg,kCGScrollWheelEventMomentumPhase):0;
 return RHGScrollInputValid(input);
}
static inline CGEventRef RHGCreateScrollEvent(const RHGInput *input){
 if(!RHGScrollInputValid(input))return NULL;
 CGEventRef cg=CGEventCreateScrollWheelEvent2(NULL,input->scrollPrecise?kCGScrollEventUnitPixel:kCGScrollEventUnitLine,2,0,0,0);
 if(!cg)return NULL;
 CGEventSetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis2,input->scrollLineX);
 CGEventSetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis1,input->scrollLineY);
 CGEventSetIntegerValueField(cg,kCGScrollWheelEventPointDeltaAxis2,input->scrollPointX);
 CGEventSetIntegerValueField(cg,kCGScrollWheelEventPointDeltaAxis1,input->scrollPointY);
 /* Setting the line fields resets fixed-point values in CoreGraphics. Restore
  * native fractional values LAST, after the integral representations. */
 CGEventSetDoubleValueField(cg,kCGScrollWheelEventFixedPtDeltaAxis2,input->scrollFixedX);
 CGEventSetDoubleValueField(cg,kCGScrollWheelEventFixedPtDeltaAxis1,input->scrollFixedY);
 CGEventSetIntegerValueField(cg,kCGScrollWheelEventIsContinuous,input->scrollPrecise);
 CGEventSetIntegerValueField(cg,kCGScrollWheelEventScrollPhase,input->scrollCGPhase);
 CGEventSetIntegerValueField(cg,kCGScrollWheelEventMomentumPhase,input->scrollCGMomentumPhase);
 return cg;
}
#endif
#endif
