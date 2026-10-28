#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare an isolated genuine Windows Steam host; never authenticate by default.

Real account use is an explicit library call with Root-managed QR/phase callbacks:
  authorize_and_launch(prepared, allow_real_auth=True, onQR=..., onPhase=...)
This wrapper never prints QR URLs or receives tokens in argv/environment/files.
"""
import argparse,hashlib,importlib,json,os,re,shutil,socket,stat,subprocess,sys,threading,time,types,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
RESEARCH=WORK/'retained/research-steam-windows'
HELPER_ROOT=WORK/'build/steam-ownership-jvty72ta'
HELPER_SHA='8d552562a3ab2f1e96f65c0aad6a525966a5331933462bd89787a58b3c9834dc'
PE_SHA={64:'4c3817e817f2df3f98dbda19de29c2eb7a8e834141c9b1e3a01bfdc6c33e1965',32:'3af3af7acaeb51f4b5ff1da015cfd507a6f4ae6ae1f08bb4e1d979d155b8a0b6'}
def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(path,value):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as f:json.dump(value,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
def owned(path):
    info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:raise ValueError('Private owned regular file required')
def native_steam():
    rows=subprocess.check_output(['/bin/ps','-axo','pid=,lstart=,comm='],text=True).splitlines()
    return [r.strip() for r in rows if '/Steam.AppBundle/' in r or '/Steam.app/' in r]
def scrub_environment():
    return {k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_','VK_','CX_')) and not k.lower().startswith('steam')}
def validate_app(app):
    if type(app)!=int or not 0<app<0xffffffff:raise ValueError('Exact nonreserved app ID required')
def inventory(paths):return {str(p):sha(p) for p in paths}
def records(path):
    result=[]
    if path.exists():
        if path.is_symlink() or path.stat().st_size>1024*1024:raise ValueError('Unsafe event file')
        for line in path.read_text().splitlines():
            try:item=json.loads(line)
            except ValueError:continue
            if isinstance(item,dict):result.append(item)
    return result

def sandbox_document(state,final=False):
    prefix=Path(state['prefix']);run=Path(state['run']);wine_root=Path(state['wine']).parent.parent;deps=Path(state['dependencies']);ipc=Path(state['wineIPC']);payload=run/'payload'
    denied=[Path('/Users'),Path('/Volumes'),Path('/private/var/root'),Path('/Library/Keychains'),Path('/private/var/folders'),Path('/private/tmp'),Path('/tmp'),Path('/opt/homebrew'),Path('/usr/local')]
    reads=[prefix,ipc,wine_root,deps,Path(state['vulkanRoot'])]
    literals=[Path(p) for p in state['payloadHashes']]+[Path(state['guardian']),Path(state['controls'])]
    filt=lambda kind,paths:' '.join('('+kind+' '+json.dumps(str(p))+')' for p in paths)
    policy='(version 1)\n(allow default)\n(deny network*)\n(deny appleevent-send)\n(allow mach-lookup (global-name "com.apple.trustd.agent"))\n'
    policy+='(allow network-outbound (require-not (remote ip "localhost:*")))\n(deny network-outbound (remote unix-socket (path-regex #".*")))\n'
    policy+='(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")) (remote unix-socket (path-literal "/var/run/mDNSResponder")))\n(allow network-bind)\n'
    sock=json.dumps(str(ipc/'socket'));policy+='(allow network-bind network-inbound network-outbound (local unix-socket (path-literal '+sock+')) (remote unix-socket (path-literal '+sock+')))\n'
    policy+='(deny ipc-posix-shm ipc-posix-sem)\n(deny file-read* '+filt('subpath',denied)+')\n(allow file-read* '+filt('subpath',reads)+' '+filt('literal',literals)+')\n(allow file-read-metadata)\n'
    policy+='(deny file-write*)\n(allow file-write* '+filt('subpath',[prefix,ipc])+' (literal "/dev/null"))\n'
    executables=[Path(state['wine']),Path(state['server']),wine_root/'lib/wine/x86_64-unix/wine',Path(state['guardian']),Path(state['controls'])]
    policy+='(deny process-exec)\n(allow process-exec '+filt('literal',executables)+')\n'
    if final:
        # Unknown EXE/DLL files in mutable state cannot supply the normal Steam
        # frontend/helper names. Exact bootstrapped Wine PE files stay readable.
        pattern='^'+re.escape(str(prefix))+'/.*\\.([eE][xX][eE]|[dD][lL][lL])$'
        policy+='(deny file-read-data (regex #'+json.dumps(pattern)+'))\n'
        known=[Path(p) for p in state['prefixCodeHashes']]
        policy+='(allow file-read-data '+filt('literal',known)+')\n'
        policy+='(deny file-write* '+filt('literal',known+[prefix/'.ready-windows-auth-prefix'])+')\n'
    return policy

def environment(state):
    env=scrub_environment();prefix=Path(state['prefix']);deps=Path(state['dependencies'])
    env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d;steamclient,steamclient64=n',TMPDIR=str(prefix/'tmp')+'/',XDG_CACHE_HOME=str(prefix/'cache'),READY_WINDOWS_PREFIX_NONCE=state['nonce'],READY_WINDOWS_DEPENDENCY_PATH=state['vulkanRoot']+':'+str(deps/'lib'),READY_WINDOWS_GUARDIAN_EVENT=str(prefix/'.ready-windows-guardian.json'),P11_MODULE_PATH=str(deps/'lib/pkcs11'),P11_PACKAGE_CONFIG_MODULES=str(deps/'share/p11-kit/modules'),P11_SYSTEM_CONFIG_MODULES=str(deps/'etc/pkcs11/modules'),steam_master_ipc_name_override=state['namespace'])
    env['READY_STEAM_WINDOWS_CLIENT_DLL']='Z:'+state['clientDLL'].replace('/','\\')
    return env

def guarded_start(state,args,*,stdin=subprocess.DEVNULL):
    read,write=os.pipe();os.set_inheritable(read,True);env=environment(state);env['READY_WINDOWS_GUARDIAN_FD']=str(read)
    event=Path(state['prefix'])/'.ready-windows-guardian.json'
    if event.exists():raise ValueError('Previous guardian event must be retained before reuse')
    command=['/usr/bin/sandbox-exec','-f',state['sandbox'],state['guardian'],state['prefix'],state['server'],state['wine'],*map(str,args)]
    try:process=subprocess.Popen(command,cwd=state['prefix'],env=env,stdin=stdin,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(read,))
    except BaseException:os.close(read);os.close(write);raise
    os.close(read);return process,write

def guarded_finish(state,process,lifeline,label,timeout=20):
    try:process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        if lifeline is not None:os.close(lifeline);lifeline=None
        else:process.terminate()
        try:process.wait(timeout=15)
        except subprocess.TimeoutExpired:process.kill();process.wait(timeout=2)
    finally:
        if lifeline is not None:os.close(lifeline)
    event=Path(state['prefix'])/'.ready-windows-guardian.json';data=records(event)
    if event.exists():target=Path(state['run'])/(label+'-guardian.json');shutil.copy2(event,target);event.unlink()
    result=data[-1] if data else {};result['guardianExit']=process.returncode
    if result.get('exactPrefixValidated') is not True or result.get('serverWait')!=0 or result.get('serverKill') not in (0,1):raise RuntimeError('Exact-prefix guardian cleanup did not validate')
    return result

def prepare(architecture=64,app_id=1091500):
    validate_app(app_id)
    if architecture not in (32,64):raise ValueError('PE32/PE64 only')
    owned(WORK/'.ready-external-workspace')
    if shutil.disk_usage(WORK).free<1024**3:raise RuntimeError('Work-volume reserve below1GiB')
    auth=json.loads((RESEARCH/'authenticode-verification.json').read_text());assert auth['allVerified']
    cfg=json.loads((ROOT/'Runtime/runtime.json').read_text());receipt=RESEARCH/'free-probe-build-1ede483c6d262163fe81/build-receipt.json';built=json.loads(receipt.read_text());pe=next(Path(p) for p in built['artifacts'] if Path(p).name=='ready-steam-factory'+str(architecture)+'.exe');assert sha(pe)==PE_SHA[architecture]
    bridge=HELPER_ROOT/'output/ReadySteamBridge.dll';dotnet=HELPER_ROOT/'dotnet/dotnet'
    if sha(bridge)!=HELPER_SHA or not dotnet.is_file() or not os.access(dotnet,os.X_OK):raise ValueError('Pinned genuine ownership broker unavailable')
    run=WORK/'retained/windows-auth-prepared'/('prepared-'+uuid.uuid4().hex);run.mkdir(mode=0o700,parents=True);nonce=uuid.uuid4().hex
    save(run/'.ready-windows-auth-workspace',{'schema':1,'nonce':nonce,'ownerUID':os.getuid()})
    prefix=run/'prefix';prefix.mkdir(mode=0o700);(prefix/'tmp').mkdir();marker=prefix/'.ready-windows-auth-prefix';marker.write_text(nonce);marker.chmod(0o600)
    st=prefix.stat();ipc=Path('/private/tmp')/('.wine-'+str(os.getuid()))/('server-'+format(st.st_dev,'x')+'-'+format(st.st_ino,'x'));ipc.parent.mkdir(mode=0o700,exist_ok=True)
    if ipc.exists():raise RuntimeError('Fresh prefix IPC directory unexpectedly exists')
    ipc.mkdir(mode=0o700);tools=run/'tools';tools.mkdir();payload=prefix/'drive_c/ReadySteamClient';payload.mkdir(parents=True);sources=run/'sources';sources.mkdir()
    names=['steam_windows_authenticated_host.py','steam_windows_guardian.c','steam_windows_online_controls.c','steam_windows_factory_probe.c','steam_windows_credential.h','steam_windows_login_abi.h','steam_headless_auth_broker.py','steam_host_credential.py','steam_host_credential.h']
    for name in names:shutil.copy2(ROOT/'Scripts'/name,sources/name)
    commands=[]
    for name,output in [('steam_windows_guardian.c','guardian'),('steam_windows_online_controls.c','controls')]:
        command=['/usr/bin/clang','-arch','arm64','-O2','-Wall','-Wextra',str(sources/name),'-o',str(tools/output)];subprocess.run(command,check=True,capture_output=True);commands.append(command)
    target=payload/pe.name;shutil.copy2(pe,target);target.chmod(0o444);payload_hashes={str(target):sha(target)}
    selected=RESEARCH/('valve-client'+str(architecture));client_name='steamclient64.dll' if architecture==64 else 'steamclient.dll'
    for entry in auth['files']:
        source=Path(entry['file'])
        if source.parent!=selected:continue
        if sha(source)!=entry['sha256'] or entry['returncode']!=0:raise ValueError('Valve identity changed')
        target=payload/source.name;shutil.copy2(source,target);target.chmod(0o444);payload_hashes[str(target)]=sha(target)
    if len(payload_hashes)!=4:raise ValueError('Exactly own PE plus three verified Valve DLLs required')
    state={'schema':1,'run':str(run),'prefix':str(prefix),'wineIPC':str(ipc),'nonce':nonce,'architecture':architecture,'appID':app_id,'namespace':'ReadyOwned-'+uuid.uuid4().hex[:24],'wine':cfg['wineBinary'],'server':cfg['wineServer'],'dependencies':cfg['sourceDependencyPrefix'],'vulkanRoot':str(Path(cfg['vulkanLibrary']).parent),'guardian':str(tools/'guardian'),'controls':str(tools/'controls'),'sandbox':str(run/'online.sb'),'program':str(payload/pe.name),'clientDLL':str(payload/client_name),'payloadHashes':payload_hashes,'bridge':str(bridge),'dotnet':str(dotnet),'bridgeCodeHashes':inventory(p for p in (HELPER_ROOT/'output').iterdir() if p.is_file()),'dotnetHostHashes':inventory([dotnet,*[p for directory in ['host','shared'] for p in (HELPER_ROOT/'dotnet'/directory).rglob('*') if p.is_file() and p.suffix.lower() in ('.dll','.dylib','.json')]]),'beforeHashes':inventory([ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json',Path(cfg['wineBinary']),Path(cfg['wineServer'])]),'sourceHashes':inventory(sources.iterdir()),'toolHashes':inventory(tools.iterdir()),'sourceBuildCommands':commands,'nativeSteamBefore':native_steam(),'actualBackendAuthenticated':False,'ValveExecutedOnline':False}
    Path(state['sandbox']).write_text(sandbox_document(state));Path(state['sandbox']).chmod(0o600)
    # Live negative Unix endpoint plus the ONLY allowed Wine socket name, before
    # a real wineserver is started. No protocol bytes or Valve code are used.
    denied=WORK/'tmp'/('ww-'+uuid.uuid4().hex[:8]);allowed=ipc/'socket';sentinel=run/'denied-read';sentinel.write_text('Owned benign denied control\n');outside=run/'denied-write'
    with socket.socket(socket.AF_UNIX) as no,socket.socket(socket.AF_UNIX) as yes:
        no.bind(str(denied));no.listen(1);yes.bind(str(allowed));yes.listen(1)
        try:control=subprocess.run(['/usr/bin/sandbox-exec','-f',state['sandbox'],state['controls'],str(sentinel),str(outside),str(denied),str(allowed)],env=environment(state),capture_output=True,text=True,timeout=15)
        finally:denied.unlink();allowed.unlink()
    save(run/'controls.json',{'exit':control.returncode,'observation':json.loads(control.stdout) if control.stdout else {},'stderr':control.stderr})
    if control.returncode or outside.exists():raise RuntimeError('Online sandbox controls failed; no Valve code executed')
    smoke=subprocess.run(['/usr/bin/sandbox-exec','-f',state['sandbox'],state['controls'],'--public-smoke'],env=environment(state),capture_output=True,text=True,timeout=15);save(run/'network-smoke.json',{'exit':smoke.returncode,'observation':json.loads(smoke.stdout) if smoke.stdout else {},'stderr':smoke.stderr})
    if smoke.returncode:raise RuntimeError('OS DNS/public network smoke failed; no Valve code executed')
    wow=prefix/'drive_c/windows/syswow64';wow.mkdir(parents=True);shutil.copytree(Path(cfg['builtin32Directory']),wow,dirs_exist_ok=True,symlinks=True)
    process,line=guarded_start(state,['wineboot','-u']);boot=guarded_finish(state,process,line,'boot',180)
    if process.returncode:raise RuntimeError('Private Wine bootstrap failed; no Valve code executed')
    state['bootGuardian']=boot;state['prefixCodeHashes']=inventory(p for p in prefix.rglob('*') if p.is_file() and not p.is_symlink() and p.suffix.lower() in ('.dll','.exe'))
    Path(state['sandbox']).write_text(sandbox_document(state,final=True));state['sandboxSHA256']=sha(state['sandbox'])
    # Guardian liveness: own parser waits on EMPTY private stdin, and EOF on the
    # separate lifeline must stop only this worker/prefix before Valve loads.
    event=prefix/'lifetime-parser.jsonl';env=environment(state);env['READY_STEAM_WINDOWS_EVENT_FILE']='Z:'+str(event).replace('/','\\')
    # guarded_start intentionally owns its environment; supply this one safe
    # event path through the state field consumed below.
    state['eventFile']=str(event);process,line=guarded_start_with_event(state,['--credential-parse-only'],stdin=subprocess.PIPE)
    end=time.monotonic()+8
    while process.poll() is None and time.monotonic()<end:
        if records(event):break
        time.sleep(.02)
    os.close(line);result=guarded_finish(state,process,None,'lifetime',15)
    if process.stdin:process.stdin.close()
    if not result.get('parentLifetimeEOF') or result.get('guardianExit')!=130:raise RuntimeError('Guardian parent-lifetime control failed')
    state['lifetimeGuardian']=result;state['eventFile']=None
    if event.exists():shutil.copy2(event,run/'lifetime-parser.jsonl');event.unlink()
    state['prepared']=True;state['sandboxControlsSHA256']=sha(run/'controls.json');state['networkSmokeSHA256']=sha(run/'network-smoke.json');state['preparationOnly']=True
    if any(sha(path)!=digest for path,digest in state['beforeHashes'].items()):raise RuntimeError('Original runtime changed during preparation')
    save(run/'prepared.json',state);return run/'prepared.json'

def guarded_start_with_event(state,args,*,stdin):
    # Dedicated function retains controlled event path; no credentials in env.
    previous=state.get('eventFile');read,write=os.pipe();os.set_inheritable(read,True);env=environment(state);env['READY_WINDOWS_GUARDIAN_FD']=str(read);env['READY_STEAM_WINDOWS_EVENT_FILE']='Z:'+str(previous).replace('/','\\')
    command=['/usr/bin/sandbox-exec','-f',state['sandbox'],state['guardian'],state['prefix'],state['server'],state['wine'],state['program'],*args]
    try:process=subprocess.Popen(command,cwd=state['prefix'],env=env,stdin=stdin,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(read,))
    except BaseException:os.close(read);os.close(write);raise
    os.close(read);return process,write

def load_prepared(path):
    path=Path(path).resolve(strict=True);owned(path);state=json.loads(path.read_text());run=Path(state['run']).resolve(strict=True)
    if path!=run/'prepared.json' or not run.is_relative_to(WORK/'retained/windows-auth-prepared'):raise ValueError('Prepared root mismatch')
    owned(run/'.ready-windows-auth-workspace');marker=json.loads((run/'.ready-windows-auth-workspace').read_text());prefix=Path(state['prefix'])
    owned(prefix/'.ready-windows-auth-prefix')
    if marker['nonce']!=state['nonce'] or (prefix/'.ready-windows-auth-prefix').read_text()!=state['nonce']:raise ValueError('Prepared ownership marker mismatch')
    if sha(Path(__file__))!=state['sourceHashes'][str(run/'sources'/Path(__file__).name)]:raise ValueError('Wrapper source differs from prepared snapshot; reprepare explicitly')
    if not state.get('prepared') or sha(state['sandbox'])!=state['sandboxSHA256']:raise ValueError('Preparation not verified')
    for group in ['payloadHashes','prefixCodeHashes','beforeHashes','sourceHashes','toolHashes','bridgeCodeHashes','dotnetHostHashes']:
        if any(sha(p)!=h for p,h in state[group].items()):raise ValueError('Prepared input changed: '+group)
    if sha(state['bridge'])!=HELPER_SHA or state['appID']==0xffffffff:raise ValueError('Untrusted broker or reserved app')
    return state

def _prepared_broker(state):
    package_name='ready_windows_prepared_'+state['nonce']
    if package_name not in sys.modules:
        package=types.ModuleType(package_name);package.__path__=[str(Path(state['run'])/'sources')];package.__package__=package_name;sys.modules[package_name]=package
    return importlib.import_module(package_name+'.steam_headless_auth_broker')

def _validate_authorized_context(state,context):
    """Typed metadata boundary for a TRUSTED Root broker result, not ticket crypto.

    A caller able to forge objects inside this Python process is already within
    the Root trust boundary. This function does not inspect private frame bytes.
    """
    module=sys.modules.get(type(context).__module__)
    path=Path(getattr(module,'__file__','')) if module else None
    expected=state['sourceHashes'][str(Path(state['run'])/'sources/steam_headless_auth_broker.py')]
    if not module or not path or not path.is_file():raise ValueError('Trusted issued broker context required')
    canonical=path.resolve(strict=True);info=canonical.stat()
    if info.st_uid!=os.getuid() or not (canonical.is_relative_to(ROOT) or canonical.is_relative_to(WORK)) or sha(canonical)!=expected or type(context) is not getattr(module,'AuthorizedContext',None):raise ValueError('Trusted issued broker context provenance required')
    safe=context.safe;frame=context.handoff
    if not getattr(getattr(type(context),'__dataclass_params__',None),'frozen',False) or not getattr(getattr(type(safe),'__dataclass_params__',None),'frozen',False):raise ValueError('Frozen authorization metadata required')
    if type(safe) is not getattr(module,'SafeAuthorization',None) or type(frame) is not getattr(module,'PrivateCredentialFrame',None):raise ValueError('Trusted typed metadata and private frame required')
    if type(safe.appID)!=int or safe.appID!=state['appID'] or safe.authorized is not True or safe.ownershipTicketReceived is not True:raise ValueError('Exact-game genuine authorization metadata required')
    identity=safe.steamID
    if type(identity)!=int or not 0<identity<1<<64 or identity>>56!=1 or (identity>>52)&15!=1 or (identity>>32)&0xfffff!=1 or not identity&0xffffffff:raise ValueError('Valid explicit authorized identity required')
    if frame.cleared:raise ValueError('Single-use private handoff already consumed')
    return module

def run_with_authorized_context(prepared,context,*,cancel=None):
    """Root-only already-authorized path. NO helper, QR or new auth operation.

    Root must supply the actual AuthenticatedSession.authorize_game result from
    the pinned genuine preflight. Only safe AppID/SteamID metadata is inspected.
    The frame is consumed/cleared; the caller's in-memory Session stays alive.
    """
    state=load_prepared(prepared);broker=_validate_authorized_context(state,context)
    if native_steam():raise RuntimeError('Existing full Steam client present; none was stopped')
    stop=cancel if cancel is not None else threading.Event()
    if stop.is_set():context.handoff.clear();raise ValueError('Owned authorization cancelled before worker')
    process=None;line=None;report={'schema':2,'architecture':state['architecture'],'appID':state['appID'],'actualBackendAuthenticated':False,'gameLaunchVerified':False,'brokerPreflightVerified':True,'usedExistingAuthorizedContext':True,'newHelperOperation':False,'newQRRequested':False}
    try:
        event=Path(state['prefix'])/'actual-auth-events.jsonl';state['eventFile']=str(event);process,line=guarded_start_with_event(state,['--authenticate-bounded'],stdin=subprocess.PIPE)
        context.handoff.write_to(process.stdin,cancel=stop)
        end=time.monotonic()+45
        while process.poll() is None:
            if stop.is_set() or time.monotonic()>end:break
            time.sleep(.05)
        result=guarded_finish(state,process,line,'actual-auth',1 if process.poll() is None else 10);line=None;report['guardian']=result;items=records(event);ready=next((x for x in items if x.get('stage')=='bounded-auth-result'),{})
        report['actualBackendAuthenticated']=not stop.is_set() and process.returncode==0 and ready.get('authenticatedReady') is True and ready.get('loggedOn') is True and ready.get('identityMatchesExpected') is True and ready.get('ownsRequestedApp') is True
        report['safeWorkerStatus']={k:ready.get(k) for k in ['loggedOn','identityMatchesExpected','ownsRequestedApp','authenticatedReady','credentialBufferWipedAfterDispatch','callbackCount','callbackFreeCount','ValveConsoleSuppressed']}
        if event.exists():shutil.copy2(event,Path(state['run'])/'actual-auth-events.jsonl');event.unlink()
    except broker.BrokerError as error:report['brokerFailure']=error.diagnostic()
    finally:
        context.handoff.clear()
        if process and process.poll() is None:
            if line is not None:os.close(line);line=None
            try:process.wait(timeout=15)
            except subprocess.TimeoutExpired:process.kill();process.wait(timeout=2)
        if line is not None:os.close(line)
        report['cancelled']=stop.is_set()
        if stop.is_set():report['actualBackendAuthenticated']=False
        report['originalInputsUnchanged']=all(sha(p)==h for p,h in state['beforeHashes'].items());report['actualBackendNotAuth']=not report['actualBackendAuthenticated'];save(Path(state['run'])/('actual-result-'+uuid.uuid4().hex+'.json'),report)
    return report

def authorize_and_launch(prepared,*,allow_real_auth=False,onQR=None,onPhase=None,cancel=None,expectedSteamID=None):
    """Convenience fresh-QR path, explicit Root-managed opt-in only."""
    if allow_real_auth is not True or not callable(onQR):raise ValueError('Explicit real-auth opt-in and Root-managed QR callback required')
    state=load_prepared(prepared)
    if native_steam():raise RuntimeError('Existing full Steam client present; none was stopped')
    broker=_prepared_broker(state);context=None
    try:
        context=broker.authenticate_and_authorize([state['dotnet'],state['bridge']],state['appID'],onQR,onPhase=onPhase,cancel=cancel,expectedSteamID=expectedSteamID)
        return run_with_authorized_context(prepared,context,cancel=cancel)
    finally:
        if context:context.handoff.clear()

def main():
    parser=argparse.ArgumentParser(description=__doc__);mode=parser.add_mutually_exclusive_group();mode.add_argument('--prepare-only',action='store_true');mode.add_argument('--authenticate',action='store_true');parser.add_argument('--architecture',type=int,choices=[32,64],default=64);parser.add_argument('--app-id',type=int,default=1091500);args=parser.parse_args()
    if args.authenticate:raise SystemExit('Real authentication requires Root-managed onQR/onPhase callbacks through authorize_and_launch(..., allow_real_auth=True); no account request was started.')
    path=prepare(args.architecture,args.app_id);print(json.dumps({'prepared':True,'preparedState':str(path),'actualBackendNotAuth':True,'ValveExecutedOnline':False}))
if __name__=='__main__':main()
