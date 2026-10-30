#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own host scroll accounting and bounded journal; no real input or GPU work."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-input-trace-',dir=WORK/'tests'));run.chmod(0o700)
 include=ROOT/'Sources/ReadyHostedView/include';host=ROOT/'Sources/ReadyHostedView/ReadyHostedView.m';source=ROOT/'Synthetic/ReadyHostedInputTraceProbe.m'
 paths=[host,source,*sorted(include.glob('*.h')),*sorted(host.parent.glob('*.h')),pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','READY_','STEAM','Steam','MTL_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-input-trace'))
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-I',str(host.parent),str(source),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-lbsm','-o',str(run/'probe')]
 p=subprocess.run(flags,env=env,capture_output=True,text=True,timeout=90);(run/'compile.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Own trace fixture compile failed '+str(run))
 cases={}
 for mode in ['off','on']:
  active={**env}
  if mode=='on':active['RHG_INPUT_TRACE']='1'
  p=subprocess.run([str(run/'probe'),str(run/(mode+'.jsonl')),mode],env=active,capture_output=True,text=True,timeout=12);(run/(mode+'.stdout.json')).write_text(p.stdout);(run/(mode+'.stderr.log')).write_text(p.stderr)
  if p.returncode:raise RuntimeError('Own trace fixture failed '+str(run)+' '+mode)
  cases[mode]=json.loads(p.stdout);assert cases[mode]['passed']
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 report={'passed':True,'cases':cases,'sourceHashes':before,'fixtureOnly':True,'actualGameOrPhysicalInputOrGPUUsed':False};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-input-trace-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
