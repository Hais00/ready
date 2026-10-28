#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual PE32 HLSL/SM5 rasterization and texture readback through open DXMT68.

Only the original Ready freestanding probe is compiled. Central engines and
configuration remain read-only. The per-run COW prefix is removed after its exact
wineserver has stopped, unless --keep is requested.
"""
import argparse,hashlib,json,os,re,shutil,struct,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'Runtime/Probes/WoW64Shader'
RESERVE=512*1024*1024

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def command(args,**kwargs):return subprocess.run(list(map(str,args)),check=True,**kwargs)
def space():
    if shutil.disk_usage(ROOT).free<RESERVE:raise RuntimeError('Preserving 512 MiB free-space reserve')
def compile_probe():
    space();OUTPUT.mkdir(parents=True,exist_ok=True)
    cc='/opt/homebrew/opt/llvm/bin/clang';dt='/opt/homebrew/opt/llvm/bin/llvm-dlltool';link='/opt/homebrew/opt/lld/bin/lld-link'
    definition=OUTPUT/'kernel32.def';definition.write_text('LIBRARY KERNEL32.dll\nEXPORTS\nGetStdHandle@4\nWriteFile@20\nExitProcess@4\nLoadLibraryW@4\nGetProcAddress@8\nFreeLibrary@4\n')
    imports=OUTPUT/'kernel32.lib';obj=OUTPUT/'shader32.obj';exe=OUTPUT/'runtime_dxmt_shader32.exe'
    argv=[[dt,'-m','i386','--kill-at','-d',str(definition),'-l',str(imports)],
          [cc,'--target=i686-windows','--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2','-I'+str(ROOT/'Runtime/wine-11.20/include/wine/windows'),'-I'+str(ROOT/'Vendor/wine/include/msvcrt'),'-c',str(ROOT/'Scripts/runtime_dxmt_shader32_probe.c'),'-o',str(obj)],
          [link,'/timestamp:0','/entry:mainCRTStartup','/subsystem:console','/machine:x86','/safeseh:no','/nodefaultlib',str(obj),str(imports),'/out:'+str(exe)]]
    for args in argv:command(args)
    data=exe.read_bytes();pe=struct.unpack_from('<I',data,0x3c)[0]
    if data[:2]!=b'MZ' or data[pe:pe+4]!=b'PE\0\0' or struct.unpack_from('<H',data,pe+4)[0]!=0x14c or struct.unpack_from('<H',data,pe+24)[0]!=0x10b:raise RuntimeError('Shader probe is not a real i386 PE32 image')
    record={'sourceInputs':{str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__),ROOT/'Scripts/runtime_dxmt_shader32_probe.c',ROOT/'DXMTIntegration/dxmt_shader_probe.c']},'commands':argv,'executable':str(exe),'executableSHA256':sha(exe),'PEMachine':'i386 0x14c','optionalHeader':'PE32 0x10b','requestedFeatureLevel':'11_0','shaderModels':['vs_5_0','ps_5_0'],'runtimeRebuilt':False}
    (ROOT/'Evidence/runtime-wow64-shader-build.json').write_text(json.dumps(record,indent=2)+'\n');return exe,record

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--keep',action='store_true');parser.add_argument('--compile-only',action='store_true');args=parser.parse_args();exe,recipe=compile_probe()
    if args.compile_only:print(json.dumps(recipe,indent=2));return
    config_path=ROOT/'Runtime/runtime.json';evaluation_path=ROOT/'Runtime/evaluation-runtime.json';config=json.loads(config_path.read_text());base=Path(config['immutableRuntimeSet']);wine=Path(config['engineWineBinaries']['dxmtMetal']);provider=wine.parent.parent;server=Path(config['engineWineServers']['dxmtMetal'])
    if provider.parent.name!='ready-source-dxmt-68c00b7d3878699829eb':raise RuntimeError('This narrow proof targets the existing open DXMT68 source-dependency generation')
    defaults={str(p):sha(p) for p in [config_path,evaluation_path]};lock=json.loads((ROOT/'DXMTIntegration/dxmt.lock.json').read_text());core={str(provider/'lib/wine'/p):sha(provider/'lib/wine'/p) for p in lock['selectedPayloadFiles']}
    for p,h in lock['selectedPayloadFiles'].items():
        if core[str(provider/'lib/wine'/p)]!=h:raise RuntimeError('Selected DXMT payload differs from pinned source artifact: '+p)
    tracked=[provider/'bin/wine',provider/'bin/wineserver',provider/'bin/ready-wine',provider/'lib/wine/x86_64-unix/winemac.so',base/'source-generation.json',provider.parent/'source-generation.json'];before={str(p):sha(p) for p in tracked};before.update(core)
    scratch=ROOT/'Runtime/TestPrefixes'/('wow64-shader-'+uuid.uuid4().hex);scratch.mkdir();marker=scratch/'.ready-synthetic-wow64-shader';marker.write_text('Only original Ready synthetic shader fixture\n');prefix=scratch/'prefix';boot_server=base/'wine/bin/wineserver'
    env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_','CX_','D3DM_'))};env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d',DYLD_LIBRARY_PATH=str(base/'vulkan')+':'+str(base/'dependencies'))
    result={'schema':1,'runtimeID':config['runtimeID'],'wineProvider':str(provider),'pointerBitsExpected':32,'requestedFeatureLevel':'11_0','shaderModels':['vs_5_0','ps_5_0'],'passed':False,'shaderRasterization32Verified':False,'gameCompatibilityVerified':False,'directToDisplayVerified':False,'runtimeRebuilt':False,'defaultConfigurationChanged':False,'recipe':recipe,'providerHashesBefore':before};stopped=False
    try:
        # This baseline is an earlier owned synthetic Wine fixture, never user data.
        template=ROOT/'Runtime/TestPrefixes/wine-11.20';space()
        if template.is_dir():command(['/bin/cp','-cR',template,prefix]);result['bootstrapTemplate']='previous owned synthetic Wine11.20 fixture, read-only COW clone'
        else:prefix.mkdir();result['bootstrapTemplate']='fresh owned synthetic prefix'
        destination=prefix/'drive_c/windows/syswow64';destination.mkdir(parents=True,exist_ok=True)
        if destination.is_symlink():raise RuntimeError('Synthetic syswow64 must be a regular directory')
        pure=base/'wine/lib/wine/i386-windows';command(['/bin/cp','-cR',str(pure)+'/.',destination]);assert (pure/'kernel32.dll').stat().st_ino!=(destination/'kernel32.dll').stat().st_ino
        log=ROOT/'Evidence/runtime-wow64-shader-boot.log'
        with log.open('wb') as stream:boot=subprocess.run([str(base/'wine/bin/wine'),'wineboot','-u'],env=env,stdout=stream,stderr=stream,timeout=180)
        subprocess.run([str(boot_server),'-k'],env=env,capture_output=True,timeout=10);subprocess.run([str(boot_server),'-w'],env=env,capture_output=True,timeout=15);result['bootExitCode']=boot.returncode
        if boot.returncode:raise RuntimeError('Owned synthetic prefix Wineboot failed')
        space();projected={}
        for arch,folder in [('i386','syswow64'),('x86_64','system32')]:
            target_dir=prefix/'drive_c/windows'/folder
            if target_dir.is_symlink():raise RuntimeError('Synthetic renderer directory must be regular')
            for name in ['d3d10core.dll','d3d11.dll','dxgi.dll','winemetal.dll']:
                source=provider/'lib/wine'/(arch+'-windows')/name;target=target_dir/name;pending=target.with_suffix('.ready-pending');command(['/bin/cp','-c',source,pending]);os.replace(pending,target)
                assert source.stat().st_ino!=target.stat().st_ino;assert sha(source)==sha(target);projected[arch+'/'+name]=sha(target)
        result['selectedPayloadSHA256']=projected;env.update(WINEDLLOVERRIDES='d3d11,dxgi,d3d10core,winemetal=b;mscoree,mshtml=d',WINEDEBUG='+loaddll',READY_DYLD_DIAGNOSTICS='1')
        log=ROOT/'Evidence/runtime-wow64-shader.log';start=time.monotonic()
        with log.open('wb') as stream:run=subprocess.run([str(wine),str(exe)],env=env,stdout=subprocess.PIPE,stderr=stream,timeout=150)
        result.update(exitCode=run.returncode,seconds=round(time.monotonic()-start,3),stdout=run.stdout.decode(errors='replace'),moduleLog=str(log),moduleLogSHA256=sha(log))
        observations=[]
        for line in result['stdout'].splitlines():
            try:observations.append(json.loads(line))
            except ValueError:pass
        abi=next((v for v in observations if v.get('abiProbe')),{});gpu=next((v for v in observations if v.get('test')=='hlsl_triangle_readback'),{});trace=log.read_text(errors='replace')
        result.update(abiObservation=abi,observation=gpu)
        native_loaded=str(provider/'lib/wine/x86_64-unix/winemetal.so') in trace;builtin_loaded=all(re.search(r'Loaded L"C:\\\\windows\\\\(?:syswow64|system32)\\\\'+re.escape(n)+r'"[^\n]*builtin',trace,re.I) for n in ['d3d11.dll','dxgi.dll','winemetal.dll','d3dcompiler_47.dll'])
        apple_absent='D3DMetal.framework' not in trace and 'libd3dshared' not in trace
        result['moduleProvenance']={'nativeDXMTPathObserved':native_loaded,'PE32BuiltinModulesObserved':builtin_loaded,'proprietaryAppleFrameworkNotObserved':apple_absent}
        passed=run.returncode==0 and abi.get('pointerBits')==32 and gpu.get('shaderRasterizationVerified') is True and int(gpu.get('featureLevel','0'),0)>=0xb000 and gpu.get('coloredPixels')==1152 and gpu.get('backgroundPixels')==2944 and gpu.get('centerCorrect') is True and gpu.get('cornerCorrect') is True and native_loaded and builtin_loaded and apple_absent
        result.update(passed=passed,shaderRasterization32Verified=passed)
        if not passed:raise RuntimeError('Actual PE32 SM5 raster/readback or module-provenance gate failed')
    except Exception as error:
        result['error']=type(error).__name__+': '+str(error);raise
    finally:
        subprocess.run([str(server),'-k'],env=env,capture_output=True,timeout=10);wait=subprocess.run([str(server),'-w'],env=env,capture_output=True,timeout=15);stopped=wait.returncode==0
        result['providerHashesAfter']={p:sha(p) for p in before};result['defaultHashesBefore']=defaults;result['defaultHashesAfter']={p:sha(p) for p in defaults};result['centralEnginesUnchanged']=result['providerHashesAfter']==before;result['defaultConfigurationChanged']=result['defaultHashesAfter']!=defaults;result['exactPrefixStopped']=stopped
        if not result['centralEnginesUnchanged'] or result['defaultConfigurationChanged']:result.update(passed=False,shaderRasterization32Verified=False)
        if stopped and not args.keep and marker.is_file():shutil.rmtree(scratch)
        result['scratchRetained']=args.keep or not stopped;(ROOT/'Evidence/runtime-wow64-shader-proof.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
