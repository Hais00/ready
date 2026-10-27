#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual Win32 / Vulkan / D3D device-and-buffer probes, isolated from user prefixes."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import time

ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=ROOT/'Runtime'
PROBES=RUNTIME/'Probes'
CLANG='/opt/homebrew/opt/llvm/bin/clang'
DLLTOOL='/opt/homebrew/opt/llvm/bin/llvm-dlltool'
LINK='/opt/homebrew/opt/lld/bin/lld-link'

def command(args,**kwargs):subprocess.run(list(map(str,args)),check=True,**kwargs)

def compile_probes():
    PROBES.mkdir(exist_ok=True)
    libraries={
        'kernel32':('KERNEL32.dll',['GetStdHandle','WriteFile','ExitProcess','GetCurrentProcessId','GetCommandLineW','LoadLibraryW','GetProcAddress','FreeLibrary']),
        'vulkan-kernel32':('KERNEL32.dll',['LoadLibraryA','GetProcAddress','FreeLibrary','ExitProcess']),
        'present-kernel32':('KERNEL32.dll',['GetModuleHandleW','LoadLibraryA','GetProcAddress','GetCommandLineW','ExitProcess']),
        'present-user32':('USER32.dll',['RegisterClassW','CreateWindowExW','DefWindowProcW','ShowWindow','UpdateWindow','PeekMessageW','TranslateMessage','DispatchMessageW','DestroyWindow','PostQuitMessage','GetClientRect']),
        'msvcrt':('msvcrt.dll',['printf','calloc','free','strcmp'])}
    for name,(dll,exports) in libraries.items():
        definition=PROBES/(name+'.def');definition.write_text('LIBRARY '+dll+'\nEXPORTS\n'+'\n'.join(exports)+'\n')
        command([DLLTOOL,'-m','i386:x86-64','-d',definition,'-l',PROBES/(name+'.lib')])
    common=[CLANG,'--target=x86_64-windows','--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2']
    for name,libs in [('runtime_windows_probe',['kernel32']),('runtime_vulkan_probe',['vulkan-kernel32','msvcrt']),('runtime_vulkan_present',['present-kernel32','present-user32','msvcrt']),('runtime_d3d11_present',['present-kernel32','present-user32','msvcrt'])]:
        command([*common,'-I',RUNTIME/'vulkan-headers-1.4.366/include','-c',ROOT/'Scripts'/(name+'.c'),'-o',PROBES/(name+'.obj')])
        command([LINK,'/entry:mainCRTStartup','/subsystem:console','/machine:x64','/nodefaultlib',PROBES/(name+'.obj'),*[PROBES/(lib+'.lib') for lib in libs],'/out:'+str(PROBES/(name+'.exe'))])
    # Real 32-bit PE smoke, independent of the 64-bit host's architecture string.
    definition=PROBES/'kernel32-i386.def'
    definition.write_text('LIBRARY KERNEL32.dll\nEXPORTS\nGetStdHandle@4\nWriteFile@20\nExitProcess@4\nGetCurrentProcessId@0\nGetCommandLineW@0\nLoadLibraryW@4\nGetProcAddress@8\nFreeLibrary@4\n')
    command([DLLTOOL,'-m','i386','--kill-at','-d',definition,'-l',PROBES/'kernel32-i386.lib'])
    command([CLANG,'--target=i686-windows','--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2','-c',ROOT/'Scripts/runtime_windows_probe.c','-o',PROBES/'runtime_windows_probe32.obj'])
    command([LINK,'/entry:mainCRTStartup','/subsystem:console','/machine:x86','/nodefaultlib','/safeseh:no',PROBES/'runtime_windows_probe32.obj',PROBES/'kernel32-i386.lib','/out:'+str(PROBES/'runtime_windows_probe32.exe')])
    command(['/usr/bin/clang','-arch','arm64','-arch','x86_64','-O2','-I',RUNTIME/'vulkan-headers-1.4.366/include',ROOT/'Scripts/runtime_vulkan_probe.c','-o',RUNTIME/'runtime_vulkan_probe'])

def execute(args,env,timeout=90):
    started=time.monotonic()
    try:
        p=subprocess.run(list(map(str,args)),env=env,capture_output=True,text=True,timeout=timeout)
        records=[]
        for line in p.stdout.splitlines():
            try:records.append(json.loads(line))
            except json.JSONDecodeError:pass
        return {'exitCode':p.returncode,'seconds':time.monotonic()-started,'results':records,'stdout':p.stdout,'stderr':p.stderr}
    except subprocess.TimeoutExpired as e:
        return {'exitCode':None,'timeout':True,'seconds':time.monotonic()-started,'stdout':str(e.stdout),'stderr':str(e.stderr)}

def stop_server(server,env):
    # A completed console probe can naturally leave no server; -k then returns 1.
    p=subprocess.run([str(server),'-k'],env=env,capture_output=True,text=True)
    if p.returncode not in (0,1):raise RuntimeError('Cannot stop scratch prefix server: '+p.stderr)

