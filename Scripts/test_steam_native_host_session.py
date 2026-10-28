#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real-process lifecycle tests with an independent fake image, never Valve."""
import argparse,hashlib,json,os,signal,struct,subprocess,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
sys.dont_write_bytecode=True
from steam_host_credential import pack_credentials
from build_steam_native_host_session import build,SOURCES,sha
FAKE=r'''
/* SPDX-License-Identifier: GPL-3.0-only; independent fixture, not a Steam SDK. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include "steam_native_discovery.h"
typedef struct {void **table;} Object;
static void *client_table[80],*engine_table[80],*internal_table[100],*user_table[10],*apps_table[10];
static Object client={client_table},engine={engine_table},internal={internal_table},user={user_table},apps={apps_table};
static int logged,callback_pending;static uint32_t app;static double began;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int mode(const char *s){const char *m=getenv("READY_FIXTURE_MODE");return m&&!strcmp(m,s);}
static int later(void){return logged&&now()-began>.65;}
static void note(const char *s){const char *p=getenv("READY_FIXTURE_LOG");if(p){FILE*f=fopen(p,"a");if(f){fputs(s,f);fputc('\n',f);fclose(f);}}}
void *ready_fixture_method_7d9f18(void*a,int b,int c,const char*d){(void)a;(void)b;(void)c;(void)d;return &user;}
void *ready_fixture_method_7da034(void*a,int b,int c,const char*d){(void)a;(void)b;(void)c;(void)d;return &apps;}
_Bool ready_fixture_method_806114(void*a){(void)a;return logged&&!(later()&&mode("logged-off"));}
uint64_t ready_fixture_method_806124(void*a){(void)a;return UINT64_C(76561197960265729)+(later()&&mode("identity-changed"));}
_Bool ready_fixture_method_7d3bd4(void*a,uint32_t id){(void)a;return logged&&callback_pending==2&&id==app&&!(later()&&mode("license-lost"));}
void *ready_fixture_method_a0fd38(void*a,int b,int c){(void)a;(void)b;(void)c;return &internal;}
void ready_fixture_method_8a69ec(void*a,const char*b,const char*c,_Bool d){(void)a;(void)b;(void)c;(void)d;}
void ready_fixture_method_8a6ccc(void*a,const char*b,const char*c){(void)a;(void)b;(void)c;}
uint32_t ready_fixture_method_8a15cc(void*a,uint64_t id){(void)a;(void)id;if(mode("wedged-startup"))sleep(500);logged=!mode("auth-never-ready");began=now();return 1;}
_Bool ready_fixture_method_8a9104(void*a,uint64_t id,char*out,int32_t n){(void)a;(void)id;snprintf(out,(size_t)n,"synthetic_account");return 1;}
_Bool ready_fixture_method_8a623c(void*a,const char*b){(void)a;(void)b;return 1;}
_Bool ready_fixture_method_8a63b8(void*a,const char*b,_Bool c){(void)a;(void)b;(void)c;return 1;}
_Bool ready_fixture_method_8a8000(void*a,uint32_t id,_Bool flags){(void)a;(void)flags;app=id;callback_pending=1;return 1;}
__attribute__((constructor))static void setup(void){
client_table[5]=ready_fixture_method_7d9f18;client_table[15]=ready_fixture_method_7da034;
engine_table[8]=ready_fixture_method_a0fd38;user_table[1]=ready_fixture_method_806114;user_table[2]=ready_fixture_method_806124;apps_table[6]=ready_fixture_method_7d3bd4;
internal_table[54]=ready_fixture_method_8a69ec;internal_table[56]=ready_fixture_method_8a6ccc;internal_table[1]=ready_fixture_method_8a15cc;internal_table[49]=ready_fixture_method_8a623c;internal_table[50]=ready_fixture_method_8a63b8;internal_table[69]=ready_fixture_method_8a8000;internal_table[78]=ready_fixture_method_8a9104;
}
void *CreateInterface(const char*s,int*rc){*rc=0;return !strcmp(s,"SteamClient023")?&client:&engine;}
int Steam_CreateGlobalUser(int *p){*p=1;return 1;}
_Bool Steam_BLoggedOn(int a,int b){(void)a;(void)b;return logged;}
void Steam_ReleaseUser(int p,int u){(void)p;(void)u;note("user-released");}
_Bool Steam_BReleaseSteamPipe(int p){(void)p;note("pipe-released");return 1;}
typedef struct {int32_t user,id;void *payload;int32_t size;} Message;
_Bool Steam_BGetCallback(int pipe,Message*m){(void)pipe;static uint32_t fields[2];
if(callback_pending==1){fields[0]=1;fields[1]=app;*m=(Message){1,mode("startup-disconnected")?103:1020028,fields,8};callback_pending=2;return 1;}
if(later()&&(mode("disconnect-callback")||mode("malformed-callback"))){*m=(Message){1,mode("disconnect-callback")?103:900,NULL,mode("malformed-callback")?8:0};return 1;}
return 0;}
void Steam_FreeLastCallback(int p){(void)p;}
struct ReadySteamDiscovery {const ReadySteamAuthenticatedHostRecord *record;};
int ready_steam_discovery_start(const char*n,const char*c,const char*s,const ReadySteamAuthenticatedHostRecord*r,ReadySteamDiscovery**o){(void)n;(void)c;(void)s;if(mode("discovery-fails"))return 5;static struct ReadySteamDiscovery d;d.record=r;*o=&d;return atomic_load(&r->authenticated)?0:1;}
void ready_steam_discovery_stop(ReadySteamDiscovery*d){note(atomic_load(&d->record->authenticated)?"discovery-stopped-STILL-AUTHORIZED":"discovery-stopped-revoked");}
size_t ready_steam_discovery_stats_json(ReadySteamDiscovery*d,char*out,size_t n){(void)d;(void)out;(void)n;return 0;}
'''
def events(p):
    try:return [json.loads(s)for s in p.read_text().splitlines()]
    except FileNotFoundError:return []
