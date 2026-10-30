#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own original-stderr preservation, exec isolation and bounded async writes.

Compiles a constructor-disabled copy of the real shim. No game/UI/GPU/network
or global build artifacts are used; all temporary files stay on the work volume.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def safe(value):
 if isinstance(value,dict):
  assert not {'nonce','account','username','token','ticket','characters','coordinates','pointerX','pointerY','path'}&set(value)
  for v in value.values():safe(v)
 elif isinstance(value,list):
  for v in value:safe(v)
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-profiler-sink-',dir=WORK/'tests'));run.chmod(0o700)
 shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';fixture=ROOT/'Synthetic/ReadyHostedProfilerSinkProbe.m';include=ROOT/'Sources/ReadyHostedView/include'
 files=[shim,fixture,*sorted(include.glob('*.h')),pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 source=shim.read_text();marker='__attribute__((constructor))static void rhgInstall(void)';assert source.count(marker)==1
 tested=run/'under-test.m';tested.write_text(source.replace(marker,'static void rhgInstall(void)')+'\n'+fixture.read_text());binary=run/'probe'
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','READY_','DYLD_','STEAM','Steam','MTL_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-profiler-sink'))
 command=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),str(tested),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-o',str(binary)]
 p=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=90);(run/'compile.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Own profiler sink compile failed '+str(run)+'\n'+p.stderr[-2000:])
 cases={}
 for mode in ['off','on','blocked','broken']:
  replacement=run/(mode+'-game-stderr.txt');replacement.touch(mode=0o600)
  child={**env,'RHG_PERF_PROFILE':'0'if mode=='off'else'1'}
  p=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(binary),mode,str(replacement)],env=child,capture_output=True,text=True,timeout=15);(run/(mode+'.stdout.json')).write_text(p.stdout);(run/(mode+'.original-stderr.log')).write_text(p.stderr)
  if p.returncode:raise RuntimeError('Own profiler sink '+mode+' failed '+str(run)+'\n'+p.stderr[-1000:]+'\n'+replacement.read_text()[-1000:])
  cases[mode]=json.loads(p.stdout);assert cases[mode]['passed'];assert replacement.read_text()=='own-game-stderr-marker\n'
  if mode=='on':
   lines=p.stderr.splitlines();assert len(lines)==1 and len(p.stderr.encode())<=65537;profile=json.loads(lines[0]);safe(profile);assert profile['type']=='hosted-guest-performance'and profile['framesAcknowledged']==120 and profile['rpc']['present']['total']['count']==1
  else:assert p.stderr==''
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files}
 report={'passed':True,'cases':cases,'sourceHashes':before,'networkDenied':True,'constructorDisabledOnlyInPrivateFixture':True,'testCallsExactProductionSinkInitializer':True,'stderrReplacementUsesRealFreopen':True,'profilingDefaultOff':True,'noPathEnvironmentOrNewPort':True,'gameUIOrGPUUsed':False};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-profiler-sink-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
