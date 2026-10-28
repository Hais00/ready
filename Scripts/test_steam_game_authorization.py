#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Private synthetic persistent-service authorization; no account/Keychain calls.

Pass --core-products to reuse an already validated static LauncherCore build
without launching SwiftPM alongside another agent's build.
"""
import argparse,json,pathlib,subprocess,sys,tempfile
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
FAKE=r'''
import json,sys,threading,time
profile=generation=None;sequence=0;state='offline';mode='valid';cancelled=False
identity='76561198000000001';lock=threading.RLock();pending=set()
def send(kind,id=None,**fields):
 global sequence
 with lock:
  sequence+=1
  print(json.dumps(dict(type=kind,id=id,profileID=profile,profileGeneration=generation,sequence=sequence,**fields)),flush=True)
def account():return dict(accountName='fixture_account',displayName='Fixture',steamID=identity,presence='online')
def online(id):
 global state,identity
 state='online';identity='76561198000000001'
 send('state',state=state);send('persona',account=account());send('result',id)
def authorized(id,app):
 # A cancelled job deliberately emits a late frame: frontend must suppress it.
 send('result',id,appID=app,steamID=identity,authorized=True,ownershipTicketReceived=True,backendSessionReady=False)
for line in sys.stdin:
 request=json.loads(line)
 profile=request['profileID'];generation=request['profileGeneration'];id=request['id'];op=request['operation']
 if op=='connect':
  assert request['credentials']==dict(username='fixture_account',refresh_token='fixture_only_secret')
  online(id)
 elif op=='snapshot':send('result',id,state=state,account=account()if state=='online'else None,friends=[])
 elif op=='fixture_mode':mode=request['mode'];send('result',id)
 elif op=='fixture_identity':identity=request['steamID'];send('persona',account=account());send('result',id)
 elif op=='authorize_game':
  assert set(request)=={'id','operation','profileID','profileGeneration','gameID'}
  app=int(request['gameID'])
  if mode=='delay':threading.Thread(target=lambda i=id,a=app:(time.sleep(.1),authorized(i,a)),daemon=True).start()
  elif mode=='wrong_envelope':
   saved=generation;generation='00000000-0000-0000-0000-000000000000';authorized(id,app);generation=saved
  elif mode in ('revoked','logged_out','changed_identity'):
   if mode=='changed_identity':identity='76561198000000002';send('persona',account=account())
   else:state='authorization_required'if mode=='revoked'else'logged_out';send('state',state=state,reason=mode,invalidateCredentials=mode=='revoked')
   authorized(id,app)
  elif mode=='error':send('error',id,code='fixture_only_secret')
  else:
   data=dict(appID=app,steamID=identity,authorized=True,ownershipTicketReceived=True,backendSessionReady=False)
   if mode=='wrong_app':data['appID']=481
   if mode=='wrong_identity':data['steamID']='76561198000000002'
   if mode=='numeric_authorized':data['authorized']=1
   if mode=='numeric_ticket':data['ownershipTicketReceived']=1
   if mode=='false_ticket':data['ownershipTicketReceived']=False
   if mode=='boolean_app':data['appID']=True
   if mode=='invalid_individual':data['steamID']='76561197960265728'
   if mode=='missing_ticket':del data['ownershipTicketReceived']
   send('result',id,**data)
 elif op=='cancel':cancelled=True;send('result',id)
 elif op=='fixture_assert_cancelled':
  assert cancelled;send('result',id)
 elif op=='offline':state='offline';send('state',state=state);send('result',id)
 elif op=='reconnect':online(id)
 elif op=='logout':state='logged_out';send('state',state=state);send('result',id)
 else:raise AssertionError('Unexpected service operation')
'''
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--core-products',type=pathlib.Path);args=parser.parse_args()
 if args.core_products:
  products=args.core_products.resolve();modules=products if (products/'LauncherCore.swiftmodule').exists() else products/'Modules';archive=products/'libLauncherCore.a'
  module=modules/'LauncherCore.swiftmodule';importable=list(module.glob('*.swiftmodule'))if module.is_dir()else[module]
  if not archive.is_file()or not importable or any(not x.is_file()for x in importable)or archive.stat().st_mtime_ns<max(x.stat().st_mtime_ns for x in importable):raise RuntimeError('Existing static module/archive pair is missing or stale')
 else:products,modules,archive=prepare_core()
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-game-authorization-',dir=WORK/'tests'))
 fake=run/'fake.py';fake.write_text(FAKE);fake.chmod(0o600);binary=run/'probe'
 sources=['Sources/M1Launcher/Credentials.swift','Sources/M1Launcher/StoreClient.swift','Sources/M1Launcher/SteamClientSession.swift','Sources/M1Launcher/SteamGameAuthorization.swift','Synthetic/ReadySteamGameAuthorizationProbe.swift']
 command=['swiftc','-swift-version','5','-parse-as-library','-I',str(modules),*[str(ROOT/x)for x in sources],str(archive),'-framework','Security','-o',str(binary)]
 compiled=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
 if compiled.returncode:raise RuntimeError(compiled.stderr[-6000:])
 result=subprocess.run([str(binary),sys.executable,str(fake)],capture_output=True,text=True,timeout=30)
 if result.returncode:raise RuntimeError('Synthetic authorization fixture failed: '+result.stderr[-2500:])
 report=json.loads(result.stdout);assert report['allPassed'];print(json.dumps(report,sort_keys=True))
if __name__=='__main__':main()
