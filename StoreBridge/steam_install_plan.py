# SPDX-License-Identifier: GPL-3.0-only
"""Pinned Steam manifest selection and read-only managed-volume admission.

A plan qualifies depot payload totals, not physical allocation/peak or wire
traffic. DepotDownloader still performs its own account/depot permission checks.
"""
import contextlib,datetime,fcntl,hashlib,json,os,pathlib,re,stat,time,uuid
from bridge import BridgeError
from state_paths import state_root
U64=2**64-1

def fail(code='invalid_install_plan'):
    raise BridgeError(code,'A current verified Steam depot selection is required')
def uint(value,maximum=U64,positive=False):
    if type(value)is not int or not (0<value<=maximum if positive else 0<=value<=maximum):fail()
    return value

def normalize(options,*,fresh=False,now=None):
    plan=options.get('expectedInstallPlan');managed=options.get('storageReservationID')is not None
    if plan is None:
        if managed:fail('install_plan_required')
        return None
    if not isinstance(plan,dict):fail()
    game=str(options.get('gameID',''));platform=options.get('platform','windows')
    if not re.fullmatch(r'[1-9][0-9]{0,9}',game)or int(game)>0xffffffff or platform not in('windows','macOS'):fail()
    if 'appID'in plan and (type(plan['appID'])is not int or plan['appID']!=int(game)):fail()
    if plan.get('platform')!=platform or plan.get('branch')!='public' or plan.get('language')!='english' or plan.get('architecture')!='64' or plan.get('verified')is not True or plan.get('status')!='available' or plan.get('source')!='steam_pics' or plan.get('basis')!='selected_depot_payload_totals':fail()
    try:
        stamp=datetime.datetime.fromisoformat(plan['calculatedAt'].replace('Z','+00:00'))
        if stamp.tzinfo is None:fail()
        age=(time.time()if now is None else now)-stamp.timestamp()
        if age < -300 or(fresh and age>3600):fail('stale_install_plan')
    except(ValueError,TypeError,KeyError,AttributeError):fail()
    depots=plan.get('selectedDepots')
    if not isinstance(depots,list)or not 0<len(depots)<=256 or type(plan.get('selectedDepotCount'))is not int or plan['selectedDepotCount']!=len(depots):fail()
    selected=[];seen=set();download=installed=0
    for depot in depots:
        if not isinstance(depot,dict):fail()
        d=uint(depot.get('depotID'),0xffffffff,True);source=uint(depot.get('sourceAppID'),0xffffffff,True);manifest=uint(depot.get('manifestID'),U64-1,True)
        if d in seen:fail()
        seen.add(d);compressed=uint(depot.get('downloadBytes'));size=uint(depot.get('installedBytes'))
        download+=compressed;installed+=size
        if download>U64 or installed>U64:fail()
        selected.append(dict(depotID=d,sourceAppID=source,manifestID=manifest,downloadBytes=compressed,installedBytes=size))
    if uint(plan.get('downloadBytes'))!=download or uint(plan.get('installedBytes'))!=installed:fail()
    selected.sort(key=lambda x:x['depotID'])
    hashed={'AppID':int(game),'Platform':platform,'Branch':'public','Language':'english','Architecture':'64','depots':[dict(DepotID=x['depotID'],SourceAppID=x['sourceAppID'],ManifestID=x['manifestID'],DownloadBytes=x['downloadBytes'],InstalledBytes=x['installedBytes'])for x in selected]}
    fingerprint=hashlib.sha256(json.dumps(hashed,separators=(',',':')).encode()).hexdigest()
    if plan.get('fingerprint')!=fingerprint:fail()
    return dict(platform=platform,branch='public',language='english',architecture='64',verified=True,status='available',source='steam_pics',basis='selected_depot_payload_totals',downloadBytes=download,installedBytes=installed,selectedDepotCount=len(selected),selectedDepots=selected,fingerprint=fingerprint,calculatedAt=plan['calculatedAt'])

def pinned_arguments(options):
    plan=normalize(options)
    if plan is None:return []
    # Lists are positional pairs in the pinned engine; do not repeat -depot.
    return ['-depot',*[str(x['depotID'])for x in plan['selectedDepots']],'-manifest',*[str(x['manifestID'])for x in plan['selectedDepots']]]

def expected_manifests(plan):
    return {str(x['depotID']):str(x['manifestID'])for x in plan['selectedDepots']}

def canonical_directory(path):
    try:
        path=pathlib.Path(path)
        if not path.is_absolute()or path==pathlib.Path('/')or path.resolve(strict=True)!=path or any(p.is_symlink()for p in(path,*path.parents)):fail('unsafe_installation')
        return os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)
    except(OSError,ValueError,TypeError,RuntimeError):fail('unsafe_installation')

