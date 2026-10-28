#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real-process private service transport checks; no account or Keychain use."""
import json,os,pathlib,subprocess,sys,tempfile
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
FAKE=r'''
import json,sys
sequence=0;profile=None;generation=None;auth=None;current_state='offline';current_friends=[]
def send(kind,id=None,**values):
 global sequence,current_state,current_friends
 if kind=='state':current_state=values['state']
 if kind=='friends':current_friends=values['friends']
 sequence+=1
 print(json.dumps(dict(type=kind,id=id,profileID=profile,profileGeneration=generation,sequence=sequence,**values)),flush=True)
def online(id):
 send('state',state='online',reason='')
 send('persona',account={'accountName':'fixture_account','displayName':'Fixture Public Name','steamID':'76561198000000001','presence':'online'})
 send('friends',friends=[{'steamID':'76561198000000002','displayName':'Fixture friend','presence':'online','gameID':'123','gameName':'Fixture game'}])
 send('result',id)
for line in sys.stdin:
 request=json.loads(line);profile=request['profileID'];generation=request['profileGeneration'];id=request['id'];op=request['operation']
 if op=='connect':
  assert request['credentials']=={'username':'fixture_account','refresh_token':'fixture_only_secret'}
  online(id)
 elif op=='fixture_stale':
  current=generation;generation='00000000-0000-0000-0000-000000000000'
  send('persona',account={'accountName':'WRONG'})
  generation=current;send('result',id)
 elif op=='snapshot':send('result',id,state=current_state,reason='not_connected'if current_state=='offline'else'',account=None,friends=current_friends)
 elif op=='fixture_normalization':
  send('persona',account={'accountName':'fixture_account','displayName':'Fixture Public Name','steamID':'76561198000000001','presence':'Away'})
  send('friends',friends=[{'steamID':'76561198000000002','displayName':'Fixture friend','presence':'Offline','gameID':'0','gameName':''}]);send('result',id)
 elif op=='offline':send('state',state='offline',reason='manual_offline');send('result',id)
 elif op in ['reconnect','fixture_recovered']:online(id)
 elif op=='fixture_network_loss':send('state',state='reconnecting',reason='network_lost');send('result',id)
 elif op=='fixture_remote_kick':send('state',state='offline',reason='session_replaced');send('result',id)
 elif op=='fixture_revoked':send('state',state='authorization_required',reason='revoked');send('result',id)
 elif op=='authenticate':auth=id;send('qr',id,url='https://example.invalid/fixture-only')
 elif op=='fixture_auth_complete':
  send('credentials',auth,credentials={'username':'fixture_account','refresh_token':'dummy_new_secret'})
  send('state',state='online',reason='');send('result',auth);send('result',id)
 elif op=='fixture_late_qr':send('qr',auth,url='https://example.invalid/late-fixture');send('result',id)
 elif op=='logout':
  if auth:send('credentials',auth,credentials={'username':'fixture_account','refresh_token':'late_dummy_secret'})
  send('state',state='logged_out',reason='manual_logout');send('result',id)
 else:send('result',id)
'''
def main():
 products,modules,archive=prepare_core()
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-client-session-',dir=WORK/'tests'))
 fake=run/'fake.py';fake.write_text(FAKE);fake.chmod(0o600)
 binary=run/'probe'
 files=['Sources/M1Launcher/Credentials.swift','Sources/M1Launcher/StoreClient.swift','Sources/M1Launcher/SteamClientSession.swift','Synthetic/ReadySteamSessionProbe.swift']
 command=['swiftc','-swift-version','5','-parse-as-library','-I',str(modules),*[str(ROOT/x)for x in files],str(archive),'-framework','Security','-o',str(binary)]
 compiled=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
 if compiled.returncode:raise RuntimeError(compiled.stderr[-6000:])
 result=subprocess.run([str(binary),sys.executable,str(fake)],capture_output=True,text=True,timeout=30)
 (run/'stdout.log').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError('Persistent Steam transport fixture failed: '+result.stderr[-1800:])
 report=json.loads(result.stdout);assert report['allPassed']
 (ROOT/'Evidence/steam-client-session-tests.json').write_text(json.dumps({'passed':True,'fixtureOnly':True,'checks':report,'retainedRoot':str(run)},indent=2)+'\n')
 print(json.dumps(report))
if __name__=='__main__':main()
