#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual FD-safe scratch helper and manager/keeper benign child; no game."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core-products',required=True,type=pathlib.Path);args=ap.parse_args()
    products=args.core_products.resolve();modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';archive=products/'libLauncherCore.a'
    if not archive.is_file():raise ValueError('Existing matching Core required; this helper never builds Core')
    run=pathlib.Path(tempfile.mkdtemp(prefix='session-scratch-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/'Sources/M1Launcher/SessionScratchDirectory.swift',ROOT/'Sources/M1Launcher/SessionManager.swift',ROOT/'Synthetic/ReadySessionScratchProbe.swift',pathlib.Path(__file__)]
    hashes={str(p.relative_to(ROOT)):sha(p)for p in sources}
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','M1L_','Steam','STEAM','MTL_HUD_'))};env['TMPDIR']=str(WORK/'tmp')+'/'
    command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/session-scratch'),'-I',str(modules),*map(str,sources[:3]),str(archive),'-framework','AppKit','-o',str(run/'probe')]
    p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=90);(run/'compile.log').write_text(p.stdout+p.stderr)
    if p.returncode:raise RuntimeError('Scratch fixture compile failed: '+str(run/'compile.log'))
    keeper=ROOT/'Build/ReadySessionHost';keeper_sha=sha(keeper)
    p=subprocess.run([str(run/'probe'),str(run),str(keeper)],env=env,capture_output=True,text=True,timeout=20)
    (run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
    if p.returncode:raise RuntimeError('Scratch fixture failed: '+str(run/'stderr.log'))
    report=json.loads(p.stdout);report.update(sourceHashes=hashes,keeperSHA256=keeper_sha,coreArchiveSHA256=sha(archive))
    assert report['passed'] and all(sha(p)==hashes[str(p.relative_to(ROOT))]for p in sources)
    raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
    pointer={'passed':True,'count':report['count'],'retainedReport':str(raw),'retainedReportSHA256':sha(raw),'sourceHashes':hashes,'actualBenignKeeperChild':True,'accountGameOrKeychainUsed':False,'ANECompilerBehaviorVerified':False,'foundationTemporaryDirectoryRedirected':report['foundationTemporaryDirectoryRedirected']}
    (ROOT/'Evidence/session-scratch-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
