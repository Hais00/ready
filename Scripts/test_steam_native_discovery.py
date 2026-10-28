#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own mocked Mach metadata protocol and worker-local routing; no Valve/SDK/auth."""
import hashlib,json,os,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
 run=WORK/'retained/research-steam-native'/('discovery-mock-'+uuid.uuid4().hex);run.mkdir(mode=0o700);sources=run/'sources';sources.mkdir()
 for name in ['steam_native_discovery.h','steam_native_discovery.c','steam_native_discovery_redirect.c','steam_native_discovery_mock.c','test_steam_native_discovery.py']:(sources/name).write_bytes((ROOT/'Scripts'/name).read_bytes())
 commands=[]
 for label,flags in [('production',[]),('testing',['-DREADY_DISCOVERY_TESTING=1'])]:
  command=['/usr/bin/clang','-arch','arm64','-std=c11','-Wno-deprecated-declarations','-O1','-dynamiclib',*flags,str(sources/'steam_native_discovery.c'),'-lbsm','-o',str(run/(label+'.dylib'))];subprocess.run(command,capture_output=True,check=True);commands.append(command)
 command=['/usr/bin/clang','-arch','arm64','-O1','-dynamiclib',str(sources/'steam_native_discovery_redirect.c'),'-o',str(run/'redirect.dylib')];subprocess.run(command,capture_output=True,check=True);commands.append(command)
 command=['/usr/bin/clang','-arch','arm64','-std=c11','-Wno-deprecated-declarations','-O1',str(sources/'steam_native_discovery_mock.c'),'-o',str(run/'mock')];subprocess.run(command,capture_output=True,check=True);commands.append(command)
 client=run/'steamclient.dylib';sdk=run/'libsteam_api.dylib';client.write_text('PUBLIC MOCK NOT VALVE');sdk.write_text('PUBLIC MOCK NOT SDK');name='app.ready.steam.ipctool.'+uuid.uuid4().hex;ready=run/'ready.json';control=run/'control';host=subprocess.Popen([str(run/'mock'),'--host',str(run/'testing.dylib'),name,str(client),str(sdk),str(ready),str(control)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);tests={};observations={}
 try:
  deadline=time.monotonic()+5
  while not ready.exists() and host.poll() is None and time.monotonic()<deadline:time.sleep(.02)
  metadata=json.loads(ready.read_text());tests.update({k:metadata[k] for k in ['authFalseRejected','wrongOwnerRejected','globalNameRejected','collisionRejected']})
  profile=run/'client.sb';profile.write_text('(version 1)\n(allow default)\n(deny mach-lookup (global-name "com.valvesoftware.steam.ipctool"))\n(allow mach-lookup (global-name '+json.dumps(name)+'))\n(deny process-exec)\n(allow process-exec (literal "/usr/bin/env") (literal '+json.dumps(str(run/'mock'))+'))\n')
  def query(label,target,operation,redirect=True,malformed=False,namespace=name):
   command=['/usr/bin/sandbox-exec','-f',str(profile),'/usr/bin/env','READY_MOCK_EXACT_SDK_CAPACITY=1']
   if redirect:command+=['DYLD_INSERT_LIBRARIES='+str(run/'redirect.dylib'),'READY_STEAM_DISCOVERY_SERVICE='+namespace]
   command+=[str(run/'mock'),'--client',target,str(operation),*(['malformed'] if malformed else [])];p=subprocess.run(command,capture_output=True,text=True,timeout=3);items=[json.loads(line) for line in p.stdout.splitlines()];value=next(x for x in items if 'lookupStatus' in x);diagnostic=next((x for x in items if 'redirectLoaded' in x),None);
   if diagnostic:value['redirectStats']=diagnostic
   observations[label]=value;return value
  fixed='com.valvesoftware.steam.ipctool';v=query('version',fixed,100001);tests['version104']=v.get('status')==0 and v.get('value')==104 and v.get('replyBytes')==32
  v=query('metadata',fixed,14);tests['liveOwnPIDAndBoundedPath']=v.get('status')==0 and v.get('value')==host.pid and v.get('PIDAlive') and v.get('pathTerminated') and v.get('replyBytes')==544
  v=query('unknown-operation',fixed,9999);tests['unknownUnsupported']=v.get('status')!=0 and v.get('value')==0
  v=query('globalWithoutAdapter',fixed,14,redirect=False);tests['noGlobalSteamLookupPermitted']=v.get('lookupStatus')!=0
  v=query('invalidRedirectName',fixed,14,namespace='com.valvesoftware.steam.ipctool');tests['invalidRedirectFailsClosed']=v.get('lookupStatus')!=0
  v=query('otherNameUnchanged',name,100001);tests['otherLookupForwarded']=v.get('value')==104
  v=query('malformed',fixed,14,malformed=True);tests['malformedRejected']=v.get('machStatus')!=0
  control.write_text('revoke');time.sleep(.05);v=query('revokedOwnedRecord',fixed,14);tests['authLeaseRevocation']=v.get('status')!=0 and v.get('value')==0
  v=query('versionDuringRevocation',fixed,100001);tests['versionStill104WhileAuthRevoked']=v.get('value')==104 and v.get('status')==0
  control.write_text('restore');time.sleep(.05);v=query('restoredOwnedRecord',fixed,14);tests['restoreOwnRecord']=v.get('value')==host.pid
  control.write_text('quit');host.wait(timeout=3);v=query('afterOwnedStop',fixed,14);tests['ownedStopNoLiveService']=v.get('lookupStatus')!=0 or v.get('machStatus')!=0
  service_stats=json.loads(Path(str(ready)+'.stats.json').read_text());observations['serviceStats']=service_stats;tests['serviceStatsObservedValidAndMalformed']=service_stats['received']>=8 and service_stats['metadataRequests']>=3 and service_stats['versionRequests']>=2 and service_stats['badSize']>=1 and service_stats['leaseDenied']>=1 and service_stats['sendFailed']==0
  diagnostic=observations['metadata'].get('redirectStats',{});tests['redirectStatsObservedActualLookup']=diagnostic.get('redirectLoaded') and diagnostic.get('fixedLookups',0)>=1 and diagnostic.get('privateRedirects',0)>=1 and diagnostic.get('privateLookupSucceeded',0)>=1 and diagnostic.get('lastLookupStatus')==0
  tests['diagnosticMetadataContainsNoPathsOrPIDs']=not any(key in service_stats or key in diagnostic for key in ['pid','PID','path','name','steamID','account','token'])
 finally:
  if host.poll() is None:host.terminate();host.wait(timeout=3)
 report={'schema':1,'scope':'Own mock only; production service separate from TESTING image','tests':tests,'count':len(tests),'passed':all(tests.values()),'observations':observations,'commands':commands,'sourceHashes':{p.name:sha(p) for p in sources.iterdir()},'binaryHashes':{p.name:sha(p) for p in run.iterdir() if p.suffix=='.dylib' or p.name=='mock'},'globalSteamServiceRegistered':False,'ValveOrGameSDKExecuted':False,'accountAuthenticated':False,'realGameInjectionVerified':False};path=run/'report.json';path.write_text(json.dumps(report,indent=2)+'\n');summary={'retainedReport':str(path),'SHA256':sha(path),'passed':report['passed'],'count':report['count'],'ValveOrGameSDKExecuted':False};(ROOT/'Evidence/steam-native-discovery-mock.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
