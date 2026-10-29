#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Production pointer state/virtual policy with fake CG operations; never UI/cursor control."""
import hashlib,json,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
SOURCE=r'''
#include <assert.h>
#include <stdio.h>
#include "RHGPointerState.h"
_Static_assert(RHG_VERSION==6,"CPU input proof is for protocol V6");
typedef struct{int detach,attach,hide,show,anchors,failDetach,failHide,failAttach,failShow,failAnchor;} Fake;
static int32_t assoc(bool connected,void*p){Fake*f=p;if(connected){f->attach++;return f->failAttach;}f->detach++;return f->failDetach;}
static int32_t hide(void*p){Fake*f=p;f->hide++;return f->failHide;}
static int32_t show(void*p){Fake*f=p;f->show++;return f->failShow;}
static int32_t anchor(void*p){Fake*f=p;f->anchors++;return f->failAnchor;}
int main(void){unsigned count=0;Fake f={0};RHGPointerOps ops={assoc,hide,show,anchor,&f};RHGPointerState s={0};RHGVirtualPointer v={.associated=true,.x=.5,.y=.5};
assert(!RHGVirtualPointerRequest(&v,RHG_POINTER_ASSOCIATE,0,0,0,true));assert(!v.associated);RHGPointerReconcile(&s,ops,false);assert(!f.detach&&!f.hide);count++;
assert(!RHGVirtualPointerRequest(&v,RHG_POINTER_WARP,0,.8,.7,true));assert(v.x==.8&&v.y==.7&&!f.detach&&!f.hide);count++;
RHGPointerReconcile(&s,ops,true);assert(s.captured&&s.anchored&&f.detach==1&&f.hide==1&&f.anchors==1);for(int i=0;i<100;i++)RHGPointerReconcile(&s,ops,true);assert(f.hide==1&&f.anchors==1);count++;
assert(!RHGVirtualPointerRequest(&v,RHG_POINTER_ASSOCIATE,1,0,0,true));assert(s.captured&&v.associated&&f.attach==0);count++;
for(int i=0;i<1000;i++)assert(RHGVirtualPointerMove(&v,3,-2,100,100));assert(v.x==1&&v.y==0);assert(RHGVirtualPointerMove(&v,-3,2,100,100)&&v.x<1&&v.y>0);count++;
RHGPointerReconcile(&s,ops,false);assert(!s.captured&&!s.detached&&!s.hidden&&f.attach==1&&f.show==1);RHGPointerReconcile(&s,ops,false);assert(f.show==1);count++;
RHGVirtualPointer saved=v;assert(RHGVirtualPointerRequest(&v,RHG_POINTER_WARP,0,.1,.1,false)==kCGErrorInvalidOperation);assert(v.x==saved.x&&v.y==saved.y);count++;
assert(RHGVirtualPointerRequest(&v,RHG_POINTER_WARP,0,2,0,true)==kCGErrorIllegalArgument);assert(v.x==saved.x);count++;
Fake bad={.failDetach=1};RHGPointerOps badops={assoc,hide,show,anchor,&bad};RHGPointerState b={0};RHGPointerReconcile(&b,badops,true);assert(!b.captured&&!bad.hide);count++;
bad=(Fake){.failHide=1};b=(RHGPointerState){0};RHGPointerReconcile(&b,badops,true);assert(!b.captured&&!b.detached&&bad.attach==1&&!bad.show);count++;
bad=(Fake){0};b=(RHGPointerState){0};RHGPointerReconcile(&b,badops,true);bad.failShow=1;RHGPointerRelease(&b,badops);assert(!b.detached&&b.hidden&&!b.captured);bad.failShow=0;RHGPointerRelease(&b,badops);assert(!b.hidden&&bad.show==2);RHGPointerRelease(&b,badops);assert(bad.show==2);count++;
bad=(Fake){.failAnchor=1};b=(RHGPointerState){0};RHGPointerReconcile(&b,badops,true);assert(!b.captured&&!b.anchored&&!b.hidden&&!b.detached&&bad.anchors==1&&bad.show==1&&bad.attach==1);count++;
bad=(Fake){0};b=(RHGPointerState){0};RHGPointerReconcile(&b,badops,true);bad.failAttach=1;RHGPointerRelease(&b,badops);assert(b.detached&&!b.hidden&&!b.captured&&bad.attach==1&&bad.show==1);bad.failAttach=0;RHGPointerRelease(&b,badops);assert(!b.detached&&bad.attach==2&&bad.show==1);count++;
for(int cycle=0;cycle<20;cycle++){RHGPointerReconcile(&s,ops,true);RHGPointerReconcile(&s,ops,false);}assert(f.hide==f.show&&f.attach==f.detach);count++;
Fake rehide={0};RHGPointerOps rehideOps={assoc,hide,show,anchor,&rehide};RHGPointerState hidden={0};RHGPointerReconcile(&hidden,rehideOps,true);
for(int i=0;i<50;i++)assert(RHGPointerRehideIfVisible(&hidden,rehideOps,true));assert(hidden.captured&&rehide.hide==51&&rehide.show==50&&rehide.anchors==1&&rehide.detach==1);RHGPointerRelease(&hidden,rehideOps);assert(rehide.hide==rehide.show&&rehide.attach==1);count++;
rehide=(Fake){0};hidden=(RHGPointerState){0};RHGPointerReconcile(&hidden,rehideOps,true);assert(RHGPointerRehideIfVisible(&hidden,rehideOps,false)&&rehide.hide==1&&rehide.show==0);RHGPointerRelease(&hidden,rehideOps);count++;
rehide=(Fake){0};hidden=(RHGPointerState){0};RHGPointerReconcile(&hidden,rehideOps,true);rehide.failHide=1;assert(!RHGPointerRehideIfVisible(&hidden,rehideOps,true)&&!hidden.captured&&!hidden.detached&&!hidden.hidden);count++;
rehide=(Fake){0};hidden=(RHGPointerState){0};assert(RHGPointerRehideIfVisible(&hidden,rehideOps,true)&&!rehide.hide&&!rehide.show);count++;
printf("{\"passed\":true,\"count\":%u,\"physicalCGCalls\":0,\"accountOrGameUsed\":false}\n",count);return 0;}
'''
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-pointer-cpu-',dir=WORK/'tests'));run.chmod(0o700)
 paths=[ROOT/'Sources/ReadyHostedView/RHGPointerState.h',ROOT/'Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h',ROOT/'Sources/ReadyHostedView/ReadyHostedView.m',pathlib.Path(__file__).resolve()]
 digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
 before={str(p.relative_to(ROOT)):digest(p)for p in paths}
 source=run/'pointer.c';source.write_text(SOURCE);binary=run/'probe'
 r=subprocess.run(['clang','-std=c11','-O1','-Wall','-Wextra','-Werror','-I',str(ROOT/'Sources/ReadyHostedView'),'-I',str(ROOT/'Sources/ReadyHostedView/include'),str(source),'-o',str(binary)],capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stderr[-6000:])
 r=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
 if r.returncode:raise RuntimeError(r.stderr[-3000:])
 report=json.loads(r.stdout);assert before=={str(p.relative_to(ROOT)):digest(p)for p in paths};report['sourceHashes']=before
 (run/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({**report,'report':str(run/'report.json')}))
if __name__=='__main__':main()
