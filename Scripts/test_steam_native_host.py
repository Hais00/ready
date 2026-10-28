#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline native Steam loader/factory experiment with fail-closed sandboxing.

Original Steam/account data cannot be read or written. Internet, account/config reads,
mach lookups except the OS dyld loader and extra process execution are denied. This does not
authenticate, start Steam.app or claim that an existing Steam session is usable.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import socket
import stat
import sys
import threading
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')

def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def save(path,value):
    data=(json.dumps(value,indent=2)+'\n').encode()
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb')as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())

def processes():
    # Names/PIDs/start times only; no Steam helper arguments or account values.
    raw=subprocess.check_output(['/bin/ps','-axo','pid=,lstart=,comm='],text=True)
    return [line.strip()for line in raw.splitlines()if any(name in line for name in ['steam_osx','Steam Helper','steamwebhelper','steamcmd','steamhost'])]

class LiveStatus:
    """Non-secret status for the diagnostic card inside a fresh Ready window."""
    def __init__(self,run):
        self.run=run;self.path=run/'live-auth.json';self.generation=str(uuid.uuid4());self.sequence=-1
    def write(self,phase,message=None,image=None):
        self.sequence+=1
        value={'schema':1,'generation':self.generation,'sequence':self.sequence,'phase':phase}
        if message:value['message']=message
        if image:value['image']=image
        temporary=self.run/('.live-'+uuid.uuid4().hex+'.json')
        save(temporary,value);os.replace(temporary,self.path)
    def watch_cancel(self,event,stop,frontend):
        while not stop.wait(.1):
            if frontend.poll()is not None:event.set();return
            path=self.run/'cancel.request'
            try:
                if path.is_symlink()or path.stat().st_uid!=os.getuid()or path.stat().st_size>1024:continue
                value=json.loads(path.read_text())
                if value=={'schema':1,'generation':self.generation,'action':'cancel'}:
                    event.set();return
            except (FileNotFoundError,ValueError,OSError):pass

def wait_for_pinned_helper_retry(session,live,run):
    """Operator-owned retry control contains paths/hashes only, never tokens.

    Rebinding is explicit while the one approved QR session stays in RAM. A
    failed/malformed control never selects a helper or repeats authentication.
    """
    control=run/'retry-helper.json'
    while not session.closed:
        try:
            fd=os.open(control,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)
        except FileNotFoundError:time.sleep(.1);continue
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode)or info.st_uid!=os.getuid()or info.st_mode&0o077 or info.st_size>4096:raise ValueError('Invalid private retry control')
            stream=os.fdopen(fd,'rb');fd=-1
            with stream:value=json.load(stream)
            if set(value)!={'schema','generation','bridgeDLL','bridgeSHA256','dotnetHost'}or value['schema']!=1 or value['generation']!=live.generation:raise ValueError('Wrong retry generation')
            dll=Path(value['bridgeDLL']).resolve(strict=True);host=Path(value['dotnetHost']).resolve(strict=True)
            if dll.name!='ReadySteamBridge.dll'or host.name!='dotnet'or not all(x.is_relative_to(WORK/'build')and x.stat().st_uid==os.getuid()for x in [dll,host]):raise ValueError('Owned source-built helper required')
            if sha(dll)!=value['bridgeSHA256']:raise ValueError('Retry helper hash mismatch')
            os.replace(control,run/('retry-helper-used-'+uuid.uuid4().hex+'.json'))
            return [str(host),str(dll)]
        except (ValueError,TypeError,OSError):
            if control.exists()and not control.is_symlink():os.replace(control,run/('retry-helper-rejected-'+uuid.uuid4().hex+'.json'))
            print(json.dumps({'type':'retry_control_rejected','secretFree':True}),flush=True)
            time.sleep(.1)
        finally:
            if fd>=0:os.close(fd)
    return None

