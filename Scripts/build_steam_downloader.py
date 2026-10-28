#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build the pinned separate GPL-2 Steam downloader offline in an owned copy.
No account use, network fetch, engine activation or source/bin overwrite.
"""
import argparse,base64,hashlib,json,os,pathlib,shutil,subprocess,tempfile,uuid
from store_steam_tools import ROOT,canonical,owned,inventory,copy_file,sha,identity,encoded,write_new,readonly_tree,validate_sdk

def verify(version):
    version=canonical(version);owned(version,True);m=json.loads((version/'manifest.json').read_text());actual=inventory(version);actual.pop('manifest.json',None)
    if m.get('kind')!='local-ready-depot-v1' or actual!=m.get('files') or identity(actual)!=m.get('payloadFingerprintSHA256'):raise ValueError('Downloader version bytes/modes/membership changed')
    return m

def select_project(version):
    version=canonical(version);verify(version);parent=ROOT/'Runtime/Tools/StoreBridge';target=parent/'DepotDownloader';owned(parent,True);previous=None
    if target.is_symlink():
        if target.lstat().st_uid!=os.getuid():raise ValueError('Unowned downloader selector')
        previous=os.readlink(target);old=pathlib.Path(previous)
        if not old.is_absolute() or old.name!='DepotDownloader':raise ValueError('Unknown old selector')
        verify(old.parent)
    elif target.exists():raise ValueError('Unknown existing downloader directory retained')
    history=parent/'DepotDownloaderSelectionHistory';history.mkdir(mode=0o700,exist_ok=True)
    record={'schema':1,'target':str(version/'DepotDownloader'),'manifestSHA256':sha(version/'manifest.json'),'previousTarget':previous,'oldDevelopmentFallbackRetained':True}
    record_path=history/(uuid.uuid4().hex+'.json');write_new(record_path,record)
    pending=parent/('.DepotDownloader-'+uuid.uuid4().hex);pending.symlink_to(version/'DepotDownloader',target_is_directory=True);os.replace(pending,target)
    return {'history':str(record_path),**record}

def rollback_project(record_path):
    parent=ROOT/'Runtime/Tools/StoreBridge';history=parent/'DepotDownloaderSelectionHistory';record_path=canonical(record_path);owned(record_path)
    if record_path.parent!=history:raise ValueError('Owned project history required')
    record=json.loads(record_path.read_text());target=parent/'DepotDownloader'
    if not target.is_symlink() or os.readlink(target)!=record.get('target'):raise ValueError('Current selector differs; preserved')
    current=pathlib.Path(record['target']);verify(current.parent)
    if sha(current.parent/'manifest.json')!=record['manifestSHA256']:raise ValueError('Manifest changed')
    archive=history/(uuid.uuid4().hex+'.retired-link');previous=record.get('previousTarget')
    if previous is None:os.rename(target,archive)
    else:
        old=canonical(previous);verify(old.parent);archive.symlink_to(current,target_is_directory=True)
        pending=parent/('.DepotDownloader-'+uuid.uuid4().hex);pending.symlink_to(old,target_is_directory=True);os.replace(pending,target)
    return {'restoredTarget':previous,'archivedSelector':str(archive),'codeDeleted':False}

def build(workspace,sdk_root,destination):
    workspace=canonical(workspace);sdk=canonical(sdk_root);destination=canonical(destination)
    owned(workspace,True);owned(sdk,True);destination.mkdir(mode=0o700,parents=True,exist_ok=True)
    sdk_source,sdk_hash=validate_sdk(sdk)
    source_root=ROOT/'StoreBridge/Dependencies/depotdownloader';before={str(p.relative_to(source_root)):sha(p) for p in source_root.rglob('*.cs') if 'bin' not in p.parts and 'obj' not in p.parts}
    run=pathlib.Path(tempfile.mkdtemp(prefix='depot-ready-build-',dir=workspace));source=run/'source';shutil.copytree(source_root,source,symlinks=True,ignore=shutil.ignore_patterns('bin','obj','.git'),copy_function=copy_file)
    project=source/'DepotDownloader'
    from store_bootstrap import patch_depot
    patch_depot(project) # private copy only; supports a fresh unmodified upstream checkout
    lock=json.loads((ROOT/'Scripts/steam_depot_progress.lock.json').read_text());patch=ROOT/'Scripts/steam_depot_progress.patch';helper=ROOT/'Scripts/steam_depot_progress.cs'
    if sha(patch)!=lock['patchSHA256'] or sha(helper)!=lock['helperSHA256']:raise ValueError('Pinned progress recipe changed')
    for name,entry in lock['files'].items():
        if sha(project/name)!=entry['baseSHA256']:raise ValueError('Pinned downloader base changed')
    if 'READY_TOKEN_STDIN' not in (project/'Program.cs').read_text() or 'READY_TOKEN_STDIN' not in (project/'AccountSettingsStore.cs').read_text():raise ValueError('Private stdin credential patch required')
    subprocess.run(['git','apply','--check',str(patch)],cwd=project,check=True,capture_output=True);subprocess.run(['git','apply',str(patch)],cwd=project,check=True,capture_output=True)
    for name,entry in lock['files'].items():
        if hashlib.sha256((project/name).read_text(encoding='utf-8-sig').encode()).hexdigest()!=entry['patchedUTF8SHA256']:raise ValueError('Patched downloader source changed')
    copy_file(helper,project/'ReadyDownloadProgress.cs')
    csproj=project/'DepotDownloader.csproj';text=csproj.read_text(encoding='utf-8-sig')
    if '<TargetFramework>net9.0</TargetFramework>' not in text:raise ValueError('Expected pinned downloader target')
    csproj.write_text(text.replace('<TargetFramework>net9.0</TargetFramework>','<TargetFramework>net10.0</TargetFramework>'))
    source_inputs=inventory(source)
    assets=json.loads((source_root/'DepotDownloader/obj/project.assets.json').read_text());original_packages=pathlib.Path(next(iter(assets['packageFolders'])));packages=run/'nuget';packages.mkdir(mode=0o700);receipts={}
    for lib in assets['libraries'].values():
        if lib['type']!='package':continue
        package=original_packages/lib['path'];archives=list(package.glob('*.nupkg'))
        if len(archives)!=1:raise ValueError('Exact cached NuGet archive missing')
        digest=base64.b64encode(bytes.fromhex(sha(archives[0],'sha512'))).decode()
        if digest!=pathlib.Path(str(archives[0])+'.sha512').read_text().strip() or json.loads((package/'.nupkg.metadata').read_text())['contentHash']!=lib['sha512']:raise ValueError('NuGet identity changed')
        target=packages/lib['path'];target.parent.mkdir(parents=True,exist_ok=True);shutil.copytree(package,target,symlinks=True,copy_function=copy_file);receipts[lib['path']]={'archiveSHA512':digest,'contentHash':lib['sha512']}
    config=run/'NuGet.Config';config.write_text('<configuration><packageSources><clear /></packageSources></configuration>\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('READY_','DYLD_','STEAM','Steam','SB_'))}
    env.update(DOTNET_ROOT=str(sdk),DOTNET_CLI_HOME=str(run/'home'),NUGET_PACKAGES=str(packages),NUGET_HTTP_CACHE_PATH=str(run/'http-cache'),NUGET_PLUGINS_CACHE_PATH=str(run/'plugins-cache'),TMPDIR=str(workspace.parent/'tmp')+'/',DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_GENERATE_ASPNET_CERTIFICATE='false',DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true',DOTNET_EnableDiagnostics='0',MSBUILDDISABLENODEREUSE='1')
    output=run/'output';command=[str(sdk/'dotnet'),'build',str(project/'DepotDownloader.csproj'),'-c','Release','--nologo','--configfile',str(config),'-p:TargetFramework=net10.0','-p:NuGetAudit=false','-p:UseSharedCompilation=false','-nodeReuse:false','-o',str(output)]
    result=subprocess.run(command,cwd=run,env=env,capture_output=True,text=True,timeout=180);(run/'build.log').write_text(result.stdout+result.stderr)
    if result.returncode:raise RuntimeError('Pinned offline downloader build failed: '+str(run/'build.log'))
    check_source=ROOT/'Scripts/steam_depot_progress_checks.cs';copy_file(check_source,project/'ReadyDepotDownloadChecks.cs')
    fixture_command=command[:-2]+['-p:StartupObject=DepotDownloader.ReadyDepotDownloadChecks','-o',str(run/'fixture-output')]
    checked=subprocess.run(fixture_command,cwd=run,env=env,capture_output=True,text=True,timeout=180);(run/'fixture-build.log').write_text(checked.stdout+checked.stderr)
    if checked.returncode:raise RuntimeError('Downloader source fixture compile failed: '+str(run/'fixture-build.log'))
    fixture_env={**env,'READY_DOWNLOAD_PROGRESS_JSON':'1'}
    tested=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(sdk/'dotnet'),str(run/'fixture-output/DepotDownloader.dll'),str(run/'fixture-data')],env=fixture_env,cwd=run,capture_output=True,text=True,timeout=30)
    if tested.returncode:raise RuntimeError('Downloader source fixture failed')
    fixture_report=next(json.loads(line) for line in tested.stdout.splitlines() if line.startswith('{'))
    if not fixture_report.get('fixtureOnly') or not fixture_report.get('passed'):raise ValueError('Source fixture proof missing')
    (run/'source-fixtures.json').write_text(json.dumps(fixture_report,indent=2)+'\n')
    if sha(project/'ReadyDepotDownloadChecks.cs')!=sha(check_source):raise ValueError('Own generated fixture source changed')
    (project/'ReadyDepotDownloadChecks.cs').unlink()
    if before!={str(p.relative_to(source_root)):sha(p) for p in source_root.rglob('*.cs') if 'bin' not in p.parts and 'obj' not in p.parts}:raise ValueError('Original downloader source changed')
    stage=destination/('.stage-'+uuid.uuid4().hex);stage.mkdir(mode=0o700);shutil.copytree(output,stage/'DepotDownloader',symlinks=True,copy_function=copy_file)
    shutil.copytree(source,stage/'Sources',ignore=shutil.ignore_patterns('bin','obj'),copy_function=copy_file)
    for name in ['steam_depot_progress.cs','steam_depot_progress_checks.cs','steam_depot_progress.patch','steam_depot_progress.lock.json','build_steam_downloader.py','store_bootstrap.py','store_steam_tools.py','store_sdk_cache.py']:copy_file(ROOT/'Scripts'/name,stage/'Provenance'/name)
    copy_file(source/'LICENSE',stage/'LICENSE-GPL-2.txt')
    receipt={'schema':1,'kind':'source-built-ready-depot-download-protocol-v1','sourceInputs':source_inputs,'sourcePatch':lock,'nugetInputs':receipts,'sdkSource':sdk_source,'sdkArchiveSHA256':sdk_hash,'command':command,'fixtureCommand':fixture_command,'sourceFixtures':fixture_report,'targetFrameworkOverride':'net10.0','originalSourceAndBinaryUntouched':True,'realAccountAuthentication':False,'buildLogSHA256':sha(run/'build.log')}
    write_new(stage/'Provenance/build-receipt.json',receipt);write_new(stage/'DepotDownloader/.ready-download-protocol.json',{'schema':1,'protocol':'READY_DOWNLOAD_V1','privateCredentialStdin':True,'originalSourceVersion':'3.4.0','realDownloadVerified':False})
    readonly_tree(stage);files=inventory(stage);name='depotdownloader-'+identity(files)[:24];final=destination/name
    write_new(stage/'manifest.json',{'schema':1,'kind':'local-ready-depot-v1','files':files,'payloadFingerprintSHA256':identity(files),'binaryDistributionApproved':False,'scope':'Separate GPL-2 downloader with own source/progress patches; full .NET/NuGet source/notice closure not approved'})
    os.rename(stage,final)
    return {'versionRoot':str(final),'dllSHA256':sha(final/'DepotDownloader/DepotDownloader.dll'),'manifestSHA256':sha(final/'manifest.json'),'buildRoot':str(run),'realDownloadExecuted':False}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--workspace',type=pathlib.Path);p.add_argument('--sdk-root',type=pathlib.Path);p.add_argument('--destination',type=pathlib.Path);p.add_argument('--select-project',type=pathlib.Path);p.add_argument('--rollback-project',type=pathlib.Path);a=p.parse_args()
    if a.select_project:result=select_project(a.select_project)
    elif a.rollback_project:result=rollback_project(a.rollback_project)
    else:
        if not all([a.workspace,a.sdk_root,a.destination]):p.error('build requires explicit workspace/sdk-root/destination; no fetching')
        result=build(a.workspace,a.sdk_root,a.destination)
    print(json.dumps(result,indent=2))
