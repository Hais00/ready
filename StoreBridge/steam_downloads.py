# SPDX-License-Identifier: GPL-3.0-only
"""Durable Steam download adapter. Private metadata, no persisted credentials.

A download_run request owns the supervised process and inherited installation
lease. Control requests write desired state only, never signal a persisted PID.
Pause/cancel stop the owned engine without deleting game/cache/personal files.
"""
import contextlib,fcntl,hashlib,json,os,pathlib,selectors,signal,stat,subprocess,tempfile,time,uuid,zlib
from bridge import BridgeError,emit
from state_paths import state_root
from install_lock import private_directory,file_lock,installation_lease,verify_installation,identity

OPERATIONS={'download_prepare','download_run','download_status','download_list','download_control'}
PREFIX=b'READY_DOWNLOAD_V1 '
NETWORK_ERRORS={'network_error','network_timeout'}
ENGINE_ERRORS=NETWORK_ERRORS|{'authentication_required','not_authorized','disk_full','local_io','integrity_error','engine_cancelled','rate_limited'}
ACTIVE={'preparing','downloading','verifying','pausing','cancelling'}

def uid(value):
    try:return str(uuid.UUID(value))
    except (ValueError,TypeError,AttributeError):raise BridgeError('invalid_request','A canonical job/profile UUID is required') from None

def atomic(path,value):
    data=(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
    temporary=path.with_name('.'+path.name+'.'+uuid.uuid4().hex)
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,path)
    finally:temporary.unlink(missing_ok=True)

