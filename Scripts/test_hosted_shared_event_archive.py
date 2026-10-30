#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Public secure archive transport experiment; negative unsupported transport is evidence.
Own GPU work only, no UI, screen access, game or installed service. Run outside benchmarks.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-shared-event-archive-',dir=WORK/'tests'));run.chmod(0o700)
 source=ROOT/'Synthetic/ReadyHostedSharedEventArchiveProbe.m';paths=[source,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','READY_','MTL_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-shared-event-archive'))
 cmd=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1',str(source),'-framework','Foundation','-framework','Metal','-o',str(run/'probe')]
 p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+' compile '+p.stderr[-2500:])
 p=subprocess.run([str(run/'probe'),'parent',str(run),str(run/'probe')],env=env,capture_output=True,text=True,timeout=15);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError(str(run)+' probe '+p.stdout[-2000:]+p.stderr[-1000:])
 result=json.loads(p.stdout);assert result['probeCompleted'];assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 report={**result,'sourceHashes':before,'noUIWindowCaptureInputGameOrPrivateAPI':True,'contract':'SDK MTLEvent.h documents MTLSharedEventHandle NSSecureCoding transport via XPC; ordinary keyed archive support is experimental, not assumed.'};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-shared-event-archive-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
