#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Pure pinning + real private queue/locked-registry fixtures. No accounts/CDN."""
import copy,datetime,hashlib,json,os,pathlib,sys,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-install-plan-',dir=WORK/'tests'));run.chmod(0o700)
 data=run/'data';data.mkdir(mode=0o700);os.environ['READY_DATA_ROOT']=str(data);sys.dont_write_bytecode=True;sys.path.insert(0,str(ROOT/'StoreBridge'))
 import steam_install_plan as p,steam_downloads as q
 sources=[ROOT/'StoreBridge/steam_install_plan.py',ROOT/'StoreBridge/steam_downloads.py',ROOT/'StoreBridge/backend.py',pathlib.Path(__file__)]
 hashes={str(x.relative_to(ROOT)):sha(x)for x in sources};checks={}
 def check(name,condition):assert condition,name;checks[name]=True
 def reject(name,fn,code=None):
  try:fn()
  except q.BridgeError as e:
   assert code is None or e.code==code,(name,e.code);checks[name]=True;return
  raise AssertionError(name)
 def plan(depots=None):
  depots=depots or[dict(depotID=20,sourceAppID=999,manifestID=2**63+15,downloadBytes=20,installedBytes=50),dict(depotID=10,sourceAppID=123,manifestID=42,downloadBytes=10,installedBytes=40)]
  result=dict(platform='windows',branch='public',language='english',architecture='64',verified=True,status='available',source='steam_pics',basis='selected_depot_payload_totals',selectedDepotCount=len(depots),selectedDepots=depots,downloadBytes=sum(x['downloadBytes']for x in depots),installedBytes=sum(x['installedBytes']for x in depots),calculatedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
  hashed={'AppID':123,'Platform':'windows','Branch':'public','Language':'english','Architecture':'64','depots':[dict(DepotID=x['depotID'],SourceAppID=x['sourceAppID'],ManifestID=x['manifestID'],DownloadBytes=x['downloadBytes'],InstalledBytes=x['installedBytes'])for x in sorted(depots,key=lambda x:x['depotID'])]}
  result['fingerprint']=hashlib.sha256(json.dumps(hashed,separators=(',',':')).encode()).hexdigest();return result
 base={'gameID':'123','platform':'windows','expectedInstallPlan':plan()}
 check('pinned-positional-depot-manifest-pairs-no-rounded-uint64',p.pinned_arguments(base)==['-depot','10','20','-manifest','42',str(2**63+15)])
 check('shared-source-kept-but-engine-root-app-permission-unchanged',p.normalize(base)['selectedDepots'][1]['sourceAppID']==999)
 check('legacy-no-plan-args-unchanged',p.pinned_arguments({'gameID':'123','platform':'windows'})==[])
 reject('managed-plan-required',lambda:p.pinned_arguments({'gameID':'123','storageReservationID':str(uuid.uuid4())}),'install_plan_required')
 for key,value in [('platform','macOS'),('branch','beta'),('language','italian'),('architecture','32'),('verified',1),('status','unknown'),('source','public_store'),('basis','disk_requirement'),('selectedDepotCount',True),('installedBytes',91),('fingerprint','0'*64)]:
  o=copy.deepcopy(base);o['expectedInstallPlan'][key]=value;reject('strict-'+key,lambda:p.normalize(o))
 o=copy.deepcopy(base);o['gameID']='124';reject('fingerprint-binds-root-app',lambda:p.normalize(o))
 o=copy.deepcopy(base);o['expectedInstallPlan']['selectedDepots'][0]['manifestID']=float(2**63);reject('float-manifest-rejected-not-rounded',lambda:p.normalize(o))
 o=copy.deepcopy(base);o['expectedInstallPlan']['selectedDepots'][0]['manifestID']=2**64-1;reject('invalid-manifest-sentinel-rejected',lambda:p.normalize(o))
 o=copy.deepcopy(base);o['expectedInstallPlan']['selectedDepots'][0]['depotID']=10;reject('duplicate-depot-rejected',lambda:p.normalize(o))
 o=copy.deepcopy(base);o['expectedInstallPlan']['selectedDepots'][0]['installedBytes']=2**64-1;reject('sum-overflow-rejected',lambda:p.normalize(o))
 o=copy.deepcopy(base);o['expectedInstallPlan']['calculatedAt']='2000-01-01T00:00:00+00:00';reject('stale-new-plan-rejected',lambda:p.normalize(o,fresh=True),'stale_install_plan')
 check('persisted-paused-job-resumes-old-pinned-selection',p.normalize(o)['fingerprint']==base['expectedInstallPlan']['fingerprint'])
 o=copy.deepcopy(base);o['expectedInstallPlan']['calculatedAt']='2099-01-01T00:00:00+00:00';reject('future-plan-rejected',lambda:p.normalize(o))
 profile=str(uuid.uuid4());reservation=str(uuid.uuid4());library=str(uuid.uuid4());installation=str(uuid.uuid4())
 games=run/'games';games.mkdir();target=games/'steam/123/windows';target.mkdir(parents=True)
 s=games.stat();storage=data/'Storage';storage.mkdir(mode=0o700);lock=storage/'registry.lock';lock.touch(mode=0o600)
 registry={'schema':1,'kind':'ready-game-storage-v1','libraries':[{'id':library,'rootPath':str(games),'deviceID':s.st_dev,'rootFileID':s.st_ino,'volumeUUID':None,'isRemoved':False}], 'installations':[{'id':installation,'libraryID':library,'store':'steam','gameID':'123','platform':'windows','relativePath':'steam/123/windows'}],'reservations':[{'id':reservation,'installationID':installation,'libraryID':library,'ownerProfileID':profile,'requestedBytes':90,'remainingBytes':90,'jobID':None}]}
 path=storage/'libraries.json'
 def save():path.write_text(json.dumps(registry));path.chmod(0o600)
 save();options={**base,'storageReservationID':reservation,'installDir':str(target)}
 request={'operation':'download_prepare','store':'steam','profileID':profile,'options':options}
 original=copy.deepcopy(registry)
 bad=copy.deepcopy(request);bad['options']['expectedInstallPlan']['verified']=False;bad['options']['installDir']=str(run/'must-not-exist')
 reject('invalid-plan-before-installation-or-job-directory',lambda:q.prepare(bad));check('invalid-plan-has-no-installation-or-queue-side-effects',not(run/'must-not-exist').exists()and not(data/'Profiles').exists())
 job=q.prepare(request)['job'];stored=q.load(profile,job['jobID'])
 check('queue-persists-pinned-selection-and-plan-bytes-privately',stored['selectedManifests']=={'10':'42','20':str(2**63+15)}and stored['plannedInstalledBytes']==90 and stored['plannedDownloadBytes']==30 and stored['planFingerprint']==base['expectedInstallPlan']['fingerprint'])
 check('reservation-dto-preserved-but-plan-not-leaked-in-public-dto',job['storageReservationID']==reservation and'expectedInstallPlan'not in job and'planFingerprint'not in job)
 check('private-job-mode600',os.stat(q.paths(profile,job['jobID'])[0]).st_mode&0o777==0o600)
 check('same-plan-queue-dedup',q.prepare(request)['job']['jobID']==job['jobID'])
 other=copy.deepcopy(request);other['options']['storageReservationID']=str(uuid.uuid4());reject('unregistered-reservation-not-admitted',lambda:q.prepare(other))
 registry['reservations'][0]['ownerProfileID']=str(uuid.uuid4());save();reject('cross-profile-reservation-rejected',lambda:p.preflight(stored));registry=copy.deepcopy(original);save()
 wrong=copy.deepcopy(stored);wrong['installDir']=str(run);reject('outside-chosen-library-target-rejected',lambda:p.preflight(wrong),'unsafe_installation')
 wrong=copy.deepcopy(request);wrong['options']['installDir']=str(run/'outside-new');reject('outside-new-target-never-created',lambda:q.prepare(wrong),'unsafe_installation');check('outside-new-target-absent',not(run/'outside-new').exists())
 registry['libraries'][0]['rootFileID']+=1;save();reject('changed-library-identity-rejected',lambda:p.preflight(stored),'unsafe_installation');registry=copy.deepcopy(original);save()
 fs=os.statvfs(target);free=fs.f_bavail*fs.f_frsize
 registry['reservations'].append({'id':str(uuid.uuid4()),'installationID':installation,'libraryID':library,'remainingBytes':free,'requestedBytes':free});save();reject('other-same-volume-reservations-prevent-overcommit',lambda:p.preflight(stored),'disk_full')
 registry['reservations'][-1]['remainingBytes']=None;save();reject('unplanned-other-reservation-fails-closed',lambda:p.preflight(stored));registry=copy.deepcopy(original);save()
 registry['reservations'][0]['requestedBytes']=89;save();reject('reservation-too-small-for-pinned-plan-rejected',lambda:p.preflight(stored));registry=copy.deepcopy(original);save()
 before=path.read_bytes();p.preflight(stored);check('registry-preflight-is-read-only',before==path.read_bytes())
 path.chmod(0o644);reject('unsafe-registry-permissions-rejected',lambda:p.preflight(stored),'unsafe_storage_registry');path.chmod(0o600)
 # Resume admission must not double-count already-written bytes when the
 # worker resets its public progress counters before taking the writer lease.
 original_preflight=q.install_preflight;original_statvfs=p.os.fstatvfs;captured=[]
 from types import SimpleNamespace
 registry['reservations'][0]['remainingBytes']=40;save()
 q.mutate(profile,job['jobID'],lambda value:value.update(bytesCompleted=50,bytesTotal=90))
 p.os.fstatvfs=lambda fd:SimpleNamespace(f_bavail=40,f_frsize=1)
 def preflight(value):captured.append(('preflight',value['jobID']));return original_preflight(value)
 def factory(r,c,secret):captured.append(r['options']);raise q.BridgeError('fixture_boundary','No engine is started')
 q.install_preflight=preflight
 try:
  reject('worker-stops-at-own-fake-engine-boundary',lambda:q.run_job({'profileID':profile,'options':{'jobID':job['jobID']},'credentials':{'username':'fixture','refresh_token':'fixture'}},factory),'fixture_boundary')
  check('resume-second-admission-preserves-validated-prior-progress',len(captured)==3)
  mismatch=copy.deepcopy(stored);mismatch.update(bytesCompleted=50,bytesTotal=80)
  reject('remaining-size-never-trusts-mismatched-progress-total',lambda:p.preflight(mismatch),'disk_full')
 finally:q.install_preflight=original_preflight;p.os.fstatvfs=original_statvfs
 registry=copy.deepcopy(original);save()
 forwarded=next(x for x in captured if isinstance(x,dict));check('worker-forwards-persisted-plan-and-reservation-not-request-substitution',forwarded['expectedInstallPlan']==stored['expectedInstallPlan']and forwarded['storageReservationID']==reservation)
 check('worker-checks-free-space-before-config-and-again-before-recovery',sum(isinstance(x,tuple)for x in captured)==2)
 bad=copy.deepcopy(stored);bad['_completedManifests']={'10':'43','20':str(2**63+15)}
 reject('completion-cannot-substitute-newer-manifest',lambda:q.verify_completion(bad),'download_incomplete')
 import backend
 tools=run/'fake-tools';(tools/'dotnet').mkdir(parents=True);(tools/'dotnet/dotnet').touch();dll=tools/'DepotDownloader.dll';dll.touch()
 original_tools=backend.TOOLS;original_payload=backend.tool_payload
 backend.TOOLS=tools;backend.tool_payload=lambda *args:dll
 try:
  args,_,private,_=backend.prepare_download({'store':'steam','credentials':{'username':'fixture','refresh_token':'fixture'},'options':{**options,'downloadLoginID':0xD0000001}},run/'config',run/'secret')
  check('production-engine-hook-appends-exact-manifest-selection',args[-6:]==['-depot','10','20','-manifest','42',str(2**63+15)]and args[args.index('-app')+1]=='123')
  check('private-credentials-still-stdin-only',json.loads(private)['refresh_token']=='fixture'and 'fixture'not in args)
 finally:backend.TOOLS=original_tools;backend.tool_payload=original_payload
 check('source-inputs-stable',hashes=={str(x.relative_to(ROOT)):sha(x)for x in sources})
 report={'passed':True,'count':len(checks),'checks':checks,'sourceHashes':hashes,'realAccountDownloadNetworkOrUserDataUsed':False,'ownedScratchOnly':True}
 raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)}
 (ROOT/'Evidence/steam-install-plan-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
