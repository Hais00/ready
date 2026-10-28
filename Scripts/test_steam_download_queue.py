#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Cold subprocess pause/kill/restart/lease fixtures; no accounts or real CDN.
The fake engine verifies existing chunk bytes before reusing them, and preserves
its own cache/manifest just as the pinned adapter contract requires.
"""
import hashlib,json,os,pathlib,signal,subprocess,sys,tempfile,time,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
ENGINE=r'''
import hashlib,json,os,pathlib,plistlib,signal,struct,sys,time,zlib
r=json.loads(sys.stdin.readline());assert r['username']=='fixture_user' and r['refresh_token']=='fixture-private-token'
assert 'fixture-private-token' not in ' '.join(sys.argv) and 'fixture-private-token' not in '\n'.join(os.environ.values())
path=pathlib.Path(sys.argv[1]);mode=pathlib.Path(sys.argv[2]).read_text().strip();platform=sys.argv[3]
if mode=='stale_exit':raise SystemExit(0)
if mode=='ignore':signal.signal(signal.SIGTERM,signal.SIG_IGN)
(path/'fixture-processes.json').write_text(json.dumps({'engine':os.getpid(),'bridge':os.getppid()}))
cache=path/'.DepotDownloader';cache.mkdir(exist_ok=True);manifest=cache/'1_42.manifest';manifest.write_bytes(b'own benign manifest');(cache/'1_42.manifest.sha').write_bytes(hashlib.sha1(manifest.read_bytes()).digest())
file=path/'payload.bin';size=8*4096
if not file.exists():
 with file.open('wb') as out:out.truncate(size)
chunks=[bytes([65+i])*4096 for i in range(8)]
with file.open('rb') as stream:valid=[stream.read(4096)==chunk for chunk in chunks]
done=sum(valid)*4096;network=0
(path/'fixture-resume.json').write_text(json.dumps({'reusedBytes':done}))
def emit(kind,**extra):print('READY_DOWNLOAD_V1 '+json.dumps({'kind':kind,'totalBytes':size,'completedBytes':done,'networkBytesReceived':network,**extra}),flush=True)
emit('plan',phase='verifying');print('Raw log must never forward fixture-private-token https://fixture.invalid/signed?secret=1',flush=True)
for i,chunk in enumerate(chunks):
 if valid[i]:continue
 with file.open('r+b') as out:out.seek(i*4096);out.write(chunk);out.flush();os.fsync(out.fileno())
 done+=4096;network+=4096;emit('progress',phase='downloading')
 if mode=='network':emit('error',code='network_error');raise SystemExit(1)
 if mode=='auth':emit('error',code='authentication_required');raise SystemExit(1)
 if mode in ('slow','ignore'):time.sleep(.15)
if platform=='windows':
 code=bytearray(0x86);code[:2]=b'MZ';struct.pack_into('<I',code,0x3c,0x80);code[0x80:0x84]=b'PE\0\0';struct.pack_into('<H',code,0x84,0x8664);(path/'Game.exe').write_bytes(code)
else:
 app=path/'Game.app';(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True);(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Game','CFBundlePackageType':'APPL'}));(app/'Contents/MacOS/Game').write_bytes(struct.pack('<IIIIIIII',0xfeedfacf,0x0100000c,0,2,0,0,0,0));(app/'Contents/MacOS/Game').chmod(0o755)
compress=zlib.compressobj(wbits=-15);(cache/'depot.config').write_bytes(compress.compress(b'\x0a\x04\x08\x01\x10\x2a')+compress.flush())
emit('completed',phase='verifying',manifests={'1':'42'})
if mode=='descendant':
 import subprocess
 inherited=[]
 for f in range(3,256):
  try:os.fstat(f);inherited.append(f)
  except OSError:pass
 subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],pass_fds=tuple(inherited),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

'''
WRAPPER=r'''
import json,os,pathlib,signal,sys
sys.path.insert(0,sys.argv[1]);import steam_downloads as q
signal.signal(signal.SIGTERM,lambda a,b:(_ for _ in ()).throw(KeyboardInterrupt()))
request=json.loads(sys.stdin.readline())
def factory(r,c,s):
 path=pathlib.Path(r['options']['installDir']);env={k:v for k,v in os.environ.items() if 'token' not in k.lower()}
 return [sys.executable,sys.argv[2],str(path),sys.argv[3],r['options']['platform']],env,json.dumps(r['credentials'])+'\n',path
try:
 result=q.run_job(request,factory) if request['operation']=='download_run' else q.dispatch(request)
 print(json.dumps({'type':'result',**result}),flush=True)
except q.BridgeError as error:print(json.dumps({'type':'error','code':error.code}),flush=True);raise SystemExit(1)
except KeyboardInterrupt:print(json.dumps({'type':'error','code':'cancelled'}),flush=True);raise SystemExit(130)
'''

def main():
 assert(WORK/'.ready-external-workspace').read_text().strip()=='ready project work for thread01a17e79'
 work=pathlib.Path(tempfile.mkdtemp(prefix='steam-download-fixtures-',dir=WORK/'tests'));work.chmod(0o700);data=work/'data';data.mkdir(mode=0o700)
 os.environ['READY_DATA_ROOT']=str(data);os.environ['PYTHONDONTWRITEBYTECODE']='1';sys.path.insert(0,str(ROOT/'StoreBridge'))
 import steam_downloads as q
 engine=work/'engine.py';engine.write_text(ENGINE);wrapper=work/'wrapper.py';wrapper.write_text(WRAPPER);mode=work/'mode';mode.write_text('complete')
 env={**os.environ,'READY_DATA_ROOT':str(data),'TMPDIR':str(WORK/'tmp')+'/','PYTHONDONTWRITEBYTECODE':'1'};profile=str(uuid.uuid4());other=str(uuid.uuid4());checks={}
 personal=data/'Profiles'/profile/'personal.marker';personal.parent.mkdir(parents=True,mode=0o700);personal.write_bytes(b'personal profile bytes must survive')
 def req(op,options=None,p=profile):return {'operation':op,'store':'steam','profileID':p,'credentials':{'username':'fixture_user','refresh_token':'fixture-private-token'},'options':options or {}}
 def prepare(name,platform='windows',p=profile,path=None):
  path=path or work/'games'/name
  return q.prepare(req('download_prepare',{'gameID':'123','platform':platform,'installDir':str(path),'metadata':{'launch':[{'executable':'Game.exe' if platform=='windows' else 'Game.app','oslist':'windows' if platform=='windows' else 'macos','type':'default'}]}},p))['job']
 def command(request):
  return [sys.executable,str(ROOT/'StoreBridge/supervisor.py'),str(work/'entry.py')]
 # Supervisor accepts one script, so the entry owns only constant fixture paths;
 # no request or credential is embedded in args/environment.
 entry=work/'entry.py';entry.write_text('import runpy,sys\nsys.argv='+repr([str(wrapper),str(ROOT/'StoreBridge'),str(engine),str(mode)])+'\nrunpy.run_path('+repr(str(wrapper))+',run_name="__main__")\n')
 def start(job,p=profile):
  process=subprocess.Popen(command({}),env=env,cwd=work,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  process.stdin.write(json.dumps(req('download_run',{'jobID':job['jobID']},p))+'\n');process.stdin.close();return process
 def finish(process):
  output=process.stdout.read();error=process.stderr.read();process.wait(timeout=10)
  assert 'fixture-private-token' not in output+error and 'signed?secret' not in output+error
  messages=[json.loads(line) for line in output.splitlines() if line.startswith('{')]
  assert messages;return messages[-1],messages
 def wait_bytes(job,minimum):
  deadline=time.monotonic()+8
  while time.monotonic()<deadline:
   value=q.load(profile,job['jobID'])
   if (value.get('bytesCompleted') or 0)>=minimum:return value
   time.sleep(.03)
  raise AssertionError('Fixture worker did not progress')
 # Normal completion verifies selected manifest/cache and binary metadata.
 a=prepare('normal');mode.write_text('complete');last,events=finish(start(a));assert last['job']['state']=='completed' and last['installedVariant']['architecture']=='x86_64';checks['cold-supervised-completion-manifest-and-PE-verified']=True
 assert any(m.get('type')=='progress' and m['job']['bytesCompleted'] is not None for m in events);checks['numeric-progress-and-raw-secret-log-suppression']=True
 # Same game and target dedup while partial, no new job identifier.
 b=prepare('pause');mode.write_text('slow');process=start(b);wait_bytes(b,8192)
 try:
  with q.installation_lease(pathlib.Path(b['installDir']),mode='read'):raise AssertionError('Reader admitted during download')
 except q.BridgeError as e:assert e.code=='installation_busy'
 control=q.control(req('download_control',{'jobID':b['jobID'],'action':'pause'}));assert control['job']['state']=='pausing'
 last,_=finish(process);assert last['job']['state']=='paused';partial=pathlib.Path(b['installDir'])/'payload.bin';before=partial.read_bytes();assert any(before)
 again=prepare('pause');assert again['jobID']==b['jobID'];checks['pause-stops-only-worker-and-durable-job-is-deduplicated']=True
 q.control(req('download_control',{'jobID':b['jobID'],'action':'resume'}));mode.write_text('complete');last,_=finish(start(b));assert last['job']['state']=='completed';reuse=json.loads((pathlib.Path(b['installDir'])/'fixture-resume.json').read_text());assert reuse['reusedBytes']>=8192 and last['job']['networkBytesReceived']<last['job']['bytesTotal'];checks['resume-validates-and-reuses-existing-chunks-cache']=True
 with q.installation_lease(pathlib.Path(b['installDir']),mode='read'):pass
 checks['pause-resume-releases-and-reacquires-installation-lease']=True
 # Network failures are retryable; auth failures are not auto-network retries.
 c=prepare('network');mode.write_text('network');last,_=finish(start(c));assert last['job']['state']=='retry_wait' and last['job']['retryable']
 q.control(req('download_control',{'jobID':c['jobID'],'action':'retry'}));mode.write_text('complete');last,_=finish(start(c));assert last['job']['state']=='completed' and json.loads((pathlib.Path(c['installDir'])/'fixture-resume.json').read_text())['reusedBytes']>=4096;checks['network-retry-resumes-partial-data']=True
 d=prepare('auth');mode.write_text('auth');last,_=finish(start(d));assert last['job']['state']=='failed' and not last['job']['retryable'] and last['job']['errorCode']=='authentication_required';checks['auth-denial-never-auto-network-retry']=True
 # Cancel retains partial content and cache; explicit resume can continue later.
 e=prepare('cancel');mode.write_text('slow');process=start(e);wait_bytes(e,4096);q.control(req('download_control',{'jobID':e['jobID'],'action':'cancel'}));last,_=finish(process);assert last['job']['state']=='cancelled' and (pathlib.Path(e['installDir'])/'payload.bin').exists() and (pathlib.Path(e['installDir'])/'.DepotDownloader/1_42.manifest').exists();checks['cancel-preserves-game-and-depot-cache']=True
 # Kill the exact owned bridge, not a PID from a persisted job file. Supervisor
 # reserves its group and terminates the inherited-lease engine before EOF.
 f=prepare('crash');mode.write_text('ignore');process=start(f);wait_bytes(f,4096);pids=json.loads((pathlib.Path(f['installDir'])/'fixture-processes.json').read_text());os.kill(pids['bridge'],signal.SIGKILL);finish(process)
 state=q.status(req('download_status',{'jobID':f['jobID']}))['job'];assert state['state']=='interrupted';q.control(req('download_control',{'jobID':f['jobID'],'action':'resume'}));mode.write_text('complete');last,_=finish(start(f));assert last['job']['state']=='completed';checks['SIGKILL-supervisor-recovery-cold-restart-and-lease-handoff']=True
 # Another profile cannot use/alter this job, nor write the active shared target.
 mode.write_text('slow');g=prepare('shared');process=start(g);wait_bytes(g,4096)
 h=prepare('same-target','windows',other,pathlib.Path(g['installDir']));denied,_=finish(start(h,other));assert denied.get('code')=='installation_busy';checks['cross-profile-shared-installation-writer-conflicts']=True
 try:q.load(other,g['jobID'])
 except q.BridgeError as er:assert er.code=='download_not_found'
 else:raise AssertionError('Cross-profile job access admitted')
 q.control(req('download_control',{'jobID':g['jobID'],'action':'cancel'}));finish(process);checks['jobs-profile-scoped-controls-cannot-rebind']=True
 # macOS variant uses the same durable protocol and verified installed Mach-O.
 mode.write_text('complete');m=prepare('mac','macOS');last,_=finish(start(m));assert last['installedVariant']['architecture']=='arm64' and last['installedVariant']['platform']=='macOS';checks['macOS-variant-completion-inspects-actual-binary']=True
 # Never count old depot completion evidence as a new successful run.
 stale=prepare('normal');mode.write_text('stale_exit');last,_=finish(start(stale));assert last['job']['state']=='failed' and last['job']['errorCode']=='engine_protocol_required';checks['exit-zero-stale-manifest-cannot-forge-completion']=True
 try:prepare('forbidden',path=data/'Profiles'/profile/'victim')
 except q.BridgeError:pass
 else:raise AssertionError('Protected profile path admitted')
 assert not (data/'Profiles'/profile/'victim').exists();assert personal.read_bytes()==b'personal profile bytes must survive';checks['profile-personal-data-untouched-and-protected-target-not-created']=True
 # The engine exits first but an owned descendant retains writer descriptors.
 mode.write_text('descendant');late=prepare('descendant');last,_=finish(start(late));assert last['job']['state']=='verifying' and 'installedVariant' not in last
 final=q.status(req('download_status',{'jobID':late['jobID']}))['job'];assert final['state']=='completed';checks['completion-waits-for-orphan-descendant-writer-lease-release']=True
 # Legacy corrupt cache metadata is retained, not deleted or mistaken for proof.
 corrupt=prepare('corrupt');cache=pathlib.Path(corrupt['installDir'])/'.DepotDownloader';cache.mkdir();(cache/'depot.config').write_bytes(b'owned interrupted legacy metadata')
 mode.write_text('complete');last,_=finish(start(corrupt));assert last['job']['state']=='completed';archived=list((cache/'ready-recovery').glob('*.depot.config'));assert len(archived)==1 and archived[0].read_bytes()==b'owned interrupted legacy metadata';checks['corrupt-legacy-config-archived-before-resume']=True
 # A mutable installation alias can never write a personal profile directory.
 unsafe=prepare('unsafe');(pathlib.Path(unsafe['installDir'])/'outside').symlink_to(personal.parent,target_is_directory=True)
 denied,_=finish(start(unsafe));assert denied['code']=='unsafe_installation' and personal.read_bytes()==b'personal profile bytes must survive';checks['symlink-escape-refused-without-personal-writes']=True
 # Both OS variants share credentials but retain independent locks and jobs.
 mode.write_text('slow');win=prepare('parallel-win');mac=prepare('parallel-mac','macOS');pw=start(win);pm=start(mac);lw,_=finish(pw);lm,_=finish(pm);assert lw['job']['state']==lm['job']['state']=='completed';checks['same-profile-Windows-macOS-downloads-independent']=True
 states=[q.load(profile,value['jobID']) for value in [a,b,c,d,e,f,g,m,late,corrupt,unsafe,win,mac]]
 ids=[value['loginID'] for value in states];assert len(ids)==len(set(ids)) and all(0xD0000000<=value<=0xDfffffff for value in ids);checks['unique-durable-loginIDs-disjoint-from-shared-service']=True
 all_jobs=q.list_jobs(req('download_list'))['jobs'];assert len(all_jobs)>=8 and all(j['profileID']==profile for j in all_jobs);checks['persistent-list-restores-jobs-after-process-exit']=True
 for path in data.rglob('*.json'):
  assert 'fixture-private-token' not in path.read_text() and 'fixture_user' not in path.read_text()
 checks['credentials-never-persist-in-job-metadata']=True
 report={'schema':1,'fixtureOnly':True,'passed':all(checks.values()),'checks':checks,'checkCount':len(checks),'fixtureRoot':str(work),'sourceSHA256':hashlib.sha256((ROOT/'StoreBridge/steam_downloads.py').read_bytes()).hexdigest(),'testSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'realAccountUsed':False,'realCDNUsed':False,'commercialGameDownloaded':False}
 (ROOT/'Evidence/steam-download-queue-fixtures.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