def configure_dlls(prefix,source):
    names=['d3d11.dll','d3d12.dll','d3d12core.dll','dxgi.dll']
    dest=prefix/'drive_c/windows/system32'
    if not dest.exists():raise RuntimeError('Wine prefix initialization did not create system32')
    for name in names:
        p=dest/name;original=p.with_suffix('.dll.ready-original')
        if original.exists():
            if p.exists() or p.is_symlink():p.unlink()
            shutil.copy2(original,p)
        elif p.exists() or p.is_symlink():
            p.rename(original);shutil.copy2(original,p)
        if source and (source/name).exists():
            if p.exists() or p.is_symlink():p.unlink()
            shutil.copy2(source/name,p)

def smoke_wine(include_apple=False):
    wine=RUNTIME/'wine-11.20/bin/wine';server=RUNTIME/'wine-11.20/bin/wineserver'
    if not wine.is_file():raise RuntimeError('Wine 11.20 build/install is incomplete')
    prefix=RUNTIME/'TestPrefixes/wine-11.20';prefix.mkdir(parents=True,exist_ok=True)
    env=dict(os.environ,WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d',
             DYLD_LIBRARY_PATH=str(RUNTIME/'vulkan-sdk-1.4.366/lib')+':'+str(RUNTIME/'wine-deps/lib'))
    report={'wineVersion':subprocess.check_output([str(wine),'--version'],env=env,text=True).strip(),'strictNativeDLLs':True,
            'wineModuleSHA256':hashlib.sha256((RUNTIME/'wine-11.20/lib/wine/x86_64-unix/win32u.so').read_bytes()).hexdigest(),'engines':{}}
    report['win32']=execute([wine,PROBES/'runtime_windows_probe.exe'],env,180)
    (ROOT/'Evidence/runtime-engine-probes.json').write_text(json.dumps(report,indent=2)+'\n')
    stop_server(server,env)
    if report['win32']['exitCode']!=0:
        (ROOT/'Evidence/runtime-engine-probes.json').write_text(json.dumps(report,indent=2)+'\n');return report
    targets=[
        ('wineD3D','dx9',None,None,'d3d9,d3d11,d3d12,dxgi=b'),
        ('vulkanKosmic','vulkan',None,RUNTIME/'mesa-x64-26.3.0-rc2/share/vulkan/icd.d/kosmickrisp_mesa_icd.x86_64.json',''),
        ('vulkanMolten','vulkan',None,RUNTIME/'moltenvk-1.4.2/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json',''),
        ('dxvkKosmic','dx11',RUNTIME/'dxvk-3.1.1/x64',RUNTIME/'mesa-x64-26.3.0-rc2/share/vulkan/icd.d/kosmickrisp_mesa_icd.x86_64.json','d3d11,dxgi=n'),
        ('dxvkMolten','dx11',RUNTIME/'dxvk-3.1.1/x64',RUNTIME/'moltenvk-1.4.2/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json','d3d11,dxgi=n'),
        ('vkd3dKosmic','dx12',RUNTIME/'engines/vkd3d-kosmic-3.0.1',RUNTIME/'mesa-x64-26.3.0-rc2/share/vulkan/icd.d/kosmickrisp_mesa_icd.x86_64.json','d3d12,d3d12core,dxgi=n')]
    if include_apple:
        raise RuntimeError('Apple DLLs are Wine builtins with a Unix/framework provider; use runtime_apple_trace.py. Native-only overrides are intentionally invalid for that runtime.')
    for engine,api,dlls,icd,overrides in targets:
        configure_dlls(prefix,dlls)
        e=dict(env);e['WINEDLLOVERRIDES']=overrides+';mscoree,mshtml=d'
        if icd:e['VK_DRIVER_FILES']=str(icd);e['VK_ICD_FILENAMES']=str(icd)
        if engine=='d3dMetal':e['DYLD_LIBRARY_PATH']+=':'+str(RUNTIME/'apple-evaluation-4.0b3/lib/external')
        exe=PROBES/('runtime_vulkan_probe.exe' if api=='vulkan' else 'runtime_windows_probe.exe')
        result=execute([wine,exe,*([api] if api!='vulkan' else [])],e)
        stop_server(server,e)
        result['wineVersion']=report['wineVersion']
        result['api']=api
        result['verified']=result['exitCode']==0 and any(r.get('readbackVerified') or r.get('gpuBufferReadbackVerified') for r in result.get('results',[]))
        result['verificationScope']='GPU buffer readback' if api!='dx12' else 'Device creation only; not enough to enable renderer'
        report['engines'][engine]=result
        (ROOT/'Evidence/runtime-engine-probes.json').write_text(json.dumps(report,indent=2)+'\n')
        print(engine, result['exitCode'], result['verified'], flush=True)
    configure_dlls(prefix,None)
    return report

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--include-apple',action='store_true');parser.add_argument('--compile-only',action='store_true');args=parser.parse_args()
    compile_probes()
    if not args.compile_only:
        print(json.dumps(smoke_wine(args.include_apple),indent=2))
