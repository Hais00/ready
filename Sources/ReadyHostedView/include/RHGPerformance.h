/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef READY_HOSTED_PERFORMANCE_H
#define READY_HOSTED_PERFORMANCE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <limits.h>
#include <math.h>
#define RHG_PERF_BUCKETS 64
#define RHG_PERF_OPERATIONS 12
/* Fixed-size log2 nanosecond histogram. Percentiles are bucket upper bounds,
 * clamped to the observed maximum, never exact per-frame samples. */
typedef struct {
 uint64_t count,sumNs,maxNs,buckets[RHG_PERF_BUCKETS],invalidIntervals;
 bool saturated;
} RHGPerfStats;
static inline uint64_t RHGPerfSaturatingAdd(uint64_t a,uint64_t b,bool *saturated){
 if(UINT64_MAX-a<b){if(saturated)*saturated=true;return UINT64_MAX;}return a+b;
}
static inline void RHGPerfAddNanoseconds(RHGPerfStats *s,uint64_t ns){
 unsigned bucket=ns?64u-(unsigned)__builtin_clzll(ns):0;if(bucket>=RHG_PERF_BUCKETS)bucket=RHG_PERF_BUCKETS-1;
 s->count=RHGPerfSaturatingAdd(s->count,1,&s->saturated);
 s->sumNs=RHGPerfSaturatingAdd(s->sumNs,ns,&s->saturated);if(ns>s->maxNs)s->maxNs=ns;
 s->buckets[bucket]=RHGPerfSaturatingAdd(s->buckets[bucket],1,&s->saturated);
}
static inline void RHGPerfAddTicks(RHGPerfStats *s,uint64_t begin,uint64_t end,uint32_t numer,uint32_t denom){
 if(end<begin||!numer||!denom){s->invalidIntervals=RHGPerfSaturatingAdd(s->invalidIntervals,1,&s->saturated);return;}
 __uint128_t converted=(__uint128_t)(end-begin)*numer/denom;
 if(converted>UINT64_MAX){s->saturated=true;converted=UINT64_MAX;}
 RHGPerfAddNanoseconds(s,(uint64_t)converted);
}
static inline uint64_t RHGPerfPercentileUpperNs(const RHGPerfStats *s,unsigned percentile){
 if(!s->count)return 0;if(percentile>100)percentile=100;if(!percentile)percentile=1;
 uint64_t rank=(s->count/100)*percentile+((s->count%100)*percentile+99)/100,total=0;
 for(unsigned i=0;i<RHG_PERF_BUCKETS;i++){
  total=RHGPerfSaturatingAdd(total,s->buckets[i],NULL);
  if(total>=rank){uint64_t upper=i==63?UINT64_MAX:(i?(UINT64_C(1)<<i)-1:0);return upper<s->maxNs?upper:s->maxNs;}
 }
 return s->maxNs;
}
typedef struct {
 RHGPerfStats interval;
 uint64_t handlers,positiveTimes,zeroOrSkippedTimes,invalidTimes,nonIncreasingTimes;
 double lastPositiveTime;
} RHGPerfPresentation;
static inline void RHGPerfObservePresentation(RHGPerfPresentation *s,double time){
 s->handlers=RHGPerfSaturatingAdd(s->handlers,1,NULL);
 if(!isfinite(time)||time<0){s->invalidTimes=RHGPerfSaturatingAdd(s->invalidTimes,1,NULL);return;}
 if(time==0){s->zeroOrSkippedTimes=RHGPerfSaturatingAdd(s->zeroOrSkippedTimes,1,NULL);return;}
 s->positiveTimes=RHGPerfSaturatingAdd(s->positiveTimes,1,NULL);
 if(s->lastPositiveTime>0){
  if(time<=s->lastPositiveTime){s->nonIncreasingTimes=RHGPerfSaturatingAdd(s->nonIncreasingTimes,1,NULL);return;}
  long double ns=((long double)time-s->lastPositiveTime)*1000000000.0L;
  if(ns<18446744073709551616.0L)RHGPerfAddNanoseconds(&s->interval,(uint64_t)ns);
  else s->interval.invalidIntervals=RHGPerfSaturatingAdd(s->interval.invalidIntervals,1,NULL);
 }
 s->lastPositiveTime=time;
}
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
static inline bool RHGPerfProfileEnabled(void){
 static bool enabled;static dispatch_once_t once;
 dispatch_once(&once,^{const char *v=getenv("RHG_PERF_PROFILE");enabled=v&&strcmp(v,"1")==0;});return enabled;
}
static inline uint64_t RHGPerfNow(void){return RHGPerfProfileEnabled()?mach_continuous_time():0;}
static inline void RHGPerfInterval(RHGPerfStats *s,uint64_t begin,uint64_t end){
 if(!begin)return;static mach_timebase_info_data_t base;static dispatch_once_t once;
 dispatch_once(&once,^{mach_timebase_info(&base);});RHGPerfAddTicks(s,begin,end,base.numer,base.denom);
}
static inline NSString *RHGPerfOperationName(unsigned op){
 switch(op){case 1:return @"hello";case 2:return @"configure";case 3:return @"acquire";case 4:return @"present";case 5:return @"poll";case 6:return @"done";case 7:return @"pointer_associate";case 8:return @"pointer_warp";case 9:return @"pointer_cursor";case 10:return @"remote_attach";case 11:return @"remote_first_frame";default:return @"unknown";}
}
static inline NSDictionary *RHGPerfStatsJSON(const RHGPerfStats *s){
 NSMutableArray *hist=[NSMutableArray arrayWithCapacity:RHG_PERF_BUCKETS];
 for(unsigned i=0;i<RHG_PERF_BUCKETS;i++)[hist addObject:@(s->buckets[i])];
 return @{@"count":@(s->count),@"sumNs":@(s->sumNs),@"maxNs":@(s->maxNs),
  @"p50UpperNs":@(RHGPerfPercentileUpperNs(s,50)),@"p95UpperNs":@(RHGPerfPercentileUpperNs(s,95)),@"p99UpperNs":@(RHGPerfPercentileUpperNs(s,99)),
  @"histogramLog2Ns":hist,@"invalidIntervals":@(s->invalidIntervals),@"saturated":@(s->saturated)};
}
static inline NSDictionary *RHGPerfPresentationJSON(const RHGPerfPresentation *s){
 return @{@"handlers":@(s->handlers),@"positivePresentedTimes":@(s->positiveTimes),@"zeroOrSkippedPresentedTimes":@(s->zeroOrSkippedTimes),
  @"invalidPresentedTimes":@(s->invalidTimes),@"nonIncreasingPresentedTimes":@(s->nonIncreasingTimes),@"interval":RHGPerfStatsJSON(&s->interval)};
}
#endif
#endif
