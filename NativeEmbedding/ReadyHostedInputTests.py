#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own production input policy probe; no UI, hardware, CG mutations or accounts."""
import hashlib,json,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
SOURCE=r'''
#include <assert.h>
#include <float.h>
#include <stdio.h>
#include "RHGInputMotion.h"
int main(void){unsigned count=0;RHGVirtualPointer v={.associated=false,.x=.4,.y=.6,.hiddenUntilMove=true};
 assert(RHGInputPointerMove(&v,12,-8,100,100)&&v.x==.4&&v.y==.6&&!v.hiddenUntilMove);count++;
 assert(!RHGVirtualPointerRequest(&v,RHG_POINTER_WARP,0,.2,.8,true));assert(v.x==.2&&v.y==.8);
 assert(RHGInputPointerMove(&v,10,-10,100,100)&&v.x==.2&&v.y==.8);count++;
 assert(!RHGVirtualPointerRequest(&v,RHG_POINTER_ASSOCIATE,1,0,0,true));assert(RHGInputPointerMove(&v,10,-10,100,100));assert(fabs(v.x-.3)<1e-12&&fabs(v.y-.7)<1e-12);count++;
 assert(!RHGInputPointerMove(&v,NAN,0,100,100));count++;
 RHGInput motion={.type=RHG_MOUSE_MOVE,.deltaX=.25,.deltaY=-.5,.x=.1,.y=.2,.timestamp=1},merged=motion;
 for(unsigned i=1;i<1000;i++){RHGInput next=motion;next.timestamp=1+i*.001;next.x=.9;next.y=.8;assert(RHGInputMergeMotion(merged,next,&merged));}
 assert(merged.deltaX==250&&merged.deltaY==-500&&merged.x==.9&&merged.y==.8&&merged.timestamp==1.999);count++;
 for(unsigned type=RHG_KEY_DOWN;type<=RHG_FOCUS;type++){if(type==RHG_MOUSE_MOVE)continue;RHGInput barrier=motion;barrier.type=type;assert(!RHGInputMergeMotion(motion,barrier,&merged)&&!RHGInputMergeMotion(barrier,motion,&merged));}count++;
 RHGInput next=motion;next.modifiers=1;assert(!RHGInputMergeMotion(motion,next,&merged));next=motion;next.button=1;assert(!RHGInputMergeMotion(motion,next,&merged));count++;
 next=motion;next.timestamp=.5;assert(!RHGInputMergeMotion(motion,next,&merged));next.timestamp=NAN;assert(!RHGInputMergeMotion(motion,next,&merged));count++;
 next=motion;next.deltaX=DBL_MAX;motion.deltaX=DBL_MAX;assert(!RHGInputMergeMotion(motion,next,&merged));count++;
 RHGInputQueue q={0};motion=(RHGInput){.type=RHG_MOUSE_MOVE,.deltaX=.25,.deltaY=-.5,.timestamp=1};
 for(unsigned i=0;i<1000;i++){motion.timestamp=1+i*.001;assert(RHGInputQueuePush(&q,motion));}assert(q.count==1&&q.events[0].deltaX==250);count++;
 RHGInputQueueBarrier(&q);assert(RHGInputQueuePush(&q,motion)&&q.count==2);count++;
 RHGInput down={.type=RHG_MOUSE_DOWN},up={.type=RHG_MOUSE_UP},keyUp={.type=RHG_KEY_UP};
 assert(RHGInputQueuePush(&q,down)&&RHGInputQueuePush(&q,motion)&&RHGInputQueuePush(&q,up)&&RHGInputQueuePush(&q,keyUp));
 RHGInput out[8];assert(RHGInputQueuePop(&q,out,8)==6&&out[2].type==RHG_MOUSE_DOWN&&out[4].type==RHG_MOUSE_UP&&out[5].type==RHG_KEY_UP);count++;
 RHGInputQueueClear(&q);assert(!q.count&&!q.mergeAllowed);assert(RHGInputQueuePush(&q,motion));
 for(unsigned i=1;i<RHG_INPUT_QUEUE_CAPACITY;i++){down.keyCode=i;assert(RHGInputQueuePush(&q,down));}
 assert(RHGInputQueuePush(&q,keyUp)&&q.count==RHG_INPUT_QUEUE_CAPACITY&&q.events[0].keyCode==1&&q.events[q.count-1].type==RHG_KEY_UP);count++;
 assert(!RHGInputQueuePush(&q,up)&&q.count==RHG_INPUT_QUEUE_CAPACITY);count++;
 unsigned delivered=0;while(q.count){unsigned n=RHGInputQueuePop(&q,out,8);for(unsigned i=0;i<n;i++){if(delivered<127)assert(out[i].keyCode==delivered+1);else assert(out[i].type==RHG_KEY_UP);delivered++;}}assert(delivered==128);count++;
 printf("{\"passed\":true,\"count\":%u,\"physicalCGCalls\":0,\"accountOrGameUsed\":false}\n",count);return 0;}
'''
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-input-cpu-',dir=WORK/'tests'));run.chmod(0o700)
 paths=[ROOT/'Sources/ReadyHostedView/RHGInputMotion.h',ROOT/'Sources/ReadyHostedView/RHGPointerState.h',ROOT/'Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h',pathlib.Path(__file__).resolve()]
 digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
 before={str(p.relative_to(ROOT)):digest(p)for p in paths}
 source=run/'input.c';source.write_text(SOURCE);binary=run/'probe'
 result=subprocess.run(['clang','-std=c11','-O1','-Wall','-Wextra','-Werror','-I',str(ROOT/'Sources/ReadyHostedView'),'-I',str(ROOT/'Sources/ReadyHostedView/include'),str(source),'-o',str(binary)],capture_output=True,text=True)
 if result.returncode:raise RuntimeError(result.stderr[-6000:])
 result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
 if result.returncode:raise RuntimeError(result.stderr[-3000:])
 report=json.loads(result.stdout);assert before=={str(p.relative_to(ROOT)):digest(p)for p in paths};report['sourceHashes']=before
 (run/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({**report,'report':str(run/'report.json')}))
if __name__=='__main__':main()
