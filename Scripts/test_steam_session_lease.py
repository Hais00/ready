#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Private descriptor/process/lease fixtures. Never loads a Valve SDK or account."""
import array,fcntl,hashlib,json,os,signal,socket,subprocess,sys,tempfile,time,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
sys.dont_write_bytecode=True
from test_steam_native_host_session import FAKE,await_type,events
from steam_host_credential import pack_credentials
GAME=r'''
// SPDX-License-Identifier: GPL-3.0-only
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
int main(int argc,char**argv){if(argc!=4)return 64;const char*root=argv[1];int ignore=atoi(argv[2]),forked=atoi(argv[3]);
if(ignore)signal(SIGTERM,SIG_IGN);char p[4096];snprintf(p,sizeof p,"%s/leader.json",root);FILE*f=fopen(p,"w");fprintf(f,"{\"leader\":%d,\"group\":%d}",getpid(),getpgrp());fclose(f);
if(forked){pid_t c=fork();if(c<0)return 71;if(c>0)_exit(0);}
snprintf(p,sizeof p,"%s/state.json",root);f=fopen(p,"w");const char*libs=getenv("DYLD_INSERT_LIBRARIES");fprintf(f,"{\"pid\":%d,\"group\":%d,\"extraFDs\":[",getpid(),getpgrp());int n=0;for(int fd=3;fd<128;fd++)if(fcntl(fd,F_GETFD)>=0&&fd!=fileno(f))fprintf(f,"%s%d",n++?",":"",fd);fprintf(f,"],\"injectionPresent\":%s}",libs&&*libs?"true":"false");fclose(f);
for(int tick=0;tick<500;tick++){char done[4096],temp[4096];snprintf(done,sizeof done,"%s/finish",root);if(!access(done,F_OK))return 0;snprintf(temp,sizeof temp,"%s/beat.tmp",root);f=fopen(temp,"w");if(!f)return 71;fprintf(f,"%d",tick);fclose(f);snprintf(p,sizeof p,"%s/beat",root);if(rename(temp,p))return 71;usleep(50000);}return 0;}
'''
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def wait(fn,timeout=6):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        try:
            v=fn()
            if v:return v
        except(FileNotFoundError,json.JSONDecodeError,ProcessLookupError):pass
        time.sleep(.02)
    raise AssertionError('Timed out waiting for owned fixture')
def locked(p):
    with p.open('a+b')as f:
        try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return True
        return False
