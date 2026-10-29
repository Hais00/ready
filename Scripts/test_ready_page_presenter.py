#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Nonmodal page lifecycle and actual AppKit geometry; private offscreen app."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    run=pathlib.Path(tempfile.mkdtemp(prefix='ready-page-presenter-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/x for x in ['Sources/M1Launcher/ReadyPagePresenter.swift','Sources/M1Launcher/ReadyDialogs.swift','Sources/M1Launcher/SteamAccountView.swift','Synthetic/ReadyPagePresenterProbe.swift']]
    before={str(path.relative_to(ROOT)):sha(path)for path in sources};binary=run/'probe'
    env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM'))};env['TMPDIR']=str(WORK/'tmp')+'/'
    result=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/swift-ready-page'),*map(str,sources),'-framework','AppKit','-framework','CoreImage','-o',str(binary)],env=env,capture_output=True,text=True,timeout=90)
    (run/'build.log').write_text(result.stdout+result.stderr)
    if result.returncode:raise RuntimeError('Page presenter fixture compilation failed; private log retained')
    report=run/'report.json';result=subprocess.run([str(binary),str(report)],env=env,capture_output=True,text=True,timeout=45)
    (run/'stdout.log').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
    if result.returncode or not report.exists():raise RuntimeError('Page presenter private AppKit fixture failed; diagnostics retained')
    data=json.loads(report.read_text());assert data['passed'];assert before=={str(path.relative_to(ROOT)):sha(path)for path in sources}
    data.update(sourceHashes=before,probeSHA256=sha(binary));report.write_text(json.dumps(data,indent=2)+'\n');report.chmod(0o600)
    pointer={'passed':True,'count':data['count'],'retainedReport':str(report),'retainedReportSHA256':sha(report),'sourceHashes':before,'fixtureOnly':True,'realAccountUsed':False,'windowsShown':False}
    (ROOT/'Evidence/ready-page-presenter-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
