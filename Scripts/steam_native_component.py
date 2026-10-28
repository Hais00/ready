#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare our local GPL native component and bind externally installed code.

No network, dlopen, authentication, game execution or Valve payload copying.
Bindings are references, not proof of entitlement or commercial-game readiness.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import uuid

ROOT=Path(__file__).resolve().parents[1]
WORKSPACE_MARKER='ready project work for thread01a17e79'
CLIENT_SHA='b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd'
SDK_SHA='2cbe2533e09d1561051f417d7b8c784481a2efdc4fc9d1274704ee8a7ef50cb1'
SOURCE_NAMES=['steam_native_host_session.c','steam_native_host_session.h','steam_native_host_probe.c','steam_host_credential.h','steam_native_discovery.h','steam_native_state_fs.c','steam_native_ipc_namespace.c','steam_native_discovery.c','steam_native_discovery_redirect.c','steam_native_game_api_probe.c','build_steam_native_host_session.py','steam_native_component.py']
ROLES={'host':'ready-steam-native-host-session','fsAdapter':'libReadySteamStateFS.dylib','ipcAdapter':'libReadySteamIPC.dylib','discoveryLibrary':'libReadySteamDiscovery.dylib','lookupAdapter':'libReadySteamLookup.dylib','sdkProbe':'ready-steam-native-game-api-probe'}
class ComponentError(ValueError):pass

def encoded(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)+'\n').encode()
def digest(data):return hashlib.sha256(data).hexdigest()
def canonical(path):
    p=Path(path)
    if not p.is_absolute()or str(p)!=os.path.normpath(str(p))or any(x in str(p)for x in ('\0','\\')):raise ComponentError('Canonical absolute path required')
    if p.resolve(strict=True)!=p:raise ComponentError('Aliases are not permitted')
    return p

def directory(path):
    p=canonical(path);s=p.lstat()
    if not stat.S_ISDIR(s.st_mode)or s.st_uid!=os.getuid()or s.st_mode&0o077:raise ComponentError('Private owned directory required')
    return p

def child_directory(parent,name):
    if not name or '/'in name or name in ('.','..'):raise ComponentError('Invalid child directory')
    path=parent/name
    try:path.mkdir(mode=0o700)
    except FileExistsError:pass
    return directory(path)

def checked_file(path,private=False,limit=16*1024*1024):
    p=canonical(path);fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode)or before.st_uid!=os.getuid()or before.st_mode&0o022 or(private and before.st_mode&0o077)or before.st_size>limit:raise ComponentError('Unsafe owned file')
        out=bytearray()
        while True:
            b=os.read(fd,65536)
            if not b:break
            out.extend(b)
            if len(out)>limit:raise ComponentError('File exceeds limit')
        after=os.fstat(fd);named=p.lstat()
        if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)or(named.st_dev,named.st_ino)!=(after.st_dev,after.st_ino):raise ComponentError('File changed during verification')
        return bytes(out)
    finally:os.close(fd)

def private_json(path,value):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    try:
        data=encoded(value);at=0
        while at<len(data):
            count=os.write(fd,data[at:])
            if count<=0:raise ComponentError('Short private metadata write')
            at+=count
        os.fsync(fd)
    finally:os.close(fd)

def sync_dir(path):
    fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
    try:os.fsync(fd)
    finally:os.close(fd)

