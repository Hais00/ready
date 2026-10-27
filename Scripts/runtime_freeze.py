#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create a content-addressed, centrally versioned runtime set using APFS clones.

Existing sets are never overwritten. Source/build staging remains separate from
the runtime configuration consumed by active game sessions.
"""
import hashlib
import json
import os
import pathlib
import subprocess

ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=ROOT/'Runtime'
INPUTS={
    'wine':RUNTIME/'wine-11.20',
    'dependencies':RUNTIME/'wine-deps/lib',
    'vulkan':RUNTIME/'vulkan-sdk-1.4.366/lib',
    'kosmic-x64':RUNTIME/'mesa-x64-26.3.0-rc2/lib',
    'kosmic-arm64':RUNTIME/'mesa-26.3.0-rc2/lib',
    'molten':RUNTIME/'moltenvk-1.4.2/MoltenVK/dynamic/dylib/macOS',
    'dxvk':RUNTIME/'dxvk-3.1.1/x64',
    'vkd3d':RUNTIME/'engines/vkd3d-kosmic-3.0.1',
}

def filehash(path):
    h=hashlib.sha256()
    with path.open('rb') as src:
        while chunk:=src.read(1<<20):h.update(chunk)
    return h.hexdigest()

def main():
    staging_config=RUNTIME/'staging-runtime.json'
    config=json.loads((staging_config if staging_config.exists() else RUNTIME/'runtime.json').read_text())
    manifest={'format':1,'wineVersion':'wine-11.20','freezeRecipeSHA256':filehash(pathlib.Path(__file__).resolve()),'buildFlags':['x86_64-macOS','x86_64-PE','i386-PE','O2','g0','explicit-sonames','strict-native-DLLs'],'files':{}}
    for name,folder in INPUTS.items():
        if not folder.is_dir():raise RuntimeError('Missing runtime input: '+str(folder))
        for p in sorted(folder.rglob('*')):
            relative=name+'/'+str(p.relative_to(folder))
            if p.is_symlink():manifest['files'][relative]={'symlink':os.readlink(p)}
            elif p.is_file():manifest['files'][relative]={'sha256':filehash(p)}
    patch=ROOT/'Evidence/runtime-wine-portability-adapter.json'
    if patch.exists():manifest['wineAdapter']=json.loads(patch.read_text())
    identity=hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    runtime_id='ready-runtime-'+identity[:20]
    sets=RUNTIME/'Sets';sets.mkdir(exist_ok=True)
    target=sets/runtime_id
    if not target.exists():
        staged=sets/(runtime_id+'.staging')
        if staged.exists():raise RuntimeError('A previous staging snapshot needs inspection: '+str(staged))
        staged.mkdir()
        for name,folder in INPUTS.items():
            subprocess.run(['/bin/cp','-cR',str(folder),str(staged/name)],check=True)
        (staged/'runtime-manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
        staged.rename(target)
    elif json.loads((target/'runtime-manifest.json').read_text())!=manifest:
        raise RuntimeError('Content-addressed runtime manifest mismatch; refusing overwrite')
    icds=target/'icd';icds.mkdir(exist_ok=True)
    for name,library,version,portable in [
        ('kosmic-x64',target/'kosmic-x64/libvulkan_kosmickrisp.dylib','1.4.363',False),
        ('kosmic-arm64',target/'kosmic-arm64/libvulkan_kosmickrisp.dylib','1.4.363',False),
        ('molten',target/'molten/libMoltenVK.dylib','1.4.0',True)]:
        path=icds/(name+'.json')
        desired={'file_format_version':'1.0.1','ICD':{'library_path':str(library),'api_version':version}}
        if portable:desired['ICD']['is_portability_driver']=True
        encoded=json.dumps(desired,indent=2)+'\n'
        if path.exists() and path.read_text()!=encoded:raise RuntimeError('Refusing to mutate existing ICD manifest')
        if not path.exists():path.write_text(encoded)
    wrapper=target/'wine/bin/ready-wine'
    script='''#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -u
READY_WINE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
READY_SET=$(CDPATH= cd -- "$READY_WINE_ROOT/.." && pwd)
export DYLD_LIBRARY_PATH="$READY_SET/vulkan:$READY_SET/dependencies${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
if [ -n "${READY_OVERLAY_LIBRARY:-}" ] && [ -f "$READY_OVERLAY_LIBRARY" ]; then
  export DYLD_INSERT_LIBRARIES="$READY_OVERLAY_LIBRARY"
fi
case "${1:-}" in --version|--help) exec "$READY_WINE_ROOT/bin/wine" "$@" ;; esac
if [ -z "${WINEPREFIX:-}" ]; then echo 'An explicit per-game/per-profile WINEPREFIX is required' >&2; exit 64; fi
trap '"$READY_WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1 || true' TERM INT HUP
"$READY_WINE_ROOT/bin/wine" "$@" &
READY_CHILD=$!
wait "$READY_CHILD"
READY_STATUS=$?
"$READY_WINE_ROOT/bin/wineserver" -w
exit "$READY_STATUS"
'''
    if wrapper.exists() and wrapper.read_text()!=script:raise RuntimeError('Refusing to modify an existing runtime wrapper')
    if not wrapper.exists():wrapper.write_text(script);wrapper.chmod(0o755)
    config.update({'runtimeID':runtime_id,'wine':str(wrapper),'wineBinary':str(target/'wine/bin/wine'),'wineServer':str(target/'wine/bin/wineserver'),'wineBoot':None,
                   'builtin32Directory':str(target/'wine/lib/wine/i386-windows'),
                   'kosmicICD':str(icds/'kosmic-x64.json'),'kosmicNativeICD':str(icds/'kosmic-arm64.json'),'moltenICD':str(icds/'molten.json'),
                   'vulkanLibrary':str(target/'vulkan/libvulkan.1.dylib'),'engineDLLs':{'dxvkKosmic':str(target/'dxvk'),'dxvkMolten':str(target/'dxvk'),'vkd3dKosmic':str(target/'vkd3d')},
                   'immutableRuntimeSet':str(target),'runtimeManifestSHA256':identity})
    pending=RUNTIME/'runtime.json.pending';pending.write_text(json.dumps(config,indent=2)+'\n');os.replace(pending,RUNTIME/'runtime.json')
    (ROOT/'Evidence/runtime-frozen-set.json').write_text(json.dumps({'runtimeID':runtime_id,'path':str(target),'manifestSHA256':identity,'APFSCloned':True,'sourceStagingSeparate':True,'proprietaryAppleFilesExcluded':True},indent=2)+'\n')
    print(json.dumps({'runtimeID':runtime_id,'path':str(target)},indent=2))
if __name__=='__main__':main()
