#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Direct Steam file backend; own fake payloads/files only."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-products',type=pathlib.Path,required=True);args=ap.parse_args()
 if WORK.resolve()!=WORK or WORK.stat().st_uid!=os.getuid()or WORK.stat().st_mode&0o077 or(WORK/'.ready-external-workspace').read_text()!='ready project work for thread01a17e79\n':raise ValueError('Owned marked external workspace required')
 products=args.core_products.resolve();modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';archive=products/'libLauncherCore.a';m=modules/'LauncherCore.swiftmodule';ms=list(m.glob('*.swiftmodule'))if m.is_dir()else[m]
 if not archive.is_file()or not ms or archive.stat().st_mtime_ns<max(p.stat().st_mtime_ns for p in ms):raise ValueError('Refusing stale Core archive/module')
 run=pathlib.Path(tempfile.mkdtemp(prefix='private-steam-credential-file-',dir=WORK/'tests'));run.chmod(0o700)
 sources=[ROOT/'Sources/M1Launcher/Credentials.swift',ROOT/'Sources/M1Launcher/PrivateCredentialFile.swift',ROOT/'Synthetic/ReadyPrivateCredentialFileProbe.swift',pathlib.Path(__file__)];hashes={str(p.relative_to(ROOT)):sha(p)for p in sources}
 # Direct backend checks select no normal application preference; the separate
 # policy fixture tests routing using volatile defaults and mocked SecItem APIs.
 env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/'}
 cmd=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/steam-private-credential-module-cache'),'-I',str(modules),*map(str,sources[:3]),str(archive),'-framework','Security','-o',str(run/'probe')]
 result=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=120);(run/'build.log').write_text(result.stdout+result.stderr)
 if result.returncode:raise RuntimeError('Private file fixture compilation failed: '+result.stderr[-3000:])
 result=subprocess.run([str(run/'probe'),str(run)],env=env,capture_output=True,text=True,timeout=30);(run/'stdout.json').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError('Private file fixture failed; own diagnostics retained at '+str(run))
 report=json.loads(result.stdout);assert report['passed']and not report['backendActivated'];assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in sources};report['sourceHashes']=hashes
 retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
 pointer={'passed':True,'count':report['count'],'fixtureOnly':True,'backendActivated':False,'realCredentialOrKeychainOrAccountUsed':False,'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':hashes};(ROOT/'Evidence/private-steam-credential-file-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
