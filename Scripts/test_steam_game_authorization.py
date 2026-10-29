#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Private synthetic persistent-service authorization; no account/Keychain calls.

Pass --core-products to reuse an already validated static LauncherCore build
without launching SwiftPM alongside another agent's build.
"""
import argparse,hashlib,json,pathlib,subprocess,sys,tempfile
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
FAKE=r'''
import json,sys,threading,time,pathlib
authorization_count=0
pathlib.Path(__file__).with_name('authorization-count').write_text('0')
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
  authorization_count+=1;pathlib.Path(__file__).with_name('authorization-count').write_text(str(authorization_count))
  assert set(request)=={'id','operation','profileID','profileGeneration','gameID'}
  app=int(request['gameID'])
  if mode=='delay':threading.Thread(target=lambda i=id,a=app:(time.sleep(.1),authorized(i,a)),daemon=True).start()
  elif mode.startswith('error_'):
   failures={'error_denied':('not_authorized','AccessDenied'),'error_timeout':('timeout',None),'error_network':('network_error','NoConnection'),
    'error_auth':('authentication_required','Expired'),'error_busy':('busy',None),'error_invalid_callback':('ownership_invalid_response','OK'),
    'error_uncorroborated_denial':('not_authorized',None),'error_throttle':('rate_limited','RateLimitExceeded'),'error_job':('ownership_request_failed',None),
    'error_unknown_result':('steam_error','fixture_only_secret'),'error_numeric_facts':('steam_error','OK'),'error_then_result':('network_error','NoConnection')}
   code,result=failures[mode]
   fields=dict(code=code,steamResult=result,message='fixture_only_secret',rawAccount='fixture_account',rawTicket='fixture_only_secret')
   if mode in ('error_denied','error_invalid_callback'):fields.update(ownershipResponseReceived=True,ownershipAppMatched=mode=='error_denied',ownershipTicketNonEmpty=mode=='error_invalid_callback',ownershipSteamIDPresent=True,ownershipDecisionAuthorized=False)
   if mode=='error_numeric_facts':fields.update(ownershipResponseReceived=1,ownershipAppMatched=1,ownershipTicketNonEmpty=1)
   send('error',id,**fields)
   if mode=='error_then_result':authorized(id,app)
  elif mode=='wrong_envelope':
   saved=generation;generation='00000000-0000-0000-0000-000000000000';authorized(id,app);generation=saved
  elif mode in ('revoked','logged_out','changed_identity'):
   if mode=='changed_identity':identity='76561198000000002';send('persona',account=account())
   else:state='authorization_required'if mode=='revoked'else'logged_out';send('state',state=state,reason=mode,steamResult='Revoked'if mode=='revoked'else'LogonSessionReplaced',invalidateCredentials=mode=='revoked')
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
 elif op=='fixture_connection_result':state='authorization_required';send('state',state=state,reason='fixture_unavailable',steamResult=request['steamResult']);send('result',id)
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
 sources=['Sources/M1Launcher/Credentials.swift','Sources/M1Launcher/PrivateCredentialFile.swift','Sources/M1Launcher/StoreClient.swift','Sources/M1Launcher/SteamClientSession.swift','Sources/M1Launcher/SteamGameAuthorization.swift','Synthetic/ReadySteamGameAuthorizationProbe.swift']
 hashes={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest()for name in sources}
 command=['swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/steam-ui-module-cache'),'-I',str(modules),*[str(ROOT/x)for x in sources],str(archive),'-framework','Security','-o',str(binary)]
 compiled=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
 if compiled.returncode:raise RuntimeError(compiled.stderr[-6000:])
 result=subprocess.run([str(binary),sys.executable,str(fake),str(run)],capture_output=True,text=True,timeout=30)
 (run/'stdout.json').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError('Synthetic authorization fixture failed: '+result.stderr[-2500:])
 report=json.loads(result.stdout);assert report['allPassed'];assert hashes=={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest()for name in sources}
 retained=run/'report.json';retained.write_text(json.dumps({'passed':True,'count':len(report)-1,'checks':report,'sourceHashes':hashes,'fixtureOnly':True,'realAccountUsed':False,'realKeychainUsed':False},indent=2)+'\n');retained.chmod(0o600)
 pointer={'passed':True,'count':len(report)-1,'retainedReport':str(retained),'retainedReportSHA256':hashlib.sha256(retained.read_bytes()).hexdigest(),'sourceHashes':hashes,'fixtureOnly':True,'realAccountUsed':False,'realKeychainUsed':False}
 (ROOT/'Evidence/steam-game-authorization-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