@contextlib.contextmanager
def lock(path):
    fd=os.open(path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    try:
        s=os.fstat(fd)
        if not stat.S_ISREG(s.st_mode)or s.st_uid!=os.getuid()or s.st_mode&0o077 or s.st_nlink!=1:raise ComponentError('Unsafe component lock')
        fcntl.flock(fd,fcntl.LOCK_EX);yield
    finally:os.close(fd)

def workspace(path):
    p=directory(path)
    if checked_file(p/'.ready-external-workspace',private=True,limit=256).decode().strip()!=WORKSPACE_MARKER:raise ComponentError('Workspace ownership marker mismatch')
    return p

def source_capture(root=ROOT):
    return {str(Path('Scripts')/name):checked_file(root/'Scripts'/name,limit=1024*1024)for name in SOURCE_NAMES}|{'LICENSE':checked_file(root/'LICENSE',limit=1024*1024)}

def assert_sources(captured,root=ROOT):
    if any(checked_file(root/name,limit=1024*1024)!=value for name,value in captured.items()):raise ComponentError('Source changed during component build')

def inventory(root):
    result={};total=0
    for p in sorted(root.rglob('*')):
        relative=str(p.relative_to(root));s=p.lstat()
        if s.st_uid!=os.getuid()or stat.S_ISLNK(s.st_mode):raise ComponentError('Unowned object or alias in component')
        if stat.S_ISDIR(s.st_mode):continue
        if not stat.S_ISREG(s.st_mode)or len(result)>=128:raise ComponentError('Unsupported component object/count')
        data=checked_file(p);total+=len(data)
        if total>64*1024*1024:raise ComponentError('Component exceeds bounded size')
        if relative=='component.json':continue
        result[relative]={'sha256':digest(data),'bytes':len(data),'mode':stat.S_IMODE(s.st_mode)}
    return result

def static_closure(binary):
    architectures=subprocess.check_output(['/usr/bin/lipo','-archs',str(binary)],text=True).strip().split()
    if architectures!=['arm64']:raise ComponentError('Unexpected component architecture')
    output=subprocess.check_output(['/usr/bin/otool','-L',str(binary)],text=True)
    dependencies=[]
    for line in output.splitlines()[1:]:
        name=line.strip().split(' (compatibility version',1)[0]
        if name.startswith('@rpath/')and name.endswith('/'+binary.name):continue
        if not(name.startswith('/usr/lib/')or name.startswith('/System/Library/')):raise ComponentError('Non-system static dependency')
        dependencies.append(name)
    loads=subprocess.check_output(['/usr/bin/otool','-l',str(binary)],text=True)
    if 'LC_RPATH'in loads:raise ComponentError('Unexpected rpath in own component')
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(binary)],check=True,capture_output=True)
    return {'architecture':'arm64','systemDependencies':dependencies,'nonSystemDependencyFound':False,'dynamicExternalCodeNotIncluded':True}

def verify_component(component_root):
    root=directory(component_root);raw=checked_file(root/'component.json',private=True,limit=256*1024);doc=json.loads(raw)
    if doc.get('schema')!=1 or doc.get('kind')!='ready-steam-native-component-v1'or doc.get('fixtureOnly')is not False or doc.get('localOnly')is not True or doc.get('binaryDistributionApproved')is not False or doc.get('componentOwnLicense')!='GPL-3.0-only'or set(doc.get('assets',{}))!=set(ROLES):raise ComponentError('Unsupported or non-production component')
    source_hashes={str(Path('Scripts')/name):digest(checked_file(root/'sources/Scripts'/name,limit=1024*1024))for name in SOURCE_NAMES}
    source_hashes['LICENSE']=digest(checked_file(root/'sources/LICENSE',limit=1024*1024))
    recipe_raw=checked_file(root/'recipe.json',private=True,limit=128*1024);recipe=json.loads(recipe_raw)
    if doc.get('sourceHashes')!=source_hashes or recipe.get('sourceHashes')!=source_hashes or recipe.get('kind')!='ready-native-component-build-recipe-v1'or recipe.get('fixtureDefines')!=[]or recipe.get('compiler')!='/usr/bin/clang'or recipe.get('architecture')!='arm64'or doc.get('componentID')!='native-'+digest(encoded(recipe))[:24]or doc.get('recipeSHA256')!=digest(recipe_raw):raise ComponentError('Component source/recipe binding mismatch')
    host_receipt=json.loads(checked_file(root/('bin/'+ROLES['host']+'.json'),private=True,limit=128*1024))
    if host_receipt.get('fixtureOnly')is not False or host_receipt.get('sourceHashes')!={name:source_hashes['Scripts/'+name]for name in ('steam_native_host_session.c','steam_native_host_session.h','steam_native_host_probe.c','steam_host_credential.h','steam_native_discovery.h')}or host_receipt.get('binarySHA256')!=doc['assets']['host']['sha256']or host_receipt.get('buildRecipeSHA256')!=source_hashes['Scripts/build_steam_native_host_session.py']:raise ComponentError('Production host source binding mismatch')
    commands=json.loads(checked_file(root/'build.json',private=True,limit=128*1024)).get('commands',[])
    if len(commands)!=6 or any(any('-DREADY_'in str(x)for x in command)for command in commands):raise ComponentError('Unsupported build command record')
    actual=inventory(root)
    if actual!=doc.get('inventory')or digest(encoded(actual))!=doc.get('inventorySHA256'):raise ComponentError('Component inventory changed')
    marker=json.loads(checked_file(root/'.ready-native-component',private=True,limit=4096))
    if marker!={'schema':1,'kind':'ready-owned-native-component-v1','componentID':doc.get('componentID')}:raise ComponentError('Component marker mismatch')
    for role,name in ROLES.items():
        asset=doc['assets'][role]
        if asset.get('path')!='bin/'+name or actual.get(asset['path'],{}).get('sha256')!=asset.get('sha256'):raise ComponentError('Component role mismatch')
    return doc