def read(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o777!=0o600 or info.st_nlink!=1 or info.st_size>1024*1024:raise BridgeError('unsafe_state_path','Private owned download metadata required')
        value=json.load(stream)
    if not isinstance(value,dict):raise BridgeError('invalid_download_state','Download metadata is invalid')
    return value

def profile_root(profile):
    current=state_root()
    for component in ['Profiles',uid(profile),'Stores','steam','DownloadQueue']:current=private_directory(current/component)
    return current

def paths(profile,job):
    root=profile_root(profile);job=uid(job);return root/(job+'.json'),root/(job+'.lock'),root/(job+'.run.lock')

def load(profile,job):
    path,_,_=paths(profile,job)
    try:value=read(path)
    except FileNotFoundError:raise BridgeError('download_not_found','This profile has no such download') from None
    if value.get('schema')!=1 or value.get('jobID')!=uid(job) or value.get('profileID')!=uid(profile):raise BridgeError('invalid_download_state','Download ownership does not match')
    return value

def mutate(profile,job,callback):
    path,lock,_=paths(profile,job)
    with file_lock(lock,fcntl.LOCK_EX,nonblocking=False):
        value=load(profile,job);callback(value);value['sequence']+=1;value['updatedAt']=time.time();atomic(path,value);return value

def busy(profile,job):
    _,_,lock=paths(profile,job)
    try:
        with file_lock(lock,fcntl.LOCK_EX,'download_busy','Download worker is still active'):return False
    except BridgeError as error:
        if error.code=='download_busy':return True
        raise

def dto(value):
    allowed=['jobID','profileID','gameID','platform','installDir','state','phase','sequence','createdAt','updatedAt','bytesCompleted','bytesTotal','networkBytesReceived','errorCode','retryable','attempts','installedVariant','launchCandidates','launchSelectionRequired','downloadComplete','executionVerified']
    result={key:value.get(key) for key in allowed if key in value}
    completed=value.get('bytesCompleted');total=value.get('bytesTotal')
    result['fraction']=None if completed is None or not total else min(completed/total,1.0 if value['state']=='completed' else 0.999999)
    return result

def installation(value):
    if not isinstance(value,str) or not value.startswith('/') or '\0' in value:raise BridgeError('invalid_path','Choose an absolute game installation directory')
    root=pathlib.Path(value).resolve();data=state_root()
    for name in ['Profiles','InstallLocks','Migration','Runtimes','Tools']:
        reserved=(data/name).resolve()
        if root.is_relative_to(reserved) or reserved.is_relative_to(root):raise BridgeError('invalid_path','Game content cannot overlap profile, engine or lock state')
    if root==pathlib.Path(root.anchor):raise BridgeError('invalid_path','A filesystem root cannot be a game installation')
    root.mkdir(parents=True,exist_ok=True)
    if not root.is_dir():raise BridgeError('invalid_path','Game installation must be a directory')
    return root

def validate_tree(target):
    cache=target/'.DepotDownloader'
    if cache.is_symlink():raise BridgeError('unsafe_installation','The depot cache cannot be an alias')
    for entry in target.rglob('*'):
        info=entry.lstat()
        if stat.S_ISLNK(info.st_mode):
            if not entry.resolve().is_relative_to(target):raise BridgeError('unsafe_installation','An installation alias leaves the game folder')
        elif stat.S_ISREG(info.st_mode) and info.st_nlink!=1:raise BridgeError('unsafe_installation','Hardlinked game files must be separated before updating')

def clean_metadata(value):
    if not isinstance(value,dict):return {}
    result={'launch':value.get('launch',[])}
    encoded=json.dumps(result)
    if len(encoded)>128*1024:raise BridgeError('invalid_launch_metadata','Launch metadata is too large')
    return result

def login_id(job):
    root=private_directory(state_root()/'DownloadCoordination')
    with file_lock(root/'loginids.lock',fcntl.LOCK_EX,nonblocking=False):
        path=root/'loginids.json'
        try:record=read(path)
        except FileNotFoundError:record={'schema':1,'next':1,'jobs':{}}
        if record.get('schema')!=1 or not isinstance(record.get('jobs'),dict):raise BridgeError('invalid_download_state','Download identity registry is invalid')
        if job not in record['jobs']:
            value=record.get('next')
            if type(value)is not int or not 0<value<=0x0fffffff:raise BridgeError('download_limit','Download identity space is exhausted')
            record['jobs'][job]=0xD0000000|value;record['next']=value+1;atomic(path,record)
        return record['jobs'][job]

def prepare(request):
    options=request.get('options',{});profile=uid(request.get('profileID'));game=str(options.get('gameID',''))
    if not game.isascii() or not game.isdecimal() or not 0<int(game)<=0xffffffff:raise BridgeError('invalid_game_id','Steam gameID must be a nonzero uint32')
    platform=options.get('platform','windows')
    if platform not in ('windows','macOS'):raise BridgeError('invalid_platform','Choose Windows or macOS')
    target=installation(options.get('installDir'));root=profile_root(profile)
    with file_lock(root/'queue.lock',fcntl.LOCK_EX,nonblocking=False):
        for path in root.glob('*.json'):
            value=read(path)
            if value.get('gameID')==game and value.get('platform')==platform and value.get('installDir')==str(target) and value.get('state') not in ('completed','cancelled'):
                return {'job':dto(value)}
        job=str(uuid.uuid4());now=time.time()
        value={'schema':1,'jobID':job,'profileID':profile,'gameID':game,'platform':platform,'installDir':str(target),'installationIdentity':list(identity(target)),'loginID':login_id(job),
               'metadata':clean_metadata(options.get('metadata',{})),'state':'queued','desiredState':'run','phase':'queued','sequence':0,'createdAt':now,'updatedAt':now,'bytesCompleted':None,'bytesTotal':None,'networkBytesReceived':None,'retryable':False,'attempts':0}
        atomic(root/(job+'.json'),value)
    return {'job':dto(value)}

def control(request):
    profile=uid(request['profileID']);job=uid(request.get('options',{}).get('jobID'));action=request.get('options',{}).get('action')
    if action not in ('pause','resume','cancel','retry'):raise BridgeError('invalid_request','Unknown download control')
    running=busy(profile,job)
    def update(value):
        if value['state']=='completed':return
        if action in ('resume','retry'):
            if running:raise BridgeError('download_busy','Wait for the current worker to finish stopping')
            value.update(state='queued',desiredState='run',phase='queued',errorCode=None,retryable=False)
        else:
            desired='paused' if action=='pause' else 'cancelled'
            value.update(desiredState=desired,state=('pausing' if action=='pause' else 'cancelling') if running else desired,phase=desired)
    return {'job':dto(mutate(profile,job,update))}

def manifest_map(path,allow_invalid=False):
    source=path/'.DepotDownloader/depot.config';info=source.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size>1024*1024:raise ValueError()
    decompressor=zlib.decompressobj(-15);data=decompressor.decompress(source.read_bytes(),1024*1024+1)
    if len(data)>1024*1024 or not decompressor.eof:raise ValueError()
    def number(at):
        result=0
        for count in range(10):
            if at>=len(data):raise ValueError()
            byte=data[at];at+=1;result|=(byte&127)<<(count*7)
            if byte<128:return result,at
        raise ValueError()
    result={};at=0
    while at<len(data):
        tag,at=number(at);length,at=number(at);end=at+length
        if tag!=10 or end>len(data):raise ValueError()
        depot=manifest=None
        while at<end:
            key,at=number(at);value,at=number(at)
            if key==8:depot=value
            elif key==16:manifest=value
            else:raise ValueError()
        if at!=end or not depot or manifest is None or (not allow_invalid and manifest in (0,2**64-1)):raise ValueError()
        result[str(depot)]=str(manifest)
    return result

def recover_cache(target):
    cache=target/'.DepotDownloader';cache.mkdir(exist_ok=True)
    source=cache/'depot.config'
    if not source.exists():return
    try:manifest_map(target,allow_invalid=True)
    except (ValueError,zlib.error,OSError):
        info=source.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or info.st_size>1024*1024:raise BridgeError('unsafe_installation','Depot cache recovery requires an owned regular metadata file')
        archive=cache/'ready-recovery';archive.mkdir(mode=0o700,exist_ok=True)
        if archive.is_symlink():raise BridgeError('unsafe_installation','Depot recovery cannot be an alias')
        os.rename(source,archive/(uuid.uuid4().hex+'.depot.config'))

def verify_completion(value):
    from backend import profile_config,game_config
    from launch_resolver import resolve_installed_launch
    target=pathlib.Path(value['installDir']);verify_installation(target,tuple(value['installationIdentity']))
    expected=value.get('_completedManifests')
    if not isinstance(expected,dict) or not expected:raise BridgeError('download_incomplete','The engine did not verify selected depot manifests')
    try:
        actual=manifest_map(target)
        if any(actual.get(str(depot))!=str(manifest) for depot,manifest in expected.items()):raise ValueError()
        for depot,manifest in expected.items():
            cache=target/'.DepotDownloader';binary=cache/(str(depot)+'_'+str(manifest)+'.manifest');checksum=cache/(binary.name+'.sha')
            if cache.resolve()!=cache or not binary.is_file() or binary.is_symlink() or checksum.is_symlink() or binary.stat().st_size>64*1024*1024 or checksum.stat().st_size!=20:raise ValueError()
            with binary.open('rb') as stream:
                if hashlib.file_digest(stream,'sha1').digest()!=checksum.read_bytes():raise ValueError()
    except (OSError,ValueError):raise BridgeError('download_incomplete','Selected depot manifest verification failed') from None
    request={'store':'steam','profileID':value['profileID'],'options':{'gameID':value['gameID'],'platform':value['platform'],'metadata':value.get('metadata',{})}}
    config=game_config(request,profile_config(request));resolved=resolve_installed_launch(request,config,config,target)
    return {key:resolved.get(key) for key in ['installedVariant','launchCandidates','launchSelectionRequired']}

def finalize(profile,job):
    value=load(profile,job)
    if value['state']!='verifying' or not value.get('_completedManifests') or value.get('_engineExitConfirmed') is not True:return value
    if value.get('desiredState')!='run':return mutate(profile,job,lambda current:current.update(state=current['desiredState'],phase=current['desiredState']))
    target=pathlib.Path(value['installDir'])
    try:
        with installation_lease(target,mode='read'):
            result=verify_completion(value)
            def complete(current):
                if current.get('desiredState')!='run':return
                current.update(result,state='completed',phase='completed',downloadComplete=True,executionVerified=False,bytesCompleted=current.get('bytesTotal'),errorCode=None,retryable=False)
            return mutate(profile,job,complete)
    except BridgeError as error:
        if error.code=='installation_busy':return value # orphan descendants still retain the writer lease
        return mutate(profile,job,lambda current:current.update(state='failed',phase='verification_failed',errorCode=error.code,retryable=False))

def status(request):
    profile=uid(request['profileID']);job=uid(request.get('options',{}).get('jobID'));value=load(profile,job)
    if not busy(profile,job):
        if value['state'] in ACTIVE and not (value.get('_completedManifests') and value.get('_engineExitConfirmed')):
            desired=value.get('desiredState');state=desired if desired in ('paused','cancelled') else 'interrupted'
            value=mutate(profile,job,lambda current:current.update(state=state,phase=state,errorCode='worker_interrupted' if state=='interrupted' else None,retryable=False))
        value=finalize(profile,job)
    elif value['state'] in ('paused','cancelled'):
        value={**value,'state':'pausing' if value['state']=='paused' else 'cancelling'}
    return {'job':dto(value)}

def list_jobs(request):
    jobs=[]
    for path in profile_root(request['profileID']).glob('*.json'):
        jobs.append(status({**request,'options':{'jobID':path.stem}})['job'])
    return {'jobs':sorted(jobs,key=lambda value:value['createdAt'])}

def numeric(value):return type(value)is int and 0<=value<=0x7fffffffffffffff

def progress(profile,job,event):
    kind=event.get('kind')
    if kind=='error':
        code=event.get('code');return code if code in ENGINE_ERRORS else 'download_failed'
    if kind not in ('plan','progress','completed'):return None
    total=event.get('totalBytes');done=event.get('completedBytes');network=event.get('networkBytesReceived')
    if not all(numeric(v) for v in [total,done,network]) or done>total:raise BridgeError('engine_protocol_error','Invalid numeric download progress')
    def update(value):
        phase=event.get('phase')
        value.update(bytesTotal=total,bytesCompleted=done,networkBytesReceived=network,phase=phase if phase in ('verifying','downloading') else ('verifying' if kind=='plan' else 'downloading'))
        if kind=='completed':
            manifests=event.get('manifests')
            if done!=total or not isinstance(manifests,dict) or not manifests or any(not str(k).isdecimal() or not str(v).isdecimal() or not 0<int(k)<=0xffffffff or not 0<int(v)<2**64-1 for k,v in manifests.items()):raise BridgeError('engine_protocol_error','Invalid completed manifest set')
            value.update(state='verifying',phase='verifying',_completedManifests={str(k):str(v) for k,v in manifests.items()})
    value=mutate(profile,job,update);emit('progress',phase=value['phase'],job=dto(value));return None

def stop_engine(process):
    if process.poll() is not None:return
    process.terminate()
    try:process.wait(timeout=1)
    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=1)

