#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own real Metal4 fence + gated PRESENT lane; no game/UI/global artifacts.

The private historical control changes only the listener's dispatch queue back
to PRESENT. Credits still require the real controlled Mach acknowledgement.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-metal4-completion-queue-',dir=WORK/'tests'));run.chmod(0o700)
 shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';fixture=ROOT/'Synthetic/ReadyHostedMetal4CompletionQueueProbe.m';include=ROOT/'Sources/ReadyHostedView/include'
 paths=[shim,fixture,*sorted(include.glob('*.h')),pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 source=shim.read_text();marker='__attribute__((constructor))static void rhgInstall(void)';assert source.count(marker)==1
 current='[[MTLSharedEventListener alloc]initWithDispatchQueue:rhgGPUCompletionWorker()]';previous='[[MTLSharedEventListener alloc]initWithDispatchQueue:rhgPresentationWorker()]';assert source.count(current)==1
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','RHG_','STEAM','Steam','MTL_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/metal4-completion-queue'),RHG_PERF_PROFILE='0',MTL_HUD_ENABLED='0')
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics']
 cases={}
 for mode,text in [('independent',source),('shared',source.replace(current,previous))]:
  tested=run/(mode+'.m');tested.write_text(text.replace(marker,'static void rhgInstall(void)')+'\n'+fixture.read_text());binary=run/mode
  p=subprocess.run([*flags,str(tested),'-o',str(binary)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=90);(run/(mode+'.build.log')).write_text(p.stdout+p.stderr)
  if p.returncode:raise RuntimeError('Own completion-queue compile failed '+str(run)+'\n'+p.stderr[-1600:])
  p=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(binary),mode],env=env,capture_output=True,text=True,timeout=20);(run/(mode+'.stdout.json')).write_text(p.stdout);(run/(mode+'.stderr.log')).write_text(p.stderr)
  if p.returncode:raise RuntimeError('Own completion-queue '+mode+' failed '+str(run)+'\n'+p.stderr[-1600:])
  cases[mode]=json.loads(p.stdout);assert cases[mode]['passed']
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 report={'passed':True,'cases':cases,'sourceHashes':before,'privateBuildOnly':True,'networkDenied':True,'realGPUFenceAndMachACK':True,'gameOrUserUIUsed':False,'gameFPSClaimed':False};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-metal4-completion-queue-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