def prepare(workspace_root,components_store):
    work=workspace(workspace_root);store=Path(components_store)
    if not store.is_absolute()or not store.is_relative_to(work)or store==work:raise ComponentError('Component store must be inside the owned workspace')
    # Only the immediate explicitly requested store is created; ancestors must exist.
    if not store.exists():directory(store.parent);store.mkdir(mode=0o700)
    store=directory(store)
    if store.stat().st_dev!=work.stat().st_dev:raise ComponentError('Component store must share the work filesystem')
    marker=store/'.ready-steam-native-component-store'
    expected={'schema':1,'kind':'ready-steam-native-component-store-v1'}
    if marker.exists():
        if json.loads(checked_file(marker,private=True,limit=4096))!=expected:raise ComponentError('Component store marker mismatch')
    else:private_json(marker,expected)
    versions=child_directory(store,'versions')
    with lock(store/'.prepare.lock'):
        captured=source_capture();source_hashes={k:digest(v)for k,v in captured.items()}
        compiler=subprocess.check_output(['/usr/bin/clang','--version'],text=True)
        recipe={'schema':1,'kind':'ready-native-component-build-recipe-v1','sourceHashes':source_hashes,'compilerVersionSHA256':digest(compiler.encode()),'architecture':'arm64','minimumCompileTarget':'14.0','fixtureDefines':[],'compiler':'/usr/bin/clang','codeSign':'ad-hoc','externalPayloadCopied':False}
        identity='native-'+digest(encoded(recipe))[:24];final=versions/identity
        if final.exists():
            result=verify_component(final)
            if result['sourceHashes']!=source_hashes:raise ComponentError('Version identity collision')
            assert_sources(captured)
            return {'componentRoot':str(final),'componentManifestSHA256':digest(checked_file(final/'component.json',private=True)),'reused':True}
        stage=store/('.stage-'+uuid.uuid4().hex);stage.mkdir(mode=0o700)
        private_json(stage/'.ready-native-component',{'schema':1,'kind':'ready-owned-native-component-v1','componentID':identity})
        sources=stage/'sources';sources.mkdir(mode=0o700);(sources/'Scripts').mkdir(mode=0o700)
        for name,data in captured.items():(sources/name).write_bytes(data)
        private_json(stage/'recipe.json',recipe)
        binary_dir=stage/'bin';binary_dir.mkdir(mode=0o700)
        tmp=child_directory(work,'tmp');cache=child_directory(work,'cache');module_cache=child_directory(cache,'steam-native-component-clang')
        environment={k:os.environ[k]for k in ('HOME','USER','LOGNAME')if k in os.environ}
        environment.update(LANG='C',LC_ALL='C')
        environment.update(TMPDIR=str(tmp)+'/',CLANG_MODULE_CACHE_PATH=str(module_cache),PATH='/usr/bin:/bin:/usr/sbin:/sbin')
        commands=[]
        command=[sys.executable,str(sources/'Scripts/build_steam_native_host_session.py'),'--output',str(binary_dir/ROLES['host'])]
        subprocess.run(command,env=environment,check=True,capture_output=True);commands.append(command)
        common=['/usr/bin/clang','-arch','arm64','-mmacosx-version-min=14.0','-std=c11','-O2','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations','-fmodules-cache-path='+str(module_cache)]
        for role,name,flags in [('fsAdapter','steam_native_state_fs.c',[]),('ipcAdapter','steam_native_ipc_namespace.c',[]),('discoveryLibrary','steam_native_discovery.c',['-lbsm','-pthread']),('lookupAdapter','steam_native_discovery_redirect.c',[]),('sdkProbe','steam_native_game_api_probe.c',[])]:
            output=binary_dir/ROLES[role];command=[*common]
            if role!='sdkProbe':command+=['-dynamiclib','-install_name','@rpath/'+output.name]
            command += [str(sources/'Scripts'/name),*flags,'-o',str(output)]
            subprocess.run(command,env=environment,check=True,capture_output=True);commands.append(command)
            subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(output)],env=environment,check=True,capture_output=True)
        closure={role:static_closure(binary_dir/name)for role,name in ROLES.items()}
        private_json(stage/'closure.json',closure)
        private_json(stage/'build.json',{'schema':1,'commands':commands,'sourceHashes':source_hashes,'genuineAccountOrSDKExecuted':False})
        assert_sources(captured)
        # No symlink is created at any stage. Freeze payload modes before hashing.
        for p in sorted(stage.rglob('*'),reverse=True):
            if p.is_file():p.chmod(0o555 if p.parent==binary_dir and p.name in ROLES.values()else 0o400)
            elif p.is_dir():p.chmod(0o500)
        tree=inventory(stage)
        manifest={'schema':1,'kind':'ready-steam-native-component-v1','componentID':identity,'fixtureOnly':False,'localOnly':True,'binaryDistributionApproved':False,'componentOwnLicense':'GPL-3.0-only','externalClientAndSDKCopied':False,'genuineSDKInteropVerified':False,'commercialGameExecutionVerified':False,'researchReferenceAppIDs':[1091500],'sourceHashes':source_hashes,'recipeSHA256':digest(checked_file(stage/'recipe.json',private=True)),'inventory':tree,'inventorySHA256':digest(encoded(tree)),'assets':{role:{'path':'bin/'+name,'sha256':tree['bin/'+name]['sha256']}for role,name in ROLES.items()}}
        private_json(stage/'component.json',manifest);(stage/'component.json').chmod(0o400)
        verify_component(stage);assert_sources(captured);publish_directory(stage,final);final.chmod(0o500);sync_dir(versions)
        return {'componentRoot':str(final),'componentManifestSHA256':digest(checked_file(final/'component.json',private=True)),'reused':False}

