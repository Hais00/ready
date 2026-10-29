/* SPDX-License-Identifier: GPL-3.0-only */
#include <assert.h>
#include <stdio.h>
#include <float.h>
#include "RHGPerformance.h"
#define check(value) do {assert(value);checks++;} while(0)
int main(void){unsigned checks=0;RHGPerfStats s={0};
 check(sizeof s<=600);check(RHGPerfPercentileUpperNs(&s,95)==0);
 const uint64_t values[]={0,1,2,3,4,5,10,15,16,100};
 for(unsigned i=0;i<10;i++)RHGPerfAddNanoseconds(&s,values[i]);
 check(s.count==10);check(s.sumNs==156);check(s.maxNs==100);check(!s.saturated);
 check(s.buckets[0]==1&&s.buckets[1]==1&&s.buckets[2]==2&&s.buckets[3]==2);
 check(RHGPerfPercentileUpperNs(&s,50)==7);check(RHGPerfPercentileUpperNs(&s,95)==100);check(RHGPerfPercentileUpperNs(&s,99)==100);
 check(RHGPerfPercentileUpperNs(&s,0)==0);check(RHGPerfPercentileUpperNs(&s,101)==100);
 uint64_t total=0;for(unsigned i=0;i<RHG_PERF_BUCKETS;i++)total+=s.buckets[i];check(total==s.count);
 RHGPerfStats clock={0};RHGPerfAddTicks(&clock,100,110,3,2);check(clock.count==1&&clock.sumNs==15);
 RHGPerfAddTicks(&clock,100,110,125,3);check(clock.count==2&&clock.sumNs==431);
 RHGPerfAddTicks(&clock,100,99,1,1);RHGPerfAddTicks(&clock,100,110,1,0);RHGPerfAddTicks(&clock,100,110,0,1);
 check(clock.count==2&&clock.invalidIntervals==3);
 RHGPerfAddTicks(&clock,10,10,1,1);check(clock.count==3&&clock.buckets[0]==1);
 bool saturated=false;check(RHGPerfSaturatingAdd(UINT64_MAX-1,10,&saturated)==UINT64_MAX&&saturated);
 RHGPerfStats large={0};RHGPerfAddTicks(&large,0,UINT64_MAX,UINT32_MAX,1);check(large.saturated&&large.sumNs==UINT64_MAX);
 RHGPerfAddNanoseconds(&large,1);check(large.count==2&&large.sumNs==UINT64_MAX&&large.maxNs==UINT64_MAX);
 check(RHGPerfPercentileUpperNs(&large,99)==UINT64_MAX);
 RHGPerfPresentation p={0};RHGPerfObservePresentation(&p,1);RHGPerfObservePresentation(&p,1.125);RHGPerfObservePresentation(&p,1.25);
 check(p.handlers==3&&p.positiveTimes==3&&p.interval.count==2&&p.interval.sumNs==250000000);
 RHGPerfObservePresentation(&p,1.125);RHGPerfObservePresentation(&p,1.25);
 check(p.nonIncreasingTimes==2&&p.interval.count==2&&p.lastPositiveTime==1.25);
 RHGPerfObservePresentation(&p,0);check(p.zeroOrSkippedTimes==1&&p.interval.count==2);
 RHGPerfObservePresentation(&p,NAN);RHGPerfObservePresentation(&p,-1);
 check(p.invalidTimes==2&&p.handlers==8&&p.positiveTimes==5);
 RHGPerfObservePresentation(&p,DBL_MAX);check(p.interval.invalidIntervals==1);
 printf("{\"passed\":true,\"count\":%u,\"clock\":\"controlled ticks with explicit timebase\",\"unit\":\"nanoseconds\",\"GPUOrUIOrAccountUsed\":false}\n",checks);return 0;
}
