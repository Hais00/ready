#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real process/descriptor tests. Uses only private temporary lock files and owned child PIDs."""
import argparse, fcntl, hashlib, json, os, pathlib, shutil, signal, stat, subprocess, sys, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
HOST=ROOT/'Build/ReadySessionHost'
NATIVE_WRAPPER_SOURCE = r'''// SPDX-License-Identifier: GPL-3.0-only
#include <sys/types.h>
#include <sys/proc.h>
#include <libproc.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv) {
    if(argc==3 && !strcmp(argv[1],"--inspect")){
        struct proc_bsdinfo info={0};
        if(proc_pidinfo(atoi(argv[2]),PROC_PIDTBSDINFO,1,&info,sizeof(info))!=(int)sizeof(info)){
            puts("{\"available\":false}");return 0;
        }
        printf("{\"available\":true,\"pid\":%u,\"group\":%u,\"status\":%u}\n",info.pbi_pid,info.pbi_pgid,info.pbi_status);return 0;
    }
    if(argc!=3)return 64;
    char info[4096],beat[4096],temp[4096],finish[4096];
    snprintf(info,sizeof(info),"%s/wrapper.json",argv[1]);
    snprintf(beat,sizeof(beat),"%s/heartbeat.json",argv[1]);
    snprintf(temp,sizeof(temp),"%s/heartbeat.tmp",argv[1]);
    snprintf(finish,sizeof(finish),"%s/finish",argv[1]);
    pid_t child=fork();if(child<0)return 71;
    if(child>0){
        FILE *file=fopen(info,"w");if(!file)return 71;
        fprintf(file,"{\"leader\":%d,\"child\":%d,\"group\":%d}\n",getpid(),child,getpgrp());fclose(file);
        _exit(atoi(argv[2]));
    }
    // Self-limited owned fixture, even if its test coordinator dies.
    for(unsigned tick=1;tick<=600 && access(finish,F_OK)!=0;tick++){
        FILE *file=fopen(temp,"w");if(!file)_exit(71);
        fprintf(file,"{\"pid\":%d,\"group\":%d,\"tick\":%u}\n",getpid(),getpgrp(),tick);fclose(file);
        if(rename(temp,beat)!=0)_exit(71);
        usleep(50000);
    }
    _exit(0);
}
'''
def wait_for(predicate,timeout=8):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            result=predicate()
            if result:return result
        except (FileNotFoundError,json.JSONDecodeError,ProcessLookupError):pass
        time.sleep(.025)
    raise AssertionError('Timed out waiting for a specific test process/state')
def locked(path):
    with path.open('a+b') as handle:
        try:fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return True
        fcntl.flock(handle,fcntl.LOCK_UN);return False
def spawn(lock,program,args=(),server=None,prefix=None,environment=None,installation=None,installation_root=None):
    handle=lock.open('a+b');os.fchmod(handle.fileno(),0o600);fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
    command=[str(HOST)]
    if server:command+=['--wine-server',str(server)]
    if prefix:command+=['--prefix',str(prefix)]
    if installation:command+=['--installation',str(installation)]
    if installation_root:command+=['--installation-lock-root',str(installation_root)]
    command+=['--',str(program),*map(str,args)]
    process=subprocess.Popen(command,stdin=handle,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True,env=environment)
    # CLOSE, not LOCK_UN. The child's fd0 shares this exact open-file-description.
    handle.close();return process
