#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Fetch pinned OPEN store helpers and build locally. Never fetch GameNative closed helpers."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, sys, tarfile, urllib.request, venv
ROOT=pathlib.Path(__file__).resolve().parents[1]
ENV={**os.environ,'DOTNET_CLI_TELEMETRY_OPTOUT':'1','DOTNET_SKIP_FIRST_TIME_EXPERIENCE':'1','DOTNET_GENERATE_ASPNET_CERTIFICATE':'false'}
def run(*args,**kw):subprocess.run([str(a) for a in args],check=True,env=ENV,**kw)
def sources():
    lock=json.loads((ROOT/'StoreBridge/dependencies.lock.json').read_text());base=ROOT/'StoreBridge/Dependencies';base.mkdir(exist_ok=True)
    for d in lock:
        target=base/d.get('directory',d['name'])
        if target.is_dir() and any(target.iterdir()):continue
        archive=base/(d['name']+'.tar.gz');data=urllib.request.urlopen(d['source_url'],timeout=90).read()
        if hashlib.sha256(data).hexdigest()!=d['source_sha256']:raise RuntimeError('Source hash mismatch: '+d['name'])
        archive.write_bytes(data);stage=base/(d['name']+'.extract');stage.mkdir(exist_ok=True)
        def safe_filter(info,destination):
            if info.issym() and os.path.isabs(info.linkname):return None
            return tarfile.data_filter(info,destination)
        with tarfile.open(archive) as t:t.extractall(stage,filter=safe_filter)
        next(stage.iterdir()).rename(target);stage.rmdir();archive.unlink()
def install_python():
    root=ROOT/'Runtime/Tools/StoreBridge';target=root/'venv'
    if not (target/'bin/python').exists():venv.EnvBuilder(with_pip=True).create(target)
    # Upstream Nile's sdist has an extra assets/ directory and setuptools refuses
    # automatic package discovery. This packaging-only patch is reproducible.
    nile=ROOT/'StoreBridge/Dependencies/nile/pyproject.toml'
    text=nile.read_text()
    if '[tool.setuptools.packages.find]' not in text:
        nile.write_text(text+'\n[tool.setuptools.packages.find]\ninclude = ["nile*"]\n')
    run(target/'bin/python','-m','pip','install','--disable-pip-version-check',ROOT/'StoreBridge/Dependencies/legendary',ROOT/'StoreBridge/Dependencies/gogdl',ROOT/'StoreBridge/Dependencies/nile')
    with (ROOT/'Evidence/stores-python-packages.txt').open('w') as out:run(target/'bin/python','-m','pip','freeze',stdout=out)
def patch_depot():
    # Separate GPL-2 tool, communicating over stdin/stdout; never linked into the GPL-3 app.
    source=ROOT/'StoreBridge/Dependencies/depotdownloader/DepotDownloader'
    program=source/'Program.cs';text=program.read_text(encoding='utf-8-sig')
    if 'READY_TOKEN_STDIN' not in text:
        needle='ContentDownloader.Config.RememberPassword = HasParameter(args, "-remember-password");'
        replacement='''// Ready patch: credentials arrive through private stdin, never process arguments.
            if (Environment.GetEnvironmentVariable("READY_TOKEN_STDIN") == "1")
            {
                using var readyDoc = System.Text.Json.JsonDocument.Parse(Console.ReadLine() ?? "{}");
                username = readyDoc.RootElement.GetProperty("username").GetString();
                var readyToken = readyDoc.RootElement.GetProperty("refresh_token").GetString();
                if (string.IsNullOrEmpty(username) || string.IsNullOrEmpty(readyToken)) return 1;
                AccountSettingsStore.Instance.LoginTokens[username] = readyToken;
            }
            '''+needle
        if needle not in text:raise RuntimeError('DepotDownloader patch no longer applies')
        program.write_text(text.replace(needle,replacement,1))
        account=source/'AccountSettingsStore.cs';text=account.read_text()
        needle='if (IsolatedStorage.FileExists(filename))'
        replacement='''if (Environment.GetEnvironmentVariable("READY_TOKEN_STDIN") == "1")
            {
                Instance = new AccountSettingsStore(); Instance.FileName = filename; return;
            }
            '''+needle
        text=text.replace(needle,replacement,1)
        needle='public static void Save()\n        {'
        text=text.replace(needle,needle+'\n            if (Environment.GetEnvironmentVariable("READY_TOKEN_STDIN") == "1") return;',1)
        account.write_text(text)
