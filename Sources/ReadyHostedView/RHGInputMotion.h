/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RHG_INPUT_MOTION_H
#define RHG_INPUT_MOTION_H
#include "RHGPointerState.h"
#include <string.h>
/* NSEvent deltas keep the game's native AppKit scaling. Disassociation freezes
 * the absolute point while relative movement continues in the event itself. */
static inline bool RHGInputPointerMove(RHGVirtualPointer*v,double dx,double dy,double width,double height){
 if(!isfinite(dx)||!isfinite(dy)||!isfinite(width)||!isfinite(height)||width<=0||height<=0)return false;
 v->hiddenUntilMove=false;
 return !v->associated||RHGVirtualPointerMove(v,dx,dy,width,height);
}
/* Caller enforces contiguity and clears its merge permission at a virtual warp
 * or association change. Never combine across a control, focus or modifier. */
static inline bool RHGInputMergeMotion(RHGInput previous,RHGInput incoming,RHGInput*result){
 if(previous.type!=RHG_MOUSE_MOVE||incoming.type!=RHG_MOUSE_MOVE||previous.button!=incoming.button||previous.modifiers!=incoming.modifiers||
    !isfinite(previous.timestamp)||!isfinite(incoming.timestamp)||incoming.timestamp<previous.timestamp||
    !isfinite(incoming.x)||!isfinite(incoming.y)||!isfinite(previous.deltaX)||!isfinite(previous.deltaY)||!isfinite(incoming.deltaX)||!isfinite(incoming.deltaY))return false;
 double dx=previous.deltaX+incoming.deltaX,dy=previous.deltaY+incoming.deltaY;
 if(!isfinite(dx)||!isfinite(dy))return false;
 *result=incoming;result->deltaX=dx;result->deltaY=dy;return true;
}
#define RHG_INPUT_QUEUE_CAPACITY 128
/* Host main-thread owned. Control events are never silently discarded. */
typedef struct {RHGInput events[RHG_INPUT_QUEUE_CAPACITY];uint32_t count;bool mergeAllowed;} RHGInputQueue;
static inline void RHGInputQueueBarrier(RHGInputQueue*q){q->mergeAllowed=false;}
static inline void RHGInputQueueClear(RHGInputQueue*q){q->count=0;q->mergeAllowed=false;}
static inline bool RHGInputQueuePush(RHGInputQueue*q,RHGInput event){
 RHGInput merged;
 if(q->count&&q->mergeAllowed&&RHGInputMergeMotion(q->events[q->count-1],event,&merged)){q->events[q->count-1]=merged;return true;}
 if(q->count>=RHG_INPUT_QUEUE_CAPACITY){
  uint32_t motion=0;while(motion<q->count&&q->events[motion].type!=RHG_MOUSE_MOVE)motion++;
  if(motion==q->count)return false;
  memmove(q->events+motion,q->events+motion+1,(q->count-motion-1)*sizeof(RHGInput));q->count--;
 }
 q->events[q->count++]=event;q->mergeAllowed=event.type==RHG_MOUSE_MOVE;return true;
}
static inline uint32_t RHGInputQueuePop(RHGInputQueue*q,RHGInput*out,uint32_t capacity){
 uint32_t count=q->count<capacity?q->count:capacity;
 memcpy(out,q->events,count*sizeof(RHGInput));q->count-=count;
 memmove(q->events,q->events+count,q->count*sizeof(RHGInput));if(!q->count)q->mergeAllowed=false;return count;
}
#endif