def game_id(value):
    if isinstance(value,bool)or not str(value).isascii()or not str(value).isdigit():raise ComponentError('Invalid AppID')
    app=int(value)
    if not 0<app<2**32 or str(app)!=str(value):raise ComponentError('Canonical positive uint32 AppID required')
    return app

def external_asset(path,expected,name):
    p=canonical(path)
    if p.name!=name:raise ComponentError('Unexpected external image name')
    data=checked_file(p,limit=256*1024*1024)
    if digest(data)!=expected:raise ComponentError('External image is not the exact supported genuine reference')
    return {'path':str(p),'sha256':expected}

def state_marker(state_root,create=False):
    root=directory(state_root);marker=root/'.ready-steam-native-component-state'
    expected={'schema':1,'kind':'ready-steam-native-component-state-v1'}
    if marker.exists():
        if json.loads(checked_file(marker,private=True,limit=4096))!=expected:raise ComponentError('State ownership marker mismatch')
    elif create:private_json(marker,expected)
    return root

def selection_root(state_root,app,create=False):
    root=state_marker(state_root,create=create)
    for name in ('Components','SteamNativeHost',str(app)):
        root=child_directory(root,name)if create else directory(root/name)
    return root

def relative_manifest(root,relative):
    if not isinstance(relative,str)or relative.startswith('/')or '\\'in relative or any(x in ('','.','..')for x in relative.split('/')):raise ComponentError('Invalid relative manifest path')
    p=canonical(root/relative)
    if not p.is_relative_to(root/'versions')or p.name!='binding.json':raise ComponentError('Manifest must be an owned version')
    return p

