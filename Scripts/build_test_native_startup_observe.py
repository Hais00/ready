#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build arm64 diagnostic library; CPU-only getter/dedup/finalization controls.
Never launches or modifies a game. Root explicitly supplies DYLD_INSERT_LIBRARIES.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run_command(command,env,root,name):
 p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=60);(root/(name+'.stdout.log')).write_text(p.stdout);(root/(name+'.stderr.log')).write_text(p.stderr)
 if p.returncode:raise RuntimeError(str(root)+' '+name+' '+p.stderr[-2000:])
 return p

def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='native-startup-observe-',dir=WORK/'tests'));run.chmod(0o700)
 source=ROOT/'Synthetic/ReadyNativeStartupObserve.m';probe=ROOT/'Synthetic/ReadyNativeStartupObserveProbe.m';paths=[source,probe,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','READY_','MTL_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/native-startup-observe'))
 flags=['xcrun','clang','-arch','arm64','-fobjc-arc','-fblocks','-std=gnu11','-O1'];frameworks=['-framework','Foundation','-framework','Metal','-framework','QuartzCore']
 library=run/'libReadyNativeStartupObserve.dylib'
 run_command(flags+['-dynamiclib',str(source),*frameworks,'-o',str(library)],env,run,'library-build')
 run_command(['codesign','--force','--sign','-',str(library)],env,run,'library-sign')
 run_command(flags+[str(probe),*frameworks,'-o',str(run/'probe')],env,run,'probe-build')
 cases={}
 for mode in ['positive','budget','deadline']:
  p=run_command([str(run/'probe'),mode],env,run,mode);cases[mode]=json.loads(p.stdout)
  rows=[json.loads(line)for line in p.stderr.splitlines()];final=[r for r in rows if r.get('phase')=='final'];assert len(final)==1
  if mode=='positive':assert final[0]['firstPositiveObservation']==11 and final[0]['zero']==10
  if mode=='budget':assert final[0]['reason']=='nonpositive-frame-budget'and final[0]['observed']==128
  if mode=='deadline':assert final[0]['reason']=='startup-deadline'
  assert all(not any(k in row for k in ['path','address','pid','windowTitle','drawableID'])for row in rows)
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 report={'passed':True,'cases':cases,'sourceHashes':before,'library':str(library),'librarySHA256':sha(library),'architecture':'arm64','adHocSigned':True,'noGameLaunched':True,'noWindowInputDeviceQueuePresentOrCAContextHooks':True};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/native-startup-observe-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
