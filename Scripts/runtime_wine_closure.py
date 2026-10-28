#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read-only linked/dlopen-name closure of installed native Wine modules.

Unshipped user ODBC managers and explicitly external Apple evaluation support are
listed separately. No component license is inferred from a dylib filename.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

from runtime_dependency_inventory import binary_headers


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def closure(wine,dependencies,auxiliary):
    wine=wine.resolve();dependencies=dependencies.resolve();library_dirs=[dependencies,*[p.resolve() for p in auxiliary]]
    modules=[wine/'bin/wine',wine/'bin/wineserver',*sorted((wine/'lib/wine/x86_64-unix').glob('*.so'))]
    output=[];missing=[];optional=[]
    for path in modules:
        data=path.read_bytes();header=binary_headers(path);loads=[item['name'] for part in header.get('slices',[]) for item in part.get('dependencies',[])]
        system_names={Path(name).name for name in loads if name.startswith(('/usr/lib/','/System/'))}
        literals=sorted({value.decode() for value in re.findall(rb'[\x20-\x7e]{5,}',data) if re.fullmatch(rb'lib[\w.+-]+\.dylib(?: \(compatibility[^\r\n]*)?',value)})
        entries=[]
        for name in sorted(set(loads+literals)):
            item={'name':name,'kind':'linked' if name in loads else 'embedded-dlopen-name'};basename=Path(name).name
            if name.startswith(('/usr/lib/','/System/')) or name in system_names:item['resolution']='macOS-system-not-bundled'
            elif basename.endswith('.so') and (wine/'lib/wine/x86_64-unix'/basename).is_file():item['resolution']='matching-Wine-module'
            else:
                found=next((folder/basename for folder in library_dirs if (folder/basename).is_file()),None)
                if found:
                    resolved=found.resolve(strict=True)
                    if not any(resolved.is_relative_to(folder) for folder in library_dirs):raise ValueError('Dependency alias escapes allowed library directories')
                    item.update(resolution='candidate-library',path=str(resolved),sha256=digest(resolved))
                elif basename=='libodbc.dylib' and path.name=='odbc32.so':
                    item.update(resolution='optional-unshipped-ODBC-plugin',source='dlls/odbc32/unixlib.c: LIB_ODBC_DRIVER_MANAGER / fallback SONAME');optional.append({'module':str(path),'name':name})
                elif basename=='libd3dshared.dylib' and path.name=='ntdll.so':
                    item.update(resolution='optional-external-evaluation-only',source='WineCX CX_APPLEGPTK_LIBD3DSHARED_PATH; excluded from open/default payload');optional.append({'module':str(path),'name':name})
                else:
                    item['resolution']='missing-required';missing.append({'module':str(path),'name':name,'malformedConfigureSoname':' (compatibility' in name})
            entries.append(item)
        output.append({'module':str(path.relative_to(wine)),'sha256':hashlib.sha256(data).hexdigest(),'libraries':entries})
    manifest_path=dependencies.parent/'manifest.json';mapping=[];unmapped=[]
    selection_path=dependencies.parent/'selected-runtime-files.json'
    if selection_path.is_file():
        selection=json.loads(selection_path.read_text());manifest_path=dependencies.parent/selection['originManifestPath']
        if digest(manifest_path)!=selection['originManifestSHA256']:raise ValueError('Subset origin manifest hash differs')
    if manifest_path.is_file():
        manifest=json.loads(manifest_path.read_text());index={str((manifest_path.parent/entry['path']).resolve()):entry for entry in manifest.get('binaryFiles',[])}
        index={str((dependencies.parent/entry['path']).resolve()):entry for entry in manifest.get('binaryFiles',[])}
        for path in sorted(dependencies.rglob('*')):
            if path.is_symlink() or not path.is_file():continue
            header=binary_headers(path)
            if header.get('format')!='Mach-O' or not all(item['fileType'] in [6,8] for item in header.get('slices',[])):continue
            entry=index.get(str(path.resolve()));actual=digest(path)
            if not entry or entry.get('sha256')!=actual:unmapped.append(str(path))
            else:mapping.append({'path':str(path),'sha256':actual,'component':entry.get('component'),'version':entry.get('version'),'sourceSHA256':entry.get('sourceSHA256'),'recipeSHA256':entry.get('recipeSHA256'),'notices':entry.get('notices',[])})
    return {'wineRoot':str(wine),'dependencyRoot':str(dependencies),'modules':output,'missingRequiredLibraries':missing,'optionalUnshippedEntrypoints':optional,'requiredClosureComplete':not missing,'manifestPresent':manifest_path.is_file(),'candidateSourceMappedFiles':mapping,'unmappedOrChangedCandidateDylibs':unmapped,'sourceMappingComplete':manifest_path.is_file() and bool(mapping) and not unmapped,'runtimeValidationPerformedByThisReadOnlyTool':False}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--wine-root',required=True,type=Path);p.add_argument('--dependency-root',required=True,type=Path);p.add_argument('--aux-library-dir',action='append',type=Path,default=[]);p.add_argument('--output',required=True,type=Path);a=p.parse_args();result=closure(a.wine_root,a.dependency_root,a.aux_library_dir);a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({key:result[key] for key in ['requiredClosureComplete','missingRequiredLibraries','manifestPresent','sourceMappingComplete','unmappedOrChangedCandidateDylibs']}))
