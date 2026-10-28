#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Loader preparation, static genuine-code inspection and own fake-SDK tests.

NEVER dlopen/execute the installed game SDK. Static metadata is read from code
paths only. Tests load only a newly compiled GPL synthetic dylib on Dati APFS.
"""
import hashlib,json,os
from pathlib import Path
import subprocess,tempfile,uuid
ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
GAME=Path('/Volumes/Dati APFS/SteamLibrary/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app')
SDK=GAME/'Contents/Frameworks/libsteam_api.dylib'
EXPECTED='2cbe2533e09d1561051f417d7b8c784481a2efdc4fc9d1274704ee8a7ef50cb1'
FAKE=r'''
// SPDX-License-Identifier: GPL-3.0-only
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
static bool initialized;
__attribute__((constructor)) static void loaded(void){(void)write(STDERR_FILENO,"synthetic-private-library-console",33);const char *p=getenv("READY_FAKE_SDK_MARKER");if(p){int f=open(p,O_CREAT|O_EXCL|O_WRONLY,0600);if(f>=0)close(f);}}
int32_t SteamAPI_InitFlat(char *error){strcpy(error,"synthetic-private-diagnostic-never-log");initialized=true;return 0;}
bool SteamAPI_IsSteamRunning(void){return initialized;}
bool SteamAPI_RestartAppIfNecessary(uint32_t id){if(id!=1091500)_exit(78);const char*mode=getenv("READY_FAKE_RESTART_RESULT");if(mode&&!strcmp(mode,"false"))return false;if(mode&&!strcmp(mode,"true"))return true;if(mode&&!strcmp(mode,"hang")){for(;;)pause();}_exit(77);}
void SteamAPI_RunCallbacks(void){}
void SteamAPI_Shutdown(void){initialized=false;}
static int user_object,apps_object;
void *SteamAPI_SteamUser_v023(void){return initialized?&user_object:NULL;}
bool SteamAPI_ISteamUser_BLoggedOn(void *p){return initialized&&p==&user_object&&!getenv("READY_FAKE_LOGGED_OFF");}
uint64_t SteamAPI_ISteamUser_GetSteamID(void *p){return p==&user_object?76561198000000001ULL:0;}
void *SteamAPI_SteamApps_v008(void){return initialized?&apps_object:NULL;}
bool SteamAPI_ISteamApps_BIsSubscribedApp(void *p,uint32_t id){return initialized&&p==&apps_object&&id==1091500&&!getenv("READY_FAKE_NOT_SUBSCRIBED");}

'''
STATS=r'''
// SPDX-License-Identifier: GPL-3.0-only
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
size_t ready_steam_discovery_redirect_stats_json(char *out,size_t capacity){
 const char *mode=getenv("READY_FAKE_STATS_MODE");if(mode&&!strcmp(mode,"oversize"))return capacity+1;
 if(mode&&!strcmp(mode,"private")){int n=snprintf(out,capacity,"{\"pid\":12345,\"path\":\"/synthetic-private-path\"}");return n>0?(size_t)n:0;}
 int n=snprintf(out,capacity,"{\"redirectLoaded\":true,\"fixedLookups\":2,\"privateRedirects\":2,\"otherLookupsForwarded\":3,\"missingConfiguration\":0,\"invalidConfiguration\":0,\"privateLookupSucceeded\":1,\"privateLookupFailed\":1,\"lastLookupStatus\":1102}");return n>0?(size_t)n:0;
}
'''

def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
 assert(WORK/'.ready-external-workspace').read_text().strip()=='ready project work for thread01a17e79'
 work=Path(tempfile.mkdtemp(prefix='steam-game-api-preparation-',dir=WORK/'tests'));work.chmod(0o700)
 (work/'.ready-steam-game-api-fixture').write_text('own loader/fake SDK; never execute genuine SDK\n')
 source=ROOT/'Scripts/steam_native_game_api_probe.c';copy=work/source.name;copy.write_bytes(source.read_bytes())
 fake=work/'fake-sdk.c';fake.write_text(FAKE)
 cache=WORK/'cache/steam-game-api-clang';cache.mkdir(mode=0o700,exist_ok=True)
 env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','READY_','STEAM','Steam','SB_'))};env['TMPDIR']=str(WORK/'tmp')+'/'
 flags=['xcrun','clang','-mmacosx-version-min=14.0','-O2','-Wall','-Wextra','-Werror','-arch','arm64','-arch','x86_64','-fmodules-cache-path='+str(cache)]
 exe=work/'ready-game-api-probe';library=work/'libOwnSyntheticSteamAPI.dylib'
 commands=[[*flags,str(copy),'-o',str(exe)],[*flags,'-dynamiclib',str(fake),'-o',str(library)]]
 for command in commands:subprocess.run(command,env=env,check=True,capture_output=True)
 checks={};records=[];base=[str(exe),'--library',str(library),'--code-root',str(work),'--expected-sha256',sha(library),'--fixture-only']
 for arch in ['arm64','x86_64']:
  marker=work/('own-load-marker-'+arch)
  context={**env,'READY_STEAM_GAME_API_PROBE':'1','READY_STEAM_IPC_NAMESPACE':uuid.uuid4().hex,'SteamAppId':'1091500','SteamGameId':'1091500','STEAMID':'76561198000000001','READY_FAKE_SDK_MARKER':str(marker)}
  p=subprocess.run(['/usr/bin/arch','-'+arch,*base],env=context,text=True,capture_output=True,timeout=20);assert p.returncode==65 and not marker.exists();checks[arch+'-missing-explicit-permission-does-not-load']=True
  for mode in ['exports','init-flat']:
   p=subprocess.run(['/usr/bin/arch','-'+arch,*base,'--allow-sdk-execution','--mode',mode,'--callback-ms','30'],env=context,text=True,capture_output=True,timeout=20)
   assert p.returncode==0 and not p.stderr and 'synthetic-private-diagnostic-never-log' not in p.stdout
   outputs=[json.loads(line) for line in p.stdout.splitlines()];assert len(outputs)==3
   r=outputs[0]|outputs[1]|outputs[2];assert not r['redirectStatsGetterFound']
   assert r['fixtureOnly'] and not r['restartCalled'] and not r['gameLaunchRequested'] and r['sdkUnchanged']
   assert r['exports']['SteamAPI_InitFlat'] and not r['exports']['SteamAPI_Init']
   if mode=='init-flat':assert r['apiInitialized'] and r['callbackCalls']>0 and r['shutdownCalled'] and r['gameAPIContextAuthenticated'] and r['identityMatches']
   else:assert not r['initializationAttempted'] and r['callbackCalls']==0
   checks[arch+'-own-fake-'+mode+'-restart-never-called']=True;records.append({'architecture':arch,'mode':mode,**r})
  for name,changes in [('wrong-expected-identity',{'STEAMID':'76561198000000002'}),('expected-env-alone-is-not-login',{'READY_FAKE_LOGGED_OFF':'1'}),('missing-subscription',{'READY_FAKE_NOT_SUBSCRIBED':'1'})]:
   p=subprocess.run(['/usr/bin/arch','-'+arch,*base,'--allow-sdk-execution','--mode','init-flat','--callback-ms','0'],env={**context,**changes},text=True,capture_output=True,timeout=20)
   assert p.returncode==4 and not p.stderr
   status=next(value for value in map(json.loads,p.stdout.splitlines()) if 'gameAPIContextAuthenticated' in value);assert not status['gameAPIContextAuthenticated']
   checks[arch+'-'+name+'-does-not-authenticate']=True
  for label,permission_flags,extra in [('missing-restart-permission',[],{'READY_STEAM_RESTART_PROBE_SANDBOX':'client-launch-denied-v1'}),('missing-restart-sandbox',['--allow-restart-query'],{})]:
   untouched=work/('must-not-load-'+arch+'-'+label)
   p=subprocess.run(['/usr/bin/arch','-'+arch,*base,'--allow-sdk-execution','--mode','restart-flat',*permission_flags],env={**context,**extra,'READY_FAKE_SDK_MARKER':str(untouched)},text=True,capture_output=True,timeout=15)
   assert p.returncode==65 and not untouched.exists();checks[arch+'-'+label+'-refuses-before-load']=True
  for value in ['false','true']:
   p=subprocess.run(['/usr/bin/arch','-'+arch,*base,'--allow-sdk-execution','--allow-restart-query','--mode','restart-flat','--callback-ms','0'],env={**context,'READY_STEAM_RESTART_PROBE_SANDBOX':'client-launch-denied-v1','READY_FAKE_RESTART_RESULT':value},text=True,capture_output=True,timeout=15)
   output=[json.loads(line)for line in p.stdout.splitlines()];summary=output[0]
   assert not p.stderr and summary['restartCalled'] and summary['restartReturned']==(value=='true') and not summary['gameExecutableExecutedByProbe']
   if value=='false':assert p.returncode==0 and summary['apiInitialized'] and output[1]['gameAPIContextAuthenticated'] and not summary['gameLaunchRequested']
   else:assert p.returncode==5 and not summary['initializationAttempted'] and not summary['apiInitialized'] and not summary['shutdownCalled'] and summary['callbackCalls']==0 and summary['gameLaunchRequested']
   checks[arch+'-restart-'+value+'-respected-without-spoofing']=True
  if arch=='arm64':
   p=subprocess.run(['/usr/bin/arch','-'+arch,*base,'--allow-sdk-execution','--allow-restart-query','--mode','restart-flat'],env={**context,'READY_STEAM_RESTART_PROBE_SANDBOX':'client-launch-denied-v1','READY_FAKE_RESTART_RESULT':'hang'},text=True,capture_output=True,timeout=13)
   assert p.returncode==124 and json.loads(p.stdout)['restartCalled'] is True and json.loads(p.stdout)['gameLaunchRequested'] is True;checks['restart-timeout-reports-call-conservatively']=True
  stats_source=work/'own-stats.c';stats_library=work/'libOwnStats.dylib'
  if not stats_library.exists():
   stats_source.write_text(STATS);cmd=[*flags,'-dynamiclib',str(stats_source),'-o',str(stats_library)];subprocess.run(cmd,env=env,check=True,capture_output=True);commands.append(cmd)
  for stats_mode in ['valid','private','oversize']:
   args=['/usr/bin/arch','-'+arch,'/usr/bin/env','DYLD_INSERT_LIBRARIES='+str(stats_library),'READY_FAKE_STATS_MODE='+stats_mode,*base,'--allow-sdk-execution','--mode','exports']
   p=subprocess.run(args,env=context,text=True,capture_output=True,timeout=20);assert p.returncode==0 and not p.stderr
   result=json.loads(p.stdout.splitlines()[-1]);assert result['redirectStatsGetterFound']
   assert 'synthetic-private-path' not in p.stdout and '\"pid\"' not in p.stdout
   if stats_mode=='valid':assert result['redirectStatsParsed'] and result['redirectStats']['fixedLookups']==2 and result['redirectStats']['lastLookupStatus']==1102
   else:assert not result['redirectStatsParsed'] and result['redirectStats'] is None
   checks[arch+'-own-redirect-stats-'+stats_mode+'-safe-schema']=True
  assert marker.exists()
  invalid={**context,'SteamAppId':'0'}
  p=subprocess.run(['/usr/bin/arch','-'+arch,*base,'--allow-sdk-execution'],env=invalid,text=True,capture_output=True,timeout=20);assert p.returncode==65;checks[arch+'-wrong-app-context-refused']=True
  bad=base.copy();bad[bad.index('--expected-sha256')+1]='0'*64
  p=subprocess.run(['/usr/bin/arch','-'+arch,*bad,'--allow-sdk-execution'],env=context,text=True,capture_output=True,timeout=20);assert p.returncode==65;checks[arch+'-changed-sdk-refused']=True
  bad=base.copy();bad[bad.index('--code-root')+1]=str(work/'not-parent');(work/'not-parent').mkdir(exist_ok=True)
  p=subprocess.run(['/usr/bin/arch','-'+arch,*bad,'--allow-sdk-execution'],env=context,text=True,capture_output=True,timeout=20);assert p.returncode==65;checks[arch+'-code-root-escape-refused']=True
 # Genuine SDK: static reads/metadata tools only. No loader command is run on it.
 assert SDK.is_file() and not SDK.is_symlink() and sha(SDK)==EXPECTED
 subprocess.run(['/usr/bin/codesign','--verify','--strict',str(SDK)],env=env,check=True,capture_output=True)
 architectures=subprocess.check_output(['/usr/bin/lipo','-archs',str(SDK)],env=env,text=True).strip().split();assert set(architectures)=={'arm64','x86_64'}
 symbols=subprocess.check_output(['/usr/bin/nm','-arch','arm64','-gU',str(SDK)],env=env,text=True)
 names=['SteamAPI_Init','SteamAPI_InitFlat','SteamAPI_IsSteamRunning','SteamAPI_RestartAppIfNecessary','SteamAPI_RunCallbacks','SteamAPI_Shutdown','SteamAPI_SteamUser_v023','SteamAPI_ISteamUser_BLoggedOn','SteamAPI_ISteamUser_GetSteamID','SteamAPI_SteamApps_v008','SteamAPI_ISteamApps_BIsSubscribedApp']
 exports={name:any(line.split()[-1:] == ['_'+name] for line in symbols.splitlines()) for name in names}
 assert exports==dict.fromkeys(names,True)|{'SteamAPI_Init':False}
 exports_by_arch={}
 for cpu in architectures:
  listing=subprocess.check_output(['/usr/bin/nm','-arch',cpu,'-gU',str(SDK)],env=env,text=True)
  exports_by_arch[cpu]={name:any(line.split()[-1:]==['_'+name] for line in listing.splitlines()) for name in names}
  assert exports_by_arch[cpu]==exports
 checks['genuine-sdk-static-signature-hash-and-exports-only']=True
 assert copy.read_bytes()==source.read_bytes()
 planned={'command':[str(exe),'--allow-sdk-execution','--library',str(SDK),'--code-root',str(GAME),'--expected-sha256',EXPECTED,'--mode','init-flat','--callback-ms','250'],
          'requiredEnvironment':{'SteamAppId':'1091500','SteamGameId':'1091500','READY_STEAM_GAME_API_PROBE':'1','READY_STEAM_IPC_NAMESPACE':'<same live host namespace>','STEAMID':'<explicit genuine host identity; comparison input only>'},
          'requiredIndependentPolicy':['Root authenticated host kept online','own child with same scoped IPC namespace/state adaptation','read-only installed game code root','deny Steam/full-client/game execution and unapproved state/IPC','independent parent timeout and loaded-image/process audit'],
          'genuineSDKExecuted':False,'RootReviewAndGORequiredBeforeExecution':True}
 (work/'future-owned-child-plan.json').write_text(json.dumps(planned,indent=2)+'\n')
 report={'schema':1,'fixtureOnly':True,'passed':all(checks.values()),'checks':checks,'checkCount':len(checks),'records':records,'probePath':str(exe),'probeSHA256':sha(exe),'sourceSHA256':sha(source),'testSHA256':sha(Path(__file__)),
         'genuineSDK':{'path':str(SDK),'sha256':EXPECTED,'bytes':SDK.stat().st_size,'architectures':architectures,'codesignStrictVerified':True,'exports':exports,'exportsByArchitecture':exports_by_arch,'executed':False,'genuineClientAssetsAreOpenSource':False},
         'commands':commands,'futurePlan':str(work/'future-owned-child-plan.json'),'fixtureRoot':str(work),'gameLaunched':False,'SteamAppLaunched':False,'originalSteamConfigRead':False,'realCredentialsRead':False,'genuineGameAPIWorkingVerified':False}
 (ROOT/'Evidence/steam-native-game-api-preparation.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({k:report[k] for k in ['passed','checkCount','probePath','probeSHA256','sourceSHA256','futurePlan','genuineGameAPIWorkingVerified']},indent=2))
if __name__=='__main__':main()
