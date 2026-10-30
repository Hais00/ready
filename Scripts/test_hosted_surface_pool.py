#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own brief NSWindow/real GPU regression; never captures screen or launches a game.
Requires an unlocked graphical session. Run only outside game benchmark intervals.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-surface-pool-',dir=WORK/'tests'));run.chmod(0o700)
 source=ROOT/'Synthetic/ReadyHostedSurfacePoolProbe.m';paths=[source,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','READY_','MTL_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-surface-pool'))
 cmd=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations',str(source),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-o',str(run/'probe')]
 p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+' compile '+p.stderr[-2500:])
 p=subprocess.run([str(run/'probe')],env=env,capture_output=True,text=True,timeout=25);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError(str(run)+' probe '+p.stdout[-2000:]+p.stderr[-1000:])
 result=json.loads(p.stdout);assert result['passed'];assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 report={**result,'sourceHashes':before,'limitation':'Own-process surface aliases, not production cross-process timing; validates pool recycling, not game FPS improvement.'};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-surface-pool-tests.json').write_text(json.dumps(out,indent=2)+'\n')
 print(json.dumps({k:v for k,v in out.items()if k not in ('uncached','cached')},indent=2));print(json.dumps({mode:{k:v for k,v in result[mode].items()if k not in ('surfaceIDs','presentedTimes','acquireMilliseconds')}for mode in ('uncached','cached')},indent=2))
if __name__=='__main__':main()
