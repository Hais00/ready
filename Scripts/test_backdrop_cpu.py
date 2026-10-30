#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exact software filter and MainActor completion gate, procedural colors only."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='backdrop-cpu-',dir=WORK/'tests'));run.chmod(0o700);source=ROOT/'Sources/M1Launcher/GameBackdropSnapshot.swift';fixture=ROOT/'Synthetic/ReadyBackdropCPUProbe.swift';files=[source,fixture,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files};tested=run/'under-test.swift';tested.write_text(source.read_text().replace('private static func renderBackdrop','static func renderBackdrop').replace('private final class CompletionGate','final class CompletionGate'));binary=run/'probe';env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','RHG_','READY_','Steam','STEAM','MTL_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/backdrop-cpu'));p=subprocess.run(['xcrun','swiftc','-swift-version','6','-target','arm64-apple-macos14.0','-parse-as-library',str(tested),str(fixture),'-o',str(binary)],env=env,capture_output=True,text=True,timeout=90);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Own CPU backdrop compile failed '+str(run)+'\n'+p.stderr[-2000:])
 p=subprocess.run([str(binary)],env=env,capture_output=True,text=True,timeout=15);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError('Own CPU backdrop failed '+str(run)+'\n'+p.stderr[-1500:])
 result=json.loads(p.stdout);assert result['passed'];assert before=={str(p.relative_to(ROOT)):sha(p)for p in files};report={**result,'sourceHashes':before,'testChangesVisibilityOnly':True};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/backdrop-cpu-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
