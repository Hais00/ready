#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import argparse,hashlib,json,os,pathlib,shutil,subprocess,sys,tempfile
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
FAKE=r'''
import fcntl,json,os,pathlib,sys,time,uuid
r=json.loads(sys.stdin.readline());root=pathlib.Path(os.environ['READY_DATA_ROOT']);root.mkdir(parents=True,exist_ok=True,mode=0o700);db=root/'fixture-jobs.json';lock=root/'lock';o=r['options'];op=r['operation']
def atomic(path,value):
 temporary=path.with_name(path.name+'.'+uuid.uuid4().hex);temporary.write_text(json.dumps(value));temporary.chmod(0o600);os.replace(temporary,path)
def change(fn):
 with lock.open('a')as f:
  fcntl.flock(f,fcntl.LOCK_EX);data=json.loads(db.read_text())if db.exists()else{};value=fn(data);atomic(db,data);return value
with lock.open('a')as f:
 fcntl.flock(f,fcntl.LOCK_EX);path=root/'fixture-calls.json';calls=json.loads(path.read_text())if path.exists()else[];calls.append(dict(operation=op,profileID=r['profileID'],options=o));atomic(path,calls)
def emit(kind,**values):print(json.dumps(dict(type=kind,**values)),flush=True)
def get(data):return data[o['jobID']]
def state(data,value):
 j=get(data);j['state']=value;j['sequence']+=1;return dict(j)
if op=='download_prepare':
 id=str(uuid.uuid4());j=dict(jobID=id,profileID=r['profileID'],gameID=o['gameID'],platform=o['platform'],installDir=o['installDir'],state='queued',phase='queued',bytesCompleted=0,bytesTotal=1000,fraction=0,sequence=1,runs=0)
 if 'storageReservationID'in o:j['storageReservationID']=o['storageReservationID']
 change(lambda data:data.update({id:j}));emit('result',job=j)
elif op=='download_list':emit('result',jobs=change(lambda data:[x for x in data.values()if x['profileID']==r['profileID']]))
elif op=='download_status':emit('result',job=change(lambda data:dict(get(data))))
elif op=='download_control':emit('result',job=change(lambda data:state(data,{'pause':'paused','resume':'queued','retry':'queued','cancel':'cancelled'}[o['action']])))
elif op=='download_run':
 def begin(data):j=get(data);j['runs']+=1;return dict(j)
 j=change(begin)
 if j['gameID']=='999':emit('error',code='engine_failed');raise SystemExit
 j=change(lambda data:state(data,'running'));emit('progress',job=j)
 for _ in range(20):
  time.sleep(.07)
  def step(data):
   j=get(data)
   if j['state']!='running':return dict(j)
   j['bytesCompleted']=min(1000,j['bytesCompleted']+100);j['fraction']=j['bytesCompleted']/1000;j['sequence']+=1
   if j['bytesCompleted']==1000:
    p=pathlib.Path(j['installDir']);p.mkdir(parents=True,exist_ok=True);(p/'game.exe').write_bytes(b'fixture-only')
    j['state']='completed';j['installedVariant']=dict(id='windows',platform='windows',architecture='x86_64',executable=str(p/'game.exe'),arguments=[],installed=True,verification='fixture only')
   return dict(j)
  j=change(step);emit('progress',job=j)
  if j['state']!='running':emit('result',job=j);break
else:emit('error',code='unsupported_operation')
'''
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-products',type=pathlib.Path);a=ap.parse_args()
 if a.core_products:
  products=a.core_products.resolve();modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';archive=products/'libLauncherCore.a';module=modules/'LauncherCore.swiftmodule';importable=list(module.glob('*.swiftmodule'))if module.is_dir()else[module]
  if not archive.is_file()or not importable or any(not p.is_file()for p in importable)or archive.stat().st_mtime_ns<max(p.stat().st_mtime_ns for p in importable):raise ValueError('Matching Core module/archive required')
 else:products,modules,archive=prepare_core()
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-download-manager-',dir=WORK/'tests'))
 (run/'data').mkdir(mode=0o700)
 project=run/'project/StoreBridge';project.mkdir(parents=True)
 shutil.copy2(ROOT/'StoreBridge/supervisor.py',project/'supervisor.py');(project/'bridge.py').write_text(FAKE)
 binary=run/'probe'
 sources=['Sources/M1Launcher/Credentials.swift','Sources/M1Launcher/PrivateCredentialFile.swift','Sources/M1Launcher/StoreClient.swift','Sources/M1Launcher/SteamDownloads.swift','Synthetic/ReadySteamDownloadsProbe.swift']
 source_paths=[ROOT/x for x in sources]+[pathlib.Path(__file__),ROOT/'StoreBridge/supervisor.py'];sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();hashes={str(p.relative_to(ROOT)):sha(p)for p in source_paths}
 env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/','PYTHONDONTWRITEBYTECODE':'1'}
 compiled=subprocess.run(['swiftc','-module-cache-path',str(WORK/'cache/steam-download-manager'),'-swift-version','5','-parse-as-library','-I',str(modules),*[str(ROOT/x)for x in sources],str(archive),'-framework','Security','-o',str(binary)],capture_output=True,text=True,cwd=ROOT,env=env,timeout=120)
 if compiled.returncode:raise RuntimeError(compiled.stderr[-3000:])
 result=subprocess.run([str(binary),str(run)],capture_output=True,text=True,timeout=65,env=env)
 (run/'stdout.log').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError(result.stderr[-1400:]+result.stdout[-1000:])
 report=json.loads(result.stdout);assert report['passed'];assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in source_paths}
 report.update(sourceHashes=hashes,coreProducts=str(products),coreArchiveSHA256=sha(archive),coreModuleHashes={str(p.relative_to(modules)):sha(p)for p in importable},fixtureOnly=True,realAccountKeychainNetworkDownloadOrGameUsed=False)
 raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)}
 (ROOT/'Evidence/steam-download-manager-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
