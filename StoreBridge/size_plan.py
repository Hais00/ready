# SPDX-License-Identifier: GPL-3.0-only
"""Read-only manifest size plans. Bytes are not a peak workspace requirement."""
import json,os,pathlib,re,selectors,subprocess,tempfile,time
from bridge import BridgeError,ROOT

MAX_OUTPUT=4*1024*1024
def uint64(value):
    if type(value)is int:return value if 0<=value<2**64 else None
    if isinstance(value,str) and value and len(value)<=20 and value.isascii() and value.isdecimal():
        number=int(value);return number if number<2**64 else None
    return None

def context(request):
    store=request.get('store');o=request.get('options',{});gid=o.get('gameID');platform=o.get('platform','windows');language=o.get('language','en')
    if store not in ('epic','gog','amazon'):raise BridgeError('unsupported_operation','Size planning is not available for this store')
    if not isinstance(gid,str)or not re.fullmatch(r'[A-Za-z0-9_.-]{1,200}',gid)or gid in ('.','..'):raise BridgeError('invalid_game_id','A valid store game ID is required')
    if store=='gog'and(not gid.isdecimal()or not gid.isascii()or gid.startswith('0')):raise BridgeError('invalid_game_id','A canonical GOG game ID is required')
    if platform not in ('windows','macOS'):raise BridgeError('invalid_platform','Choose Windows or macOS')
    if not isinstance(language,str)or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,31}',language):raise BridgeError('invalid_language','Choose a supported language')
    if o.get('includeDLC',False)is not False:raise BridgeError('unsupported_selection','This planner currently selects the base game only')
    return dict(store=store,gameID=gid,platform=platform,variantKey=platform,language=language)

def plan(c,installed=None,download=None,source='unknown',verified=False,reason='manifest_unavailable',status=None,**basis):
    return {**{k:c[k]for k in ('store','gameID','platform','variantKey')},'installedBytes':uint64(installed),'downloadBytes':uint64(download),
      'verified':verified,'source':source,'status':status or ('available'if installed is not None and download is not None else 'partial'if installed is not None or download is not None else'unknown'),
      'reason':reason,'basis':{'selection':'fresh_full_install','language':c['language'],'includeDLC':False,'temporarySpaceIncluded':False,'deltaComparison':False,**basis}}

def epic_plan(data,c):
    if not isinstance(data,dict)or not isinstance(data.get('game'),dict)or data['game'].get('app_name')!=c['gameID']:return plan(c,source='legendary_manifest',reason='game_identity_unconfirmed')
    manifest=data.get('manifest')
    if not isinstance(manifest,dict):return plan(c,source='legendary_manifest')
    if manifest.get('app_name')not in(None,c['gameID']):return plan(c,source='legendary_manifest',reason='game_identity_mismatch')
    installed,download=uint64(manifest.get('disk_size')),uint64(manifest.get('download_size'))
    return plan(c,installed,download,'legendary_manifest',installed is not None and download is not None,'manifest_sizes'if installed is not None else'manifest_size_missing',
      installTags='all_manifest_tags',dependenciesIncluded=False)

def gog_plan(data,c):
    if not isinstance(data,dict)or data.get('gameID')!=c['gameID']or not isinstance(data.get('selected'),dict):return plan(c,source='gogdl_manifest',reason='selected_manifest_unavailable')
    sizes=data['selected'];installed,download=uint64(sizes.get('disk_size')),uint64(sizes.get('download_size'))
    return plan(c,installed,download,'gogdl_manifest',installed is not None and download is not None,'selected_depots'if installed is not None else'manifest_size_missing',
      generation=data.get('generation')if type(data.get('generation'))is int and data['generation']in(1,2)else None,dependenciesIncluded='inline_non_redist',deduplicatedDepots=True)

def amazon_plan(data,c):
    if not isinstance(data,dict)or data.get('gameID')!=c['gameID']or data.get('signatureVerified')is not True:return plan(c,source='nile_manifest',reason='signed_manifest_unconfirmed')
    files=data.get('files');packages=uint64(data.get('packageCount'))
    if not isinstance(files,list)or packages is None:return plan(c,source='nile_manifest',reason='invalid_manifest')
    unique={}
    for entry in files:
        if not isinstance(entry,dict):return plan(c,source='nile_manifest',reason='invalid_manifest')
        path=entry.get('path');size=uint64(entry.get('size'));digest=entry.get('hash')
        if not isinstance(path,str)or not path or path.startswith(('/','\\'))or ':'in path or any(p in ('','..','.')for p in path.replace('\\','/').split('/'))or size is None or not isinstance(digest,str):return plan(c,source='nile_manifest',reason='invalid_manifest')
        key=path.replace('\\','/')
        if key in unique and unique[key]!=(size,digest):return plan(c,source='nile_manifest',reason='conflicting_manifest_files')
        unique[key]=(size,digest)
    installed=sum(item[0]for item in unique.values())
    if uint64(installed)is None:return plan(c,source='nile_manifest',reason='manifest_size_overflow')
    return plan(c,installed,None,'nile_manifest',packages==1,'download_size_not_declared'if packages==1 else'engine_multiple_packages_unverified',
      status='partial',manifestSignatureVerified=True,packageCount=packages,uniqueFiles=len(unique),dependenciesIncluded=False)