def verify_binding(binding_path,expected_hash=None):
    path=canonical(binding_path);raw=checked_file(path,private=True,limit=256*1024);doc=json.loads(raw)
    if expected_hash is not None and digest(raw)!=expected_hash:raise ComponentError('Binding changed')
    if doc.get('schema')!=1 or doc.get('kind')!='ready-steam-native-host-binding-v1'or doc.get('fixtureOnly')is not False or doc.get('localOnly')is not True or doc.get('binaryDistributionApproved')is not False:raise ComponentError('Unsupported binding')
    app=game_id(doc.get('gameID'))
    component_path=canonical(doc['componentManifestPath']);component=verify_component(component_path.parent)
    if digest(checked_file(component_path,private=True))!=doc['componentManifestSHA256']:raise ComponentError('Component binding changed')
    expected_assets={role:{'path':str(component_path.parent/value['path']),'sha256':value['sha256']}for role,value in component['assets'].items()if role!='sdkProbe'}
    assets=doc.get('assets',{})
    expected_assets['library']=external_asset(assets.get('library',{}).get('path',''),CLIENT_SHA,'steamclient.dylib')
    expected_assets['sdk']=external_asset(assets.get('sdk',{}).get('path',''),SDK_SHA,'libsteam_api.dylib')
    probe=component['assets']['sdkProbe'];expected_probe={'path':str(component_path.parent/probe['path']),'sha256':probe['sha256']}
    if assets!=expected_assets or doc.get('extraFiles')!=[expected_probe]or doc.get('sdkProbe')!=expected_probe:raise ComponentError('Binding asset roles changed')
    if not any(p.name=='Steam.AppBundle'for p in Path(assets['library']['path']).parents):raise ComponentError('External client must remain in its installed code bundle')
    return doc

def verify_selection(root):
    raw=checked_file(root/'selected.json',private=True,limit=8192);doc=json.loads(raw)
    if doc.get('schema')!=1 or doc.get('kind')!='ready-native-steam-host-selection-v1'or set(doc)!={'schema','kind','manifestPath','manifestSHA256'}:raise ComponentError('Invalid existing selector')
    binding=relative_manifest(root,doc['manifestPath']);value=verify_binding(binding,doc['manifestSHA256'])
    if str(value['gameID'])!=root.name:raise ComponentError('Selector AppID scope mismatch')
    return raw,doc

def select(root,selection):
    # Caller holds this AppID's private selection lock. Old selectors are copied
    # byte-for-byte BEFORE replacement, and retained forever for rollback.
    old=None
    if (root/'selected.json').exists():old,_=verify_selection(root)
    data=encoded(selection)
    if old==data:return
    history=child_directory(root,'history')
    if old is not None:
        p=history/(uuid.uuid4().hex+'.json');fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        try:
            if os.write(fd,old)!=len(old):raise ComponentError('Short history write')
            os.fsync(fd)
        finally:os.close(fd)
    temp=root/('.selected-'+uuid.uuid4().hex)
    private_json(temp,selection);os.replace(temp,root/'selected.json');sync_dir(root)

def preflight_state_layout(state,app):
    p=state
    for name in ('Components','SteamNativeHost',str(app)):
        p=p/name
        if p.exists()or p.is_symlink():directory(p)
        else:return
    for name in ('versions','history'):
        child=p/name
        if child.exists()or child.is_symlink():directory(child)
    if (p/'selected.json').exists()or(p/'selected.json').is_symlink():verify_selection(p)

