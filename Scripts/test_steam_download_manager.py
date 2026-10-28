#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import json,pathlib,shutil,subprocess,sys,tempfile
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
FAKE=r'''
import fcntl,json,os,pathlib,sys,time,uuid
r=json.loads(sys.stdin.readline());root=pathlib.Path(os.environ['READY_DATA_ROOT']);root.mkdir(parents=True,exist_ok=True);db=root/'fixture-jobs.json';lock=root/'lock';o=r['options'];op=r['operation']
def change(fn):
 with lock.open('a')as f:
  fcntl.flock(f,fcntl.LOCK_EX);data=json.loads(db.read_text())if db.exists()else{};value=fn(data);db.write_text(json.dumps(data));return value
def emit(kind,**values):print(json.dumps(dict(type=kind,**values)),flush=True)
def get(data):return data[o['jobID']]
def state(data,value):
 j=get(data);j['state']=value;j['sequence']+=1;return dict(j)
if op=='download_prepare':
 id=str(uuid.uuid4());j=dict(jobID=id,profileID=r['profileID'],gameID=o['gameID'],platform=o['platform'],installDir=o['installDir'],state='queued',phase='queued',bytesCompleted=0,bytesTotal=1000,fraction=0,sequence=1,runs=0)
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
 products,modules,archive=prepare_core();run=pathlib.Path(tempfile.mkdtemp(prefix='steam-download-manager-',dir=WORK/'tests'))
 project=run/'project/StoreBridge';project.mkdir(parents=True)
 shutil.copy2(ROOT/'StoreBridge/supervisor.py',project/'supervisor.py');(project/'bridge.py').write_text(FAKE)
 binary=run/'probe'
 sources=['Sources/M1Launcher/Credentials.swift','Sources/M1Launcher/StoreClient.swift','Sources/M1Launcher/SteamDownloads.swift','Synthetic/ReadySteamDownloadsProbe.swift']
 compiled=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-I',str(modules),*[str(ROOT/x)for x in sources],str(archive),'-framework','Security','-o',str(binary)],capture_output=True,text=True,cwd=ROOT)
 if compiled.returncode:raise RuntimeError(compiled.stderr[-3000:])
 result=subprocess.run([str(binary),str(run)],capture_output=True,text=True,timeout=35)
 (run/'stdout.log').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError(result.stderr[-1400:]+result.stdout[-1000:])
 report=json.loads(result.stdout);assert report['passed']
 (ROOT/'Evidence/steam-download-manager-tests.json').write_text(json.dumps({'fixtureOnly':True,'retainedRoot':str(run),**report},indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