def gog_catalog_sizes(gid,installers):
    """Offline-installer totals are a labelled estimate, not gogdl depot size."""
    output={}
    if not isinstance(installers,list):return output
    for platform,osname in [('windows','windows'),('macOS','osx')]:
        candidates=[i for i in installers if isinstance(i,dict)and i.get('os')==osname and i.get('language')in('en','en-US','English')]
        if len(candidates)!=1:continue
        size=uint64(candidates[0].get('total_size'))
        if size is None:continue
        c=dict(store='gog',gameID=str(gid),platform=platform,variantKey=platform,language='en')
        output[platform]=plan(c,None,size,'gog_offline_installer_metadata',False,'offline_installer_estimate',delivery='offline_installer')
    return output

def execute(request,*,python=None,worker=None,timeout=60):
    c=context(request)
    if c['store']=='amazon'and c['platform']=='macOS':return {'plan':plan(c,source='nile_manifest',reason='platform_not_supported',status='unsupported')}
    from runtime_paths import tools_root
    from state_paths import state_root
    from install_lock import private_directory
    from backend import supervised,stop_child
    interpreter=pathlib.Path(python)if python else tools_root()/'venv/bin/python'
    if not interpreter.is_file():raise BridgeError('backend_missing','Install the open store engines before requesting a size plan')
    directory=private_directory(state_root()/'SizePlans')
    with tempfile.TemporaryDirectory(prefix='plan-',dir=directory)as scratch:
        os.chmod(scratch,0o700)
        env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','Steam','STEAM','M1L_','READY_','NILE_','LEGENDARY_','GOGDL_','PYTHONPATH','PYTHONHOME','PYTHONSTARTUP','PYTHONINSPECT'))}
        env.update(PYTHONUNBUFFERED='1',PYTHONDONTWRITEBYTECODE='1',TMPDIR=scratch+'/',XDG_CONFIG_HOME=scratch,XDG_CACHE_HOME=scratch)
        command=[str(interpreter),str(worker or ROOT/'StoreBridge/size_plan_worker.py')]
        process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,cwd=scratch,env=env,start_new_session=not supervised())
        try:
            payload={'context':c,'credentials':request.get('credentials',{}),'scratch':scratch}
            encoded=(json.dumps(payload,separators=(',',':'))+'\n').encode()
            if len(encoded)>65536:raise BridgeError('invalid_request','Size planning credentials exceeded the private frame limit')
            os.set_blocking(process.stdin.fileno(),False)
            selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ,'output');selector.register(process.stdin,selectors.EVENT_WRITE,'input')
            offset=0;output=bytearray();deadline=time.monotonic()+timeout
            try:
                while selector.get_map():
                    if time.monotonic()>=deadline:raise BridgeError('size_plan_timeout','Size metadata timed out')
                    for key,_ in selector.select(min(.1,max(0,deadline-time.monotonic()))):
                        if key.data=='input':
                            try:offset+=os.write(key.fd,encoded[offset:offset+16384])
                            except BlockingIOError:continue
                            except BrokenPipeError:raise BridgeError('size_plan_invalid','The size helper closed its private input')from None
                            if offset==len(encoded):selector.unregister(key.fileobj);process.stdin.close()
                            continue
                        chunk=os.read(key.fd,65536)
                        if not chunk:selector.unregister(key.fileobj);continue
                        output.extend(chunk)
                        if len(output)>MAX_OUTPUT:raise BridgeError('size_plan_invalid','Size metadata exceeded the limit')
            finally:selector.close()
            process.wait(timeout=max(.1,deadline-time.monotonic()))
            try:data=json.loads(output)
            except (ValueError,UnicodeDecodeError):raise BridgeError('size_plan_invalid','The size helper returned invalid metadata')from None
            if process.returncode or not isinstance(data,dict):raise BridgeError('size_plan_unavailable','The size helper could not obtain a manifest')
            credentials=data.get('credentials')if isinstance(data.get('credentials'),dict)else None
            if isinstance(data.get('sdkMetadata'),dict):data=data['sdkMetadata']
            if data.get('error'):
                allowed={'authentication_required','network_error','invalid_language','manifest_unavailable','unsupported_platform'}
                code=data['error']if isinstance(data['error'],str)and data['error']in allowed else'manifest_unavailable'
                result={'plan':plan(c,source={'epic':'legendary_manifest','gog':'gogdl_manifest','amazon':'nile_manifest'}[c['store']],reason=code)}
                if credentials is not None:result['credentials']=credentials
                return result
            parser={'epic':epic_plan,'gog':gog_plan,'amazon':amazon_plan}[c['store']]
            result={'plan':parser(data,c)}
            if credentials is not None:result['credentials']=credentials
            return result
        except subprocess.TimeoutExpired:raise BridgeError('size_plan_timeout','Size metadata timed out')from None
        finally:
            stop_child(process)
            if process.stdin and not process.stdin.closed:process.stdin.close()
            if process.stdout:process.stdout.close()
