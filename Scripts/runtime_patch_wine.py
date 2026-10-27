#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build a minimal macOS host adapter against Wine 11.20 without editing Vendor.

The adapted Wine source retains its LGPL header. The corresponding change and
the exact original source hash are emitted alongside the module's provenance.
No device features are fabricated: this only opts in to portability ICD discovery.
"""
import difflib
import hashlib
import json
import os
import pathlib
import shlex
import shutil
import subprocess

ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Vendor/wine/dlls/win32u/vulkan.c'
BUILD=ROOT/'Runtime/build-wine-11.20'
STAGING=ROOT/'Runtime/wine-ready-adapter'
ANCHOR='''    /* VK_KHR_win32_keyed_mutex only requires external memory extensions, but we will use
'''
ADAPTER='''#ifdef __APPLE__
    if (vulkan_funcs.host_extensions.has_VK_KHR_portability_enumeration)
    {
        instance->obj.extensions.has_VK_KHR_portability_enumeration = 1;
        info->flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
#endif

'''

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    if (ROOT/'Vendor/wine/VERSION').read_text().strip()!='Wine version 11.20':
        raise RuntimeError('This adapter must be re-reviewed for a different Wine version')
    source=SOURCE.read_text()
    if source.count(ANCHOR)!=1:raise RuntimeError('Wine source anchor changed')
    STAGING.mkdir(exist_ok=True)
    adapted=STAGING/'vulkan.c';adapted.write_text(source.replace(ANCHOR,ADAPTER+ANCHOR))
    patch=''.join(difflib.unified_diff(source.splitlines(keepends=True),adapted.read_text().splitlines(keepends=True),fromfile='a/dlls/win32u/vulkan.c',tofile='b/dlls/win32u/vulkan.c'))
    (ROOT/'Scripts/runtime_wine_portability.patch').write_text(patch)
    env=dict(os.environ)
    env['PATH']='/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin'
    env['DYLD_LIBRARY_PATH']=str(ROOT/'Runtime/wine-deps/lib')+':'+str(ROOT/'Runtime/vulkan-sdk-1.4.366/lib')
    env['DYLD_FALLBACK_LIBRARY_PATH']=env['DYLD_LIBRARY_PATH']
    flags=['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0','i386_CFLAGS=-O2 -g0','x86_64_CFLAGS=-O2 -g0']
    dry=subprocess.check_output(['/opt/homebrew/bin/gmake','-n','-W','../../Vendor/wine/dlls/win32u/vulkan.c',*flags,'dlls/win32u/vulkan.o'],cwd=BUILD,env=env,text=True)
    lines=dry.replace('\\\n',' ').splitlines()
    compile_line=next(line for line in lines if '-c -o dlls/win32u/vulkan.o ' in line)
    args=shlex.split(compile_line)
    old='../../Vendor/wine/dlls/win32u/vulkan.c'
    if args.count(old)!=1:raise RuntimeError('Unexpected compile command')
    args=[str(adapted) if arg==old else arg for arg in args]
    subprocess.run(args,cwd=BUILD,env=env,check=True)
    subprocess.run(['/opt/homebrew/bin/gmake','-j3',*flags,'dlls/win32u/win32u.so'],cwd=BUILD,env=env,check=True)
    compiled=BUILD/'dlls/win32u/win32u.so'
    dest=ROOT/'Runtime/wine-11.20/lib/wine/x86_64-unix/win32u.so'
    before=digest(dest)
    pending=dest.with_suffix('.so.ready-new')
    shutil.copy2(compiled,pending)
    # Atomic replacement preserves any already-mapped older module's inode.
    os.replace(pending,dest)
    record={'wineVersion':'11.20','adapter':'macOS portability ICD opt-in','patchRevision':1,'originalSourceSHA256':digest(SOURCE),'adaptedSourceSHA256':digest(adapted),'oldModuleSHA256':before,'moduleSHA256':digest(dest),'license':'LGPL-2.1-or-later','vendorSourceUnmodified':True}
    (ROOT/'Evidence/runtime-wine-portability-adapter.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record,indent=2))
if __name__=='__main__':main()
