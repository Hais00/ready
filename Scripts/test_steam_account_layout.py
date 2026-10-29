#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real AppKit geometry for the Steam card, using private offscreen windows only."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--observe',action='store_true');args=parser.parse_args()
    run=pathlib.Path(tempfile.mkdtemp(prefix='steam-account-layout-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/x for x in ['Sources/M1Launcher/SteamAccountView.swift','Sources/M1Launcher/ReadyDialogs.swift','Sources/M1Launcher/ReadyPagePresenter.swift','Synthetic/ReadySteamAccountLayoutProbe.swift']]
    before={str(p.relative_to(ROOT)):sha(p)for p in sources}
    binary=run/'ReadySteamAccountLayoutProbe'
    env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM'))};env['TMPDIR']=str(WORK/'tmp')+'/'
    build=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/swift-steam-layout'),*map(str,sources),'-framework','AppKit','-framework','CoreImage','-o',str(binary)],env=env,capture_output=True,text=True,timeout=90)
    (run/'build.log').write_text(build.stdout+build.stderr)
    if build.returncode:raise RuntimeError('Private layout fixture failed to compile; build log retained')
    report=run/'geometry.json';cmd=[str(binary),str(report)]+(['--observe']if args.observe else[])
    result=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=45)
    (run/'stdout.log').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
    if not report.exists():raise RuntimeError('Private AppKit geometry did not complete; diagnostics retained')
    value=json.loads(report.read_text());value['sourceHashes']=before
    assert before=={str(p.relative_to(ROOT)):sha(p)for p in sources}
    value['probeSHA256']=sha(binary);report.write_text(json.dumps(value,indent=2)+'\n');report.chmod(0o600)
    pointer={'passed':value['passed'],'observationalBaseline':args.observe,'retainedReport':str(report),'retainedReportSHA256':sha(report),'sourceHashes':before,'realAccountUsed':False,'windowsShown':False}
    target=ROOT/'Evidence'/('steam-account-layout-baseline.json'if args.observe else'steam-account-layout-tests.json')
    target.write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
    if result.returncode and not args.observe:raise SystemExit(1)
if __name__=='__main__':main()
