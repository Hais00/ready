#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Production coordinator/merge/session with a slow memory vault and fake IPC only."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
FAKE=r'''
import json,sys,time,pathlib
run=pathlib.Path(sys.argv[1]);sequence=0;profile=generation=None;online=False;other=False;metadata_calls=0;public_calls=0
def send(kind,id=None,**fields):
 global sequence
 sequence+=1;print(json.dumps(dict(type=kind,id=id,profileID=profile,profileGeneration=generation,sequence=sequence,**fields)),flush=True)
def account():return dict(accountName='fixture_other'if other else'fixture_account',steamID='76561198000000002'if other else'76561198000000001',displayName='Fixture',presence='online')
def connected(id):
 global online
 online=True;send('state',state='online');send('persona',account=account());send('result',id)
def game(app):
 return dict(id='steam-'+str(app),store='steam',storeID=str(app),title='Fixture '+str(app),engine='automatic',saveRules=[],variants=[dict(id='remote-mac',platform='macOS',architecture='unknown',arguments=[],installed=True,executable='/not-trusted',verification='fixture'),dict(id='remote-win',platform='windows',architecture='unknown',arguments=[],installed=False,verification='fixture')])
for line in sys.stdin:
 r=json.loads(line);profile=r['profileID'];generation=r['profileGeneration'];id=r['id'];op=r['operation']
 if op in('library','catalog_metadata'):public_calls+=1;(run/'public-calls').write_text(str(public_calls))
 if op=='connect':connected(id)
 elif op=='snapshot':send('result',id,state='online'if online else'offline',account=account()if online else None,friends=[])
 elif op=='offline':online=False;send('state',state='offline');send('result',id)
 elif op=='reconnect':connected(id)
 elif op=='fixture_other':other=True;send('persona',account=account());send('result',id)
 elif op=='library':
  assert r['paged']is True
  mode=(run/'mode').read_text()if(run/'mode').exists()else'normal'
  if mode=='error':send('error',id,code='network_error');continue
  if mode in('partial','bad-bool'):
   send('library_page',id,pageIndex=0,games=[game(480)]);send('result',id,gameCount=1,pageCount=1,licenseMembershipComplete=False if mode=='partial'else 0);continue
  if mode=='delay':time.sleep(.25)
  if mode=='large':
   values=[game(10000+i)for i in range(1200)]
   for v in values:v['metadata']={'description':'f'*4096}
   total=0
   for page,start in enumerate(range(0,len(values),50)):
    chunk=values[start:start+50];total+=len(json.dumps(chunk).encode());send('library_page',id,pageIndex=page,games=chunk)
   (run/'large-bytes').write_text(str(total));send('result',id,gameCount=len(values),pageCount=24);continue
  values=[game(600)]if other else[game(480),game(482),game(483)]
  send('library_page',id,pageIndex=0,games=values[:1]);(run/'first-page').write_text('fixture');time.sleep(.15)
  if mode=='duplicate':send('library_page',id,pageIndex=1,games=values[:1]);send('result',id,gameCount=2,pageCount=2)
  elif len(values)>1:send('library_page',id,pageIndex=1,games=values[1:]);send('result',id,gameCount=99 if mode=='count'else len(values),pageCount=2)
  else:send('result',id,gameCount=len(values),pageCount=1)
 elif op=='catalog_metadata':
  metadata_calls+=1;(run/'metadata-calls').write_text(str(metadata_calls));time.sleep(.05);send('result',id,appID=r['gameID'],metadata=dict(shortDescription='Fixture details',metadataComplete=True))
 elif op=='cancel':send('result',id)
 else:send('error',id,code='invalid_request')
'''
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-products',type=pathlib.Path,required=True);args=ap.parse_args();products=args.core_products.resolve();archive=products/'libLauncherCore.a';modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';m=modules/'LauncherCore.swiftmodule';ms=list(m.glob('*.swiftmodule'))if m.is_dir()else[m]
 if not archive.is_file()or not ms or archive.stat().st_mtime_ns<max(x.stat().st_mtime_ns for x in ms):raise RuntimeError('Refusing stale/missing Core archive/module')
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-library-',dir=WORK/'tests'));run.chmod(0o700);fake=run/'fake.py';fake.write_text(FAKE);fake.chmod(0o600)
 sources=[ROOT/'Sources/M1Launcher'/n for n in ['Credentials.swift','PrivateCredentialFile.swift','StoreClient.swift','SteamClientSession.swift','SteamLibraryCoordinator.swift','LibraryEntryPresentation.swift']]+[ROOT/'Synthetic/ReadySteamLibraryProbe.swift'];hashes={str(p.relative_to(ROOT)):sha(p)for p in sources}
 env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/'}
 command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/steam-ui-module-cache'),'-I',str(modules),*map(str,sources),str(archive),'-framework','Security','-o',str(run/'probe')]
 result=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=120);(run/'compile.log').write_text(result.stdout+result.stderr)
 if result.returncode:raise RuntimeError('Library compile failed: '+result.stderr[-1800:])
 result=subprocess.run([str(run/'probe'),os.sys.executable,str(fake),str(run)],env=env,capture_output=True,text=True,timeout=40);(run/'stdout.json').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError('Library fixture failed; private diagnostics retained at '+str(run))
 checks=json.loads(result.stdout);assert checks.pop('allPassed');assert all(checks.values());assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in sources}
 report={'passed':True,'count':len(checks),'checks':checks,'sourceHashes':hashes,'coreArchiveSHA256':sha(archive),'coreModuleSHA256':{p.name:sha(p)for p in ms},'persistenceSourceSHA256':sha(ROOT/'Sources/LauncherCore/Persistence.swift'),'fixtureOnly':True,'actualAccountOrKeychainOrGameUsed':False};retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
 pointer={'passed':True,'count':len(checks),'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':hashes,'coreArchiveSHA256':sha(archive),'coreModuleSHA256':{p.name:sha(p)for p in ms},'persistenceSourceSHA256':sha(ROOT/'Sources/LauncherCore/Persistence.swift'),'fixtureOnly':True,'actualAccountOrKeychainOrGameUsed':False};(ROOT/'Evidence/steam-library-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
