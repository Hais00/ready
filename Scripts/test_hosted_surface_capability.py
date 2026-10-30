#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""CPU-only real two-process Mach port capability identity/uref experiment."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-surface-capability-',dir=WORK/'tests'));run.chmod(0o700)
 source=ROOT/'Synthetic/ReadyHostedSurfaceCapabilityProbe.m';paths=[source,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','READY_','MTL_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-surface-capability'))
 cmd=['xcrun','clang','-fobjc-arc','-std=gnu11','-O1',str(source),'-framework','Foundation','-framework','IOSurface','-o',str(run/'probe')]
 p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+' compile '+p.stderr[-2500:])
 cases={}
 for case,mode in [('create-twice','parent'),('reuse-one-port','parent-reused')]:
  case_root=run/case;case_root.mkdir(mode=0o700)
  p=subprocess.run([str(run/'probe'),mode,str(case_root),str(run/'probe')],env=env,capture_output=True,text=True,timeout=12);(case_root/'stdout.json').write_text(p.stdout);(case_root/'stderr.log').write_text(p.stderr)
  if p.returncode:raise RuntimeError(str(run)+' probe '+p.stdout[-2000:]+p.stderr[-1000:])
  result=json.loads(p.stdout);assert result['probeCompleted'];cases[case]=result
 assert not cases['create-twice']['capabilityIdentityFastPathSupported']
 assert cases['reuse-one-port']['capabilityIdentityFastPathSupported']
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 result={'passed':True,'cases':cases}
 report={**result,'sourceHashes':before,'limitation':'Retained original port COPY_SEND coalescence works in this probe; independently created IOSurface ports do not. No production fast path or skipped metadata validation implemented.'};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-surface-capability-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
