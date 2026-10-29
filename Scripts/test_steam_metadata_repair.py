#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Bounded public repair: fake metadata service, no account/network/game/Keychain."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
FAKE=r'''
import json,sys,pathlib,threading,time
run=pathlib.Path(sys.argv[1]);lock=threading.RLock();sequence=active=0

def send(r,kind,**fields):
 global sequence
 with lock:
  sequence+=1;print(json.dumps(dict(type=kind,id=r['id'],profileID=r['profileID'],profileGeneration=r['profileGeneration'],sequence=sequence,**fields)),flush=True)
def metadata(r):
 global active
 app=int(r['gameID']);refresh=r.get('refresh',False)
 with lock:
  active+=1
  with(run/'calls.jsonl').open('a')as f:f.write(json.dumps(dict(operation='catalog_metadata',gameID=r['gameID'],refresh=refresh,active=active,time=time.monotonic()))+'\n')
 time.sleep(.02 if refresh else .3 if 5000<=app<7000 else .01 if app==7001 else .05 if app==7002 else .02)
 with lock:active-=1
 if app in(7001,7002):send(r,'error',code='rate_limited',retryAfterSeconds=2 if app==7001 else 1)
 elif 1000<=app<1080 and app%4==0:send(r,'error',code='metadata_not_found'if app%8==0 else'metadata_unavailable')
 else:send(r,'result',appID=r['gameID'],metadata=dict(title=('Fresh 'if refresh else'Official ')+r['gameID'],contentType='dlc'if app%5==0 else'game',libraryKind='dlc'if app%5==0 else'game',libraryClassificationSource='public_store',metadataComplete=True,description='Public description',downloadableVariants=['windows','macOS'],bannerURL='https://example.invalid/banner.png'))
for line in sys.stdin:
 r=json.loads(line);op=r['operation']
 if op=='catalog_metadata':threading.Thread(target=metadata,args=(r,),daemon=True).start()
 elif op=='snapshot':send(r,'result',state='offline',friends=[])
 elif op=='cancel':send(r,'result')
 else:
  with lock:
   with(run/'calls.jsonl').open('a')as f:f.write(json.dumps(dict(operation=op))+'\n')
  send(r,'error',code='unexpected_operation')
'''
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-products',required=True,type=pathlib.Path);a=ap.parse_args();products=a.core_products.resolve();modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';archive=products/'libLauncherCore.a';m=modules/'LauncherCore.swiftmodule';ms=list(m.glob('*.swiftmodule'))if m.is_dir()else[m]
 if not archive.is_file()or not ms or archive.stat().st_mtime_ns<max(p.stat().st_mtime_ns for p in ms):raise ValueError('Fresh matching Core required')
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-metadata-repair-',dir=WORK/'tests'));run.chmod(0o700);fake=run/'fake.py';fake.write_text(FAKE)
 sources=[ROOT/'Sources/M1Launcher'/n for n in ['Credentials.swift','PrivateCredentialFile.swift','StoreClient.swift','SteamClientSession.swift','SteamLibraryCoordinator.swift','LibraryEntryPresentation.swift']]+[ROOT/'Synthetic/ReadySteamMetadataRepairProbe.swift'];hashes={str(p.relative_to(ROOT)):sha(p)for p in sources};env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/'}
 cmd=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/steam-ui-module-cache'),'-I',str(modules),*map(str,sources),str(archive),'-framework','Security','-o',str(run/'probe')];result=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=120);(run/'build.log').write_text(result.stdout+result.stderr)
 if result.returncode:raise RuntimeError('Repair compile failed: '+result.stderr[-2500:])
 result=subprocess.run([str(run/'probe'),os.sys.executable,str(fake),str(run)],env=env,capture_output=True,text=True,timeout=40);(run/'stdout.json').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError('Repair fixture failed; private diagnostics '+str(run))
 checks=json.loads(result.stdout);assert checks.pop('allPassed');assert all(checks.values());assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in sources};report={'passed':True,'count':len(checks),'checks':checks,'sourceHashes':hashes,'coreArchiveSHA256':sha(archive),'coreModuleSHA256':{p.name:sha(p)for p in ms},'persistenceSourceSHA256':sha(ROOT/'Sources/LauncherCore/Persistence.swift'),'fixtureOnly':True,'realAccountCredentialKeychainNetworkOrGameUsed':False};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/steam-metadata-repair-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
