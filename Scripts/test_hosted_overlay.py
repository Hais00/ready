#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Finite own-window AppKit+Metal proof; no global events, games or accounts."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-overlay-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/'Sources/M1Launcher/HostedGameOverlay.swift',ROOT/'Synthetic/ReadyHostedOverlayProbe.swift',pathlib.Path(__file__)]
    before={str(p.relative_to(ROOT)):sha(p)for p in sources}
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','MTL_HUD_','RHG_'))}
    env['TMPDIR']=str(WORK/'tmp')+'/'
    build=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',*map(str,sources[:2]),'-framework','AppKit','-framework','QuartzCore','-framework','Metal','-o',str(run/'probe')],env=env,capture_output=True,text=True)
    (run/'build.log').write_text(build.stdout+build.stderr)
    if build.returncode:raise RuntimeError('Own overlay probe compile failed: '+str(run/'build.log'))
    result=subprocess.run([str(run/'probe'),str(run)],env=env,capture_output=True,text=True,timeout=10)
    (run/'run.log').write_text(result.stderr)
    report=json.loads(result.stdout);report['sourceHashes']=before
    report['sourceInputsUnchanged']=all(sha(p)==before[str(p.relative_to(ROOT))]for p in sources)
    report['overlayRasterSHA256']=sha(run/'overlay-own-window.png')
    retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
    pointer={k:report[k]for k in ['passed','count','actualMetalGPUReadback','actualAppKitRaster','ownWindowOnly','actualCommercialGameVerified','sourceHashes']}
    pointer.update(retainedReport=str(retained),retainedReportSHA256=sha(retained))
    (ROOT/'Evidence/hosted-overlay-tests.json').write_text(json.dumps(pointer,indent=2)+'\n')
    print(json.dumps(pointer,indent=2))
    if result.returncode or not report['passed']:raise SystemExit(1)
if __name__=='__main__':main()