def await_type(p,kind,timeout=5):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        found=[x for x in events(p)if x.get('type')==kind]
        if found:return found[-1]
        time.sleep(.02)
    raise AssertionError(f'Missing {kind}')
def check_bad_lifelines(run,fixture,fake,env,frame):
    checks={}
    for kind in ('regular-file','write-end'):
        ep=run/('negative-'+kind+'-events.jsonl');ef=os.open(ep,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
        if kind=='regular-file':
            life=os.open(run/'not-a-lifeline',os.O_CREAT|os.O_EXCL|os.O_RDWR,0o600);extra=None
        else:extra,life=os.pipe()
        command=[str(fixture),'--host-session','--library',str(fake),'--lifeline-fd',str(life),'--events-fd',str(ef),'--mode','credentials','--discovery-library',str(fake),'--discovery-service','app.ready.steam.ipctool.'+'1'*32,'--sdk',str(fake)]
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,pass_fds=(life,ef),env=env)
        out,err=child.communicate(frame,timeout=4);os.close(life);os.close(ef)
        if extra is not None:os.close(extra)
        assert child.returncode==65 and not out and not err and not events(ep)
        checks['rejectLifeline-'+kind]=True
    return checks

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--quick',action='store_true',help='Skip only the 41-second and real 45-second startup tests');a=parser.parse_args()
    run=Path(tempfile.mkdtemp(prefix='steam-host-session-',dir=WORK/'tests'));run.chmod(0o700)
    before={s:sha(ROOT/'Scripts'/s)for s in SOURCES}
    (run/'fake.c').write_text(FAKE);fake=run/'fake.dylib';fixture=run/'fixture-host';production=run/'ready-steam-native-host-session'
    env=dict(os.environ,TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/clang-host-session'),PYTHONDONTWRITEBYTECODE='1',READY_STEAM_IPC_NAMESPACE='1'*32,steam_master_ipc_name_override='127.0.0.1:30101',SteamClientService='127.0.0.1:30102',READY_STEAM_STATE_FS_LIBRARY=str(fake),READY_STEAM_IPC_LIBRARY=str(fake),READY_STEAM_ORIGINAL_STATE_ROOT=str(run/'original'),READY_STEAM_PRIVATE_STATE_ROOT=str(run/'private'))
    for args in [ ['-dynamiclib','-I'+str(ROOT/'Scripts'),str(run/'fake.c'),'-o',str(fake)], ['-DREADY_STEAM_HOST_SESSION_FIXTURE=1',str(ROOT/'Scripts/steam_native_host_session.c'),'-o',str(fixture),'-pthread'] ]:
        subprocess.run(['/usr/bin/clang','-arch','arm64','-std=c11','-O1','-Wno-deprecated-declarations','-Wno-unused-function',*args],env=env,capture_output=True,check=True)
    receipt=build(production)
    checks={};counter=0
    source={'username':'synthetic_account','refresh_token':'synthetic_fixture_not_a_real_token','steamID':'76561197960265729','appID':480}
    # pack_credentials uses the genuine protocol shape, with deliberately fake values.
    frame=pack_credentials(source)
    def launch(mode='normal',cached=False,binary=fixture,raw=None,stdout_events=False):
        nonlocal counter
        counter+=1;d=run/f'case-{counter}';d.mkdir(mode=0o700);ep=d/'events.jsonl';ef=os.open(ep,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);rd,wr=os.pipe();log=d/'fake.log'
        child_env=dict(env,READY_FIXTURE_MODE=mode,READY_FIXTURE_LOG=str(log))
        cmd=[str(binary),'--host-session','--library',str(fake),'--lifeline-fd',str(rd),'--events-fd','1'if stdout_events else str(ef),'--mode','cached'if cached else'credentials','--discovery-library',str(fake),'--discovery-service','app.ready.steam.ipctool.'+'1'*32,'--sdk',str(fake)]
        child=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=ef if stdout_events else subprocess.PIPE,stderr=subprocess.PIPE,pass_fds=(rd,ef),env=child_env)
        os.close(rd);os.close(ef)
        payload=raw if raw is not None else pack_credentials(dict(source,refresh_token='READY_USE_GENUINE_CACHED_LOGIN'))if cached else frame
        child.stdin.write(payload);child.stdin.close();child.stdin=None
        return child,wr,ep,log
    def close_check(mode='normal',cached=False):
        p,w,ep,log=launch(mode,cached);ready=await_type(ep,'ready');assert ready['fixtureOnly']and ready['authenticated']and ready['identityMatches']and ready['ownedSubscription']and ready['gameID']==480
        start=time.monotonic();os.close(w);assert p.wait(timeout=3)==42;assert time.monotonic()-start<2.5
        out,err=p.communicate();assert not out and not err
        assert await_type(ep,'stopped')['userReleased']and await_type(ep,'stopped')['pipeReleased']
        text=log.read_text();assert 'discovery-stopped-revoked' in text and 'STILL-AUTHORIZED'not in text
        assert 'synthetic_'not in ep.read_text();return True
    checks['credentialReadyAndEOFRelease']=close_check()
    checks['cachedSentinelReadyAndEOFRelease']=close_check(cached=True)
    p,w,ep,log=launch(stdout_events=True);r=await_type(ep,'ready');assert r['privateName'].endswith(r['namespace'])and r['masterEndpoint']!=r['serviceEndpoint'];os.close(w);assert p.wait(timeout=3)==42;checks['EventsOnFD1AndValidatedContext']=True
    for mode,code in [('logged-off',43),('identity-changed',43),('license-lost',43),('disconnect-callback',43),('malformed-callback',45)]:
        p,w,ep,log=launch(mode);await_type(ep,'ready');assert p.wait(timeout=4)==code;os.close(w);state=await_type(ep,'state');assert state['revoked']and not state['authenticated'];assert 'discovery-stopped-revoked'in log.read_text();checks[mode]=True
    p,w,ep,log=launch();await_type(ep,'ready');p.send_signal(signal.SIGTERM);assert p.wait(timeout=3)==44;os.close(w);checks['SIGTERMOnlyOwnedCleanup']=await_type(ep,'stopped')['pipeReleased']
    for name,options,code in [('invalidFrame',{'raw':b'RDYAUTH1'},65),('wrongCachedSentinel',{'cached':True,'raw':frame},65),('productionRejectsFakeImage',{'binary':production},67),('discoveryFailsClosed',{'mode':'discovery-fails'},67),('StartupDisconnectNeverReady',{'mode':'startup-disconnected'},43)]:
        p,w,ep,log=launch(**options);assert p.wait(timeout=4)==code;os.close(w);assert not any(x.get('type')=='ready'for x in events(ep));checks[name]=True
    p,w,ep,log=launch('wedged-startup');time.sleep(.3);start=time.monotonic();os.close(w);assert p.wait(timeout=3)==42 and time.monotonic()-start<2.6;checks['EOFDuringBlockedVendorCallBounded']=True
    # A distinct owner holds the only writer; its SIGKILL is observed as EOF.
    owner_source=run/'owner.py';owner_source.write_text('''import os,subprocess,sys,time\nr,w=os.pipe();e=os.open(sys.argv[2],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)\na=[sys.argv[1],"--host-session","--library",sys.argv[3],"--lifeline-fd",str(r),"--events-fd",str(e),"--mode","credentials","--discovery-library",sys.argv[3],"--discovery-service","app.ready.steam.ipctool."+"1"*32,"--sdk",sys.argv[3]]\np=subprocess.Popen(a,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(r,e));os.close(r);os.close(e);p.stdin.write(bytes.fromhex(sys.argv[4]));p.stdin.close();time.sleep(100)\n''')
    owner_events=run/'owner-events.jsonl';owner=subprocess.Popen([sys.executable,str(owner_source),str(fixture),str(owner_events),str(fake),frame.hex()],env=env)
    await_type(owner_events,'ready');owner.kill();owner.wait(timeout=2);stopped=await_type(owner_events,'stopped',3);assert stopped['reason']==42 and stopped['pipeReleased'];checks['ParentSIGKILLClosesSoleWriter']=True
    checks.update(check_bad_lifelines(run,fixture,fake,env,frame))
    if not a.quick:
        print(json.dumps({'progress':'long-lifetime-fixture'}),flush=True)
        p,w,ep,log=launch();await_type(ep,'ready');time.sleep(41.1);assert p.poll()is None;assert any(e.get('type')=='state'and e.get('authenticated')is True and e.get('revoked')is False for e in events(ep));os.close(w);assert p.wait(timeout=3)==42;checks['LifelineBeyondHistorical40SecondAlarm']=True
        print(json.dumps({'progress':'real-startup-deadline-fixture'}),flush=True)
        started=time.monotonic();p,w,ep,log=launch('auth-never-ready');assert p.wait(timeout=49)==70;os.close(w);assert 44<time.monotonic()-started<49;checks['Real45SecondStartupBudget']=True
    assert before=={s:sha(ROOT/'Scripts'/s)for s in SOURCES}
    report={'schema':1,'kind':'steam-native-host-session-fixture-tests','passed':all(checks.values()),'count':len(checks),'checks':checks,'fixtureOnly':True,'ValveOrGameSDKExecuted':False,'realAccountUsed':False,'productionBuild':receipt,'fixtureBinarySHA256':sha(fixture),'fakeImageSHA256':sha(fake),'sourceHashes':before,'longBudgetTestsIncluded':not a.quick}
    p=run/'report.json';p.write_text(json.dumps(report,indent=2)+'\n');p.chmod(0o600)
    print(json.dumps({'passed':report['passed'],'count':len(checks),'report':str(p),'reportSHA256':sha(p),'production':receipt}),flush=True)
if __name__=='__main__':main()
