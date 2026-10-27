#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real process/descriptor tests. Uses only private temporary lock files and owned child PIDs."""
import fcntl, json, os, pathlib, signal, stat, subprocess, sys, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
HOST=ROOT/'Build/ReadySessionHost'
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
def spawn(lock,program,args=(),server=None,prefix=None,environment=None):
    handle=lock.open('a+b');os.fchmod(handle.fileno(),0o600);fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
    command=[str(HOST)]
    if server:command+=['--wine-server',str(server)]
    if prefix:command+=['--prefix',str(prefix)]
    command+=['--',str(program),*map(str,args)]
    process=subprocess.Popen(command,stdin=handle,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True,env=environment)
    # CLOSE, not LOCK_UN. The child's fd0 shares this exact open-file-description.
    handle.close();return process
def stop(process):
    if process.poll() is None:process.terminate()
    try:process.wait(timeout=8)
    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
def main():
    subprocess.run(['sh',str(ROOT/'Scripts/build_session_host.sh')],check=True)
    results={}
    with tempfile.TemporaryDirectory(prefix='ready-session-host-tests-') as temp:
        d=pathlib.Path(temp);worker=d/'worker.py'
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
        if native_probe.is_file() and overlay.is_file():
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
        report={'passed':all(results.values()),'checks':results,'platform':sys.platform,'hostArchitecture':'arm64','testType':'real-process-flock-handoff-and-signals','noGlobalProcessTermination':True}
        (ROOT/'Evidence/session-host-tests.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