def private_file(directory,name):
    fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC,dir_fd=directory)
    s=os.fstat(fd)
    if not stat.S_ISREG(s.st_mode)or s.st_uid!=os.getuid()or stat.S_IMODE(s.st_mode)!=0o600 or s.st_nlink!=1 or s.st_size>16*1024*1024:
        os.close(fd);fail('unsafe_storage_registry')
    return fd

def identifier(value):
    try:return str(uuid.UUID(value))
    except(ValueError,TypeError,AttributeError):fail('invalid_storage_reservation')

def preflight(value):
    """Check the locked Core reservation and real available blocks before spawn.

    Read-only: never releases/shrinks a reservation or creates a storage root.
    Admission cannot reserve unmodelled downloader staging/peak overhead.
    """
    options={'gameID':value['gameID'],'platform':value['platform'],'expectedInstallPlan':value.get('expectedInstallPlan'),'storageReservationID':value.get('storageReservationID')}
    plan=normalize(options)
    if plan is None:return
    target=pathlib.Path(value['installDir']);target_fd=canonical_directory(target)
    try:
        fs=os.fstatvfs(target_fd);free=fs.f_bavail*fs.f_frsize
        if options['storageReservationID']is None:
            if plan['installedBytes']>free:fail('disk_full')
            return
        with contextlib.ExitStack()as stack:
            directory=canonical_directory(state_root()/'Storage');stack.callback(os.close,directory)
            d=os.fstat(directory)
            if d.st_uid!=os.getuid()or stat.S_IMODE(d.st_mode)!=0o700:fail('unsafe_storage_registry')
            lock=private_file(directory,'registry.lock');stack.callback(os.close,lock);fcntl.flock(lock,fcntl.LOCK_SH);stack.callback(fcntl.flock,lock,fcntl.LOCK_UN)
            fd=private_file(directory,'libraries.json')
            with os.fdopen(fd,'rb')as stream:registry=json.load(stream)
            if registry.get('schema')!=1 or registry.get('kind')!='ready-game-storage-v1':fail('invalid_storage_reservation')
            libraries=registry.get('libraries');installs=registry.get('installations');reservations=registry.get('reservations')
            if not isinstance(libraries,list)or len(libraries)>1000 or not isinstance(installs,list)or len(installs)>100000 or not isinstance(reservations,list)or len(reservations)>10000:fail('invalid_storage_reservation')
            own=[x for x in reservations if identifier(x.get('id'))==identifier(options['storageReservationID'])]
            if len(own)!=1:fail('invalid_storage_reservation')
            own=own[0];library=next((x for x in libraries if identifier(x.get('id'))==identifier(own.get('libraryID'))),None)
            install=next((x for x in installs if identifier(x.get('id'))==identifier(own.get('installationID'))),None)
            if library is None or install is None or library.get('isRemoved')is not False or identifier(install.get('libraryID'))!=identifier(library['id'])or install.get('store')!='steam'or install.get('gameID')!=value['gameID']or install.get('platform')!=value['platform']or identifier(own.get('ownerProfileID'))!=identifier(value['profileID'])or(value.get('jobID')is not None and own.get('jobID')not in(None,value['jobID'])):fail('invalid_storage_reservation')
            relative=install.get('relativePath')
            if not isinstance(relative,str)or any(x in('','.','..')for x in relative.split('/'))or relative.startswith('/'):fail('invalid_storage_reservation')
            root=pathlib.Path(library['rootPath']);root_fd=canonical_directory(root);stack.callback(os.close,root_fd);s=os.fstat(root_fd)
            if s.st_dev!=library.get('deviceID')or s.st_ino!=library.get('rootFileID')or target!=root/relative or os.fstat(target_fd).st_dev!=s.st_dev:fail('unsafe_installation')
            requested=uint(own.get('requestedBytes'));remaining=uint(own.get('remainingBytes'))
            if requested<plan['installedBytes']or remaining>requested:fail('invalid_storage_reservation')
            done=value.get('bytesCompleted');done=done if type(done)is int and value.get('bytesTotal')==plan['installedBytes']and 0<=done<=plan['installedBytes']else 0
            needed=max(remaining,plan['installedBytes']-done);other=0
            for item in reservations:
                if identifier(item['id'])==identifier(own['id']):continue
                l=next((x for x in libraries if identifier(x.get('id'))==identifier(item.get('libraryID'))),None)
                if l is None:fail('invalid_storage_reservation')
                if l.get('deviceID')==s.st_dev or(library.get('volumeUUID')is not None and l.get('volumeUUID')==library.get('volumeUUID')):
                    other+=uint(item.get('remainingBytes'))
                    if other>U64:fail('invalid_storage_reservation')
            if other>free or needed>free-other:fail('disk_full')
    except BridgeError:raise
    except(OSError,ValueError,TypeError,KeyError,AttributeError,OverflowError):fail('invalid_storage_reservation')
    finally:os.close(target_fd)
