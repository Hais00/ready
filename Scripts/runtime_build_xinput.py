#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build copied Wine XInput source with session-local overlay capture.

Production and deterministic test-provider variants remain separate. No Vendor
source, current provider, live prefix or project runtime pointer is modified.
"""
import difflib
import hashlib
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Vendor/wine/dlls/xinput1_3/main.c'
BUILD=ROOT/'Runtime/build-wine-input-11.20'
OUTPUT=ROOT/'Runtime/XInputDiagnostic'
VERSIONS=['xinput1_1','xinput1_2','xinput1_3','xinput1_4','xinput9_1_0']

def patched_source():
    original=SOURCE.read_text();text=original.replace('DWORD WINAPI DECLSPEC_HOTPATCH XInputSetState(DWORD index, XINPUT_VIBRATION *vibration)','static DWORD ready_physical_set_state(DWORD index, XINPUT_VIBRATION *vibration)')
    text=text.replace('static DWORD xinput_get_state(DWORD index, XINPUT_STATE *state)','static DWORD ready_physical_get_state(DWORD index, XINPUT_STATE *state)')
    anchor='DWORD WINAPI DECLSPEC_HOTPATCH XInputGetState(DWORD index, XINPUT_STATE *state)'
    text=text.replace(anchor,'#include "runtime_xinput_gate.h"\n\n'+anchor)
    text=text.replace('    state->Gamepad.wButtons &= ~XINPUT_GAMEPAD_GUIDE;','    state->Gamepad.wButtons &= ~XINPUT_GAMEPAD_GUIDE;\n    ready_filter_state(index, state);')
    old='    return xinput_get_state(index, state);\n}'
    if text.count(old)!=1:raise RuntimeError('Wine GetStateEx anchor changed')
    text=text.replace(old,'    DWORD ret = xinput_get_state(index, state);\n    if (!ret) ready_filter_state(index, state);\n    return ret;\n}')
    text=text.replace('    static XINPUT_GAMEPAD last_state[XUSER_MAX_COUNT];\n    static SRWLOCK keystroke_lock = SRWLOCK_INIT;\n','')
    text=text.replace('XINPUT_GAMEPAD *last = last_state + index;','XINPUT_GAMEPAD filtered;\n    XINPUT_GAMEPAD *last = ready_last_key_state + index;')
    text=text.replace('&keystroke_lock','&ready_keystroke_lock')
    anchor='    cur = &state.Gamepad;'
    text=text.replace(anchor,anchor+'\n    if (ready_capture_player(index, cur)) { *last = *cur; ret = ERROR_EMPTY; goto done; }\n    filtered = *cur;\n    if (ready_capture.active) { filtered.wButtons &= ~XINPUT_GAMEPAD_START; last->wButtons &= ~XINPUT_GAMEPAD_START; }\n    cur = &filtered;')
    text=text.replace('DWORD WINAPI DECLSPEC_HOTPATCH XInputGetKeystroke(DWORD index, DWORD reserved, PXINPUT_KEYSTROKE keystroke)','static DWORD ready_physical_get_keystroke(DWORD index, DWORD reserved, PXINPUT_KEYSTROKE keystroke)')
    if text==original:raise RuntimeError('No Wine XInput adaptation made')
    OUTPUT.mkdir(exist_ok=True);path=OUTPUT/'main.c';path.write_text(text)
    (ROOT/'Scripts/runtime_wine_xinput_capture.patch').write_text(''.join(difflib.unified_diff(original.splitlines(keepends=True),text.splitlines(keepends=True),fromfile='a/dlls/xinput1_3/main.c',tofile='b/dlls/xinput1_3/main.c')))
    return path

def build(versions):
    if not BUILD.exists():subprocess.run(['/bin/cp','-cR',str(ROOT/'Runtime/build-wine-11.20'),str(BUILD)],check=True)
    source=patched_source();env=dict(os.environ);env['PATH']='/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin';env['DYLD_LIBRARY_PATH']=str(ROOT/'Runtime/vulkan-sdk-1.4.366/lib')+':'+str(ROOT/'Runtime/wine-deps/lib')
    flags=['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0','CXXFLAGS=-O2 -g0','i386_CFLAGS=-O2 -g0','x86_64_CFLAGS=-O2 -g0'];make='/opt/homebrew/bin/gmake'
    native=OUTPUT/'xinput-capture.so'
    subprocess.run(['/usr/bin/clang','-arch','x86_64','-mmacosx-version-min=14.0','-O2','-g0','-dynamiclib','-D__WINESRC__','-D_NTSYSTEM_','-I'+str(BUILD/'include'),'-I'+str(ROOT/'Vendor/wine/include'),'-I'+str(ROOT/'Scripts'),str(ROOT/'Scripts/runtime_xinput_unix.c'),'-install_name','@rpath/xinput-capture.so','-o',str(native)],check=True)
    for version in versions:
        for architecture in ['x86_64','i386']:
            target=f'dlls/{version}/{architecture}-windows/{version}.dll'
            subprocess.run([make,'-j2',*flags,target],cwd=BUILD,env=env,check=True)
            if version=='xinput9_1_0':
                for kind in ['production','test']:
                    dest=OUTPUT/kind/(architecture+'-windows');dest.mkdir(parents=True,exist_ok=True);shutil.copy2(BUILD/target,dest/(version+'.dll'))
                continue
            obj=f'dlls/{version}/{architecture}-windows/main.o'
            dry=subprocess.check_output([make,'-n','-W','../../Vendor/wine/dlls/xinput1_3/main.c',*flags,obj],cwd=BUILD,env=env,text=True).replace('\\\n',' ')
            line=next(line for line in dry.splitlines() if '-c -o '+obj+' ' in line);original_source='../../Vendor/wine/dlls/xinput1_3/main.c';arguments=shlex.split(line)
            if arguments.count(original_source)!=1:raise RuntimeError('XInput compile command changed')
            link=subprocess.check_output([make,'-n','-W',obj,*flags,target],cwd=BUILD,env=env,text=True).replace('\\\n',' ')
            link_line=next(line for line in link.splitlines() if line.startswith('tools/winegcc/winegcc -o '+target+' '));link_args=shlex.split(link_line)
            for kind in ['production','test']:
                compiler=[str(source) if value==original_source else value for value in arguments]+['-I'+str(ROOT/'Scripts')]
                if kind=='test':compiler.append('-DREADY_XINPUT_TEST_PROVIDER')
                subprocess.run(compiler,cwd=BUILD,env=env,check=True)
                command=list(link_args)
                if kind=='test':
                    spec_dir=OUTPUT/'test-spec';spec_dir.mkdir(exist_ok=True);spec=spec_dir/(version+'.spec');spec.write_text((ROOT/'Vendor/wine/dlls'/version/(version+'.spec')).read_text()+'\n@ stdcall ReadyInputTestCapture(ptr)\n');command=[str(spec) if value.endswith('/'+version+'.spec') else value for value in command]
                subprocess.run(command,cwd=BUILD,env=env,check=True)
                destination=OUTPUT/kind/(architecture+'-windows');destination.mkdir(parents=True,exist_ok=True);shutil.copy2(BUILD/target,destination/(version+'.dll'))
    for kind in ['production','test']:
        directory=OUTPUT/kind/'x86_64-unix';directory.mkdir(exist_ok=True)
        shutil.copy2(native,directory/'xinput-capture.so')
        for version in versions:
            if version=='xinput9_1_0':continue
            path=directory/(version+'.so');path.unlink(missing_ok=True);path.symlink_to('xinput-capture.so')
    production_files=[p for p in (OUTPUT/'production').rglob('*') if p.is_file() and not p.is_symlink()]
    forbidden=['ReadyInputTestCapture','M1L_XINPUT_TEST_PROVIDER','ReadyTestGetState','ReadyTestSetState']
    test_backend_present=any(token.encode(encoding) in p.read_bytes() for p in production_files for token in forbidden for encoding in ['utf-8','utf-16le'])
    if test_backend_present:raise RuntimeError('Production payload contains deterministic-test interface')
    original_root=Path(json.loads((ROOT/'Runtime/runtime.json').read_text())['immutableRuntimeSet'])/'wine/lib/wine'
    parity=[]
    for architecture in ['x86_64','i386']:
        for version in versions:
            relative=Path(architecture+'-windows')/(version+'.dll')
            def exports(path):
                data=subprocess.check_output(['/opt/homebrew/opt/llvm/bin/llvm-readobj','--coff-exports',str(path)],text=True)
                return [(int(o),n.strip(),int(r,16)!=0) for o,n,r in re.findall(r'Ordinal: (\d+)\n  Name: (.*?)\n  RVA: (0x[0-9A-Fa-f]+)',data)]
            same=exports(original_root/relative)==exports(OUTPUT/'production'/relative)
            if not same:raise RuntimeError('Production export ABI changed: '+str(relative))
            parity.append({'path':str(relative),'originalSHA256':hashlib.sha256((original_root/relative).read_bytes()).hexdigest(),'exportsEqual':True})
    inputs=[SOURCE,source,Path(__file__),*(ROOT/'Scripts'/name for name in ['runtime_xinput_gate.h','runtime_xinput_unix.c','runtime_xinput_protocol.h','runtime_wine_xinput_capture.patch'])]
    record={'sourceInputs':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'productionExportParity':parity,'payloadHashes':{str(p.relative_to(OUTPUT)):hashlib.sha256(p.read_bytes()).hexdigest() for kind in ['production','test'] for p in (OUTPUT/kind).rglob('*') if p.is_file() and not p.is_symlink()},'protocolVersion':2,'requiredOptIn':{'name':'M1L_XINPUT_CAPTURE','value':'1'},'wineVersion':'11.20','sourceSHA256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'adaptedSourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'nativeMinimumMacOS':'14.0','nativeModuleSHA256':hashlib.sha256(native.read_bytes()).hexdigest(),'versions':versions,'productionContainsTestBackend':test_backend_present,'vendorModified':False,'liveRuntimeModified':False,'license':'LGPL-2.1-or-later'}
    (ROOT/'Evidence/runtime-xinput-build.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--version',action='append',choices=VERSIONS);a=p.parse_args();build(a.version or VERSIONS)
