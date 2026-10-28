#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Stage and test optional user-supplied Apple graphics on isolated public WineCX.

No downloads/license acceptance and no live configuration or user prefix changes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import runtime_build_winecx as build
import runtime_smoke
ROOT=Path(__file__).resolve().parents[1]
EXPERIMENT=ROOT/'Runtime/AppleCXExperiment'
DLLS=('d3d10.dll','d3d11.dll','d3d12.dll','d3d12core.dll','dxgi.dll')

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def freeze_pure():
    source=build.INSTALL
    manifest={'schema':1,'source':json.loads(build.LOCK.read_text()),'files':{},'appleFilesIncluded':False}
    for path in sorted(source.rglob('*')):
        relative=str(path.relative_to(source))
        if path.is_symlink():manifest['files'][relative]={'symlink':os.readlink(path)}
        elif path.is_file():manifest['files'][relative]={'sha256':digest(path)}
    for name in ['LICENSE','COPYING.LIB']:manifest[name+'SHA256']=digest(build.SOURCE/name)
    identity=hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    target=ROOT/'Runtime/Providers'/('ready-winecx-'+identity[:20])
    if not target.exists():
        stage=target.with_name(target.name+'.staging');stage.mkdir()
        subprocess.run(['/bin/cp','-cR',str(source),str(stage/'wine')],check=True)
        for name in ['LICENSE','COPYING.LIB']:shutil.copy2(build.SOURCE/name,stage/name)
        (stage/'pure-winecx-manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n');stage.rename(target)
    elif json.loads((target/'pure-winecx-manifest.json').read_text())!=manifest:raise RuntimeError('Refusing to modify existing pure WineCX provider')
    return target/'wine',identity

def environment(engine,prefix):
    cfg=json.loads((ROOT/'Runtime/runtime.json').read_text());base=Path(cfg['immutableRuntimeSet'])
    env=dict(os.environ,WINEPREFIX=str(prefix),WINEDEBUG='+loaddll',
        WINEDLLOVERRIDES='d3d10,d3d11,d3d12,d3d12core,dxgi=b;nvapi64,nvapi,nvngx=d;mscoree,mshtml=d',
        DYLD_LIBRARY_PATH=str(engine/'lib/external')+':'+str(base/'vulkan')+':'+str(base/'dependencies'),
        DYLD_FRAMEWORK_PATH=str(engine/'lib/external'),CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine/'lib/external/libd3dshared.dylib'))
    return env