def run_job(request,engine_factory=None):
    from backend import prepare_download,profile_config,game_config
    profile=uid(request['profileID']);job=uid(request.get('options',{}).get('jobID'));_,_,run_lock=paths(profile,job)
    with file_lock(run_lock,fcntl.LOCK_EX,'download_busy','This download already has an active worker') as run_fd:
        value=load(profile,job)
        if value['state']=='completed':return {'job':dto(value),**{key:value[key] for key in ['installedVariant','launchCandidates','launchSelectionRequired'] if key in value}}
        if value['desiredState']!='run':return {'job':dto(value)}
        target=pathlib.Path(value['installDir'])
        try:verify_installation(target,tuple(value['installationIdentity']));validate_tree(target)
        except BridgeError as error:
            mutate(profile,job,lambda current:current.update(state='failed',phase='failed',errorCode=error.code,retryable=False));raise
        credentials=request.get('credentials',{})
        if not credentials.get('username') or not credentials.get('refresh_token'):raise BridgeError('authentication_required','Steam credentials are required to resume')
        run_request={'operation':'download','store':'steam','profileID':profile,'credentials':credentials,'options':{'gameID':value['gameID'],'platform':value['platform'],'installDir':str(target),'metadata':value.get('metadata',{}),'downloadJobID':job,'downloadLoginID':value['loginID']}}
        config=game_config(run_request,profile_config(run_request));cache=private_directory(config/value['platform'])
        def starting(current):
            current.update(state='preparing',phase='preparing',bytesCompleted=None,bytesTotal=None,networkBytesReceived=None,errorCode=None,retryable=False,attempts=current['attempts']+1);current.pop('_completedManifests',None);current.pop('_engineExitConfirmed',None)
        mutate(profile,job,starting);code=None;engine_error=None;stopped=None;process=None
        try:
            with installation_lease(target) as lease,file_lock(cache/'operation.lock',fcntl.LOCK_EX,'store_busy','This game/platform already has an engine') as cache_fd:
                recover_cache(target)
                with tempfile.TemporaryDirectory(prefix='ready-download-auth-',dir=os.getenv('READY_STORE_SECRET_PARENT')) as temp:
                    secret=pathlib.Path(temp);secret.chmod(0o700)
                    factory=engine_factory or prepare_download
                    args,environment,private_input,_=factory(run_request,config,secret)
                    if engine_factory is None:
                        marker=pathlib.Path(args[1]).parent/'.ready-download-protocol.json'
                        if marker.is_symlink() or not marker.is_file() or marker.stat().st_size>4096:raise BridgeError('engine_protocol_required','Install the source-built structured Steam downloader before starting a job')
                        protocol=json.loads(marker.read_text())
                        if protocol.get('schema')!=1 or protocol.get('protocol')!='READY_DOWNLOAD_V1':raise BridgeError('engine_protocol_required','Unsupported Steam download engine protocol')
                    environment={**environment,'READY_DOWNLOAD_PROGRESS_JSON':'1'}
                    process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=environment,pass_fds=lease.fds+(cache_fd,run_fd),start_new_session=False)
                    process.stdin.write(private_input.encode() if isinstance(private_input,str) else private_input or b'');process.stdin.close()
                    selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ);buffer=b'';eof=False
                    mutate(profile,job,lambda current:current.update(state='downloading',phase='preparing'))
                    while not eof or process.poll() is None:
                        desired=load(profile,job).get('desiredState')
                        if desired in ('paused','cancelled'):
                            stopped=desired;stop_engine(process);break
                        for key,_ in selector.select(.1):
                            chunk=os.read(key.fd,16384)
                            if not chunk:eof=True;selector.unregister(key.fileobj);continue
                            buffer+=chunk
                            if len(buffer)>65536 and b'\n' not in buffer:buffer=b''
                            while b'\n' in buffer:
                                line,buffer=buffer.split(b'\n',1)
                                if len(line)>65536 or not line.startswith(PREFIX):continue
                                try:event=json.loads(line[len(PREFIX):])
                                except (ValueError,UnicodeDecodeError):raise BridgeError('engine_protocol_error','Malformed structured download progress') from None
                                if not isinstance(event,dict):raise BridgeError('engine_protocol_error','Malformed download progress')
                                observed=progress(profile,job,event)
                                if observed and (engine_error is None or engine_error in ('download_failed','engine_cancelled')):engine_error=observed
                    code=process.wait();selector.close()
                    verify_installation(target,lease.identity)
        except KeyboardInterrupt:
            if process:stop_engine(process)
            mutate(profile,job,lambda current:current.update(state='interrupted',phase='interrupted',errorCode='worker_interrupted',retryable=False));raise
        except BridgeError as error:
            if process:stop_engine(process)
            mutate(profile,job,lambda current:current.update(state='failed',phase='failed',errorCode=error.code,retryable=False));raise
        except (OSError,ValueError,subprocess.SubprocessError):
            if process:stop_engine(process)
            mutate(profile,job,lambda current:current.update(state='failed',phase='failed',errorCode='local_io',retryable=False));raise BridgeError('local_io','The download could not safely continue') from None
        finally:
            if process and process.stdout:process.stdout.close()
        if stopped:
            value=mutate(profile,job,lambda current:current.update(state=stopped,phase=stopped,errorCode=None,retryable=False))
        elif code!=0:
            error=engine_error or 'download_failed';state='retry_wait' if error in NETWORK_ERRORS else 'failed'
            value=mutate(profile,job,lambda current:current.update(state=state,phase=state,errorCode=error,retryable=error in NETWORK_ERRORS))
        else:
            value=load(profile,job)
            if not value.get('_completedManifests'):
                value=mutate(profile,job,lambda current:current.update(state='failed',phase='failed',errorCode='engine_protocol_required',retryable=False))
            else:
                mutate(profile,job,lambda current:current.update(_engineExitConfirmed=True))
                value=finalize(profile,job)
        return {'job':dto(value),**{key:value[key] for key in ['installedVariant','launchCandidates','launchSelectionRequired'] if key in value}}

def dispatch(request):
    operation=request['operation']
    if operation=='download_prepare':return prepare(request)
    if operation=='download_control':return control(request)
    if operation=='download_status':return status(request)
    if operation=='download_list':return list_jobs(request)
    if operation=='download_run':return run_job(request)
    raise BridgeError('unsupported_operation','Unsupported download operation')

def legacy_download(request):
    value=prepare(request)['job'];result=run_job({**request,'options':{'jobID':value['jobID']}})
    job=result['job']
    if job['state']!='completed':raise BridgeError(job.get('errorCode') or 'download_incomplete','The download is not complete; partial game files and resume cache are retained')
    return {**result,'installDir':job['installDir'],'downloadComplete':True,'executionVerified':False}
