#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Account-free URLSession/SecTrust differential under an owned Steam test policy.
Never executes Valve, authenticates, prints response bodies or reads Steam data.
"""
import hashlib,json,os,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
ORIGIN=WORK/'retained/research-steam-native/offline-arm64-f51402a25c384c81b4fd25a76b225f14'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(p,value):p.write_text(json.dumps(value,indent=2)+'\n');p.chmod(0o600)
def main():
 assert (WORK/'.ready-external-workspace').is_file();run=WORK/'retained/research-steam-native'/('network-only-'+uuid.uuid4().hex);run.mkdir(mode=0o700);(run/'tmp').mkdir();(run/'.owned-network-only').write_text('Account-free network probe only\n');binary=run/'ready-native-network-probe';source=ROOT/'Scripts/steam_native_network_probe.m';snapshot=run/source.name;snapshot.write_bytes(source.read_bytes());driver=run/Path(__file__).name;driver.write_bytes(Path(__file__).read_bytes());command=['/usr/bin/clang','-arch','arm64','-O1','-fobjc-arc','-fblocks','-Wno-deprecated-declarations',str(snapshot),'-framework','Foundation','-framework','Security','-o',str(binary)];subprocess.run(command,capture_output=True,check=True)
 original=(ORIGIN/'offline.sb').read_text();original_report=json.loads((ORIGIN/'report.json').read_text());bundle=next(p for p in Path(original_report['library']).parents if p.name=='Steam.AppBundle')
 lines=[]
 for line in original.splitlines():
  if line.startswith('(allow process-exec') or line.startswith('(allow ipc-posix-'):continue
  if line.startswith('(allow network-') and 'localhost:' in line and '(require-not ' not in line:continue
  if line.startswith('(allow file-read* (literal ') and 'steam_native_' in line:continue
  line=line.replace(str(ORIGIN),str(run));line=line.replace('(subpath '+json.dumps(str(bundle))+')','')
  lines.append(line)
 base='\n'.join(lines)+'\n(allow process-exec (literal '+json.dumps(str(binary))+'))\n'
 assert '(allow network-outbound (require-not (remote ip "localhost:*")))' in base
 trials=[('baseline',[]),('trustd-system-only',['com.apple.trustd']),('trustd-agent-only',['com.apple.trustd.agent']),('trustd-pair',['com.apple.trustd','com.apple.trustd.agent'])]
 env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','READY_','M1L_','STEAM','Steam','SB_'))};env.update(TMPDIR=str(run/'tmp')+'/',XDG_CACHE_HOME=str(run/'cache'))
 report={'schema':1,'scope':'Account-free network stack differential, no Valve code','originPolicySHA256':sha(ORIGIN/'offline.sb'),'sourceSHA256':sha(snapshot),'driverSHA256':sha(driver),'binarySHA256':sha(binary),'buildCommand':command,'trials':[],'accountUsed':False,'ValveLoaded':False,'normalSteamConfigRead':False,'broaderKeychainOrSecuritydAccess':False}
 for label,services in trials:
  profile=run/(label+'.sb');profile.write_text(base+(''.join('(allow mach-lookup (global-name '+json.dumps(service)+'))\n' for service in services)));start=time.monotonic()
  try:result=subprocess.run(['/usr/bin/sandbox-exec','-f',str(profile),str(binary)],env=env,cwd=run,capture_output=True,text=True,timeout=30);code=result.returncode;stdout=result.stdout;stderr=result.stderr
  except subprocess.TimeoutExpired as e:code=124;stdout=e.stdout.decode(errors='replace') if isinstance(e.stdout,bytes) else e.stdout or '';stderr=e.stderr.decode(errors='replace') if isinstance(e.stderr,bytes) else e.stderr or ''
  (run/(label+'.stdout')).write_text(stdout);(run/(label+'.stderr')).write_text(stderr)
  observations=[]
  for line in stdout.splitlines():
   try:observations.append(json.loads(line))
   except ValueError:pass
  trial={'label':label,'addedMachServices':services,'seconds':round(time.monotonic()-start,3),'exit':code,'observations':observations,'policySHA256':sha(profile),'stdoutSHA256':sha(run/(label+'.stdout')),'stderrSHA256':sha(run/(label+'.stderr'))};report['trials'].append(trial);save(run/'progress.json',trial);print(json.dumps({'trial':label,'seconds':trial['seconds'],'exit':code,'observations':observations}),flush=True)
 save(run/'report.json',report);summary={'retainedReport':str(run/'report.json'),'retainedReportSHA256':sha(run/'report.json'),'accountUsed':False,'ValveLoaded':False};save(ROOT/'Evidence/steam-native-network-probe.json',summary);print(json.dumps(summary))
if __name__=='__main__':main()
