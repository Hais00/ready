#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real credential facade routing; only volatile prefs, own files and SecItem mocks."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-products',type=pathlib.Path,required=True);args=ap.parse_args()
 if WORK.resolve()!=WORK or WORK.stat().st_uid!=os.getuid()or WORK.stat().st_mode&0o077 or(WORK/'.ready-external-workspace').read_text()!='ready project work for thread01a17e79\n':raise ValueError('Owned marked external workspace required')
 products=args.core_products.resolve();modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';archive=products/'libLauncherCore.a';m=modules/'LauncherCore.swiftmodule';ms=list(m.glob('*.swiftmodule'))if m.is_dir()else[m]
 if not archive.is_file()or not ms or archive.stat().st_mtime_ns<max(p.stat().st_mtime_ns for p in ms):raise ValueError('Refusing stale Core archive/module')
 run=pathlib.Path(tempfile.mkdtemp(prefix='credential-storage-policy-',dir=WORK/'tests'));run.chmod(0o700)
 swift=[ROOT/'Sources/M1Launcher'/n for n in ['Credentials.swift','PrivateCredentialFile.swift','StoreClient.swift']]+[ROOT/'Synthetic/ReadyCredentialStoragePolicyProbe.swift'];mock=ROOT/'Synthetic/PrivateCredentialKeychainMock.c';sources=[*swift,mock,pathlib.Path(__file__)];hashes={str(p.relative_to(ROOT)):sha(p)for p in sources}
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/steam-private-credential-clang'))
 library=run/'libReadyCredentialMock.dylib';obj=run/'MockBindingCheck.o';probe=run/'probe'
 commands=[['xcrun','clang','-std=gnu11','-O1','-dynamiclib','-framework','Security','-framework','CoreFoundation','-install_name','@rpath/libReadyCredentialMock.dylib',str(mock),'-o',str(library)],['xcrun','clang','-std=gnu11','-O1','-DREADY_CREDENTIAL_BINDING_CHECK=1','-c',str(mock),'-o',str(obj)],['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/steam-private-credential-module-cache'),'-I',str(modules),*map(str,swift),str(obj),str(archive),'-L',str(run),'-lReadyCredentialMock','-Xlinker','-rpath','-Xlinker',str(run),'-framework','Security','-o',str(probe)]]
 for i,cmd in enumerate(commands):
  result=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=120);(run/f'build-{i}.log').write_text(result.stdout+result.stderr)
  if result.returncode:raise RuntimeError('Credential policy fixture compile failed: '+result.stderr[-2600:])
 env['DYLD_INSERT_LIBRARIES']=str(library)
 result=subprocess.run([str(probe),str(run)],env=env,capture_output=True,text=True,timeout=30);(run/'stdout.json').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError('Policy fixture failed; private diagnostic retained at '+str(run))
 report=json.loads(result.stdout);assert report['passed']and report['realApplicationPreferencesChanged']is False;assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in sources}
 report.update(sourceHashes=hashes,mockLibrarySHA256=sha(library));retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
 pointer={'passed':True,'count':report['count'],'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':hashes,'fixtureOnly':True,'realApplicationPreferencesChanged':False,'realCredentialKeychainOrAccountUsed':False,'allSecItemBindingsVerifiedMockedBeforeFirstCredentialCall':True};(ROOT/'Evidence/credential-storage-policy-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
