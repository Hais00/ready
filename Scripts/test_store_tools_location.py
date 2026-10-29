#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual Swift component locators with owned fake files and a synthetic bridge.
No component/user selector is changed outside the fresh private fixture root.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    products,modules,archive=prepare_core()
    run=pathlib.Path(tempfile.mkdtemp(prefix='store-tools-location-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/p for p in ['Sources/LauncherCore/StoreToolsLocation.swift','Sources/M1Launcher/StoreClient.swift','Sources/M1Launcher/Credentials.swift','Sources/M1Launcher/PrivateCredentialFile.swift','Sources/M1Launcher/SteamClientSession.swift','Sources/M1Launcher/SteamNativeHostSelection.swift','Sources/M1Launcher/SteamNativeHostProcess.swift','Synthetic/ReadyStoreToolsLocationProbe.swift','Scripts/test_store_tools_location.py']]
    before={str(p.relative_to(ROOT)):sha(p)for p in sources}
    compiled=[p for p in sources if p.suffix=='.swift'and p.parent.name!='LauncherCore']
    binary=run/'probe'
    result=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',str(modules),'-module-cache-path',str(WORK/'cache/swift-store-tools-location'),*map(str,compiled),str(archive),'-framework','Security','-o',str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=120)
    (run/'build.log').write_text(result.stdout+result.stderr)
    if result.returncode:raise RuntimeError('Component locator probe compilation failed; private build log retained')
    environment={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','STEAM','Steam','SB_'))}
    environment.update(TMPDIR=str(WORK/'tmp')+'/',PYTHONDONTWRITEBYTECODE='1')
    result=subprocess.run([str(binary),str(run),str(ROOT)],env=environment,capture_output=True,text=True,timeout=45)
    (run/'stdout.json').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
    if result.returncode:raise RuntimeError('Component locator fixture failed; private diagnostics retained')
    report=json.loads(result.stdout);assert report['passed'];assert before=={str(p.relative_to(ROOT)):sha(p)for p in sources}
    report.update(sourceHashes=before,coreArchiveSHA256=sha(archive),probeSHA256=sha(binary))
    retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
    pointer={'passed':True,'count':report['count'],'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':before,'fixtureOnly':True,'realAccountUsed':False,'realKeychainUsed':False}
    (ROOT/'Evidence/store-tools-location-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
