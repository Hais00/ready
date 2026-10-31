/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RHG_OVERLAY_TRANSITION_H
#define RHG_OVERLAY_TRANSITION_H
#include <math.h>
typedef struct {double from,to,began,duration;} RHGOverlayTransition;
static inline double RHGOverlayTransitionValue(RHGOverlayTransition t,double now){
 if(t.duration<=0)return t.to;
 double p=fmax(0,fmin(1,(now-t.began)/t.duration));p=p*p*(3-2*p);
 return t.from+(t.to-t.from)*p;
}
static inline void RHGOverlayTransitionRetarget(RHGOverlayTransition*t,double target,double now,double duration){
 *t=(RHGOverlayTransition){RHGOverlayTransitionValue(*t,now),target,now,duration};
}
static inline double RHGOverlayTransitionTrackValue(RHGOverlayTransition current,RHGOverlayTransition previous,double now){
 return RHGOverlayTransitionValue(now<current.began?previous:current,now);
}
#endif
