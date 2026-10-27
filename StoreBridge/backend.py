# SPDX-License-Identifier: GPL-3.0-or-later
"""Open download engines isolated from the app. No credentials in process arguments."""
import contextlib, fcntl, json, os, pathlib, re, shutil, signal, subprocess, sys, tempfile, time, zlib
from bridge import BridgeError, ROOT, emit, require, PUBLIC_CLIENT_IDS, inspect_native

TOOLS=ROOT/'Runtime/Tools/StoreBridge'
LEGENDARY_CACHE=('installed.json','metadata','manifests')
def transfer_legendary_cache(source,dest):
    dest.mkdir(parents=True,exist_ok=True,mode=0o700)
    for name in LEGENDARY_CACHE:
        src=source/name;target=dest/name
        if not src.exists():continue
        if src.is_dir():shutil.copytree(src,target,dirs_exist_ok=True)
        else:shutil.copy2(src,target)
def steam_request(request):
    if request['operation'] in ('download','install'):return download(request)
    dotnet=TOOLS/'dotnet/dotnet';helper=ROOT/'StoreBridge/SteamBridge/bin/Release/net10.0/ReadySteamBridge.dll'
    if not dotnet.exists() or not helper.exists():raise BridgeError('backend_missing','Build the open Steam bridge with Scripts/store_bootstrap.py first')
    env={**os.environ,'DOTNET_CLI_TELEMETRY_OPTOUT':'1','DOTNET_GENERATE_ASPNET_CERTIFICATE':'false'}
    p=subprocess.Popen([str(dotnet),str(helper)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=env,start_new_session=True)
    p.stdin.write(json.dumps(request)+'\n');p.stdin.close();result=None
    try:
        for line in p.stdout:
            try:event=json.loads(line)
            except json.JSONDecodeError:continue
            if event.get('type')=='result':result={k:v for k,v in event.items() if k!='type'}
            elif event.get('type')=='error':raise BridgeError(event.get('code','steam_error'),event.get('message','Steam failed'))
            else:emit(event.pop('type','progress'),**event)
        p.wait(timeout=15)
        if p.returncode or result is None:raise BridgeError('steam_error','Steam helper did not finish successfully')
        return result
    finally:
        if p.poll() is None:
            with contextlib.suppress(ProcessLookupError):os.killpg(p.pid,signal.SIGTERM)
            with contextlib.suppress(subprocess.TimeoutExpired):p.wait(timeout=5)
            if p.poll() is None:
                with contextlib.suppress(ProcessLookupError):os.killpg(p.pid,signal.SIGKILL)
        if p.stdout:p.stdout.close()

def profile_config(request):
    # UUID has already been validated by dispatch. No caller-controlled path components.
    path=pathlib.Path.home()/'Library/Application Support/M1Launcher/Profiles'/request['profileID']/'Stores'/request['store']
    path.mkdir(parents=True,exist_ok=True,mode=0o700);path.chmod(0o700)
    return path

def prepare_download(request,config,secrets_dir):
    c=request.get('credentials',{});o=request.get('options',{});store=request['store']
    gid=str(require(o.get('gameID'),'gameID is required'));platform=o.get('platform','windows')
    if platform not in ('windows','macOS'):raise BridgeError('invalid_platform','Choose Windows or macOS')
    path=pathlib.Path(require(o.get('installDir'),'installDir is required')).expanduser()
    if not path.is_absolute() or path==pathlib.Path('/'):raise BridgeError('invalid_path','Choose an absolute game installation directory')
    env={**os.environ,'PYTHONUNBUFFERED':'1','DOTNET_CLI_TELEMETRY_OPTOUT':'1','DOTNET_GENERATE_ASPNET_CERTIFICATE':'false'}
    py=TOOLS/'venv/bin/python'
    if store=='steam':
        if not gid.isdigit():raise BridgeError('invalid_game_id','Steam gameID must be numeric')
        require(c.get('username'),'Steam username missing');require(c.get('refresh_token'),'Steam refresh token missing')
        dll=ROOT/'StoreBridge/Dependencies/depotdownloader/DepotDownloader/bin/Release/net9.0/DepotDownloader.dll';dotnet=TOOLS/'dotnet/dotnet'
        if not dotnet.exists() or not dll.exists():raise BridgeError('backend_missing','Build the open Steam downloader first')
        env['READY_TOKEN_STDIN']='1'
        args=[str(dotnet),str(dll),'-app',gid,'-username','ready-stdin-account','-remember-password','-os','macos' if platform=='macOS' else 'windows','-osarch','64','-dir',str(path)]
        return args,env,json.dumps({'username':c['username'],'refresh_token':c['refresh_token']})+'\n',path
    if not py.exists():raise BridgeError('backend_missing','Install the open store engines with Scripts/store_bootstrap.py first')
    if store=='epic':
        # Keep download manifests across sessions, but account tokens only in an ephemeral user.json.
        ephemeral=secrets_dir/'legendary-config';transfer_legendary_cache(config/platform,ephemeral)
        (ephemeral/'user.json').write_text(json.dumps(c));(ephemeral/'user.json').chmod(0o600)
        env['LEGENDARY_CONFIG_PATH']=str(ephemeral)
        args=[str(py),'-m','legendary.cli','--yes','install',gid,'--platform','Mac' if platform=='macOS' else 'Windows','--base-path',str(path.parent),'--game-folder',path.name,'--skip-dlcs']
    elif store=='gog':
        auth=secrets_dir/'gog-auth.json';auth.write_text(json.dumps({PUBLIC_CLIENT_IDS['gog'][0]:{**c,'loginTime':time.time()}}));auth.chmod(0o600)
        env['GOGDL_CONFIG_PATH']=str(config/platform)
        args=[str(py),'-m','gogdl.cli','--auth-config-path',str(auth),'download',gid,'--platform','osx' if platform=='macOS' else 'windows','--path',str(path),'--lang',o.get('language','en'),'--skip-dlcs']
    else:
        if platform=='macOS':raise BridgeError('unsupported_platform','Amazon Games does not advertise a macOS build through this API')
        creds=secrets_dir/'amazon-auth.json';creds.write_text(json.dumps(c));creds.chmod(0o600)
        env['READY_CREDENTIAL_FILE']=str(creds);env['NILE_CONFIG_PATH']=str(secrets_dir/'nile-config')
        args=[str(py),str(ROOT/'StoreBridge/nile_runner.py'),'install',gid,'--path',str(path)]
    return args,env,None,path

def steam_manifest_ids(path):
    """Read DepotDownloader's deflated protobuf map without trusting log text."""
    source=path/'.DepotDownloader/depot.config'
    if not source.is_file() or source.stat().st_size>1024*1024:return []
    compressed=source.read_bytes()
    try:data=zlib.decompress(compressed,-15)
    except zlib.error:return []
    if len(data)>1024*1024:return []
    def varint(data,at):
        value=0
        for shift in range(0,70,7):
            if at>=len(data):raise ValueError('truncated protobuf')
            byte=data[at];at+=1;value|=(byte&127)<<shift
            if not byte&128:return value,at
        raise ValueError('invalid protobuf')
    entries=[];at=0
    try:
        while at<len(data):
            key,at=varint(data,at)
            if key!=10:return []
            size,at=varint(data,at);end=at+size
            if end>len(data):return []
            manifest=None
            while at<end:
                tag,at=varint(data,at);value,at=varint(data,at)
                if tag==16:manifest=value
                elif tag!=8:return []
            if manifest is not None:entries.append(manifest)
        return entries
    except ValueError:return []

def completion_proof(request,config,secret_dir,path):
    store=request['store'];o=request.get('options',{});gid=str(o['gameID']);platform=o.get('platform','windows')
    try:
        if store=='steam':
            manifests=steam_manifest_ids(path)
            return bool(manifests) and all(m not in (0,2**64-1) for m in manifests)
        if store=='epic':
            ledger=json.loads((secret_dir/'legendary-config/installed.json').read_text());entry=ledger.get(gid,{})
            return bool(entry) and not entry.get('needs_verification',False) and pathlib.Path(entry.get('install_path','')).resolve()==path.resolve()
        if store=='gog':
            manifest=config/platform/'heroic_gogdl/manifests'/gid
            return manifest.is_file() and not (path/'.gogdl-resume').exists()
        ledger=json.loads((secret_dir/'nile-config/nile/installed.json').read_text())
        return any(str(e.get('id'))==gid and pathlib.Path(e.get('path','')).resolve()==path.resolve() for e in ledger)
    except (OSError,ValueError,TypeError):return False

def installed_variants(path,platform):
    output=[]
    if not path.exists():return output
    for item in path.rglob('*'):
        if len(output)>=40:break
        if platform=='macOS' and item.suffix=='.app':
            try:
                info=inspect_native(str(item));output.append({'id':'mac:'+item.name,'platform':'macOS','architecture':info['architecture'],'executable':info['path'],'arguments':[],'installed':True,'verification':info['verification']})
            except BridgeError:continue
        elif platform=='windows' and item.suffix.lower()=='.exe' and not any(v in item.name.lower() for v in ('unins','redist','setup','crashreport')):
            output.append({'id':'win:'+item.name,'platform':'windows','architecture':'unknown','executable':str(item),'arguments':[],'installed':True,'verification':'Executable candidate; choose the game launch configuration'})
    return output

def download(request):
    config=profile_config(request);creds=request.get('credentials',{})
    with (config/'operation.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise BridgeError('store_busy','This profile already has a store operation running') from None
        with tempfile.TemporaryDirectory(prefix='ready-auth-') as temp:
            secret_dir=pathlib.Path(temp);secret_dir.chmod(0o700)
            args,env,stdin,path=prepare_download(request,config,secret_dir)
            refreshed=None
            emit('progress',phase='download',fraction=0.0)
            p=None
            try:
                p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env,start_new_session=True,bufsize=1)
                if stdin:p.stdin.write(stdin)
                p.stdin.close()
                last=-1.0
                for line in p.stdout:
                    # Raw upstream log lines can contain bearer URLs or account data. Never forward them.
                    match=re.search(r'(?<!\d)(\d{1,3}(?:\.\d+)?)\s*%',line)
                    if match:
                        fraction=min(float(match.group(1))/100,1.0)
                        if fraction!=last:emit('progress',phase='download',fraction=fraction);last=fraction
                code=p.wait()
                if code:raise BridgeError('download_failed','The store download engine failed; the partial download can be resumed')
                epic_config=secret_dir/'legendary-config'
                if request['store']=='epic' and (epic_config/'user.json').exists():refreshed=json.loads((epic_config/'user.json').read_text())
                variants=installed_variants(path,request.get('options',{}).get('platform','windows'))
                if not path.exists() or not any(path.iterdir()):raise BridgeError('download_incomplete','The engine exited without installing game content')
                if not completion_proof(request,config,secret_dir,path):raise BridgeError('download_incomplete','The store engine did not record a completed installation')
                emit('progress',phase='download',fraction=1.0)
                return {'installDir':str(path),'variants':variants,'credentials':refreshed or creds,'launchSelectionRequired':len(variants)!=1,'downloadComplete':True,'executionVerified':False}
            finally:
                if p is not None and p.poll() is None:
                    with contextlib.suppress(ProcessLookupError):os.killpg(p.pid,signal.SIGTERM)
                    with contextlib.suppress(subprocess.TimeoutExpired):p.wait(timeout=5)
                    if p.poll() is None:
                        with contextlib.suppress(ProcessLookupError):os.killpg(p.pid,signal.SIGKILL)
                if p is not None and p.stdout:p.stdout.close()
                if request['store']=='epic':transfer_legendary_cache(secret_dir/'legendary-config',config/request.get('options',{}).get('platform','windows'))
                # Legendary may atomically replace the credential file after token refresh.
                for name in ('user.json','user.json.lock'):
                    with contextlib.suppress(FileNotFoundError):(config/name).unlink()
