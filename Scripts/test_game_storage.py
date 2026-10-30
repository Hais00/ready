#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import pathlib,subprocess,tempfile,hashlib,json,os
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='game-storage-',dir=WORK/'tests'));run.chmod(0o700);core=sorted((ROOT/'Sources/LauncherCore').glob('*.swift'));files=core+[ROOT/'Sources/M1Launcher/GameStorageSizeService.swift',ROOT/'Synthetic/ReadyGameStorageProbe.swift',pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files};env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/'}
 commands=[['xcrun','swiftc','-swift-version','5','-module-cache-path',str(WORK/'cache/game-storage-swift'),'-emit-library','-emit-module','-module-name','LauncherCore',*map(str,core),'-emit-module-path',str(run/'LauncherCore.swiftmodule'),'-o',str(run/'libLauncherCore.dylib')],['xcrun','swiftc','-swift-version','5','-module-cache-path',str(WORK/'cache/game-storage-swift'),'-parse-as-library','-I',str(run),str(files[-3]),str(files[-2]),'-L',str(run),'-lLauncherCore','-Xlinker','-rpath','-Xlinker',str(run),'-o',str(run/'probe')]]
 for c in commands:
  p=subprocess.run(c,cwd=ROOT,env=env,capture_output=True,text=True,timeout=120);(run/'compile.log').write_text(p.stdout+p.stderr)
  if p.returncode:raise RuntimeError(p.stderr[-3000:])
 p=subprocess.run([str(run/'probe'),str(run/'fixture')],cwd=ROOT,env=env,capture_output=True,text=True,timeout=15);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError('Own storage fixture failed '+str(run))
 report=json.loads(p.stdout);assert report['passed'];assert before=={str(p.relative_to(ROOT)):sha(p)for p in files};report['sourceHashes']=before;raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');out={'passed':True,'count':report['count'],'retainedReport':str(raw),'retainedReportSHA256':sha(raw),'sourceHashes':before,'realLibraryOrAccountUsed':False};(ROOT/'Evidence/game-storage-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