def main():
    run=Path(tempfile.mkdtemp(prefix='steam-session-lease-',dir=WORK/'tests'));run.chmod(0o700)
    env=dict(os.environ,TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/clang-host-session'),PYTHONDONTWRITEBYTECODE='1')
    keeper=run/'ReadySessionHost';game=run/'game';host=run/'fixture-host';fake=run/'fake.dylib'
    (run/'game.c').write_text(GAME);(run/'fake.c').write_text(FAKE)
    recipes=[['-Wall','-Wextra','-Werror','-D_DARWIN_C_SOURCE',str(ROOT/'SessionHost/ReadySessionHost.c'),str(ROOT/'SessionHost/InstallationLease.c'),'-o',str(keeper)], [str(run/'game.c'),'-o',str(game)], ['-dynamiclib','-I'+str(ROOT/'Scripts'),str(run/'fake.c'),'-o',str(fake)], ['-DREADY_STEAM_HOST_SESSION_FIXTURE=1','-Wno-deprecated-declarations',str(ROOT/'Scripts/steam_native_host_session.c'),'-o',str(host),'-pthread']]
    for recipe in recipes:subprocess.run(['/usr/bin/clang','-std=c11','-O1','-arch','arm64',*recipe],env=env,capture_output=True,check=True)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(keeper)],capture_output=True,check=True)
    adapters=[]
    (run/'adapter.c').write_text('// SPDX-License-Identifier: GPL-3.0-only\nint ready_own_fixture_adapter(void){return 1;}\n')
    for i in range(4):
        p=run/f'adapter-{i}.dylib';subprocess.run(['/usr/bin/clang','-dynamiclib',str(run/'adapter.c'),'-o',str(p)],env=env,capture_output=True,check=True);adapters.append(str(p))
    env['READY_STEAM_ADAPTER_LIBRARIES']=':'.join(adapters[:3]);env['READY_OVERLAY_LIBRARY']=adapters[3]
    sys.path.insert(0,str(ROOT/'StoreBridge'));import install_lock
    from bridge import BridgeError
    install_lock.LOCK_ROOT=run/'install-locks'
    checks={};counter=0
    def busy(path):
        try:
            with install_lock.installation_lease(path):pass
        except BridgeError as e:assert e.code=='installation_busy';return True
        return False
    def prepare(ignore=False,forked=True,rights=2,frame=b'RDYSLF1\0',eof=True,health_kind='read',env_extra=None,wine=False,binding=None):
        nonlocal counter
        counter+=1;d=run/f'case-{counter}';d.mkdir(mode=0o700);installation=d/'installation';installation.mkdir();prefix=d/'prefix.lock'
        lease=prefix.open('a+b');os.fchmod(lease.fileno(),0o600);fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
        parent,child=socket.socketpair();parent.settimeout(4);rd,wr=os.pipe();fds=[lease.fileno(),rd]
        if health_kind=='write':fds[1]=wr
        if health_kind=='regular':fds[1]=lease.fileno()
        if health_kind=='closed':os.close(wr);wr=-1
        if rights==3:fds.append(lease.fileno())
        else:fds=fds[:rights]
        launch_game=game;bindings=[];sdk=None
        if binding:
            launch_game=installation/'game';shutil.copy2(game,launch_game);sdk=installation/'libsteam_api.dylib';sdk.write_bytes(b'owned synthetic SDK marker')
            executable_hash=sha(launch_game);sdk_hash=sha(sdk)
            if binding=='sdk-outside':sdk=d/'outside-sdk';sdk.write_bytes(b'owned synthetic SDK marker')
            if binding=='sdk-symlink':alias=installation/'sdk-alias';alias.symlink_to(sdk);sdk=alias
            if binding=='game-symlink':alias=installation/'game-alias';alias.symlink_to(launch_game);launch_game=alias
            if binding=='sdk-world-write':sdk.chmod(0o666)
            if binding=='game-world-write':launch_game.chmod(0o777)
            if binding=='sdk-special':sdk.unlink();os.mkfifo(sdk,0o600)
            bindings=['--steam-executable-sha256',executable_hash,'--steam-sdk',str(sdk),'--steam-sdk-sha256',sdk_hash]
            if binding=='partial':bindings=bindings[:2]
            if binding=='bad-digest':bindings[1]='g'*64
        command=[str(keeper),'--steam-bootstrap','--installation',str(installation),'--installation-lock-root',str(install_lock.LOCK_ROOT),*bindings]
        if binding=='non-steam':command.remove('--steam-bootstrap')
        if wine:command+=['--wine-server','/usr/bin/true','--prefix',str(d)]
        command+=['--',str(launch_game),str(d),str(int(ignore)),str(int(forked))]
        p=subprocess.Popen(command,stdin=child,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,env=dict(env,**(env_extra or {})))
        child.close()
        # Change bytes after the parent's hash selection, before descriptor
        # admission lets the keeper acquire its real read lease and re-hash.
        if binding=='flip-executable':
            with launch_game.open('ab')as changed:changed.write(b'changed after selection')
        if binding=='flip-sdk':sdk.write_bytes(b'changed after selection')
        try:parent.sendmsg([frame],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',fds))]if fds else [])
        except BrokenPipeError:pass
        if eof:
            try:parent.shutdown(socket.SHUT_WR)
            except OSError:pass
        lease.close();os.close(rd)
        return p,parent,wr,d,prefix,installation
    def ack(s):
        data=b''
        while len(data)<8:
            piece=s.recv(8-len(data));assert piece;data+=piece
        assert data==b'RDYACK1\0'and s.recv(1)==b''
    def finish(p,s,w,d):
        if w>=0:os.close(w)
        s.close()
        if p.poll()is None:p.terminate()
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)
    # Independent A/B groups; a zombie leader must keep both real leases.
    A=prepare();B=prepare();
    try:
        for p,s,w,d,lock,installation in (A,B):
            ack(s);state=wait(lambda:json.loads((d/'state.json').read_text()));assert not state['extraFDs']and state['injectionPresent'];assert locked(lock)and busy(installation)
        p,s,w,d,lock,installation=A;beat=(d/'beat').read_text();os.close(w);A=(p,s,-1,d,lock,installation);assert p.wait(timeout=4)==75;wait(lambda:not locked(lock));assert not busy(installation)
        other=B[0];assert other.poll()is None and locked(B[4])and busy(B[5]);checks['EOFStopsOnlyOwnedAnchoredGroupAndReleasesBothLeases']=True
        checks['SteamGameInheritsAdaptersOverlayButNoExtraFDs']=True
        checks['ZombieLeaderRetainsInstallationAndPrefixUntilGroupDone']=True
    finally:
        for p,s,w,d,*_ in (A,B):finish(p,s,w,d)
    p,s,w,d,lock,installation=prepare(ignore=True)
    ack(s);wait(lambda:(d/'beat').exists());start=time.monotonic();os.close(w);w=-1;time.sleep(.25);assert p.poll()is None and locked(lock)and busy(installation)
    assert p.wait(timeout=4)==75 and 1.8<time.monotonic()-start<4;assert not locked(lock)and not busy(installation);finish(p,s,w,d);checks['IgnoredTERMThenAnchoredKILLRetainsBothLeases']=True
    p,s,w,d,lock,installation=prepare();ack(s);wait(lambda:(d/'beat').exists());os.write(w,b'x');assert p.wait(timeout=4)==75;finish(p,s,w,d);checks['HealthPayloadFailsClosed']=True
    p,s,w,d,lock,installation=prepare();ack(s);wait(lambda:(d/'beat').exists());(d/'finish').touch();assert p.wait(timeout=4)==0;assert not locked(lock);finish(p,s,w,d);checks['NaturalGameExitPreservesWrapperStatus']=True
    negatives=[('zeroFD',dict(rights=0),65),('oneFD',dict(rights=1),65),('extraFD',dict(rights=3),65),('badFrame',dict(frame=b'BADSLF1\0'),65),('truncatedFrame',dict(frame=b'RDYS'),65),('extraData',dict(frame=b'RDYSLF1\0x'),65),('writeHealth',dict(health_kind='write'),65),('regularHealth',dict(health_kind='regular'),65),('prelaunchHealthEOF',dict(health_kind='closed'),65),('wineRejected',dict(wine=True),64),('invalidAdapters',dict(env_extra={'READY_STEAM_ADAPTER_LIBRARIES':'/invalid:/invalid:/invalid'}),75)]
    for name,options,code in negatives:
        p,s,w,d,lock,installation=prepare(**options);assert p.wait(timeout=4)==code,(name,p.returncode,p.stderr.read());assert not(d/'leader.json').exists()and not locked(lock);finish(p,s,w,d);checks[name]=True
    p,s,w,d,lock,installation=prepare(binding='valid');ack(s);wait(lambda:(d/'beat').exists());assert locked(lock)and busy(installation);(d/'finish').touch();assert p.wait(timeout=4)==0;finish(p,s,w,d);checks['BoundGameAndSDKRehashedAfterReadLeaseAdmission']=True
    for name,code in [('flip-executable',76),('flip-sdk',76),('sdk-outside',76),('sdk-symlink',76),('game-symlink',76),('sdk-world-write',76),('game-world-write',76),('sdk-special',76),('partial',64),('bad-digest',64),('non-steam',64)]:
        p,s,w,d,lock,installation=prepare(binding=name);assert p.wait(timeout=4)==code,(name,p.returncode,p.stderr.read());assert not(d/'leader.json').exists()and not locked(lock);finish(p,s,w,d);checks['binding-'+name+'-rejected-before-ACK-or-game']=True
    start=time.monotonic();p,s,w,d,lock,installation=prepare(eof=False);assert p.wait(timeout=4)==65;assert 2.8<time.monotonic()-start<4;finish(p,s,w,d);checks['WholeBootstrapBudgetRequiresEOF']=True
    # Compose the actual new C host (test-only fake image), health pipe and keeper.
    source={'username':'synthetic_account','refresh_token':'synthetic_not_real','steamID':'76561197960265729','appID':480};packet=pack_credentials(source)
    def compose(mode='normal'):
        nonlocal counter
        counter+=1;d=run/f'composed-{counter}';d.mkdir(mode=0o700);ep=d/'events';ef=os.open(ep,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);lr,lw=os.pipe();hr,hw=os.pipe()
        henv=dict(env,READY_STEAM_IPC_NAMESPACE='1'*32,steam_master_ipc_name_override='127.0.0.1:30101',SteamClientService='127.0.0.1:30102',READY_FIXTURE_MODE=mode,READY_FIXTURE_LOG=str(d/'fake.log'))
        args=[str(host),'--host-session','--library',str(fake),'--lifeline-fd',str(lr),'--events-fd',str(ef),'--mode','credentials','--discovery-library',str(fake),'--discovery-service','app.ready.steam.ipctool.'+'1'*32,'--sdk',str(fake),'--game-health-fd',str(hw)]
        h=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(lr,ef,hw),env=henv);os.close(lr);os.close(hw);os.close(ef);h.stdin.write(packet);h.stdin.close();await_type(ep,'ready')
        installation=d/'installation';installation.mkdir();lock=d/'prefix.lock';f=lock.open('a+b');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);a,b=socket.socketpair();a.settimeout(4)
        k=subprocess.Popen([str(keeper),'--steam-bootstrap','--installation',str(installation),'--installation-lock-root',str(install_lock.LOCK_ROOT),'--',str(game),str(d),'0','1'],stdin=b,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,env=env);b.close();a.sendmsg([b'RDYSLF1\0'],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',[f.fileno(),hr]))]);a.shutdown(socket.SHUT_WR);f.close();os.close(hr);ack(a);wait(lambda:(d/'beat').exists());return h,k,lw,a,d,lock,installation,ep
    h,k,lw,s,d,lock,installation,ep=compose('logged-off')
    assert k.wait(timeout=4)==75;assert h.wait(timeout=4)==43;os.close(lw);s.close();assert not locked(lock)and not busy(installation);assert await_type(ep,'stopped')['pipeReleased'];checks['GenuineHostLifecycleCodeRevokesFakeGameBeforeVendorCleanup']=True
    # Kill the actual worker: kernel closes its sole health writer immediately.
    h,k,lw,s,d,lock,installation,ep=compose();h.kill();h.wait(timeout=2);assert k.wait(timeout=4)==75;os.close(lw);s.close();assert not locked(lock);checks['HostSIGKILLStopsGameAndKeepsLeaseUntilDead']=True
    # This own coordinator is the sole lifeline writer. Its death closes the host,
    # whose health EOF then stops the keeper; no Swift callback is involved.
    h,k,lw,s,d,lock,installation,ep=compose();os.close(lw);assert h.wait(timeout=3)==42;assert k.wait(timeout=4)==75;s.close();assert not locked(lock)and not busy(installation);checks['UIOwnerEOFStopsHostThenGameWithoutUICallback']=True
    crash_record=run/'crash-owner.json'
    owner=os.fork()
    if owner==0:
        try:
            h,k,lw,s,d,lock,installation,ep=compose()
            crash_record.write_text(json.dumps({'directory':str(d),'lock':str(lock),'installation':str(installation),'events':str(ep)}))
            time.sleep(100)
        finally:os._exit(90)
    meta=wait(lambda:json.loads(crash_record.read_text()));os.kill(owner,signal.SIGKILL);os.waitpid(owner,0)
    ended=await_type(Path(meta['events']),'stopped',4);assert ended['reason']==42 and ended['pipeReleased']
    wait(lambda:not locked(Path(meta['lock'])));assert not busy(Path(meta['installation']));checks['UIParentSIGKILLStopsHostAndGameWithoutSwift']=True
    # Legacy native and Wine contracts remain unchanged on the same new binary.
    for command,expected,name in [(['/usr/bin/true'],0,'legacyQuickChild'),(['/usr/bin/false'],1,'legacyFailedChild'),(['/ready-own-nonexistent-fixture'],127,'legacyMissingExecutable')]:
        lock=run/(name+'.lock');f=lock.open('a+b');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        legacy=subprocess.Popen([str(keeper),'--',*command],stdin=f,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,env=env);f.close();assert legacy.wait(timeout=3)==expected and not locked(lock);checks[name]=True
    server_source=run/'server.c';server_source.write_text('#include <unistd.h>\n#include <stdlib.h>\n#include <stdio.h>\nint main(void){const char*p=getenv("READY_FIXTURE_SERVER_FINISH"),*b=getenv("READY_FIXTURE_SERVER_STARTED");FILE*f=fopen(b,"w");if(!f)return 71;fputs("started",f);fclose(f);while(access(p,F_OK))usleep(50000);return 0;}\n')
    server=run/'wineserver';subprocess.run(['/usr/bin/clang',str(server_source),'-o',str(server)],env=env,capture_output=True,check=True)
    lock=run/'legacy-wine.lock';f=lock.open('a+b');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);prefix=run/'wine-prefix';prefix.mkdir();server_end=run/'server-finish';server_started=run/'server-started'
    legacy=subprocess.Popen([str(keeper),'--wine-server',str(server),'--prefix',str(prefix),'--','/usr/bin/true'],stdin=f,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,env=dict(env,READY_FIXTURE_SERVER_FINISH=str(server_end),READY_FIXTURE_SERVER_STARTED=str(server_started)));f.close();wait(lambda:server_started.exists());legacy.terminate();time.sleep(.15);assert legacy.poll()is None and locked(lock);server_end.touch();assert legacy.wait(timeout=3)==0 and not locked(lock);checks['LegacyWineWaitAndSignalRetainPrefixLease']=True
    source_files=['SessionHost/ReadySessionHost.c' ,'SessionHost/SteamSessionLease.h','SessionHost/InstallationLease.c','SessionHost/InstallationLease.h','Scripts/steam_native_host_session.c','Scripts/steam_native_host_session.h','Scripts/steam_native_host_probe.c','Scripts/test_steam_session_lease.py']
    report={'schema':1,'kind':'steam-native-session-descriptor-and-lifetime-fixtures','passed':all(checks.values()),'count':len(checks),'checks':checks,'fixtureOnly':True,'ValveOrGameSDKExecuted':False,'realAccountUsed':False,'keeper':str(keeper),'keeperSHA256':sha(keeper),'fixtureHostSHA256':sha(host),'sourceHashes':{f:sha(ROOT/f)for f in source_files}}
    p=run/'report.json';p.write_text(json.dumps(report,indent=2)+'\n');p.chmod(0o600);print(json.dumps({'passed':True,'count':len(checks),'report':str(p),'reportSHA256':sha(p),'keeper':str(keeper),'keeperSHA256':sha(keeper)}))
if __name__=='__main__':main()