def prepare(apple):
    engine=EXPERIMENT/'wine';apple=apple.resolve();source=build.INSTALL
    if not (source/'bin/wine').is_file():raise RuntimeError('Build the pinned public WineCX first')
    if engine.exists():raise RuntimeError('Refusing to overwrite an existing WineCX experiment')
    if not (apple/'lib/external/D3DMetal.framework').is_dir() or not list(apple.glob('*License*')):raise RuntimeError('Complete optional local Apple redist and licenses required')
    EXPERIMENT.mkdir(exist_ok=True)
    pure,pure_identity=freeze_pure()
    subprocess.run(['/bin/cp','-cR',str(pure),str(engine)],check=True)
    for directory in ['x86_64-windows','x86_64-unix']:
        for item in (apple/'lib/wine'/directory).iterdir():
            target=engine/'lib/wine'/directory/item.name;target.unlink(missing_ok=True)
            if item.is_symlink():target.symlink_to(os.readlink(item))
            elif item.is_file():shutil.copy2(item,target)
    subprocess.run(['/usr/bin/ditto',str(apple/'lib/external'),str(engine/'lib/external')],check=True)
    for name in ['License.rtf','Acknowledgements.rtf','Read Me.rtf']:shutil.copy2(apple/name,engine/name)
    record={'sourceWineCX':json.loads(build.LOCK.read_text()),'pureWineRoot':str(pure),'pureWineIdentity':pure_identity,'engineBootstrap32Dir':str(pure/'lib/wine/i386-windows'),'appleSourceLocal':str(apple),'engine':str(engine),'graphicsDLLSHA256':{name:digest(engine/'lib/wine/x86_64-windows'/name) for name in DLLS},'proprietaryFilesIncludedLocally':True,'publicRedistributionEnabled':False,'evaluationOnly':True,'enabledForConsumerPlay':False,'verifiedAPIs':[]}
    (EXPERIMENT/'prepared.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))

def execute(engine,prefix,exe,args,tag,timeout,env):
    started=time.monotonic();log=ROOT/'Evidence'/('runtime-winecx-'+tag+'.log');result={'exitCode':124}
    try:
        with log.open('wb') as stream:
            p=subprocess.run([str(engine/'bin/wine'),str(exe),*args],env=env,stdout=subprocess.PIPE,stderr=stream,timeout=timeout)
        output=p.stdout.decode(errors='replace');result={'exitCode':p.returncode,'stdout':output,'observations':[]}
        for line in output.splitlines():
            try:result['observations'].append(json.loads(line))
            except ValueError:pass
    except subprocess.TimeoutExpired as exc:result.update(timeout=True,stdout=(exc.stdout or b'').decode(errors='replace'))
    finally:subprocess.run([str(engine/'bin/wineserver'),'-k'],env=env,capture_output=True,timeout=10)
    result.update(seconds=round(time.monotonic()-started,3),log=str(log));return result

def probe(timeout):
    engine=EXPERIMENT/'wine';prefix=EXPERIMENT/'prefix'
    if prefix.exists():raise RuntimeError('A fresh WineCX test prefix is required; inspect the previous synthetic experiment first')
    runtime_smoke.compile_d3d12_probe();prefix.mkdir();(prefix/'.ready-synthetic-winecx').write_text('Only synthetic GPU tests\n')
    # Bootstrap from the matching PURE WineCX, before renderer files or Wineboot.
    wow64=prefix/'drive_c/windows/syswow64';wow64.mkdir(parents=True)
    prepared=json.loads((EXPERIMENT/'prepared.json').read_text())
    subprocess.run(['/bin/cp','-cR',str(Path(prepared['pureWineRoot'])/'lib/wine/i386-windows')+'/.',str(wow64)],check=True)
    env=environment(engine,prefix)
    version=subprocess.check_output([str(engine/'bin/wine'),'--version'],env=env,text=True).strip()
    result={'sourceWineCX':json.loads(build.LOCK.read_text()),'reportedVersion':version,'engine':str(engine),'prefix':str(prefix),'evaluationOnly':True,'enabledForConsumerPlay':False,'verifiedAPIs':[],'dx12Verified':False,'directToDisplayVerified':False,'gameCompatibilityVerified':False,'tests':{}}
    boot=execute(engine,prefix,Path('wineboot'),['-u'],'boot',max(timeout,180),env);result['tests']['boot']=boot
    report=ROOT/'Evidence/runtime-winecx-probes.json';report.write_text(json.dumps(result,indent=2)+'\n');print('boot',boot['exitCode'],flush=True)
    if boot['exitCode']!=0:return
    env['DYLD_PRINT_LIBRARIES']='1'
    for tag,exe,args in [('win32',ROOT/'Runtime/Probes/runtime_windows_probe.exe',[]),('dx11',ROOT/'Runtime/Probes/runtime_windows_probe.exe',['dx11']),('dx12',ROOT/'Runtime/Probes/runtime_d3d12_probe.exe',[])]:
        test=execute(engine,prefix,exe,args,tag,timeout,env);result['tests'][tag]=test
        if tag=='dx12':
            result['dx12Verified']=test['exitCode']==0 and any(x.get('gpuBufferReadbackVerified') is True and x.get('renderTargetClearReadbackVerified') is True and x.get('shaderRasterizationVerified') is True for x in test.get('observations',[]))
            if result['dx12Verified']:result['verifiedAPIs'].append('d3d12')
        if tag=='dx11' and test['exitCode']==0 and any(x.get('gpuBufferReadbackVerified') is True and int(x.get('featureLevel','0'),0)>=0xb000 for x in test.get('observations',[])):result['verifiedAPIs'].append('d3d11')
        report.write_text(json.dumps(result,indent=2)+'\n');print(tag,json.dumps(test),flush=True)
    print(json.dumps({'reportedVersion':version,'verifiedAPIs':result['verifiedAPIs'],'dx12Verified':result['dx12Verified']}))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('command',choices=['prepare','probe']);p.add_argument('--apple-root',type=Path,default=ROOT/'Runtime/apple-evaluation-4.0b3');p.add_argument('--timeout',type=float,default=90);a=p.parse_args()
    prepare(a.apple_root) if a.command=='prepare' else probe(a.timeout)
