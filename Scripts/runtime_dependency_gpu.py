#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Validate existing GPU paths with source-built dependencies in private clones."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]

def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--dependency-root',required=True,type=Path);p.add_argument('--include-apple-evaluation',action='store_true');p.add_argument('--keep',action='store_true');a=p.parse_args()
    deps=a.dependency_root.resolve();manifest_path=deps.parent/'manifest.json';manifest=json.loads(manifest_path.read_text());hashes={v['path']:v['sha256'] for v in manifest['binaryFiles']}
    if not all(digest(deps.parent/name)==sha for name,sha in hashes.items()):raise RuntimeError('Candidate differs from source manifest')
    config=json.loads((ROOT/'Runtime/runtime.json').read_text());base=Path(config['immutableRuntimeSet']);parent=ROOT/'Runtime/DependencyTests';parent.mkdir(exist_ok=True);scratch=parent/('gpu-'+uuid.uuid4().hex);scratch.mkdir();marker=scratch/'.ready-synthetic-dependency-gpu';marker.write_text('Only synthetic GPU probes\n')
    report={'dependencySetID':manifest['dependencySetID'],'dependencyManifestSHA256':digest(manifest_path),'binaryFingerprint':manifest['binaryFingerprint'],'testedBinaryHashes':hashes,'tests':{},'allOpenGPUPathsPassed':False,'evaluationOnlyApple':a.include_apple_evaluation,'consumerDefaultModified':False}
    environments={};prefixes={};wines={}
    def host(name,source):
        target=scratch/('wine-'+name);subprocess.run(['/bin/cp','-cR',str(source),str(target)],check=True)
        if name in ['base','dxmt']:shutil.copy2(ROOT/'Runtime/SourceRuntimeModules/wine-11.20-dwrite.so',target/'lib/wine/x86_64-unix/dwrite.so')
        prefix=scratch/('prefix-'+name);subprocess.run(['/bin/cp','-cR',str(ROOT/'Runtime/TestPrefixes/wine-11.20'),str(prefix)],check=True)
        if name in ['dxmt','apple']:
            pure=base/'wine' if name=='dxmt' else Path(json.loads((ROOT/'Runtime/AppleCXExperiment/prepared.json').read_text())['pureWineRoot'])
            wow=prefix/'drive_c/windows/syswow64';wow.mkdir(exist_ok=True);subprocess.run(['/bin/cp','-cR',str(pure/'lib/wine/i386-windows')+'/.',str(wow)],check=True)
        env=dict(os.environ,WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d',DYLD_LIBRARY_PATH=str(base/'vulkan')+':'+str(deps),DXMT_SHADER_CACHE_PATH=str(prefix/'dxmt-cache'),DXMT_LOG_PATH='none')
        for key in ['CX_APPLEGPTK_LIBD3DSHARED_PATH','DYLD_FRAMEWORK_PATH','DYLD_INSERT_LIBRARIES','READY_OVERLAY_LIBRARY','WINEDLLPATH']:env.pop(key,None)
        for key,value in manifest.get('runtimeEnvironmentForRelocation',{}).items():env[key]=value.replace('${prefix}',str(deps.parent))
        if name=='apple':
            env.update(CX_APPLEGPTK_LIBD3DSHARED_PATH=str(target/'lib/external/libd3dshared.dylib'),DYLD_FRAMEWORK_PATH=str(target/'lib/external'),DYLD_LIBRARY_PATH=str(target/'lib/external')+':'+env['DYLD_LIBRARY_PATH'],D3DM_MTL4='1')
        boot=subprocess.run([str(target/'bin/wine'),'wineboot','-u'],env=env,capture_output=True,timeout=180);subprocess.run([str(target/'bin/wineserver'),'-k'],env=env,capture_output=True,timeout=10)
        if boot.returncode:raise RuntimeError('Matching GPU host bootstrap failed: '+name)
        wines[name]=target;environments[name]=env;prefixes[name]=prefix
    def test(name,host_name,executable,arguments,overrides,check,icd=None):
        wine=wines[host_name];env=dict(environments[host_name],WINEDLLOVERRIDES=overrides+';mscoree,mshtml=d',WINEDEBUG='+loaddll',DYLD_PRINT_LIBRARIES='1')
        if icd:env.update(VK_DRIVER_FILES=icd,VK_ICD_FILENAMES=icd)
        log=ROOT/'Evidence'/('runtime-dependencies-gpu-'+name+'.log');start=time.monotonic()
        try:
            with log.open('wb') as stream:r=subprocess.run([str(wine/'bin/wine'),str(executable),*arguments],env=env,stdout=subprocess.PIPE,stderr=stream,timeout=110)
            stdout=r.stdout.decode(errors='replace');observations=[]
            for line in stdout.splitlines():
                try:observations.append(json.loads(line))
                except ValueError:pass
            passed=r.returncode==0 and any(check(v) for v in observations)
            loaded=[]
            for line in log.read_text(errors='replace').splitlines():
                if line.startswith('dyld[') and '> ' in line:
                    path=line.split('> ',1)[1].strip()
                    if path.endswith('.dylib'):loaded.append(path)
            allowed=('/System/','/usr/lib/',str(deps.parent)+'/',str(base/'vulkan')+'/',str(base/'kosmic-x64')+'/',str(base/'molten')+'/')
            if host_name=='apple':allowed+= (str(wine/'lib/external')+'/',)
            unexpected=[path for path in loaded if not path.startswith(allowed)]
            passed &= not unexpected and not any('MacportsLegacy' in path for path in loaded)
            report['tests'][name]={'exitCode':r.returncode,'observations':observations,'passed':passed,'seconds':round(time.monotonic()-start,3),'log':str(log),'executableSHA256':digest(executable),'loadedDylibs':sorted(set(loaded)),'unexpectedNonSystemDylibs':sorted(set(unexpected))}
            print(name,json.dumps({'passed':passed,'observations':observations}),flush=True)
            (ROOT/'Evidence/runtime-dependencies-gpu.json').write_text(json.dumps(report,indent=2)+'\n')
            if not passed:raise RuntimeError('GPU dependency regression: '+name)
        finally:subprocess.run([str(wine/'bin/wineserver'),'-k'],env=env,capture_output=True,timeout=10)
    try:
        host('base',base/'wine')
        test('dx9','base',ROOT/'Runtime/Probes/runtime_windows_probe.exe',['dx9'],'d3d9,d3d11,dxgi=b',lambda v:v.get('gpuBufferReadbackVerified') is True)
        for name,key in [('vulkanKosmic','kosmicICD'),('vulkanMolten','moltenICD')]:test(name,'base',ROOT/'Runtime/Probes/runtime_vulkan_probe.exe',[],'',lambda v:v.get('readbackVerified') is True,config[key])
        host('dxmt',Path(config['engineWineBinaries']['dxmtMetal']).parent.parent)
        for bits in [64,32]:
            for architecture,folder in [('x86_64','system32'),('i386','syswow64')]:
                for name in ['d3d10core.dll','d3d11.dll','dxgi.dll','winemetal.dll']:
                    source=wines['dxmt']/'lib/wine'/(architecture+'-windows')/name;target=prefixes['dxmt']/'drive_c/windows'/folder/name;target.unlink(missing_ok=True);subprocess.run(['/bin/cp','-c',str(source),str(target)],check=True)
            suffix='' if bits==64 else '32';overrides='d3d11,dxgi,d3d10core,winemetal=b'
            test('dxmt-buffer-'+str(bits),'dxmt',ROOT/'Runtime/Probes'/('runtime_windows_probe'+suffix+'.exe'),['dx11'],overrides,lambda v:v.get('gpuBufferReadbackVerified') is True and int(v.get('featureLevel','0'),0)>=0xb000)
            if bits==64:test('dxmt-shader-64','dxmt',ROOT/'Runtime/DXMTExperiment/dxmt_shader_probe.exe',[],overrides,lambda v:v.get('shaderRasterizationVerified') is True)
            test('dxmt-present-'+str(bits),'dxmt',ROOT/'Runtime/Probes'/('runtime_d3d11_present'+suffix+'.exe'),[],overrides,lambda v:v.get('presentedFrames',0)>=60)
        report['allOpenGPUPathsPassed']=True
        if a.include_apple_evaluation:
            evaluation=json.loads((ROOT/'Runtime/evaluation-runtime.json').read_text());host('apple',Path(evaluation['engineWineBinaries']['d3dMetal']).parent.parent)
            overrides='d3d10,d3d11,d3d12,d3d12core,dxgi=b;nvapi64,nvapi,nvngx=d'
            test('apple-dx12-evaluation','apple',ROOT/'Runtime/Probes/runtime_d3d12_probe.exe',[],overrides,lambda v:v.get('shaderRasterizationVerified') is True and v.get('gpuBufferReadbackVerified') is True)
            test('apple-dx12-present-evaluation','apple',ROOT/'Runtime/Probes/runtime_d3d12_present.exe',[],overrides,lambda v:v.get('submittedShaderFrames',0)>=60 and v.get('presentedFrames',0)>=60)
    except Exception as error:report['error']=str(error);raise
    finally:
        for name,wine in wines.items():subprocess.run([str(wine/'bin/wineserver'),'-k'],env=environments[name],capture_output=True,timeout=10)
        report['candidateInputsUnchanged']=all(digest(deps.parent/name)==sha for name,sha in hashes.items())
        if not a.keep and scratch.parent==parent and marker.is_file():shutil.rmtree(scratch)
        report['scratchRetained']=a.keep;(ROOT/'Evidence/runtime-dependencies-gpu.json').write_text(json.dumps(report,indent=2)+'\n')
        if not report['candidateInputsUnchanged']:raise RuntimeError('Candidate inputs changed during GPU matrix')

if __name__=='__main__':main()
