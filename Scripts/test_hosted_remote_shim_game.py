#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own two-process production remote host + actual injected shim + native Metal.

Only a tiny marked test window; no actual game, account, screenshots or readback.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
EXPORT=r'''
#import <objc/message.h>
static id RHGOwnMakeContext(Class cls,NSDictionary*options){
 const char *strategy=getenv("OWN_REMOTE_CONTEXT_STRATEGY");
 if(strategy&&strcmp(strategy,"local-cgs")==0){
  uint32_t(*connection)(void)=dlsym(RTLD_DEFAULT,"CGSMainConnectionID");SEL selector=NSSelectorFromString(@"contextWithCGSConnection:options:");
  if(!connection||![cls respondsToSelector:selector])return nil;[(id)cls setAllowsCGSConnections:YES];return ((id(*)(id,SEL,uint32_t,id))objc_msgSend)(cls,selector,connection(),options);
 }
 return [(id)cls remoteContextWithOptions:options];
}
__attribute__((visibility("default")))BOOL RHGOwnRemoteM4QueueNative(id queue){
 return queue&&class_getMethodImplementation(object_getClass(queue),@selector(waitForDrawable:))!=(IMP)rhgWaitDrawable&&class_getMethodImplementation(object_getClass(queue),@selector(signalDrawable:))!=(IMP)rhgSignalDrawable;
}
__attribute__((visibility("default")))NSDictionary*RHGOwnRemoteState(void){
 id<MTLDevice>d=rhgGameLayer.device;BOOL native=d&&class_getMethodImplementation(object_getClass(d),@selector(newCommandQueue))!=(IMP)rhgNewQueue0;
 BOOL restored=class_getMethodImplementation(CAMetalLayer.class,@selector(nextDrawable))!= (IMP)rhgRemoteNextDrawable&&class_getMethodImplementation(CAMetalDisplayLinkUpdate.class,@selector(drawable))!=(IMP)rhgRemoteUpdateDrawable&&class_getMethodImplementation(CAMetalDisplayLink.class,@selector(initWithMetalLayer:))!=(IMP)rhgRemoteDisplayLinkInit;
 return @{@"observersRestored":@(restored),@"nativeQueuesUnhooked":@(native),@"firstSent":@(atomic_load(&rhgRemoteFirstSent)),@"frameCreditStructuresAbsent":@(!rhgFrameAvailable&&!rhgRenderLock&&!rhgOutstandingFrames),@"realGuestWindowObjectCreated":@([rhgWindow isMemberOfClass:NSWindow.class]),@"remoteContextId":@(rhgRemoteContext.contextId)};
}
'''
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-remote-shim-game-',dir=WORK/'tests'));run.chmod(0o700);include=ROOT/'Sources/ReadyHostedView/include';shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';host=ROOT/'Sources/ReadyHostedView/ReadyHostedView.m';fixture=ROOT/'Synthetic/ReadyHostedRemoteShimGame.m';files=[shim,host,fixture,*sorted(include.glob('*.h')),pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 tested=run/'shim.m';factory='rhgRemoteContext=[(id)cls remoteContextWithOptions:option?@{*option:@"ignore"}:@{}];';assert shim.read_text().count(factory)==1;private=shim.read_text().replace(factory,'rhgRemoteContext=RHGOwnMakeContext(cls,option?@{*option:@"ignore"}:@{});');tested.write_text('#import <Foundation/Foundation.h>\nstatic id RHGOwnMakeContext(Class,NSDictionary*);\n'+private+'\n'+EXPORT);library=run/'shim.dylib';binary=run/'probe';env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','RHG_','READY_','Steam','STEAM','MTL_','OWN_REMOTE_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-remote-shim-game'),MTL_HUD_ENABLED='0',OWN_REMOTE_SHIM=str(library));flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-I',str(ROOT/'NativeEmbedding'),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-lbsm']
 for name,args in [('shim',['-dynamiclib',str(tested),'-o',str(library)]),('host',[str(fixture),str(host),'-o',str(binary)])]:
  p=subprocess.run([*flags,*args],env=env,capture_output=True,text=True,timeout=90);(run/(name+'.build.log')).write_text(p.stdout+p.stderr)
  if p.returncode:raise RuntimeError('Remote injected '+name+' compile failed '+str(run)+'\n'+p.stderr[-3000:])
 cases={}
 for mode in ['metal3','metal4-native-plain','metal4-native','metal4-plain','metal4','metal4-local-cgs']:
  if mode=='metal4-local-cgs'and(cases['metal4']['passed']or not cases['metal3']['passed']):continue
  child=dict(env,OWN_REMOTE_METAL4='0'if mode=='metal3'else'1')
  if mode=='metal4-local-cgs':child['OWN_REMOTE_CONTEXT_STRATEGY']='local-cgs'
  if mode.endswith('-plain'):child['OWN_REMOTE_PLAIN_PRESENT']='1'
  p=subprocess.run([str(binary),'native'if mode.startswith('metal4-native')else'host',str(binary),str(run/(mode+'.host.jsonl'))],env=child,capture_output=True,text=True,timeout=25);(run/(mode+'.stdout.jsonl')).write_text(p.stdout);(run/(mode+'.stderr.log')).write_text(p.stderr)
  rows=[json.loads(x)for x in p.stdout.splitlines()if x.startswith('{')];cases[mode]={'passed':p.returncode==0,'exitStatus':p.returncode,'rows':rows}
  if p.returncode:cases[mode]['refusals']=[json.loads(x)for x in p.stderr.splitlines()if x.startswith('{')and json.loads(x).get('type')=='hosted-shim-refused']
  else:
   guest=next(x for x in rows if'frames'in x);assert guest['passed']
   if not mode.startswith('metal4-native'):
    parent=next(x for x in rows if'hostPassed'in x);assert parent['hostPassed']and guest['shim']['frameCreditStructuresAbsent']and not guest['shim']['realGuestWindowObjectCreated']
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files};report={'passed':cases['metal3']['passed']and cases['metal4-native']['passed']and cases['metal4']['passed'],'cases':cases,'sourceHashes':before,'privateFactoryVariantOnly':True,'productionContextStrategyUnchanged':True,'actualGameOrAccountUsed':False,'screenCaptureOrReadback':False,'ownTinyWindow':True};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-remote-shim-game-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
