#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual filesystem case/descriptor controls in a new private fixture only."""
import hashlib,json,os,pathlib,subprocess,tempfile
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    products,modules,archive=prepare_core()
    run=pathlib.Path(tempfile.mkdtemp(prefix='steam-native-state-directory-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/'Sources/M1Launcher/SteamNativeStateDirectory.swift',ROOT/'Synthetic/ReadySteamNativeStateDirectoryProbe.swift']
    hashes={str(path.relative_to(ROOT)):sha(path)for path in sources}
    binary=run/'probe'
    build=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',str(modules),'-module-cache-path',str(WORK/'cache/swift-native-state-directory'),*map(str,sources),str(archive),'-o',str(binary)],capture_output=True,text=True,timeout=90)
    (run/'build.log').write_text(build.stdout+build.stderr)
    if build.returncode:raise RuntimeError('State-directory fixture compilation failed; private log retained')
    env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM'))}
    result=subprocess.run([str(binary),str(run)],env=env,capture_output=True,text=True,timeout=30)
    (run/'stdout.json').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
    if result.returncode:raise RuntimeError('State-directory fixture failed; private diagnostics retained')
    report=json.loads(result.stdout);assert report['passed'];assert hashes=={str(path.relative_to(ROOT)):sha(path)for path in sources}
    report.update(sourceHashes=hashes,callsiteSHA256=sha(ROOT/'Sources/M1Launcher/SteamGameLaunch.swift'),probeSHA256=sha(binary))
    retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
    pointer={'passed':True,'count':report['count'],'actualCaseInsensitiveVolume':report['actualCaseInsensitiveVolume'],'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':hashes,'callsiteSHA256':report['callsiteSHA256'],'fixtureOnly':True,'accountKeychainSDKGameUsed':False}
    (ROOT/'Evidence/steam-native-state-directory-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