def stop(process):
    if process.poll() is None:process.terminate()
    try:process.wait(timeout=8)
    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--headless',action='store_true',help='Skip the optional existing Metal UI probe')
    options=parser.parse_args()
    subprocess.run(['sh',str(ROOT/'Scripts/build_session_host.sh')],check=True)
    results={}
    with tempfile.TemporaryDirectory(prefix='ready-session-host-tests-') as temp:
        d=pathlib.Path(temp).resolve();worker=d/'worker.py'
        worker.write_text("""import json,os,pathlib,stat,sys,time
extra=[]
for fd in range(3,128):
 try:os.fstat(fd);extra.append(fd)
 except OSError:pass
p=pathlib.Path(sys.argv[1]);p.write_text(json.dumps({'pid':os.getpid(),'group':os.getpgrp(),'stdinNull':stat.S_ISCHR(os.fstat(0).st_mode),'extraDescriptors':extra,'arguments':sys.argv[2:],'prefix':os.environ.get('WINEPREFIX')}))
while True:time.sleep(.03)
""")
        a_lock=d/'a.lock';b_lock=d/'b.lock';a_info=d/'a.json';b_info=d/'b.json'
        a=spawn(a_lock,sys.executable,[worker,a_info,'literal;$(do-not-execute)']);b=spawn(b_lock,sys.executable,[worker,b_info])
        try:
            ai=wait_for(lambda:json.loads(a_info.read_text()));bi=wait_for(lambda:json.loads(b_info.read_text()))
            assert locked(a_lock) and locked(b_lock)
            assert ai['stdinNull'] and bi['stdinNull'] and not ai['extraDescriptors'] and not bi['extraDescriptors'];assert ai['group']==ai['pid'] and bi['group']==bi['pid'] and ai['group']!=bi['group']
            assert ai['arguments']==['literal;$(do-not-execute)']
            # Another independent open description cannot start a second session on this prefix.
            with a_lock.open('rb') as rejected_input:
                rejected=subprocess.run([str(HOST),'--','/usr/bin/true'],stdin=rejected_input,capture_output=True,text=True,timeout=5)
            assert rejected.returncode==73
            a.send_signal(signal.SIGTERM);assert a.wait(timeout=8)==143
            wait_for(lambda:not locked(a_lock));assert b.poll() is None and locked(b_lock)
            b.send_signal(signal.SIGINT);assert b.wait(timeout=8)==130;wait_for(lambda:not locked(b_lock))
            results['independentSessionsAndSignalGroups']=True;results['childStdinIsDevNull']=True;results['noLockDescriptorInGame']=True;results['literalArguments']=True;results['duplicatePrefixRejected']=True
        finally:stop(a);stop(b)
        # Simulate the launcher dying abruptly after handoff. The host becomes an orphan.
        crash_lock=d/'crash.lock';crash_info=d/'crash-worker.json';host_info=d/'orphan-host.json'
        shim=d/'parent.py';shim.write_text("""import fcntl,json,os,pathlib,subprocess,sys
lock,host,worker,info,pidfile=sys.argv[1:]
fd=open(lock,'a+b');os.fchmod(fd.fileno(),0o600);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
p=subprocess.Popen([host,'--',sys.executable,worker,info],stdin=fd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
pathlib.Path(pidfile).write_text(json.dumps({'hostPID':p.pid}))
os._exit(19)
""")
        parent=subprocess.run([sys.executable,str(shim),str(crash_lock),str(HOST),str(worker),str(crash_info),str(host_info)],capture_output=True,text=True,timeout=8)
        assert parent.returncode==19
        orphan=wait_for(lambda:json.loads(host_info.read_text()))['hostPID']
        try:
            wait_for(lambda:crash_info.exists());assert locked(crash_lock);os.kill(orphan,0)
            os.kill(orphan,signal.SIGHUP);time.sleep(.1);assert locked(crash_lock)
            os.kill(orphan,signal.SIGTERM);wait_for(lambda:not locked(crash_lock))
            results['parentCrashKeepsLease']=True;results['parentHangupDoesNotEndGame']=True
        finally:
            try:os.kill(orphan,signal.SIGTERM)
            except ProcessLookupError:pass
            wait_for(lambda:not locked(crash_lock))
        # A finished bootstrap is insufficient: keep the lock until exact-prefix wineserver -w returns.
        server=d/'fake-wineserver';server.write_text('#!'+sys.executable+'\n'+"""import json,os,pathlib,sys,time
p=pathlib.Path(os.environ['WINEPREFIX']);(p/'waiter.json').write_text(json.dumps({'args':sys.argv[1:],'prefix':str(p),'injected':'DYLD_INSERT_LIBRARIES' in os.environ}))
while not (p/'finished').exists():time.sleep(.02)
""");server.chmod(0o700)
        prefix=d/'dedicated-prefix';prefix.mkdir();server_lock=d/'server.lock';keeper=spawn(server_lock,'/usr/bin/true',server=server,prefix=prefix)
        try:
            waiter=wait_for(lambda:json.loads((prefix/'waiter.json').read_text()));assert waiter['args']==['-w'] and waiter['prefix']==str(prefix) and not waiter['injected']
            assert keeper.poll() is None and locked(server_lock)
            keeper.send_signal(signal.SIGTERM);time.sleep(.1);assert keeper.poll() is None and locked(server_lock)
            (prefix/'finished').touch();assert keeper.wait(timeout=8)==0;wait_for(lambda:not locked(server_lock))
            results['exactPrefixWineserverWait']=True;results['waiterCannotReleaseLeaseEarlyOnSignal']=True
        finally:(prefix/'finished').touch();stop(keeper)
        # Quick success, unexpected child failure, spawn failure, and invalid handoff all release cleanly.
        for title,program,args,expected in [('quickChild','/usr/bin/true',[],0),('failedChild',sys.executable,['-c','raise SystemExit(23)'],23),('missingChild','/nonexistent/ready-test-command',[],127)]:
            lock=d/(title+'.lock');p=spawn(lock,program,args);assert p.wait(timeout=8)==expected;wait_for(lambda:not locked(lock));results[title]=True
        bad=subprocess.run([str(HOST),'--','/usr/bin/true'],stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=5);assert bad.returncode==64;results['invalidStdinRejected']=True
        native_probe=ROOT/'Build/ReadyMetalProbe';overlay=ROOT/'Build/libReadyOverlay.dylib'
        if not options.headless and native_probe.is_file() and overlay.is_file():
            session=d/'native-overlay';session.mkdir(mode=0o700);control=session/'control.json';control.write_text(json.dumps({'sequence':1,'visible':False,'selection':0}));control.chmod(0o600)
            env={k:v for k,v in os.environ.items() if k!='DYLD_INSERT_LIBRARIES'}
            env.update(READY_OVERLAY_LIBRARY=str(overlay),M1L_CONTROL_FILE=str(control),M1L_OVERLAY_STATUS=str(session/'status.json'))
            native_lock=d/'native-overlay.lock';native=spawn(native_lock,native_probe,['--frames','8','--output',session],environment=env)
            try:
                assert native.wait(timeout=30)==0,native.stderr.read()
                probe=json.loads((session/'overlay-metal3.json').read_text());status=json.loads((session/'status.json').read_text())
                assert probe['passed'] and status['frameCount']>0 and status['pid']!=native.pid and not locked(native_lock)
                results['nativeMetalOverlayHandoff']=True
            finally:stop(native)
        # Publish a genuinely rebuilt helper while its previous inode holds a live
        # child and prefix lease. Existing mappings/descriptors must remain intact.
        rebuild_lock=d/'rebuild.lock';rebuild_info=d/'rebuild-worker.json'
        rebuild=spawn(rebuild_lock,sys.executable,[worker,rebuild_info])
        try:
            info=wait_for(lambda:json.loads(rebuild_info.read_text()))
            with HOST.open('rb') as original:
                old_inode=os.fstat(original.fileno()).st_ino
                old_hash=hashlib.file_digest(original,'sha256').hexdigest()
                subprocess.run(['sh',str(ROOT/'Scripts/build_session_host.sh')],check=True)
                assert HOST.stat().st_ino!=old_inode
                original.seek(0);assert hashlib.file_digest(original,'sha256').hexdigest()==old_hash
            os.kill(info['pid'],0)
            assert rebuild.poll() is None and locked(rebuild_lock)
            rebuild.terminate();assert rebuild.wait(timeout=8)==143
            wait_for(lambda:not locked(rebuild_lock))
            results['atomicKeeperRebuildPreservesLiveSession']=True
        finally:stop(rebuild)
        # Native readers interoperate with the ACTUAL StoreBridge writer implementation.
        sys.path.insert(0,str(ROOT/'StoreBridge'))
        import install_lock
        from bridge import BridgeError
        install_lock.LOCK_ROOT=d/'installation-locks'
        game=install_lock.canonical_installation(str(d/'Games/one'))
        nested=install_lock.canonical_installation(str(game/'DLC'))
        sibling=install_lock.canonical_installation(str(d/'Games/two'))
        def writer_busy(path):
            try:
                with install_lock.installation_lease(path):pass
            except BridgeError as error:
                assert error.code=='installation_busy';return True
            return False
        # Real native .app wrapper: its leader exits immediately while a forked
        # game keeps running in that same group. Neither lease may follow only
        # the wrapper PID, and signals must still address the pinned group.
        wrapper_source=d/'native-wrapper.c';wrapper_source.write_text(NATIVE_WRAPPER_SOURCE)
        app_a=d/'NativeWrapperA.app';app_b=d/'NativeWrapperB.app'
        executable_a=app_a/'Contents/MacOS/Wrapper';executable_b=app_b/'Contents/MacOS/Wrapper'
        executable_a.parent.mkdir(parents=True);executable_b.parent.mkdir(parents=True)
        subprocess.run(['xcrun','clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-O2','-arch','arm64','-mmacosx-version-min=14.0',str(wrapper_source),'-o',str(executable_a)],check=True)
        shutil.copy2(executable_a,executable_b)
        def inspect(pid):
            return json.loads(subprocess.check_output([str(executable_a),'--inspect',str(pid)],text=True,timeout=5))
        def native_state(directory):
            info=json.loads((directory/'wrapper.json').read_text())
            beat=json.loads((directory/'heartbeat.json').read_text())
            leader=inspect(info['leader'])
            if not leader['available'] or leader['status']!=5 or beat['tick']<2:return False
            assert info['group']==info['leader']==beat['group']==leader['group']
            assert beat['pid']==info['child']
            return info,beat
        native_a=d/'native-session-A';native_b=d/'native-session-B'
        native_a.mkdir(mode=0o700);native_b.mkdir(mode=0o700)
        native_a_lock=d/'native-A.lock';native_b_lock=d/'native-B.lock'
        wrapped_a=spawn(native_a_lock,executable_a,[native_a,0],installation=app_a,installation_root=install_lock.LOCK_ROOT)
        wrapped_b=spawn(native_b_lock,executable_b,[native_b,23],installation=app_b,installation_root=install_lock.LOCK_ROOT)
        try:
            ai,ab=wait_for(lambda:native_state(native_a));bi,bb=wait_for(lambda:native_state(native_b))
            assert wrapped_a.poll() is None and wrapped_b.poll() is None
            assert locked(native_a_lock) and locked(native_b_lock)
            assert writer_busy(app_a) and writer_busy(app_b)
            time.sleep(.15)
            assert json.loads((native_a/'heartbeat.json').read_text())['tick']>ab['tick']
            assert inspect(ai['leader'])['status']==5
            results['nativeWrapperLeaderZombiePinsGroupIdentity']=True
            results['nativeWrapperDescendantsRetainPrefixAndInstallationLeases']=True
            wrapped_a.send_signal(signal.SIGTERM)
            assert wrapped_a.wait(timeout=8)==0
            wait_for(lambda:not locked(native_a_lock))
            with install_lock.installation_lease(app_a):pass
            child=inspect(ai['child']);assert not child['available'] or child['status']==5
            final=(native_a/'heartbeat.json').read_bytes();time.sleep(.1)
            assert (native_a/'heartbeat.json').read_bytes()==final
            assert wrapped_b.poll() is None and locked(native_b_lock) and writer_busy(app_b)
            assert json.loads((native_b/'heartbeat.json').read_text())['tick']>bb['tick']
            results['nativeWrapperSignalAfterLeaderExitIsIsolated']=True
            (native_b/'finish').touch()
            assert wrapped_b.wait(timeout=8)==23
            wait_for(lambda:not locked(native_b_lock))
            with install_lock.installation_lease(app_b):pass
            results['nativeWrapperNaturalCompletionPreservesLeaderStatus']=True
        finally:
            (native_a/'finish').touch();(native_b/'finish').touch();stop(wrapped_a);stop(wrapped_b)
        # A launcher crash must not release either lease of that background child.
        native_crash=d/'native-crash';native_crash.mkdir(mode=0o700)
        native_crash_lock=d/'native-crash.lock';native_crash_pid=d/'native-crash-host.json'
        native_shim=d/'native-parent.py'
        native_shim.write_text("import fcntl,json,os,pathlib,signal,subprocess,sys\n"
            "lock,host,installation,lockroot,program,session,pidfile=sys.argv[1:]\n"
            "signal.signal(signal.SIGCHLD,signal.SIG_IGN)\n"
            "fd=open(lock,'a+b');os.fchmod(fd.fileno(),0o600);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
            "p=subprocess.Popen([host,'--installation',installation,'--installation-lock-root',lockroot,'--',program,session,'0'],stdin=fd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
            "pathlib.Path(pidfile).write_text(json.dumps({'hostPID':p.pid}));os._exit(19)\n")
        crashed=subprocess.run([sys.executable,str(native_shim),str(native_crash_lock),str(HOST),str(app_a),str(install_lock.LOCK_ROOT),str(executable_a),str(native_crash),str(native_crash_pid)],capture_output=True,text=True,timeout=8)
        assert crashed.returncode==19
        native_keeper=wait_for(lambda:json.loads(native_crash_pid.read_text()))['hostPID']
        try:
            info,beat=wait_for(lambda:native_state(native_crash))
            assert locked(native_crash_lock) and writer_busy(app_a)
            os.kill(native_keeper,signal.SIGHUP);time.sleep(.15)
            assert inspect(info['leader'])['status']==5 and locked(native_crash_lock) and writer_busy(app_a)
            assert json.loads((native_crash/'heartbeat.json').read_text())['tick']>beat['tick']
            os.kill(native_keeper,signal.SIGTERM)
            wait_for(lambda:not locked(native_crash_lock))
            with install_lock.installation_lease(app_a):pass
            child=inspect(info['child']);assert not child['available'] or child['status']==5
            results['nativeWrapperLauncherCrashAndHangupRetainBothLeases']=True
            results['nativeWrapperInheritedIgnoredSIGCHLDResetsWaitability']=True
        finally:
            (native_crash/'finish').touch()
            try:os.kill(native_keeper,signal.SIGTERM)
            except ProcessLookupError:pass
            wait_for(lambda:not locked(native_crash_lock))
        read_info=d/'installation-reader.json';read_lock=d/'installation-prefix.lock'
        reader=spawn(read_lock,sys.executable,[worker,read_info],installation=game,installation_root=install_lock.LOCK_ROOT)
        try:
            read=wait_for(lambda:json.loads(read_info.read_text()));assert not read['extraDescriptors']
            assert writer_busy(game) and writer_busy(nested) and writer_busy(game.parent)
            with install_lock.installation_lease(game,mode='read'):pass
            with install_lock.installation_lease(sibling):pass
            results['nativeReaderBlocksSameNestedAndParentPythonWriters']=True
            results['nativeReaderAllowsPythonReaderAndSiblingWriter']=True
            # A second real keeper may read the same game under a different prefix.
            other_info=d/'installation-other.json'
            other=spawn(d/'installation-other-prefix.lock',sys.executable,[worker,other_info],installation=game,installation_root=install_lock.LOCK_ROOT)
            try:wait_for(lambda:other_info.exists());assert other.poll() is None
            finally:stop(other)
            results['twoNativeReadersShareInstallation']=True
        finally:stop(reader)
        with install_lock.installation_lease(game):
            child_marker=d/'unexpected-installation-child'
            denied=spawn(d/'installation-denied.lock','/usr/bin/touch',[child_marker],installation=game,installation_root=install_lock.LOCK_ROOT)
            assert denied.wait(timeout=8)==73 and not child_marker.exists()
            assert not locked(d/'installation-denied.lock')
        results['pythonWriterPreventsNativeChildSpawn']=True
        # Installation read locks must survive the launcher just like the prefix lock.
        crash_install_info=d/'crash-install.json';crash_install_host=d/'crash-install-host.json';crash_install_lock=d/'crash-install.lock'
        install_shim=d/'install-parent.py'
        install_shim.write_text("import fcntl,json,os,pathlib,subprocess,sys\n"
            "lock,host,installation,lockroot,worker,info,pidfile=sys.argv[1:]\n"
            "fd=open(lock,'a+b');os.fchmod(fd.fileno(),0o600);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
            "p=subprocess.Popen([host,'--installation',installation,'--installation-lock-root',lockroot,'--',sys.executable,worker,info],stdin=fd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
            "pathlib.Path(pidfile).write_text(json.dumps({'hostPID':p.pid}));os._exit(19)\n")
        crashed=subprocess.run([sys.executable,str(install_shim),str(crash_install_lock),str(HOST),str(game),str(install_lock.LOCK_ROOT),str(worker),str(crash_install_info),str(crash_install_host)],capture_output=True,text=True,timeout=8)
        assert crashed.returncode==19
        keeper_pid=wait_for(lambda:json.loads(crash_install_host.read_text()))['hostPID']
        try:
            wait_for(lambda:crash_install_info.exists());assert writer_busy(game) and writer_busy(nested)
            os.kill(keeper_pid,signal.SIGTERM);wait_for(lambda:not locked(crash_install_lock))
            with install_lock.installation_lease(game):pass
            results['installationReadSurvivesLauncherCrash']=True
        finally:
            try:os.kill(keeper_pid,signal.SIGTERM)
            except ProcessLookupError:pass
        # The reader must also cover an actual Wine wait stage after its main child ends.
        (prefix/'finished').unlink();(prefix/'waiter.json').unlink()
        installation_wait=spawn(d/'installation-wait.lock','/usr/bin/true',server=server,prefix=prefix,installation=game,installation_root=install_lock.LOCK_ROOT)
        try:
            wait_for(lambda:(prefix/'waiter.json').exists());assert writer_busy(game)
            (prefix/'finished').touch();assert installation_wait.wait(timeout=8)==0
            with install_lock.installation_lease(game):pass
            results['installationReadCoversExactServerWait']=True
        finally:(prefix/'finished').touch();stop(installation_wait)
        bad_install=spawn(d/'invalid-installation.lock','/usr/bin/true',installation=d/'no-such-game',installation_root=install_lock.LOCK_ROOT)
        assert bad_install.wait(timeout=8)==64
        unsafe_root=d/'unsafe-install-lock-root';unsafe_root.symlink_to(install_lock.LOCK_ROOT,target_is_directory=True)
        unsafe=spawn(d/'unsafe-installation.lock','/usr/bin/true',installation=game,installation_root=unsafe_root)
        assert unsafe.wait(timeout=8)==71
        results['invalidInstallationAndUnsafeLockRootRejected']=True
        report={'passed':all(results.values()),'checks':results,'platform':sys.platform,'hostArchitecture':'arm64','testType':'real-process-flock-handoff-and-signals','noGlobalProcessTermination':True,'skippedChecks':[] if 'nativeMetalOverlayHandoff' in results else ['nativeMetalOverlayHandoff']}
        (ROOT/'Evidence/session-host-tests.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
