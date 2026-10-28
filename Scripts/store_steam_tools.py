#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline normal SteamBridge build + versioned local central-tools publication.

No account operations, provider/runtime-config activation or user pointer writes.
The fixed project SteamBridge path can select a verified version by atomic link;
old versions and the historical development build remain recoverable.
"""
import argparse,base64,ctypes,hashlib,json,os,pathlib,shutil,stat,subprocess,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]

def sha(path,kind='sha256'):
    with pathlib.Path(path).open('rb') as stream:return hashlib.file_digest(stream,kind).hexdigest()
def encoded(value):return (json.dumps(value,sort_keys=True,indent=2)+'\n').encode()
def identity(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def canonical(path):
    path=pathlib.Path(path)
    if not path.is_absolute() or path.resolve()!=path or path==pathlib.Path('/'):raise ValueError('Canonical owned path required')
    return path

def owned(path,directory=False):
    info=pathlib.Path(path).lstat()
    if info.st_uid!=os.getuid() or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):raise ValueError('Owned normal path required')
    return info

def inventory(root):
    result={}
    for p in sorted(pathlib.Path(root).rglob('*')):
        info=p.lstat();relative=str(p.relative_to(root))
        if stat.S_ISLNK(info.st_mode):result[relative]={'kind':'symlink','target':os.readlink(p)}
        elif stat.S_ISREG(info.st_mode):result[relative]={'kind':'file','sha256':sha(p),'bytes':info.st_size,'mode':stat.S_IMODE(info.st_mode)}
        elif not stat.S_ISDIR(info.st_mode):raise ValueError('Special tool file refused')
    return result

def copy_file(source,target):
    target=pathlib.Path(target);target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    if target.exists() or target.is_symlink():raise ValueError('Build copy never overwrites')
    clone=getattr(ctypes.CDLL(None,use_errno=True),'clonefile',None)
    if clone:
        clone.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];clone.restype=ctypes.c_int
        if clone(os.fsencode(source),os.fsencode(target),1)==0:return str(target)
    shutil.copy2(source,target,follow_symlinks=False);return str(target)

def source_copy(source,target):
    shutil.copytree(source,target,symlinks=True,ignore=shutil.ignore_patterns('bin','obj','.git','__pycache__'),copy_function=copy_file)

def write_new(path,value):
    path=pathlib.Path(path);path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:stream.write(encoded(value));stream.flush();os.fsync(stream.fileno())

def apply_steamkit_patch(vendor):
    vendor=canonical(vendor);owned(vendor,True)
    if vendor.is_relative_to(ROOT/'Vendor'):raise ValueError('Never patch the normal upstream source tree')
    lock=json.loads((ROOT/'Scripts/steamkit_websocket_close.lock.json').read_text())
    patch=ROOT/'Scripts/steamkit_websocket_close.patch';target=vendor/lock['path']
    if sha(patch)!=lock['patchSHA256']:raise ValueError('Patch file changed')
    if sha(target)==lock['patchedSHA256']:return lock
    if sha(target)!=lock['baseSHA256']:raise ValueError('Pinned SteamKit base changed')
    subprocess.run(['git','apply','--check',str(patch)],cwd=vendor,check=True,capture_output=True)
    subprocess.run(['git','apply',str(patch)],cwd=vendor,check=True,capture_output=True)
    if sha(target)!=lock['patchedSHA256']:raise ValueError('Pinned patch output changed')
    return lock

def validate_sdk(sdk):
    # Only read/verify the original compact-cache metadata; no constructor,
    # restore, download, or write against the normal Runtime/Tools tree.
    import store_sdk_cache as cache_module
    tools=ROOT/'Runtime/Tools/StoreBridge'
    cache=cache_module.SDKCache.__new__(cache_module.SDKCache)
    cache.sdk=sdk;cache.source=tools/'source.json';cache.cache=tools/'sdk-cache';cache.manifest=cache.cache/'manifest.json'
    m=cache.load()
    if cache_module.snapshot(sdk)!=m['entries']:raise ValueError('Explicit SDK build tools differ from pinned cache')
    for name in ['dotnet','host','shared','LICENSE.txt','ThirdPartyNotices.txt']:
        a=tools/'dotnet'/name;b=sdk/name
        if a.is_dir():
            if inventory(a)!=inventory(b):raise ValueError('SDK runtime copy changed')
        elif sha(a)!=sha(b):raise ValueError('SDK runtime input changed')
    return json.loads(cache.source.read_text()),m['archiveSHA256']

def seed_nuget(destination):
    selected={}
    for path in [ROOT/'StoreBridge/SteamBridge/obj/project.assets.json',ROOT/'Vendor/steamkit/SteamKit2/SteamKit2/obj/project.assets.json']:
        assets=json.loads(path.read_text());base=pathlib.Path(next(iter(assets['packageFolders'])))
        for item in assets['libraries'].values():
            if item['type']=='package':selected[item['path']]=(base/item['path'],item.get('sha512'))
    receipt={}
    for relative,(source,content_hash) in selected.items():
        archives=list(source.glob('*.nupkg'))
        if len(archives)!=1:raise ValueError('Exact cached package archive required; no network fallback')
        raw=base64.b64encode(bytes.fromhex(sha(archives[0],'sha512'))).decode()
        if raw!=pathlib.Path(str(archives[0])+'.sha512').read_text().strip() or json.loads((source/'.nupkg.metadata').read_text()).get('contentHash')!=content_hash:raise ValueError('NuGet archive/content identity changed')
        target=destination/relative;target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        shutil.copytree(source,target,symlinks=True,copy_function=copy_file)
        if inventory(source)!=inventory(target):raise ValueError('NuGet input copy changed')
        receipt[relative]={'rawArchiveSHA512Base64':raw,'contentHash':content_hash}
    return receipt

def verify_version(version):
    version=canonical(version);owned(version,True)
    manifest_path=version/'manifest.json';owned(manifest_path);m=json.loads(manifest_path.read_text())
    if m.get('schema')!=1 or m.get('kind')!='ready-local-steam-tools-v1':raise ValueError('Unknown tools manifest')
    actual=inventory(version);actual.pop('manifest.json',None)
    if actual!=m['files'] or identity(actual)!=m['payloadFingerprintSHA256']:raise ValueError('Central tools content/membership/modes changed')
    if m.get('binaryDistributionApproved') is not False:raise ValueError('Local version cannot imply distribution approval')
    return m

def readonly_tree(root):
    for p in pathlib.Path(root).rglob('*'):
        if p.is_file() and not p.is_symlink():p.chmod(0o555 if p.stat().st_mode&0o111 else 0o444)

def build(*,workspace,sdk_root,tools_store,downloader_root=None):
    recipe_before=sha(pathlib.Path(__file__))
    bootstrap_before=sha(ROOT/'Scripts/store_bootstrap.py')
    workspace=canonical(workspace);owned(workspace,True);sdk=canonical(sdk_root);owned(sdk,True)
    store=canonical(tools_store)
    store.mkdir(mode=0o700,parents=True,exist_ok=True);owned(store,True)
    if shutil.disk_usage(store).free<1024*1024*1024:raise OSError('Central tools reserve unavailable')
    sdk_source,sdk_archive=validate_sdk(sdk)
    run=pathlib.Path(tempfile.mkdtemp(prefix='steam-tools-build-',dir=workspace));run.chmod(0o700)
    write_new(run/'.ready-store-steam-build',{'schema':1,'kind':'owned-steam-tools-build'})
    source=run/'source';project=source/'StoreBridge/SteamBridge';project.mkdir(mode=0o700,parents=True)
    project_files=[*sorted((ROOT/'StoreBridge/SteamBridge').glob('*.cs')),ROOT/'StoreBridge/SteamBridge/SteamBridge.csproj']
    project_inputs={path.name:sha(path)for path in project_files}
    for source_file in project_files:copy_file(source_file,project/source_file.name)
    vendor=source/'Vendor/steamkit';source_copy(ROOT/'Vendor/steamkit',vendor)
    original=ROOT/'Vendor/steamkit';original_patch=original/json.loads((ROOT/'Scripts/steamkit_websocket_close.lock.json').read_text())['path']
    upstream_before=sha(original_patch);patch=apply_steamkit_patch(vendor)
    source_inputs=inventory(source);packages=run/'nuget';packages.mkdir(mode=0o700);nuget=seed_nuget(packages)
    config=run/'NuGet.Config';config.write_text('<configuration><packageSources><clear /></packageSources></configuration>\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('READY_','DYLD_','STEAM','Steam','SB_'))}
    temporary=workspace/'tmp';temporary.mkdir(mode=0o700,exist_ok=True)
    env.update(DOTNET_ROOT=str(sdk),DOTNET_CLI_HOME=str(run/'home'),NUGET_PACKAGES=str(packages),NUGET_HTTP_CACHE_PATH=str(run/'http-cache'),NUGET_PLUGINS_CACHE_PATH=str(run/'plugins-cache'),XDG_CACHE_HOME=str(run/'cache'),TMPDIR=str(temporary)+'/',DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_GENERATE_ASPNET_CERTIFICATE='false',DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true',DOTNET_EnableDiagnostics='0',MSBUILDDISABLENODEREUSE='1',DOTNET_MULTILEVEL_LOOKUP='0')
    # A normal source build, not an import from a research fixture's output.
    output=run/'output'
    command=[str(sdk/'dotnet'),'build',str(project/'SteamBridge.csproj'),'-c','Release','--nologo','--configfile',str(config),'-p:TargetFrameworks=net10.0','-p:NuGetAudit=false','-p:UseSharedCompilation=false','-nodeReuse:false','-o',str(output)]
    result=subprocess.run(command,cwd=run,env=env,capture_output=True,text=True,timeout=180);(run/'build.log').write_text(result.stdout+result.stderr)
    if result.returncode:raise RuntimeError('Offline SteamBridge source build failed; retained private build log')
    current_project_files=[*sorted((ROOT/'StoreBridge/SteamBridge').glob('*.cs')),ROOT/'StoreBridge/SteamBridge/SteamBridge.csproj']
    if sha(original_patch)!=upstream_before or {path.name:sha(path)for path in current_project_files}!=project_inputs or any(sha(project/name)!=digest for name,digest in project_inputs.items()):raise ValueError('Source input changed during build')
    if sha(pathlib.Path(__file__))!=recipe_before or sha(ROOT/'Scripts/store_bootstrap.py')!=bootstrap_before:raise ValueError('Source build recipe changed while compiling')
    stage=store/('.stage-'+uuid.uuid4().hex);stage.mkdir(mode=0o700)
    shutil.copytree(output,stage/'SteamBridge',symlinks=True,copy_function=copy_file)
    runtime=stage/'dotnet';runtime.mkdir(mode=0o700)
    for name in ['dotnet','host','shared','LICENSE.txt','ThirdPartyNotices.txt']:
        a=sdk/name;b=runtime/name
        if a.is_dir():shutil.copytree(a,b,symlinks=True,copy_function=copy_file)
        else:copy_file(a,b)
    source_copy(source,stage/'Sources')
    for name in ['LICENSE','StoreBridge/NOTICE','Vendor/steamkit.source.json','Scripts/steamkit_websocket_close.lock.json','Scripts/steamkit_websocket_close.patch','Scripts/store_steam_tools.py','Scripts/store_bootstrap.py']:
        copy_file(ROOT/name,stage/'Provenance'/name)
    copy_file(original_patch,stage/'Provenance/WebSocketContext.original.cs')
    copy_file(original/'LICENSE',stage/'Licenses/SteamKit-LGPL-2.1.txt')
    for relative in nuget:
        for archive in (packages/relative).glob('*.nupkg'):copy_file(archive,stage/'BuildInputs/NuGet'/relative/archive.name)
    aliases={}
    for name,target in [('venv',ROOT/'Runtime/Tools/StoreBridge/venv'),('DepotDownloader',ROOT/'StoreBridge/Dependencies/depotdownloader/DepotDownloader/bin/Release/net9.0')]:
        if name=='DepotDownloader':
            if downloader_root is not None:target=canonical(downloader_root)
            elif (ROOT/'Runtime/Tools/StoreBridge/DepotDownloader').exists():target=(ROOT/'Runtime/Tools/StoreBridge/DepotDownloader').resolve(strict=True)
        if target.is_dir():
            (stage/name).symlink_to(target,target_is_directory=True)
            aliases[name]={'path':str(target),'inventorySHA256':identity(inventory(target)),'readOnlyUseContract':True,'portable':False}
    # Real non-account executions against the staged complete runtime closure.
    guarded=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)(deny file-read* (subpath '+json.dumps(str(sdk))+'))(deny file-read* (subpath '+json.dumps(str(run))+'))']
    runtime_env={'PATH':'/usr/bin:/bin','DOTNET_ROOT':str(runtime),'DOTNET_CLI_TELEMETRY_OPTOUT':'1','DOTNET_GENERATE_ASPNET_CERTIFICATE':'false','DOTNET_EnableDiagnostics':'0','TMPDIR':str(temporary)+'/'}
    process=subprocess.run([*guarded,str(runtime/'dotnet'),str(stage/'SteamBridge/ReadySteamBridge.dll')],input='{"operation":"self_test"}\n',text=True,capture_output=True,env=runtime_env,cwd=stage,timeout=30)
    self_test=json.loads(process.stdout);assert process.returncode==0 and self_test.get('type')=='result' and self_test.get('helper')=='SteamKit2'
    invalid=subprocess.run([*guarded,str(runtime/'dotnet'),str(stage/'SteamBridge/ReadySteamBridge.dll')],input='{"operation":"authorize_game","options":{"gameID":"0"}}\n',text=True,capture_output=True,env=runtime_env,cwd=stage,timeout=30)
    assert invalid.returncode==1 and json.loads(invalid.stdout).get('code')=='invalid_game_id'
    receipt={'schema':1,'kind':'normal-offline-steambridge-source-build','command':command,'sdkSource':sdk_source,'sdkBuildtoolsArchiveSHA256':sdk_archive,'sourceInputs':source_inputs,'nugetArchives':nuget,'steamKitPatch':patch,'programSourceSHA256':sha(project/'Program.cs'),'recipeSHA256':recipe_before,'bootstrapSHA256':bootstrap_before,'buildLogSHA256':sha(run/'build.log'),'selfTestPassed':True,'invalidRequestRejectedWithoutNetwork':True,'realAuthenticationAttempted':False,'sourceBuildScratchRequiredAtRuntime':False}
    write_new(stage/'Provenance/build-receipt.json',receipt)
    readonly_tree(stage);files=inventory(stage);version_id='steambridge-'+identity(files)[:24];final=store/version_id
    manifest={'schema':1,'kind':'ready-local-steam-tools-v1','version':version_id,'payloadFingerprintSHA256':identity(files),'files':files,'steamBridge':'SteamBridge/ReadySteamBridge.dll','dotnet':'dotnet/dotnet','sourceRecipe':'Provenance/Scripts/store_steam_tools.py','externalReadOnlyDependencies':aliases,'localOnly':True,'binaryDistributionApproved':False,'licenseScope':'Ready source GPL-3.0-only; patched SteamKit LGPL-2.1-only; Microsoft/NuGet/other tools retain own terms. Whole tools source/notice/distribution closure is not approved.'}
    write_new(stage/'manifest.json',manifest);(stage/'manifest.json').chmod(0o444)
    if final.exists():raise ValueError('Version destination already exists; never overwritten')
    os.rename(stage,final);verify_version(final)
    return {'versionRoot':str(final),'manifestSHA256':sha(final/'manifest.json'),'helperSHA256':sha(final/'SteamBridge/ReadySteamBridge.dll'),'runtimeRoot':str(final/'dotnet'),'buildRoot':str(run),'sourceBuildReceiptSHA256':sha(final/'Provenance/build-receipt.json')}

def select_project(version):
    version=canonical(version);manifest=verify_version(version)
    target=ROOT/'Runtime/Tools/StoreBridge/SteamBridge';parent=target.parent;owned(parent,True)
    previous=None
    if target.is_symlink():
        if target.lstat().st_uid!=os.getuid():raise ValueError('Unowned helper selector refused')
        previous=os.readlink(target)
        old=pathlib.Path(previous)
        if not old.is_absolute() or old.name!='SteamBridge':raise ValueError('Unknown previous helper selection')
        verify_version(old.parent)
    elif target.exists():raise ValueError('Existing non-pointer helper preserved; selection refused')
    history=parent/'SteamBridgeSelectionHistory';history.mkdir(mode=0o700,exist_ok=True);owned(history,True)
    record={'schema':1,'version':manifest['version'],'target':str(version/'SteamBridge'),'manifestSHA256':sha(version/'manifest.json'),'previousTarget':previous,'previousDevelopmentFallbackRetained':True}
    write_new(history/(uuid.uuid4().hex+'.json'),record)
    pending=parent/('.SteamBridge-'+uuid.uuid4().hex);pending.symlink_to(version/'SteamBridge',target_is_directory=True);os.replace(pending,target)
    return record

def rollback_project(record_path):
    parent=ROOT/'Runtime/Tools/StoreBridge';history=parent/'SteamBridgeSelectionHistory'
    record_path=canonical(record_path);owned(record_path)
    if record_path.parent!=history:raise ValueError('Only owned project selection history may be restored')
    record=json.loads(record_path.read_text());target=parent/'SteamBridge'
    if record.get('schema')!=1 or not target.is_symlink() or target.lstat().st_uid!=os.getuid() or os.readlink(target)!=record.get('target'):raise ValueError('Current helper differs from the reviewed selection')
    current=pathlib.Path(record['target']);verify_version(current.parent)
    if sha(current.parent/'manifest.json')!=record['manifestSHA256']:raise ValueError('Selected manifest changed')
    previous=record.get('previousTarget')
    archived=history/(uuid.uuid4().hex+'.retired-link')
    if previous is None:
        os.rename(target,archived)
    else:
        old=canonical(previous)
        if old.name!='SteamBridge':raise ValueError('Unexpected previous helper directory')
        verify_version(old.parent)
        # Retain the former selector itself, in addition to all immutable code.
        archived.symlink_to(current,target_is_directory=True)
        pending=parent/('.SteamBridge-'+uuid.uuid4().hex);pending.symlink_to(old,target_is_directory=True);os.replace(pending,target)
    result={'schema':1,'action':'rollback-helper-selection','restoredTarget':previous,'archivedSelector':str(archived),'developmentFallbackUsed':previous is None,'codeDeleted':False}
    write_new(history/(uuid.uuid4().hex+'.json'),result);return result

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);commands=parser.add_subparsers(dest='operation',required=True)
    command=commands.add_parser('build');command.add_argument('--workspace',type=pathlib.Path,required=True);command.add_argument('--sdk-root',type=pathlib.Path,required=True);command.add_argument('--tools-store',type=pathlib.Path,required=True);command.add_argument('--select-project-helper',action='store_true')
    command=commands.add_parser('verify');command.add_argument('version',type=pathlib.Path)
    command=commands.add_parser('select-project');command.add_argument('version',type=pathlib.Path)
    command=commands.add_parser('rollback-project');command.add_argument('history_record',type=pathlib.Path)
    args=parser.parse_args()
    if args.operation=='build':
        result=build(workspace=args.workspace,sdk_root=args.sdk_root,tools_store=args.tools_store)
        if args.select_project_helper:result['selection']=select_project(pathlib.Path(result['versionRoot']))
    elif args.operation=='verify':result=verify_version(args.version)
    elif args.operation=='select-project':result=select_project(args.version)
    else:result=rollback_project(args.history_record)
    print(json.dumps(result,indent=2))
