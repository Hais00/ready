#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core-root',required=True,type=pathlib.Path);a=ap.parse_args();core=a.core_root
    run=pathlib.Path(tempfile.mkdtemp(prefix='storage-settings-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/'Sources/M1Launcher/StorageSettings.swift',ROOT/'Synthetic/ReadyStorageSettingsProbe.swift',pathlib.Path(__file__)];hashes={str(p.relative_to(ROOT)):sha(p)for p in sources}
    env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/'}
    p=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/storage-libraries'),'-I',str(core),*map(str,sources[:2]),str(core/'libLauncherCore.a'),'-framework','AppKit','-o',str(run/'probe')],env=env,capture_output=True,text=True,timeout=90)
    (run/'compile.log').write_text(p.stdout+p.stderr)
    if p.returncode:raise RuntimeError('Storage UI compile failed: '+str(run/'compile.log'))
    p=subprocess.run([str(run/'probe'),str(run)],env=env,capture_output=True,text=True,timeout=15);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
    if p.returncode:raise RuntimeError('Storage UI fixture failed: '+str(run/'stdout.json'))
    report=json.loads(p.stdout);assert report['passed'];assert all(sha(ROOT/p)==h for p,h in hashes.items());report['sourceHashes']=hashes
    raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
    pointer={'passed':True,'count':report['count'],'retainedReport':str(raw),'retainedReportSHA256':sha(raw),'sourceHashes':hashes,'windowActivated':False}
    (ROOT/'Evidence/storage-settings-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