def bind_game(component_root,client_path,sdk_path,gameID,stateRoot):
    root=directory(component_root);component=verify_component(root)
    client=external_asset(client_path,CLIENT_SHA,'steamclient.dylib');sdk=external_asset(sdk_path,SDK_SHA,'libsteam_api.dylib');app=game_id(gameID)
    if not any(p.name=='Steam.AppBundle'for p in Path(client['path']).parents):raise ComponentError('Installed Steam code bundle required')
    state=state_marker(stateRoot)
    preflight_state_layout(state,app)
    if state.is_relative_to(root)or root.is_relative_to(state):raise ComponentError('Component code and user state must be separate')
    component_sha=digest(checked_file(root/'component.json',private=True))
    own={role:{'path':str(root/a['path']),'sha256':a['sha256']}for role,a in component['assets'].items()}
    doc={'schema':1,'kind':'ready-steam-native-host-binding-v1','fixtureOnly':False,'localOnly':True,'binaryDistributionApproved':False,'componentOwnLicense':'GPL-3.0-only','gameID':app,'componentManifestPath':str(root/'component.json'),'componentManifestSHA256':component_sha,'assets':{**{k:v for k,v in own.items()if k!='sdkProbe'},'library':client,'sdk':sdk},'extraFiles':[own['sdkProbe']],'sdkProbe':own['sdkProbe'],'genuineSDKInteropVerified':False,'commercialGameExecutionVerified':False,'genuineEntitlementVerified':False,'externalReferencesOnly':{'library':'Proprietary installed Valve client; not copied or represented as GPL','sdk':'Proprietary installed game Steamworks image; not copied or represented as GPL'}}
    binding_id='binding-'+digest(encoded(doc))[:24]
    target=selection_root(state,app,create=True);versions=child_directory(target,'versions')
    with lock(target/'.selection.lock'):
        # Pre-existing invalid/tampered selection must not be silently replaced.
        if (target/'selected.json').exists():verify_selection(target)
        final=versions/binding_id
        if final.exists():
            existing=verify_binding(final/'binding.json')
            if existing!=doc:raise ComponentError('Existing binding version differs')
        else:
            stage=target/('.binding-'+uuid.uuid4().hex);stage.mkdir(mode=0o700)
            private_json(stage/'binding.json',doc);verify_binding(stage/'binding.json')
            publish_directory(stage,final);final.chmod(0o500);sync_dir(versions)
        selected={'schema':1,'kind':'ready-native-steam-host-selection-v1','manifestPath':str((final/'binding.json').relative_to(target)),'manifestSHA256':digest(checked_file(final/'binding.json',private=True))}
        select(target,selected)
    return {'selection':str(target/'selected.json'),'binding':str(final/'binding.json'),'bindingSHA256':selected['manifestSHA256'],'componentRoot':str(root),'genuineSDKInteropVerified':False,'commercialGameExecutionVerified':False}

def rollback(state_root,gameID,binding_id):
    app=game_id(gameID)
    if not isinstance(binding_id,str)or not binding_id.startswith('binding-')or len(binding_id)!=32 or any(c not in '0123456789abcdef'for c in binding_id[8:]):raise ComponentError('Invalid binding version')
    root=selection_root(state_root,app)
    with lock(root/'.selection.lock'):
        verify_selection(root);path=relative_manifest(root,'versions/'+binding_id+'/binding.json');doc=verify_binding(path)
        if doc['gameID']!=app:raise ComponentError('Rollback AppID mismatch')
        selected={'schema':1,'kind':'ready-native-steam-host-selection-v1','manifestPath':str(path.relative_to(root)),'manifestSHA256':digest(checked_file(path,private=True))}
        select(root,selected)
        return {'selection':str(root/'selected.json'),'binding':str(path),'bindingSHA256':selected['manifestSHA256']}

def publish_directory(source,destination):
    # Darwin RENAME_EXCL (sys/stdio.h) is atomic and never replaces a version,
    # including an unexpected empty directory. No cross-volume fallback.
    import ctypes
    libc=ctypes.CDLL(None,use_errno=True)
    fn=libc.renamex_np;fn.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];fn.restype=ctypes.c_int
    if fn(os.fsencode(source),os.fsencode(destination),4):raise OSError(ctypes.get_errno(),'Exclusive component publication failed')
    sync_dir(destination.parent)

def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='operation',required=True)
    p=sub.add_parser('prepare');p.add_argument('--workspace',type=Path,required=True);p.add_argument('--components-store',type=Path,required=True)
    p=sub.add_parser('verify');p.add_argument('--component-root',type=Path,required=True)
    p=sub.add_parser('bind');p.add_argument('--component-root',type=Path,required=True);p.add_argument('--client',type=Path,required=True);p.add_argument('--sdk',type=Path,required=True);p.add_argument('--game-id',required=True);p.add_argument('--state-root',type=Path,required=True)
    p=sub.add_parser('rollback');p.add_argument('--state-root',type=Path,required=True);p.add_argument('--game-id',required=True);p.add_argument('--binding-id',required=True)
    a=parser.parse_args()
    if a.operation=='prepare':result=prepare(a.workspace,a.components_store)
    elif a.operation=='bind':result=bind_game(a.component_root,a.client,a.sdk,a.game_id,a.state_root)
    elif a.operation=='rollback':result=rollback(a.state_root,a.game_id,a.binding_id)
    else:result={'verified':True,'componentID':verify_component(a.component_root)['componentID']}
    print(json.dumps(result,sort_keys=True))
if __name__=='__main__':main()
