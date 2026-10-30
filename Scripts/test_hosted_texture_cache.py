#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual imported texture cache, own Mach surfaces and GPU color validation.

No window, game, account, screenshot or global build. CPU readback is test-only.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-texture-cache-',dir=WORK/'tests'));run.chmod(0o700);shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';fixture=ROOT/'Synthetic/ReadyHostedTextureCacheProbe.m';include=ROOT/'Sources/ReadyHostedView/include';files=[shim,fixture,*sorted(include.glob('*.h')),pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files};source=shim.read_text();marker='__attribute__((constructor))static void rhgInstall(void)';assert source.count(marker)==1
 tested=run/'under-test.m';tested.write_text(source.replace(marker,'static void rhgInstall(void)')+'\n'+fixture.read_text());binary=run/'probe';env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','RHG_','READY_','Steam','STEAM','MTL_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-texture-cache'),RHG_PERF_PROFILE='1',MTL_HUD_ENABLED='0')
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics'];p=subprocess.run([*flags,str(tested),'-o',str(binary)],env=env,capture_output=True,text=True,timeout=90);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Own texture cache compile failed '+str(run)+'\n'+p.stderr[-1800:])
 cases={}
 for mode in ['default-off','off','on','bad-id','bad-size','bad-device','bad-window','clear-active']:
  child=dict(env)
  if mode!='default-off':child['RHG_TEXTURE_CACHE']='0'if mode=='off'else'1'
  expected=77 if mode.startswith('bad-')or mode=='clear-active'else 0;p=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(binary),mode],env=child,capture_output=True,text=True,timeout=25);(run/(mode+'.stdout.json')).write_text(p.stdout);(run/(mode+'.stderr.log')).write_text(p.stderr)
  if p.returncode!=expected:raise RuntimeError('Own texture cache '+mode+' failed '+str(run)+'\n'+p.stderr[-1500:])
  if expected==0:cases[mode]=json.loads(p.stdout);assert cases[mode]['passed']
  else:
   failure=next(json.loads(line)for line in p.stderr.splitlines()if line.startswith('{'));reason='texture-cache-clear-with-outstanding-frames'if mode=='clear-active'else'host-surface-metadata-mismatch';assert failure['reason']==reason;cases[mode]={'passed':True,'expectedExit':77,'reason':reason}
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files};report={'passed':True,'cases':cases,'sourceHashes':before,'networkDenied':True,'ownGPUAndMachUsed':True,'CPUReadbackTestOnly':True,'UIOrGameOrAccountUsed':False,'defaultCacheEnabled':False,'productionCopiesAdded':0,'frameDepthChanged':False};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-texture-cache-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
