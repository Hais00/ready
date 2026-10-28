#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create candidate runtime generations with proven source-built dependencies.

Never activates a configuration. Existing sets/providers stay unchanged. Only
open Wine Mach-O metadata is normalized; Apple payload bytes are never edited.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from runtime_dependency_inventory import binary_headers
ROOT=Path(__file__).resolve().parents[1]
RUNTIME=ROOT/'Runtime'

def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def tree(root):
    result={}
    for path in sorted(root.rglob('*')):
        name=str(path.relative_to(root))
        if path.is_symlink():result[name]={'symlink':os.readlink(path)}
        elif path.is_file():result[name]={'sha256':sha(path)}
    return result

def clone(source,target):subprocess.run(['/bin/cp','-cR',str(source),str(target)],check=True)

def dependency_subset(source,target,manifest):
    """Preserve source proof54 while shipping only its approved25 shared code files."""
    selected={item['path']:item['sha256'] for item in manifest['binaryFiles'] if item.get('binary',{}).get('format')=='Mach-O' and item['path'].startswith('lib/') and all(part['fileType'] in [6,8] for part in item['binary'].get('slices',[]))}
    if len(selected)!=25:raise RuntimeError('Expected reviewed scope of exactly25 shared libraries/modules')
    excluded={item['path']:item['sha256'] for item in manifest['binaryFiles'] if item['path'] not in selected}
    target.mkdir();(target/'lib').mkdir()
    for relative,expected in selected.items():
        destination=target/relative;destination.parent.mkdir(parents=True,exist_ok=True);subprocess.run(['/bin/cp','-c',str(source/relative),str(destination)],check=True)
        if sha(destination)!=expected:raise RuntimeError('Selected code bytes changed while cloning')
    for alias in (source/'lib').rglob('*'):
        if not alias.is_symlink():continue
        canonical=alias.resolve(strict=True);relative=str(canonical.relative_to(source))
        if relative not in selected:continue
        destination=target/alias.relative_to(source);destination.parent.mkdir(parents=True,exist_ok=True)
        destination.symlink_to(os.path.relpath(target/relative,destination.parent))
    for relative in ['share/ready','share/locale','share/p11-kit','etc']:
        original=source/relative
        if original.is_dir():destination=target/relative;destination.parent.mkdir(parents=True,exist_ok=True);clone(original,destination)
    if (source/'lib/charset.alias').is_file():shutil.copy2(source/'lib/charset.alias',target/'lib/charset.alias')
    origin=target/'share/ready/origin';origin.mkdir()
    shutil.copy2(source/'manifest.json',origin/'manifest.json');shutil.copy2(source/'runtime-validation.json',origin/'runtime-validation.json')
    selection={'schema':1,'originManifestPath':'share/ready/origin/manifest.json','originManifestSHA256':sha(source/'manifest.json'),'originReceiptPath':'share/ready/origin/runtime-validation.json','originReceiptSHA256':sha(source/'runtime-validation.json'),'dependencySetID':manifest['dependencySetID'],'selectedBinaryHashes':selected,'excludedCodeInputs':excluded}
    (target/'selected-runtime-files.json').write_text(json.dumps(selection,indent=2)+'\n')
    return selection

def normalize_wine(root):
    records=[]
    for path in [*sorted((root/'bin').glob('*')),*sorted((root/'lib/wine/x86_64-unix').glob('*'))]:
        if path.is_symlink() or not path.is_file():continue
        header=binary_headers(path)
        if header.get('format')!='Mach-O':continue
        obsolete=sorted({value for part in header.get('slices',[]) for value in part.get('rpaths',[]) if value.startswith('/') and ('/Runtime/wine-deps/' in value or '/Runtime/vulkan-sdk-' in value)})
        if not obsolete:continue
        before=sha(path);commands=[]
        for value in obsolete:
            command=['/usr/bin/install_name_tool','-delete_rpath',value,str(path)];subprocess.run(command,check=True,capture_output=True);commands.append(command)
        subprocess.run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(path)],check=True,capture_output=True)
        records.append({'path':str(path.relative_to(root)),'originalSHA256':before,'finalSHA256':sha(path),'commands':commands,'sourceCodeModified':False})
    return records

