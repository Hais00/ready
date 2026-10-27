#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise actual Windows folder and registry APIs across synthetic profile/game prefixes."""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import uuid

ROOT=pathlib.Path(__file__).resolve().parents[1]
FIXTURE=ROOT/'Runtime/TestPrefixes'/('prefix-proof-'+uuid.uuid4().hex)
REPORT=ROOT/'Evidence/runtime-prefix-isolation.json'
CONFIG=json.loads((ROOT/'Runtime/runtime.json').read_text())
SET=pathlib.Path(CONFIG['immutableRuntimeSet'])
WINE=pathlib.Path(CONFIG['wineBinary'])
SERVER=pathlib.Path(CONFIG['wineServer'])
PROBE=ROOT/'Runtime/Probes/prefix_windows_probe.exe'
STATE={'runtimeID':CONFIG['runtimeID'],'templateMethod':'APFS copy-on-write clone; no hard links','steps':[],'verified':False}

def persist():REPORT.write_text(json.dumps(STATE,indent=2)+'\n')
def run(args,env=None,timeout=180):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout)
    if p.returncode:raise RuntimeError('Command failed: '+str(args)+'\n'+p.stdout[-1500:]+'\n'+p.stderr[-1500:])
    return p
def environ(prefix):
    return dict(os.environ,WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d',DYLD_LIBRARY_PATH=str(SET/'vulkan')+':'+str(SET/'dependencies'))
def stop(prefix):subprocess.run([str(SERVER),'-k'],env=environ(prefix),capture_output=True)
def prepare():return json.loads(run(['swift','run','--jobs','2','ReadyCoreProbe','--prepare-wine-fixture',FIXTURE]).stdout)['prefixes']
def import_folders(prefix):run([WINE,'regedit','/S',prefix/'.ready/folders.reg'],env=environ(prefix));stop(prefix)
def validate_links(row):
    prefix=pathlib.Path(row['prefix']);user=prefix/'drive_c/users'/os.environ['USER']
    expected={'Documents':pathlib.Path(row['documents']),'Saved Games':pathlib.Path(row['documents']).parent/'Saved Games','AppData':pathlib.Path(row['appData'])}
    for name,target in expected.items():
        path=user/name
        if not path.is_symlink() or path.resolve()!=target.resolve():raise RuntimeError('Folder link escaped expected fixture profile/game: '+str(path))
        if not str(target.resolve()).startswith(str(FIXTURE.resolve())+'/'):raise RuntimeError('Refusing a marker write outside the synthetic fixture')
def probe(row,mode='--probe'):
    validate_links(row);prefix=pathlib.Path(row['prefix']);result=run([WINE,PROBE,mode],env=environ(prefix));stop(prefix)
    parsed=json.loads(next(line for line in reversed(result.stdout.splitlines()) if line.startswith('{')))
    for key in ['documentsPath','appDataPath','savedGamesPath']:
        if '\\\\' in parsed.get(key,''):raise RuntimeError('Noncanonical Windows folder separator: '+key)
    STATE['steps'].append({'profile':row['profile'],'game':row['game'],'operation':mode,'result':parsed});persist();return parsed
def expect(result,**values):
    for key,value in values.items():
        if result[key]!=value:raise AssertionError(f'{key}: expected {value}, observed {result[key]}')
def clone_rows(rows):
    template=ROOT/'Runtime/TestPrefixes/wine-11.20'
    stop(template)
    for row in rows:
        path=pathlib.Path(row['prefix'])
        if row['profile'] not in ['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222'] or row['game'] not in ['A','B']:raise RuntimeError('Unexpected fixture identity')
        if not str(path.resolve()).startswith(str(FIXTURE.resolve())+'/Prefixes/'):raise RuntimeError('Unsafe fixture destination')
        if path.is_symlink():raise RuntimeError('Fixture prefix itself is a symlink')
        if path.exists():
            files=[str(p.relative_to(path)) for p in path.rglob('*') if p.is_file() and not p.is_symlink()]
            if any(name!='.ready/folders.reg' for name in files):raise RuntimeError('Refusing to replace an initialized/non-placeholder fixture: '+str(path))
            shutil.rmtree(path)
        path.parent.mkdir(parents=True,exist_ok=True)
        run(['/bin/cp','-cR',template,path])
        # Distinct inodes and subsequent marker writes demonstrate independent copies.
        if (template/'user.reg').stat().st_ino==(path/'user.reg').stat().st_ino:raise RuntimeError('Prefix registry was hard-linked')

def compile_probe():
    output=PROBE.parent;output.mkdir(exist_ok=True)
    libraries={'prefix-kernel32':('KERNEL32.dll',['GetStdHandle','WriteFile','CloseHandle','CreateFileA','GetFileAttributesA','GetCommandLineA','ExitProcess','WideCharToMultiByte']),
        'prefix-shell32':('SHELL32.dll',['SHGetFolderPathA','SHGetKnownFolderPath']),
        'prefix-advapi32':('ADVAPI32.dll',['RegCreateKeyExA','RegSetValueExA','RegQueryValueExA','RegCloseKey'])}
    for name,(dll,exports) in libraries.items():
        definition=output/(name+'.def');definition.write_text('LIBRARY '+dll+'\nEXPORTS\n'+'\n'.join(exports)+'\n')
        run(['/opt/homebrew/opt/llvm/bin/llvm-dlltool','-m','i386:x86-64','-d',definition,'-l',output/(name+'.lib')])
    run(['/opt/homebrew/opt/llvm/bin/clang','--target=x86_64-windows','--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2','-c',ROOT/'Scripts/prefix_windows_probe.c','-o',output/'prefix_windows_probe.obj'])
    run(['/opt/homebrew/opt/lld/bin/lld-link','/entry:mainCRTStartup','/subsystem:console','/machine:x64','/nodefaultlib',output/'prefix_windows_probe.obj',*[output/(name+'.lib') for name in libraries],'/out:'+str(PROBE)])

def main():
    global REPORT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keep',action='store_true',help="Keep only this run's synthetic prefixes for diagnosis")
    parser.add_argument('--report',type=pathlib.Path,default=REPORT)
    args=parser.parse_args();REPORT=args.report.resolve();REPORT.parent.mkdir(parents=True,exist_ok=True)
    if FIXTURE.exists():raise RuntimeError('Refusing existing fixture root')
    FIXTURE.mkdir(parents=True);(FIXTURE/'.ready-synthetic-prefix-proof').write_text('Only synthetic test data\n')
    STATE.update(fixture=str(FIXTURE),cleanupRequested=not args.keep)
    compile_probe()
    rows=prepare()
    if len(rows)!=3:raise RuntimeError('Expected exactly three synthetic fixture prefixes')
    clone_rows(rows);prepare();print('Cloned and pre-wired three independent prefixes',flush=True)
    for row in rows:
        prefix=pathlib.Path(row['prefix']);run([WINE,'wineboot','-u'],env=environ(prefix));stop(prefix)
        print('Wineboot:',row['profile'],row['game'],flush=True)
    prepare()
    for row in rows:import_folders(pathlib.Path(row['prefix']));validate_links(row)
    for row in rows:
        expect(probe(row),registryMarker=False,documentsMarker=False,appDataMarker=False,savedGamesMarker=False)
    a1,b1,a2=rows
    expect(probe(a1,'--write'),registryMarker=True,documentsMarker=True,appDataMarker=True,savedGamesMarker=True,writeSucceeded=True)
    expect(probe(b1),registryMarker=False,documentsMarker=True,appDataMarker=False,savedGamesMarker=True)
    expect(probe(a2),registryMarker=False,documentsMarker=False,appDataMarker=False,savedGamesMarker=False)
    print('Real Windows API isolation passed; recreating A1',flush=True)
    recreated=run(['swift','run','--jobs','2','ReadyCoreProbe','--recreate-wine-fixture',FIXTURE])
    STATE['recreationCLI']=json.loads(recreated.stdout)
    prefix=pathlib.Path(a1['prefix']);run([WINE,'wineboot','-u'],env=environ(prefix));stop(prefix)
    prepare();import_folders(prefix);validate_links(a1)
    expect(probe(a1),registryMarker=False,documentsMarker=True,appDataMarker=True,savedGamesMarker=True)
    STATE['verified']=True
    for row in rows:stop(pathlib.Path(row['prefix']))
    if not args.keep:
        if FIXTURE.parent!=ROOT/'Runtime/TestPrefixes' or not (FIXTURE/'.ready-synthetic-prefix-proof').is_file():raise RuntimeError('Cleanup confinement check failed')
        shutil.rmtree(FIXTURE);STATE['syntheticFixtureRemoved']=True
    else:STATE['syntheticFixtureRemoved']=False
    persist();print(json.dumps(STATE,indent=2))
if __name__=='__main__':
    try:main()
    except Exception as exc:
        STATE['error']=str(exc);persist();raise
