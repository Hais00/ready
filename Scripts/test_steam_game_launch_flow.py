#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile the production launch UI flow with isolated controlled collaborators.
No SwiftPM, account, network, vault, actual host or game/SDK is invoked.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    run=pathlib.Path(tempfile.mkdtemp(prefix='steam-game-launch-flow-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/x for x in ['Sources/M1Launcher/SteamGameLaunch.swift','Synthetic/SteamGameLaunchFlowCore.swift','Synthetic/ReadySteamGameLaunchFlowProbe.swift']]
    hashes={str(p.relative_to(ROOT)):sha(p)for p in sources}
    env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','STEAM','Steam'))};env['TMPDIR']=str(WORK/'tmp')+'/'
    common=['xcrun','swiftc','-swift-version','5','-module-cache-path',str(WORK/'cache/swift-game-launch-flow')]
    commands=[common+['-emit-module','-emit-library','-module-name','LauncherCore',str(sources[1]),'-emit-module-path',str(run/'LauncherCore.swiftmodule'),'-o',str(run/'libLauncherCore.dylib')],common+['-parse-as-library','-I',str(run),str(sources[0]),str(sources[2]),'-L',str(run),'-lLauncherCore','-Xlinker','-rpath','-Xlinker',str(run),'-framework','AppKit','-o',str(run/'probe')]]
    for index,command in enumerate(commands):
        result=subprocess.run(command,env=env,capture_output=True,text=True,timeout=90);(run/f'build-{index}.log').write_text(result.stdout+result.stderr)
        if result.returncode:raise RuntimeError('Isolated launch UI flow compile failed; private log retained')
    result=subprocess.run([str(run/'probe'),str(run)],env=env,capture_output=True,text=True,timeout=20)
    (run/'stdout.json').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
    if result.returncode:raise RuntimeError('Launch UI flow fixture failed; private diagnostics retained')
    report=json.loads(result.stdout);assert report['passed'];assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in sources}
    report['sourceHashes']=hashes;retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
    pointer={'passed':True,'count':report['count'],'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':hashes,'fixtureOnly':True,'actualGameOrSDKStarted':False,'accountNetworkKeychainUsed':False}
    (ROOT/'Evidence/steam-game-launch-flow-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