def wrapper(wine,base,evaluation=False):
    text='''#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -u
READY_WINE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
READY_BASE='''+"'"+str(base).replace("'","'\"'\"'")+"'"+'''
READY_DEPS="$READY_BASE/dependency-root"
export DYLD_LIBRARY_PATH="$READY_BASE/vulkan:$READY_DEPS/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
export P11_MODULE_PATH="$READY_DEPS/lib/pkcs11"
export P11_PACKAGE_CONFIG_MODULES="$READY_DEPS/share/p11-kit/modules"
export P11_SYSTEM_CONFIG_MODULES="$READY_DEPS/etc/pkcs11/modules"
if [ "${READY_DYLD_DIAGNOSTICS:-0}" = 1 ]; then export DYLD_PRINT_LIBRARIES=1; fi
'''
    if evaluation:text+='''# Explicit local synthetic development/evaluation only; Apple's license applies.
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$READY_WINE_ROOT/lib/external/libd3dshared.dylib"
export DYLD_FRAMEWORK_PATH="$READY_WINE_ROOT/lib/external"
export DYLD_LIBRARY_PATH="$READY_WINE_ROOT/lib/external:$DYLD_LIBRARY_PATH"
'''
    text+='''if [ -n "${READY_OVERLAY_LIBRARY:-}" ] && [ -f "$READY_OVERLAY_LIBRARY" ]; then export DYLD_INSERT_LIBRARIES="$READY_OVERLAY_LIBRARY"; fi
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
    path=wine/'bin/ready-wine';path.write_text(text);path.chmod(0o755)

def main():
    import argparse
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--dependency-prefix',required=True,type=Path);a=p.parse_args();deps=a.dependency_prefix.resolve()
    manifest=json.loads((deps/'manifest.json').read_text());validation=json.loads((deps/'runtime-validation.json').read_text());expected={x['path']:x['sha256'] for x in manifest['binaryFiles']}
    if not validation.get('passed') or validation['dependencyManifestSHA256']!=sha(deps/'manifest.json') or validation['testedBinaryHashes']!=expected:raise RuntimeError('Hash-bound source/runtime validation is required')
    for name,value in {**expected,**manifest['provenanceFiles']}.items():
        if sha(deps/name)!=value:raise RuntimeError('Dependency source/provenance changed: '+name)
    defaults=RUNTIME/'runtime.json';evaluation=RUNTIME/'evaluation-runtime.json';before={str(path):sha(path) for path in [defaults,evaluation]};config=json.loads(defaults.read_text());ev=json.loads(evaluation.read_text());old_base=Path(config['immutableRuntimeSet']);old_dxmt=Path(config['engineWineBinaries']['dxmtMetal']).parent.parent.parent;old_apple=Path(ev['engineWineBinaries']['d3dMetal']).parent.parent.parent;old_pure=Path(ev['engineBootstrap32Dirs']['d3dMetal']).parent.parent.parent.parent
    module=RUNTIME/'SourceRuntimeModules/wine-11.20-dwrite.so';module_record=json.loads((ROOT/'Evidence/runtime-dwrite-source-rebuild.json').read_text())
    if sha(module)!=module_record['moduleSHA256']:raise RuntimeError('The tested DirectWrite source module changed')
    inputs={'schema':1,'dependencyPayloadScope':'25shared-libraries-and-modules-only','recipeSHA256':sha(Path(__file__)),'oldBaseManifestSHA256':sha(old_base/'runtime-manifest.json'),'oldDXMTManifestSHA256':sha(old_dxmt/'provider-manifest.json'),'oldAppleManifestSHA256':sha(old_apple/'evaluation-manifest.json'),'pureWineCXManifestSHA256':sha(old_pure/'pure-winecx-manifest.json'),'dependencyManifestSHA256':sha(deps/'manifest.json'),'dependencyValidationSHA256':sha(deps/'runtime-validation.json'),'dwriteSourceModule':module_record}
    identity=hashlib.sha256(json.dumps(inputs,sort_keys=True,separators=(',',':')).encode()).hexdigest();base=RUNTIME/'Sets'/('ready-source-runtime-'+identity[:20]);providers=RUNTIME/'Providers';dxmt=providers/('ready-source-dxmt-'+identity[:20]);pure=providers/('ready-source-winecx-'+identity[:20]);apple=providers/('ready-source-apple-evaluation-'+identity[:20])
    if any(path.exists() for path in [base,dxmt,pure,apple]):raise RuntimeError('Candidate generation already exists; inspect it rather than overwrite')
    stage=base.with_name(base.name+'.staging');stage.mkdir()
    for name in ['wine','vulkan','kosmic-x64','kosmic-arm64','molten','dxvk','vkd3d']:clone(old_base/name,stage/name)
    selection=dependency_subset(deps,stage/'dependency-root',manifest);(stage/'dependencies').symlink_to('dependency-root/lib',target_is_directory=True);shutil.copy2(module,stage/'wine/lib/wine/x86_64-unix/dwrite.so')
    for name in ['dxvk','vkd3d']:clone(old_dxmt/'native32'/name,stage/(name+'-x86'))
    normalizations={'base':normalize_wine(stage/'wine')};wrapper(stage/'wine',base)
    icd=stage/'icd';icd.mkdir()
    for name,relative,version,portable in [('kosmic-x64','kosmic-x64/libvulkan_kosmickrisp.dylib','1.4.363',False),('kosmic-arm64','kosmic-arm64/libvulkan_kosmickrisp.dylib','1.4.363',False),('molten','molten/libMoltenVK.dylib','1.4.0',True)]:
        value={'file_format_version':'1.0.1','ICD':{'library_path':str(base/relative),'api_version':version}}
        if portable:value['ICD']['is_portability_driver']=True
        (icd/(name+'.json')).write_text(json.dumps(value,indent=2)+'\n')
    for source,target,label,is_eval in [(old_dxmt,dxmt,'dxmt',False),(old_pure,pure,'pureWineCX',False),(old_apple,apple,'appleEvaluation',True)]:
        target.mkdir();clone(source/'wine',target/'wine')
        for name in ['LICENSE','COPYING.LIB','WineCX-NOTICE.txt']:
            if (source/name).is_file():shutil.copy2(source/name,target/name)
        if label=='dxmt':shutil.copy2(module,target/'wine/lib/wine/x86_64-unix/dwrite.so')
        normalizations[label]=normalize_wine(target/'wine');wrapper(target/'wine',base,is_eval)
        (target/'source-generation.json').write_text(json.dumps({'inputs':inputs,'wineFiles':tree(target/'wine'),'normalization':normalizations[label],'evaluationOnly':is_eval,'consumerAppleEnabled':False},indent=2)+'\n')
    (stage/'source-generation.json').write_text(json.dumps({'inputs':inputs,'files':tree(stage),'normalization':normalizations,'oldSetsRetained':True},indent=2)+'\n');stage.rename(base)
    replacements={str(old_base):str(base),str(old_dxmt):str(dxmt),str(old_pure):str(pure),str(old_apple):str(apple)}
    def remap(value):
        if isinstance(value,str):
            for old,new in replacements.items():value=value.replace(old,new)
            return value
        if isinstance(value,list):return [remap(x) for x in value]
        if isinstance(value,dict):return {key:remap(item) for key,item in value.items()}
        return value
    for current,filename,include_eval in [(config,'candidate-runtime.json',False),(ev,'candidate-evaluation-runtime.json',True)]:
        current=remap(current);current['runtimeID']=base.name+'+'+dxmt.name+('+'+apple.name if include_eval else '');current['sourceDependencyPrefix']=str(base/'dependency-root');current['sourceDependencyManifestSHA256']=inputs['dependencyManifestSHA256'];current['sourceDependencyValidationSHA256']=inputs['dependencyValidationSHA256'];current['sourceDependencySelectedScope']='25shared-libraries/modules';current['sourceDependencySelectionSHA256']=sha(base/'dependency-root/selected-runtime-files.json');current['runtimeManifestSHA256']=identity;current['engineProviderIDs']['dxmtMetal']=dxmt.name
        for key in ['dxvkKosmic','dxvkMolten']:current['engineDLLs32'][key]=str(base/'dxvk-x86')
        current['engineDLLs32']['vkd3dKosmic']=str(base/'vkd3d-x86');current['engineBuiltin32Dirs']=dict(current['engineDLLs32'])
        if include_eval:current['engineProviderIDs']['d3dMetal']=apple.name;current['evaluationModeEnabled']=False;current['appleOptional']['enabledForConsumerPlay']=False
        (RUNTIME/filename).write_text(json.dumps(current,indent=2)+'\n')
    if any(sha(Path(name))!=value for name,value in before.items()):raise RuntimeError('A live configuration changed unexpectedly')
    result={'identity':identity,'base':str(base),'dxmt':str(dxmt),'pureWineCX':str(pure),'appleEvaluation':str(apple),'normalization':normalizations,'candidateConfiguration':str(RUNTIME/'candidate-runtime.json'),'candidateEvaluationConfiguration':str(RUNTIME/'candidate-evaluation-runtime.json'),'liveConfigurationsModified':False,'oldSetsRetained':True}
    (ROOT/'Evidence/runtime-source-generation.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({key:result[key] for key in ['identity','base','candidateConfiguration','candidateEvaluationConfiguration','liveConfigurationsModified']},indent=2))

if __name__=='__main__':main()
