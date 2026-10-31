/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RHG_POINTER_STATE_H
#define RHG_POINTER_STATE_H
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <CoreGraphics/CGError.h>
#include "ReadyHostedGameProtocol.h"
typedef struct {int32_t(*associate)(bool,void*);int32_t(*hide)(void*);int32_t(*show)(void*);int32_t(*anchor)(void*);void*context;} RHGPointerOps;
typedef struct {bool detached,hidden,captured,anchored;int32_t error;} RHGPointerState;
typedef struct {bool valid,warp;double x,y;} RHGPointerAnchorPlan;
static inline RHGPointerAnchorPlan RHGPlanPointerAnchor(double x,double y,double left,double bottom,double width,double height){
 if(!isfinite(x)||!isfinite(y)||!isfinite(left)||!isfinite(bottom)||!isfinite(width)||!isfinite(height)||width<=0||height<=0)return(RHGPointerAnchorPlan){0};
 bool inside=x>=left&&x<left+width&&y>=bottom&&y<bottom+height;
 return(RHGPointerAnchorPlan){true,!inside,inside?x:left+width*.5,inside?y:bottom+height*.5};
}
static inline void RHGPointerRelease(RHGPointerState*s,RHGPointerOps ops){
 s->captured=false;s->anchored=false;s->error=0;
 if(s->detached){int32_t e=ops.associate(true,ops.context);if(!e)s->detached=false;else s->error=e;}
 if(s->hidden){int32_t e=ops.show(ops.context);if(!e)s->hidden=false;else s->error=e;}
}
static inline void RHGPointerReconcile(RHGPointerState*s,RHGPointerOps ops,bool allowed){
 if(!allowed){RHGPointerRelease(s,ops);return;}if(s->captured)return;
 if(s->detached||s->hidden){RHGPointerRelease(s,ops);if(s->detached||s->hidden)return;}
 s->error=ops.associate(false,ops.context);if(s->error)return;s->detached=true;
 s->error=ops.hide(ops.context);if(s->error){int32_t e=ops.associate(true,ops.context);if(!e)s->detached=false;return;}
 s->hidden=true;
 int32_t anchor=ops.anchor?ops.anchor(ops.context):kCGErrorInvalidOperation;
 if(anchor){RHGPointerRelease(s,ops);s->error=anchor;return;}
 s->anchored=true;s->captured=true;
}
/* AppKit can unhide its process cursor after a gesture. Re-arm our ONE owned
 * hide by balancing it first; repeated gestures never accumulate hide counts. */
static inline bool RHGPointerRehideIfVisible(RHGPointerState*s,RHGPointerOps ops,bool visible){
 if(!visible||!s->captured||!s->hidden)return true;
 int32_t error=ops.show(ops.context);
 if(error){RHGPointerRelease(s,ops);s->error=error;return false;}
 s->hidden=false;error=ops.hide(ops.context);
 if(error){RHGPointerRelease(s,ops);s->error=error;return false;}
 s->hidden=true;s->error=0;return true;
}
typedef struct {bool associated,initialized,hiddenUntilMove;uint32_t hideCount;double x,y;} RHGVirtualPointer;
static inline int32_t RHGVirtualPointerRequest(RHGVirtualPointer*v,uint32_t op,uint32_t action,double x,double y,bool foreground){
 if(!foreground)return kCGErrorInvalidOperation;
 if(op==RHG_POINTER_ASSOCIATE){if(action>1)return kCGErrorIllegalArgument;v->associated=action!=0;}
 else if(op==RHG_POINTER_WARP){if(!isfinite(x)||!isfinite(y)||x<0||x>1||y<0||y>1)return kCGErrorIllegalArgument;v->x=x;v->y=y;v->initialized=true;}
 else if(op==RHG_POINTER_CURSOR){switch(action){case RHG_CURSOR_HIDE:if(v->hideCount>=1024)return kCGErrorRangeCheck;v->hideCount++;break;case RHG_CURSOR_SHOW:if(v->hideCount)v->hideCount--;break;case RHG_CURSOR_HIDE_UNTIL_MOVE:v->hiddenUntilMove=true;break;case RHG_CURSOR_CANCEL_UNTIL_MOVE:v->hiddenUntilMove=false;break;default:return kCGErrorIllegalArgument;}}
 else return kCGErrorInvalidOperation;
 return 0;
}
static inline bool RHGVirtualPointerMove(RHGVirtualPointer*v,double dx,double dy,double width,double height){
 if(!isfinite(dx)||!isfinite(dy)||!isfinite(width)||!isfinite(height)||width<=0||height<=0)return false;
 v->x=fmax(0,fmin(1,v->x+dx/width));v->y=fmax(0,fmin(1,v->y+dy/height));v->hiddenUntilMove=false;return true;
}
#endif