def dotnet():
    target=ROOT/'Runtime/Tools/StoreBridge/dotnet'
    if not (target/'dotnet').exists():
        # Exact Microsoft download and SHA512; no system-wide installer or certificates.
        meta=json.load(urllib.request.urlopen('https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/10.0/releases.json'))
        sdk=meta['releases'][0]['sdk'];f=next(f for f in sdk['files'] if f['rid']=='osx-arm64' and f['url'].endswith('.tar.gz'))
        archive=target.parent/'dotnet.tar.gz';target.mkdir(parents=True,exist_ok=True);h=hashlib.sha512()
        with urllib.request.urlopen(f['url']) as r,archive.open('wb') as out:
            while block:=r.read(1048576):out.write(block);h.update(block)
        if h.hexdigest()!=f['hash']:raise RuntimeError('Microsoft SDK hash mismatch')
        with tarfile.open(archive) as t:t.extractall(target,filter='data')
        archive.unlink();(target.parent/'source.json').write_text(json.dumps({'version':sdk['version'],'url':f['url'],'sha512':f['hash']},indent=2))
    # Runtime-only helpers keep using host/shared. A build explicitly restores
    # the verified project SDK cache instead of silently fetching another SDK.
    from store_sdk_cache import SDKCache, NAMES
    if not all((target/name).is_dir() and not (target/name).is_symlink() for name in NAMES):
        SDKCache(target).restore()
    return target/'dotnet'
def build_steam(*,work_root=None,sdk_root=None,tools_store=None,steam_only=False,select_project=True):
    # The normal source recipe applies the pinned LGPL fix in a private copy,
    # builds offline and retains a complete version rather than overwriting a
    # live DLL or quietly continuing to use the old development fallback.
    from store_steam_tools import build,select_project as select_helper
    sdk=pathlib.Path(sdk_root) if sdk_root else dotnet().parent
    workspace=pathlib.Path(work_root or os.environ.get('READY_STORE_BUILD_ROOT',ROOT/'Runtime/Tools/StoreBridge/build'))
    workspace.mkdir(parents=True,exist_ok=True,mode=0o700)
    destination=pathlib.Path(tools_store or ROOT/'Runtime/Tools/StoreBridge/Versions')
    result=build(workspace=workspace.resolve(),sdk_root=sdk.resolve(),tools_store=destination.resolve())
    if select_project:result['selection']=select_helper(pathlib.Path(result['versionRoot']))
    if not steam_only:
        patch_depot()
        run(sdk/'dotnet','build',ROOT/'StoreBridge/Dependencies/depotdownloader/DepotDownloader/DepotDownloader.csproj','-c','Release','--nologo')
    return result
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--sources-only',action='store_true');parser.add_argument('--steam-only',action='store_true')
    parser.add_argument('--work-root',type=pathlib.Path);parser.add_argument('--sdk-root',type=pathlib.Path);parser.add_argument('--tools-store',type=pathlib.Path)
    parser.add_argument('--no-project-helper-selection',action='store_true');a=parser.parse_args()
    if a.steam_only:
        if a.sources_only or not all([a.work_root,a.sdk_root,a.tools_store]):parser.error('--steam-only requires explicit --work-root, --sdk-root and --tools-store; no fetching is performed')
        print(json.dumps(build_steam(work_root=a.work_root,sdk_root=a.sdk_root,tools_store=a.tools_store,steam_only=True,select_project=not a.no_project_helper_selection),indent=2));return
    sources()
    if not a.sources_only:
        install_python();print(json.dumps(build_steam(work_root=a.work_root,sdk_root=a.sdk_root,tools_store=a.tools_store,select_project=not a.no_project_helper_selection),indent=2))
if __name__=='__main__':main()