def hold_authorized_followups(session,live,controller_run,helper_command,app_id,steam_id,library,base_env):
    """Keep the approved session available for explicit, pinned owned probes.

    A control contains a preparation path/hash, never credentials. Each attempt
    obtains a fresh genuine entitlement result and one private handoff. Closing
    the card or the ten-minute session deadline stops this controller.
    """
    class SessionCancel:
        def is_set(self):return session.closed
    request_path=controller_run/'run-authorized-probe.json'
    print(json.dumps({'type':'authorized_session_held','control':str(request_path),'generation':live.generation,'brokerCredentialsOnDisk':False}),flush=True)
    while not session.closed:
        if not request_path.exists():time.sleep(.1);continue
        fd=os.open(request_path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode)or info.st_uid!=os.getuid()or info.st_mode&0o077 or info.st_size>4096:raise ValueError('Invalid private probe control')
            stream=os.fdopen(fd,'rb');fd=-1
            with stream:req=json.load(stream)
            if set(req)!={'schema','generation','operation','preparation','preparationSHA256'}or req['schema']!=1 or req['generation']!=live.generation or req['operation']not in ('native','windows'):raise ValueError('Wrong probe generation or operation')
            preparation=Path(req['preparation']).resolve(strict=True)
            if not preparation.is_relative_to(WORK/'retained')or preparation.stat().st_uid!=os.getuid()or sha(preparation)!=req['preparationSHA256']:raise ValueError('Preparation identity mismatch')
            os.replace(request_path,controller_run/('used-probe-control-'+uuid.uuid4().hex+'.json'))
            context=session.authorize_game(helper_command,app_id,expectedSteamID=steam_id)
            try:
                if req['operation']=='windows':
                    import steam_windows_authenticated_host as windows
                    live.write('starting_native','Verifica del backend Windows sotto Wine…')
                    result=windows.run_with_authorized_context(preparation,context,cancel=SessionCancel())
                    print(json.dumps({'type':'authorized_windows_probe_finished','result':result}),flush=True)
                    live.write('completed','Prova del backend Windows conclusa; verifica dei risultati in corso.')
                    continue
                data=json.loads(preparation.read_text());trial=preparation.parent
                worker=trial/'ready-steam-native-probe';sandbox=trial/'offline.sb'
                if preparation.name!='auth-preparation.json'or not data.get('sandboxControlsPassed')or not data.get('publicNetworkSmokePassed')or data.get('librarySHA256')!=sha(library)or sha(worker)!=data.get('executableSHA256')or sha(sandbox)!=data.get('sandboxSHA256'):raise ValueError('Native preparation did not pass its controls')
                policy=sandbox.read_text();ports=list(dict.fromkeys(__import__('re').findall(r'localhost:(\d+)',policy)))
                namespace_prefix=__import__('re').search(r'\^/RS([a-f0-9]{16})_',policy)
                if len(ports)!=2 or not namespace_prefix:raise ValueError('Invalid native IPC preparation')
                # Adapter paths are exact literal file-read exceptions. Match
                # their hashes against the preparation receipt before loading.
                fs=None;ipc=None
                for literal in __import__('re').findall(r'\(literal "([^"]+\.dylib)"\)',policy):
                    path=Path(literal)
                    if sha(path)==data['stateShimSHA256']:fs=path
                    if sha(path)==data['ipcShimSHA256']:ipc=path
                if fs is None or ipc is None:raise ValueError('Prepared state adapters unavailable')
                event=trial/'followup-events.jsonl';event.touch(mode=0o600,exist_ok=False)
                env=dict(base_env,TMPDIR=str(trial/'tmp')+'/',XDG_CACHE_HOME=str(trial/'state'),READY_STEAM_STATE_FS_LIBRARY=str(fs),READY_STEAM_IPC_LIBRARY=str(ipc),READY_STEAM_IPC_NAMESPACE=namespace_prefix[1]+uuid.uuid4().hex[16:],READY_STEAM_PRIVATE_STATE_ROOT=str(trial/'state/client'),READY_STEAM_EVENT_FILE=str(event),steam_master_ipc_name_override='127.0.0.1:'+ports[0],SteamClientService='127.0.0.1:'+ports[1])
                command=['/usr/bin/sandbox-exec','-f',str(sandbox),str(worker),str(library),'CLIENTENGINE_INTERFACE_VERSION005','--create-user','--authenticate']
                live.write('starting_native','Nuova verifica del backend nativo con l’accesso già approvato…')
                with(trial/'followup-stdout.log').open('w')as out,(trial/'followup-stderr.log').open('w')as err:
                    child=subprocess.Popen(command,cwd=trial,env=env,stdin=subprocess.PIPE,stdout=out,stderr=err)
                    try:
                        context.handoff.write_to(child.stdin)
                        deadline=time.monotonic()+45
                        while child.poll()is None and not session.closed and time.monotonic()<deadline:time.sleep(.1)
                    finally:
                        if child.poll()is None:child.kill();child.wait()
                observations=[]
                for line in event.read_text().splitlines():
                    try:observations.append(json.loads(line))
                    except ValueError:pass
                authenticated=any(x.get('authenticated')is True for x in observations)
                subscribed=any(x.get('genuineSubscriptionObserved')is True for x in observations)
                save(trial/'authorized-followup.json',{'schema':1,'exitCode':child.returncode,'preparationSHA256':sha(preparation),'eventsSHA256':sha(event),'observations':observations,'accountAuthenticated':authenticated,'genuineSubscriptionObserved':subscribed,'gameCompatibilityVerified':False})
                print(json.dumps({'type':'authorized_native_probe_finished','exitCode':child.returncode,'accountAuthenticated':authenticated,'genuineSubscriptionObserved':subscribed,'report':str(trial/'authorized-followup.json')}),flush=True)
                live.write('completed'if authenticated and subscribed else'starting_native','Backend nativo verificato; sessione disponibile per le altre prove.'if authenticated and subscribed else'Accesso conservato in memoria; correzione del collegamento nativo in corso.')
            finally:context.handoff.clear()
        except Exception as error:
            if request_path.exists()and not request_path.is_symlink():os.replace(request_path,controller_run/('rejected-probe-control-'+uuid.uuid4().hex+'.json'))
            print(json.dumps({'type':'authorized_probe_failed','exceptionKind':type(error).__name__,'secretFree':True}),flush=True)
            if not session.closed:live.write('starting_native','Accesso conservato in memoria; verifica del processo in corso.')
        finally:
            if fd>=0:os.close(fd)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--library',type=Path,required=True);p.add_argument('--architecture',choices=['arm64','x86_64'],required=True);p.add_argument('--interface');p.add_argument('--create-user',action='store_true');p.add_argument('--local-ipc',action='store_true');p.add_argument('--state-fs-shim',type=Path);p.add_argument('--ipc-shim',type=Path);p.add_argument('--peer',action='store_true');p.add_argument('--invalid-login',action='store_true');p.add_argument('--authenticate',action='store_true');p.add_argument('--prepare-auth',action='store_true');p.add_argument('--bridge-dotnet',type=Path);p.add_argument('--bridge-dll',type=Path);p.add_argument('--app-id',type=int);p.add_argument('--live-ui',type=Path);a=p.parse_args()
    online=a.authenticate or a.prepare_auth
    if a.local_ipc and not a.create_user:raise ValueError('Local IPC is only an explicit unauthenticated create-user experiment')
    if a.invalid_login and not(a.create_user and a.local_ipc and a.state_fs_shim):raise ValueError('Invalid synthetic login needs isolated state and explicit local IPC')
    if a.peer and not(a.create_user and a.local_ipc and a.state_fs_shim and a.ipc_shim):raise ValueError('Peer experiment requires both isolation adapters and local IPC')
    if online and (not(a.create_user and a.local_ipc and a.state_fs_shim and a.ipc_shim)or a.peer or a.invalid_login or not a.app_id or not 0<a.app_id<2**32-1):raise ValueError('Online preparation needs exact isolated native host and a nonreserved app ID; no peer/synthetic mode')
    if a.authenticate and a.prepare_auth:raise ValueError('Select preparation or actual authorization, not both')
    if a.live_ui and not a.authenticate:raise ValueError('Live authentication card requires explicit account-test mode')
    if not(WORK/'.ready-external-workspace').is_file()or WORK.stat().st_uid!=os.getuid():raise ValueError('Owned authorized work volume required')
    library=a.library.resolve(strict=True)
    # Accept only code from the explicitly supplied installed Steam app bundle.
    bundle=next((x for x in library.parents if x.name=='Steam.AppBundle'),None)
    if not bundle or library.name!='steamclient.dylib':raise ValueError('Installed Steam code library required')
    if a.create_user and (a.architecture!='arm64' or a.interface!='CLIENTENGINE_INTERFACE_VERSION005' or sha(library)!='b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd'):
        raise ValueError('Private wrapper experiment requires the exact statically inspected ARM64 client image')
    base=WORK/'retained/research-steam-native';base.mkdir(mode=0o700,exist_ok=True)
    run=base/('offline-'+a.architecture+'-'+uuid.uuid4().hex);run.mkdir(mode=0o700)
    for name in ['tmp','state']:(run/name).mkdir(mode=0o700)
    executable=run/'ready-steam-native-probe';source=ROOT/'Scripts/steam_native_host_probe.c'
    sources=run/'sources';sources.mkdir(mode=0o700)
    for item in [source,ROOT/'Scripts/steam_host_credential.h',ROOT/'Scripts/steam_host_credential.py',ROOT/'Scripts/steam_headless_auth_broker.py',ROOT/'Scripts/steam_auth_qr.swift',Path(__file__).resolve()]:
        copy=sources/item.name;copy.write_bytes(item.read_bytes());copy.chmod(0o600)
    source_snapshot=sources/source.name
    build=['/usr/bin/clang','-arch',a.architecture,'-O1','-g','-Wall','-Wextra',str(source_snapshot),'-o',str(executable)]
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','STEAM','Steam','SB_','M1L_','READY_'))}
    env.update(TMPDIR=str(run/'tmp')+'/',XDG_CACHE_HOME=str(run/'state'))
    # Both endpoints must differ. Reserve both together during allocation;
    # another process can still take a port before the client binds (fail closed).
    ports=[]
    endpoints=[]
    try:
        for _ in range(2):
            endpoint=socket.socket();endpoints.append(endpoint)
            endpoint.bind(('127.0.0.1',0));ports.append(endpoint.getsockname()[1])
    finally:
        for endpoint in endpoints:endpoint.close()
    # Runtime assertion in the measured Mac library confirms that this override
    # is parsed as a name/address:port string. An arbitrary label is rejected.
    env['steam_master_ipc_name_override']='127.0.0.1:'+str(ports[0])
    env['SteamClientService']='127.0.0.1:'+str(ports[1])
    shim=a.state_fs_shim.resolve(strict=True)if a.state_fs_shim else None
    if shim:
        if not shim.is_relative_to(WORK)or shim.stat().st_uid!=os.getuid():raise ValueError('Owned work-volume state adapter required')
        private=run/'state/client';private.mkdir(mode=0o700)
        env.update(READY_STEAM_STATE_FS_LIBRARY=str(shim),READY_STEAM_ORIGINAL_STATE_ROOT=str(bundle.parent),READY_STEAM_PRIVATE_STATE_ROOT=str(private))
    ipc_shim=a.ipc_shim.resolve(strict=True)if a.ipc_shim else None
    namespace=uuid.uuid4().hex
    if ipc_shim:
        if not shim or not ipc_shim.is_relative_to(WORK)or ipc_shim.stat().st_uid!=os.getuid():raise ValueError('Owned work-volume IPC adapter and state adapter required')
        env.update(READY_STEAM_IPC_LIBRARY=str(ipc_shim),READY_STEAM_IPC_NAMESPACE=namespace)
    subprocess.run(build,env=env,check=True,capture_output=True)
    # No HOME redirection. Preserve OS-loader reads while denying user/account,
    # IPC/temp and other project contents. Only the supplied Steam code bundle
    # and owned research tree are exceptions inside those denied roots.
    denied=[Path('/Users'),Path('/private/var/root'),Path('/Library/Keychains'),WORK,
            Path('/private/var/folders'),Path('/private/tmp'),Path('/tmp'),
            Path('/opt/homebrew'),Path('/usr/local')]
    profile='(version 1)\n(allow default)\n(deny network*)\n(deny mach-lookup)\n(allow mach-lookup (global-name "com.apple.dyld"))\n'
    if online:
        # Genuine client endpoints/CDNs vary. Public outbound networking is
        # explicit for this account test; other loopback destinations stay
        # denied. Native game IPC retains its two exact endpoint exceptions.
        profile+='(allow network-outbound (require-not (remote ip "localhost:*")))\n'
        profile+='(deny network-outbound (remote unix-socket (path-regex #".*")))\n'
        # Apple's DNS client uses this OS-owned socket (dnssd_ipc.h). No
        # general Unix-socket exception or Steam/user-service access is added.
        profile+='(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")) (remote unix-socket (path-literal "/var/run/mDNSResponder")))\n'
        # sandbox's address grammar rejects port 0; the genuine client's
        # ephemeral client-socket binds therefore need this explicit allowance.
        # Inbound listeners are still limited by the rules below.
        profile+='(allow network-bind)\n'
        profile+='(allow mach-lookup (global-name "com.apple.mDNSResponder") (global-name "com.apple.SystemConfiguration.configd"))\n'
        # Required by the genuine image's SecTrust path. Account-free URLSession
        # and certificate-chain controls isolate this single OS trust service.
        profile+='(allow mach-lookup (global-name "com.apple.trustd.agent"))\n'
    profile+='(deny ipc-posix-shm ipc-posix-sem)\n'
    if ipc_shim:
        for kind,operation in [('S','ipc-posix-shm'),('E','ipc-posix-sem')]:
            # macOS sandbox's regex dialect did not match {10} in actual
            # controls. Spell out ten classes, as exercised by IPC fixtures.
            pattern='^/R'+kind+namespace[:16]+'_'+'[a-f0-9]'*10+'$'
            profile+='(allow '+operation+' (ipc-posix-name-regex #'+json.dumps(pattern)+'))\n'
    if a.local_ipc:
        for port in ports:
            endpoint=json.dumps('localhost:'+str(port))
            profile+='(allow network-bind (local ip '+endpoint+'))\n'
            profile+='(allow network-inbound (local ip '+endpoint+'))\n'
            profile+='(allow network-outbound (remote ip '+endpoint+'))\n'
    profile+='(deny file-read* '+ ' '.join('(subpath '+json.dumps(str(x))+')'for x in denied)+')\n'
    profile+='(allow file-read* (subpath '+json.dumps(str(bundle))+') (subpath '+json.dumps(str(run))+'))\n(allow file-read-metadata)\n'
    if shim:profile+='(allow file-read* (literal '+json.dumps(str(shim))+'))\n'
    if ipc_shim:profile+='(allow file-read* (literal '+json.dumps(str(ipc_shim))+'))\n'
    profile+='(deny file-write*)\n(allow file-write* (subpath '+json.dumps(str(run))+') (literal "/dev/null"))\n'
    profile+='(deny file-map-executable (subpath '+json.dumps(str(run/'state'))+'))\n'
    profile+='(deny process-exec)\n(allow process-exec (literal '+json.dumps(str(executable))+'))\n'
    sandbox=run/'offline.sb';sandbox.write_text(profile);sandbox.chmod(0o600)
    denied_root=WORK/'tests'/('steam-offline-control-'+uuid.uuid4().hex);denied_root.mkdir(mode=0o700)
    read_control=ROOT/'Evidence'/('.steam-private-read-control-'+uuid.uuid4().hex);read_control.write_text('Owned benign sandbox control\n');read_control.chmod(0o600)
    write_control=denied_root/'must-not-be-created'
    control_command=['/usr/bin/sandbox-exec','-f',str(sandbox),str(executable),'--controls',str(read_control),str(write_control)]
    # Darwin sockaddr_un paths are short. Keep this owned control outside the
    # longer evidence path, and remove only its fresh socket after the test.
    unix_control=WORK/'tmp'/('sc-'+uuid.uuid4().hex[:8]);env['READY_STEAM_CONTROL_UNIX']=str(unix_control)
    with socket.socket(socket.AF_UNIX)as unix_listener:
        unix_listener.bind(str(unix_control));unix_listener.listen(1)
        try:control=subprocess.run(control_command,cwd=run,env=env,capture_output=True,text=True,timeout=15)
        finally:unix_control.unlink()
    save(run/'sandbox-controls.json',{'exitCode':control.returncode,'stdout':control.stdout,'stderr':control.stderr})
    if control.returncode or write_control.exists()or read_control.read_text()!='Owned benign sandbox control\n':raise RuntimeError('Sandbox negative controls did not establish isolation; Valve library not loaded')
    read_control.unlink()
    if a.prepare_auth:
        smoke=subprocess.run(['/usr/bin/sandbox-exec','-f',str(sandbox),str(executable),'--public-network-probe'],cwd=run,env=env,capture_output=True,text=True,timeout=12)
        save(run/'public-network-smoke.json',{'exitCode':smoke.returncode,'stdout':smoke.stdout,'stderr':smoke.stderr})
        save(run/'auth-preparation.json',{'schema':1,'sandboxControlsPassed':True,'publicNetworkSmokePassed':smoke.returncode==0,'publicNetworkSmokeSHA256':sha(run/'public-network-smoke.json'),'sandboxSHA256':sha(sandbox),'executableSHA256':sha(executable),'sourceArtifacts':[{'name':x.name,'SHA256':sha(x)}for x in sorted(sources.iterdir())],'librarySHA256':sha(library),'stateShimSHA256':sha(shim),'ipcShimSHA256':sha(ipc_shim),'appID':a.app_id,'authenticated':False,'ValveLibraryExecuted':False,'existingFullClientPresent':bool(processes())})
        print(json.dumps({'prepared':True,'publicNetworkSmokePassed':smoke.returncode==0,'authenticated':False,'report':str(run/'auth-preparation.json'),'existingFullClientPresent':bool(processes())}));return
    authorization=None;auth_session=None
    live=None;cancel=threading.Event();stop_watch=threading.Event();frontend=None
    if a.authenticate:
        if processes():raise RuntimeError('existing_full_steam_client_present: close it explicitly before the real independence test; no process was stopped')
        if not(a.bridge_dotnet and a.bridge_dll):raise ValueError('Explicit source-built SteamKit helper paths required')
        dotnet=a.bridge_dotnet.resolve(strict=True);bridge=a.bridge_dll.resolve(strict=True)
        if not all(x.is_relative_to(WORK)and x.stat().st_uid==os.getuid()for x in [dotnet,bridge]):raise ValueError('Owned external source-build helper required')
        # This is the exact independently built ownership-preflight candidate.
        if sha(bridge)!='8d552562a3ab2f1e96f65c0aad6a525966a5331933462bd89787a58b3c9834dc':raise ValueError('Unverified SteamKit helper candidate')
        sys.dont_write_bytecode=True
        sys.path.insert(0,str(sources))
        from steam_headless_auth_broker import beginQR,BrokerError
        if a.live_ui:
            frontend_executable=a.live_ui.resolve(strict=True)
            if frontend_executable.stat().st_uid!=os.getuid()or not os.access(frontend_executable,os.X_OK)or not(frontend_executable.is_relative_to(ROOT/'Build')or frontend_executable.is_relative_to(WORK)):
                raise ValueError('Explicit owned Ready diagnostic frontend required')
            live=LiveStatus(run);live.write('starting','Preparazione della verifica Steam…')
            with (run/'frontend-stdout.log').open('w')as output,(run/'frontend-stderr.log').open('w')as errors:
                frontend=subprocess.Popen([str(frontend_executable),'--data-root',str(run/'frontend-data'),'--steam-auth-status',str(live.path)],cwd=run,env=dict(env,READY_RUNTIME_ROOT=str(ROOT/'Runtime')),stdin=subprocess.DEVNULL,stdout=output,stderr=errors)
            threading.Thread(target=live.watch_cancel,args=(cancel,stop_watch,frontend),daemon=True).start()
            print(json.dumps({'type':'live_ui','status':str(live.path),'pid':frontend.pid}),flush=True)
            deadline=time.monotonic()+12
            ready=False
            while frontend.poll()is None and time.monotonic()<deadline:
                try:
                    acknowledgement=run/'live-ui-ready.json'
                    if not acknowledgement.is_symlink()and acknowledgement.stat().st_size<=1024:
                        value=json.loads(acknowledgement.read_text())
                        if value=={'schema':1,'generation':live.generation,'pid':frontend.pid}:ready=True;break
                except (FileNotFoundError,ValueError,OSError):pass
                time.sleep(.1)
            if not ready:
                live.write('failed','Il pannello di accesso non è pronto. Nessuna richiesta di accesso inviata.')
                stop_watch.set();raise RuntimeError('live_frontend_not_ready_before_auth')
        qr_images=[]
        def on_qr(url):
            qr=run/('qr-'+str(uuid.uuid4())+'.png')
            qr_env=dict(os.environ,SWIFT_MODULECACHE_PATH=str(WORK/'cache/swift-module-cache'))
            subprocess.run(['/usr/bin/swift',str(sources/'steam_auth_qr.swift'),str(qr)],input=url.encode(),env=qr_env,check=True,capture_output=True,timeout=20)
            qr_images.append(qr)
            if live:live.write('qr','Scansiona con l’app Steam e approva Ready for macOS.',qr.name)
            print(json.dumps({'type':'qr','image':str(qr),'instructions':'Approve this new Ready test in the Steam mobile app.'}),flush=True)
        def on_phase(phase):
            if live:
                messages={'authenticating':'Richiesta di accesso a Steam…','authentication_complete':'Accesso ricevuto. Il QR è concluso.','authorizing_game':'Verifica della licenza del gioco…','authorized':'Licenza verificata. Preparazione del backend nativo…'}
                live.write(phase,messages.get(phase))
            if phase=='authentication_complete':
                for qr in qr_images:qr.unlink(missing_ok=True)
            print(json.dumps({'type':'phase','phase':phase}),flush=True)
        try:
            helper_command=[str(dotnet),str(bridge)]
            auth_session=beginQR(helper_command,on_qr,onPhase=on_phase,cancel=cancel,ttl=600)
            while True:
                try:
                    authorization=auth_session.authorize_game(helper_command,a.app_id,onPhase=on_phase)
                    break
                except BrokerError as error:
                    diagnostic=error.diagnostic()
                    if not live or diagnostic['code']!='steam_error' or auth_session.closed:raise
                    failure=run/('retained-session-helper-failure-'+uuid.uuid4().hex+'.json')
                    save(failure,{'schema':1,'diagnostic':diagnostic,'bridgeSHA256':sha(Path(helper_command[1])),'credentialsPersisted':False,'nativeWorkerStarted':False})
                    live.write('authorizing_game','Accesso ricevuto. Correzione della verifica in corso; la sessione resta solo in memoria. Puoi annullare.')
                    print(json.dumps({'type':'helper_retry_required','diagnostic':diagnostic,'report':str(failure),'control':str(run/'retry-helper.json'),'generation':live.generation}),flush=True)
                    helper_command=wait_for_pinned_helper_retry(auth_session,live,run)
                    if helper_command is None:raise BrokerError('session_expired')
        except BrokerError as error:
            if auth_session:auth_session.close()
            for qr in qr_images:qr.unlink(missing_ok=True)
            diagnostic=error.diagnostic()
            if live:
                if diagnostic['code']=='cancelled':live.write('cancelled','Verifica annullata.')
                elif diagnostic.get('steamResult')=='Expired':live.write('failed','Il codice Steam è scaduto. La richiesta è stata chiusa.')
                elif diagnostic['code']=='not_authorized':live.write('failed','Steam non ha confermato la licenza del gioco per questo account.')
                else:live.write('failed','Verifica Steam non riuscita: '+diagnostic['code']+'.')
            stop_watch.set()
            save(run/'auth-failure.json',{'schema':1,'diagnostic':diagnostic,'bridgeSHA256':sha(bridge),'sourceArtifacts':[{'name':x.name,'SHA256':sha(x)}for x in sorted(sources.iterdir())],'nativeWorkerStarted':False,'gameCompatibilityVerified':False})
            print(json.dumps({'type':'authorization_failed','diagnostic':diagnostic,'report':str(run/'auth-failure.json')}),flush=True)
            raise SystemExit(1)
    event_file=run/'events.jsonl'
    event_file.touch(mode=0o600,exist_ok=False)
    env['READY_STEAM_EVENT_FILE']=str(event_file)
    before=processes();library_before=sha(library)
    command=['/usr/bin/sandbox-exec','-f',str(sandbox),str(executable),str(library)]
    if a.interface:command.append(a.interface)
    if a.create_user:command.append('--create-user')
    if a.invalid_login:command.append('--invalid-login')
    if a.authenticate:command.append('--authenticate')
    timed_out=False
    peer_result=None
    try:
        if a.peer:
            host_env=dict(env,READY_STEAM_PROBE_HOLD_MS='15000')
            with (run/'host-live-stdout.log').open('w')as host_out,(run/'host-live-stderr.log').open('w')as host_err:
                host=subprocess.Popen(command,cwd=run,env=host_env,stdout=host_out,stderr=host_err,text=True)
                try:
                    deadline=time.monotonic()+12
                    while host.poll()is None and time.monotonic()<deadline:
                        if any('"globalUserHandle":1' in line for line in event_file.read_text().splitlines()):break
                        time.sleep(.05)
                    else:raise RuntimeError('Host did not establish its private user before peer launch')
                    peer_events=run/'peer-events.jsonl';peer_events.touch(mode=0o600)
                    peer_env=dict(env,READY_STEAM_EVENT_FILE=str(peer_events),READY_STEAM_PROBE_HOLD_MS='3000')
                    peer_command=command[:];peer_command[peer_command.index('--create-user')]='--connect-user'
                    if '--invalid-login' in peer_command:peer_command.remove('--invalid-login')
                    with (run/'peer-stdout.log').open('w')as peer_out,(run/'peer-stderr.log').open('w')as peer_err:
                        peer=subprocess.Popen(peer_command,cwd=run,env=peer_env,stdout=peer_out,stderr=peer_err,text=True)
                        try:
                            deadline=time.monotonic()+8
                            while peer.poll()is None and time.monotonic()<deadline:
                                if any('"connectUserAttempted":true' in line for line in peer_events.read_text().splitlines()):break
                                time.sleep(.05)
                            network={}
                            for label,process in [('host',host),('peer',peer)]:
                                listing=subprocess.run(['/usr/sbin/lsof','-nP','-a','-p',str(process.pid),'-iTCP'],capture_output=True,text=True,timeout=5)
                                network[label]={'pid':process.pid,'exitCode':listing.returncode,'stdout':listing.stdout,'stderr':listing.stderr}
                            peer.wait(timeout=12)
                        finally:
                            if peer.poll()is None:peer.kill();peer.wait()
                    peer_result={'exitCode':peer.returncode,'observations':[json.loads(line)for line in peer_events.read_text().splitlines()],'network':network,'eventsSHA256':sha(peer_events)}
                    host.wait(timeout=20)
                finally:
                    if host.poll()is None:host.kill();host.wait()
            result=subprocess.CompletedProcess(command,host.returncode,(run/'host-live-stdout.log').read_text(),(run/'host-live-stderr.log').read_text())
        elif a.authenticate:
            if live:live.write('starting_native','Accesso e licenza verificati. Collegamento al backend nativo…')
            with (run/'auth-live-stdout.log').open('w')as output,(run/'auth-live-stderr.log').open('w')as errors:
                process=subprocess.Popen(command,cwd=run,env=env,stdin=subprocess.PIPE,stdout=output,stderr=errors)
                try:
                    authorization.handoff.write_to(process.stdin)
                    process.stdin.close()
                    deadline=time.monotonic()+45
                    while process.poll()is None:
                        if cancel.is_set():raise RuntimeError('owned_native_authorization_cancelled')
                        if time.monotonic()>=deadline:raise subprocess.TimeoutExpired(command,45)
                        time.sleep(.1)
                finally:
                    authorization.handoff.clear()
                    if process.poll()is None:process.kill();process.wait()
            result=subprocess.CompletedProcess(command,process.returncode,(run/'auth-live-stdout.log').read_text(),(run/'auth-live-stderr.log').read_text())
        else:result=subprocess.run(command,cwd=run,env=env,capture_output=True,text=True,timeout=45)
    except subprocess.TimeoutExpired as error:
        timed_out=True
        def decoded(value):return value.decode(errors='replace')if isinstance(value,bytes)else(value or '')
        result=subprocess.CompletedProcess(command,124,decoded(error.stdout),decoded(error.stderr))
    except RuntimeError:
        if not(a.authenticate and cancel.is_set()):raise
        result=subprocess.CompletedProcess(command,130,'','Owned account test cancelled by its live frontend.\n')
    for label,value in [('stdout',result.stdout),('stderr',result.stderr)]:
        path=run/(label+'.log');path.write_text(value);path.chmod(0o600)
    observations=[]
    for line in event_file.read_text().splitlines()+result.stderr.splitlines():
        try:observations.append(json.loads(line))
        except ValueError:pass
    after=processes();report={'schema':2,'kind':'offline-native-steam-loader-factory','architecture':a.architecture,'interface':a.interface,'exitCode':result.returncode,'timedOut':timed_out,'observations':observations,'sourceSHA256':sha(source_snapshot),'driverSHA256':sha(sources/Path(__file__).name),'executableSHA256':sha(executable),'sandboxSHA256':sha(sandbox),'sandboxControlsSHA256':sha(run/'sandbox-controls.json'),'sandboxNegativeControlsPassed':True,'library':str(library),'librarySHA256':library_before,'libraryUnchanged':sha(library)==library_before,'buildCommand':build,'command':command,'SteamProcessesBefore':before,'SteamProcessesAfter':after,'existingSteamProcessesUnchanged':before==after,'internetPermitted':False,'loopbackIPC':{'permitted':a.local_ipc,'addresses':['127.0.0.1:'+str(port)for port in ports]if a.local_ipc else[]},'indexedMethodsAttempted':a.create_user,'invalidSyntheticLoginAttempted':a.invalid_login,'accountAuthenticated':False,'gameCompatibilityVerified':False,'normalConfigReadPermitted':False,'normalConfigWritePermitted':False,'eventsSHA256':sha(event_file),'stdoutSHA256':sha(run/'stdout.log'),'stderrSHA256':sha(run/'stderr.log'),'stateAdapter':{'path':str(shim),'SHA256':sha(shim)}if shim else None}
    report.update(peer=peer_result,ipcAdapter={'path':str(ipc_shim),'SHA256':sha(ipc_shim),'namespace':namespace}if ipc_shim else None)
    report['sourceArtifacts']=[{'name':item.name,'SHA256':sha(item)}for item in sorted(sources.iterdir())]
    if a.authenticate:
        from dataclasses import asdict
        report.update(internetPermitted=True,accountAuthenticated=any(x.get('authenticated')is True for x in observations),steamKitAuthorization=asdict(authorization.safe))
        if live:
            if cancel.is_set():live.write('cancelled','Verifica annullata. Il processo della prova è stato arrestato.')
            elif report['accountAuthenticated']and any(x.get('genuineSubscriptionObserved')is True for x in observations):live.write('completed','Prova conclusa: account e licenza verificati dal backend nativo. L’avvio del gioco resta da verificare.')
            else:live.write('failed','Accesso Steam e licenza verificati. Il collegamento del backend nativo non è ancora riuscito.')
    save(run/'report.json',report)
    print(json.dumps({'exitCode':result.returncode,'loaded':any(x.get('loaded')is True for x in observations),'existingSteamProcessesUnchanged':before==after,'report':str(run/'report.json')}))
    if a.authenticate and auth_session:
        try:
            if live and not auth_session.closed:
                if not report['accountAuthenticated']:live.write('starting_native','Accesso e licenza verificati. Correzione del backend in corso; l’accesso resta solo in memoria.')
                hold_authorized_followups(auth_session,live,run,helper_command,a.app_id,authorization.safe.steamID,library,env)
        finally:
            auth_session.close();stop_watch.set()

if __name__=='__main__':main()
