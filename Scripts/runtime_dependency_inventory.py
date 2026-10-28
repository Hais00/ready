#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Static dependency inventory and fail-closed binary distribution gate.

Reads binary headers/load commands; never dlopens or executes a dependency.
Upstream license hints are review leads, not licenses assigned to these binaries.
No dependency fetch, rebuild, signing, source edit, or runtime mutation occurs.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import struct
import sys
import uuid

ROOT=pathlib.Path(__file__).resolve().parents[1]
ORIGINAL_URL='https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-devel-11.18-osx64.tar.xz'
ORIGINAL_DIGEST='aa0ea4c82e636ae7bca2076387cb0a5affa26509ad13f119ecd0d62bd7ba6f82'
# These project-family leads were inspected on 2026-10-28. They do not establish
# the version, source/patch set, or license of any existing community binary.
CATALOG=[
 ('MacPorts Legacy Support',('libMacportsLegacy',),'mixed MIT, APSL-2.0 and per-file terms','https://github.com/macports/macports-legacy-support','https://github.com/macports/macports-legacy-support/blob/master/LICENSE'),
 ('SDL2',('libSDL2',),'zlib-style license','https://github.com/libsdl-org/SDL','https://github.com/libsdl-org/SDL/blob/SDL2/LICENSE.txt'),
 ('Brotli',('libbrotli',),'MIT','https://github.com/google/brotli','https://github.com/google/brotli/blob/master/LICENSE'),
 ('bzip2',('libbz2',),'bzip2 BSD-style license; release-specific text','https://sourceware.org/bzip2/','https://sourceware.org/bzip2/'),
 ('GNU libiconv/libcharset',('libcharset','libiconv'),'LGPL library terms; tools have separate GPL terms','https://www.gnu.org/software/libiconv/','https://www.gnu.org/software/libiconv/'),
 ('libxslt/libexslt',('libexslt','libxslt'),'MIT-style, separate libexslt notice','https://gitlab.gnome.org/GNOME/libxslt','https://github.com/GNOME/libxslt/blob/master/Copyright'),
 ('libffi',('libffi',),'MIT','https://github.com/libffi/libffi','https://github.com/libffi/libffi/blob/master/LICENSE'),
 ('FreeType',('libfreetype',),'FTL or GPLv2; exact source/per-file choice required','https://freetype.org/','https://freetype.org/license.html'),
 ('GNU GMP',('libgmp',),'LGPLv3 or GPLv2; inspect selected version and files','https://gmplib.org/','https://gmplib.org/manual/Copying'),
 ('GnuTLS',('libgnutls',),'core library LGPL-2.1-or-later; other parts differ','https://www.gnutls.org/','https://gnutls.org/'),
 ('GNU Nettle/Hogweed',('libnettle','libhogweed'),'LGPLv3 or GPLv2; inspect selected version and files','https://www.lysator.liu.se/~nisse/nettle/','https://www.lysator.liu.se/~nisse/nettle/nettle.html'),
 ('ICU',('libicu',),'Unicode license and bundled third-party terms','https://github.com/unicode-org/icu','https://github.com/unicode-org/icu/blob/main/LICENSE'),
 ('GNU libidn2',('libidn2',),'LGPLv3 or GPLv2; Unicode data also needs review','https://www.gnu.org/software/libidn/','https://www.gnu.org/s/libidn/libidn2/manual/libidn2.html'),
 ('libinotify-kqueue',('libinotify',),'MIT project-family hint','https://github.com/libinotify-kqueue/libinotify-kqueue','https://github.com/libinotify-kqueue/libinotify-kqueue/blob/master/LICENSE'),
 ('GNU gettext libintl',('libintl',),'LGPL library terms; gettext tools differ','https://www.gnu.org/software/gettext/','https://www.gnu.org/software/gettext/manual/html_node/Licenses.html'),
 ('LZ4',('liblz4',),'BSD library terms; command-line tools differ','https://github.com/lz4/lz4','https://github.com/lz4/lz4/blob/dev/lib/LICENSE'),
 ('XZ liblzma',('liblzma',),'current liblzma 0BSD; older releases have release-specific/public-domain terms','https://tukaani.org/xz/','https://github.com/tukaani-project/xz/blob/master/COPYING'),
 ('p11-kit',('libp11-kit',),'BSD-style library and per-file terms','https://github.com/p11-glue/p11-kit','https://github.com/p11-glue/p11-kit/blob/master/COPYING'),
 ('libpcap',('libpcap',),'BSD-style','https://github.com/the-tcpdump-group/libpcap','https://github.com/the-tcpdump-group/libpcap/blob/master/LICENSE'),
 ('libpng',('libpng',),'PNG Reference Library License; release-specific text','https://github.com/pnggroup/libpng','https://github.com/pnggroup/libpng/blob/libpng16/LICENSE'),
 ('GNU libtasn1',('libtasn1',),'LGPL library terms; exact source required','https://www.gnu.org/software/libtasn1/','https://www.gnu.org/software/libtasn1/'),
 ('GNU libunistring',('libunistring',),'LGPL-3.0-or-later OR GPL-2.0-or-later; per-file terms','https://www.gnu.org/software/libunistring/','https://www.gnu.org/software/libunistring/manual/html_node/Licenses.html'),
 ('Vulkan Loader',('libvulkan',),'Apache-2.0 project-family hint; exact bundled version/build unknown','https://github.com/KhronosGroup/Vulkan-Loader','https://github.com/KhronosGroup/Vulkan-Loader/blob/main/LICENSE.txt'),
 ('libxml2',('libxml2',),'MIT-style and per-file notices','https://gitlab.gnome.org/GNOME/libxml2','https://github.com/GNOME/libxml2/blob/master/Copyright'),
 ('zlib',('libz.',),'zlib license','https://zlib.net/','https://zlib.net/zlib_license.html'),
 ('Zstandard',('libzstd',),'BSD library option; alternative GPL terms and per-file notices','https://github.com/facebook/zstd','https://github.com/facebook/zstd/blob/dev/LICENSE'),
]
MACH={b'\xcf\xfa\xed\xfe':('<',64),b'\xce\xfa\xed\xfe':('<',32),b'\xfe\xed\xfa\xcf':('>',64),b'\xfe\xed\xfa\xce':('>',32)}
FAT={b'\xca\xfe\xba\xbe':('>',32),b'\xca\xfe\xba\xbf':('>',64),b'\xbe\xba\xfe\xca':('<',32),b'\xbf\xba\xfe\xca':('<',64)}
CPU={7:'x86',0x1000007:'x86_64',12:'arm',0x100000c:'arm64'}
DYLIB_LOADS={0xc,0x80000018,0x8000001f,0x20,0x80000023}


def version(number):return f'{number>>16}.{(number>>8)&255}.{number&255}'
def sha256(path):
    with path.open('rb')as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def family(name):
    for title,prefixes,license_hint,source,license_url in CATALOG:
        if name.startswith(prefixes):return {'name':title,'upstreamLicenseHint':license_hint,'sourceLeadURL':source,'licenseLeadURL':license_url,'binaryLicenseExpression':None,'hintIsNotBinaryLicenseApproval':True}
    return {'name':'unknown','binaryLicenseExpression':None,'hintIsNotBinaryLicenseApproval':True}


def binary_headers(path):
    with path.open('rb')as stream:
        length=path.stat().st_size
        def read(offset,size):
            if offset<0 or size<0 or offset+size>length:raise ValueError('Truncated binary structure')
            stream.seek(offset);data=stream.read(size)
            if len(data)!=size:raise ValueError('Truncated binary structure')
            return data
        magic=read(0,min(4,length))
        if magic==b'\x7fELF':
            data=read(0,20);endian='<'if data[5]==1 else'>'
            kind,machine=struct.unpack_from(endian+'HH',data,16)
            return {'format':'ELF','bits':{1:32,2:64}.get(data[4]),'machine':machine,'dynamicLibraryOrPIE':kind==3,'architectures':[{3:'x86',62:'x86_64',183:'arm64'}.get(machine,str(machine))]}
        if magic not in MACH and magic not in FAT:return {'format':'unknown','architectures':[]}
        offsets=[(0,length)]
        if magic in FAT:
            endian,bits=FAT[magic];count=struct.unpack(endian+'I',read(4,4))[0]
            if count>64:raise ValueError('Too many fat slices')
            stride=32 if bits==64 else 20;table=read(8,count*stride);offsets=[]
            for i in range(count):
                entry=struct.unpack_from(endian+('IIQQII'if bits==64 else'IIIII'),table,i*stride)
                offsets.append((entry[2],entry[3]))
        slices=[]
        for offset,size in offsets:
            head=read(offset,min(size,32));endian,bits=MACH.get(head[:4],(None,None))
            if endian is None:raise ValueError('Invalid Mach-O slice')
            cpu,subtype,kind,count,command_size=struct.unpack_from(endian+'IIIII',head,4)
            header_size=32 if bits==64 else 28
            if command_size>4*1024*1024 or count>65536 or header_size+command_size>size:raise ValueError('Invalid load command bounds')
            commands=read(offset+header_size,command_size);at=0
            item={'architecture':CPU.get(cpu,hex(cpu)),'cpuType':cpu,'cpuSubtype':subtype,'bits':bits,'fileType':kind,'dynamicLibrary':kind==6,'dependencies':[],'rpaths':[]}
            def text(command,position):
                if position<8 or position>=len(command):raise ValueError('Invalid string command offset')
                return command[position:].split(b'\0',1)[0].decode('utf-8','replace')
            for _ in range(count):
                if at+8>len(commands):raise ValueError('Truncated load command')
                code,bytes_=struct.unpack_from(endian+'II',commands,at)
                if bytes_<8 or at+bytes_>len(commands):raise ValueError('Invalid load command size')
                command=commands[at:at+bytes_]
                if code==0xd or code in DYLIB_LOADS:
                    if bytes_<24:raise ValueError('Invalid dylib command')
                    name,timestamp,current,compatibility=struct.unpack_from(endian+'IIII',command,8)
                    info={'name':text(command,name),'currentVersion':version(current),'compatibilityVersion':version(compatibility),'loadCommand':hex(code),'weak':code==0x80000018}
                    if code==0xd:item['installID']=info
                    else:item['dependencies'].append(info)
                elif code==0x8000001c:
                    item['rpaths'].append(text(command,struct.unpack_from(endian+'I',command,8)[0]))
                elif code==0x1b and bytes_>=24:item['uuid']=str(uuid.UUID(bytes=command[8:24]))
                elif code==0x32 and bytes_>=24:
                    platform,minimum,sdk=struct.unpack_from(endian+'III',command,8)
                    item['buildVersion']={'platform':platform,'minimumOS':version(minimum),'sdk':version(sdk)}
                elif code==0x24 and bytes_>=16:
                    minimum,sdk=struct.unpack_from(endian+'II',command,8);item['buildVersion']={'platform':1,'minimumOS':version(minimum),'sdk':version(sdk)}
                at+=bytes_
            slices.append(item)
        return {'format':'Mach-O','slices':slices,'architectures':sorted({s['architecture']for s in slices}),'dynamicLibrary':bool(slices)and all(s['dynamicLibrary']for s in slices)}


def bootstrap_inventory(root):
    root=root.resolve(strict=True);record_path=ROOT/'Runtime/wine-deps.artifact.json'
    known_bootstrap=root==(ROOT/'Runtime/wine-deps/lib').resolve()
    artifact=json.loads(record_path.read_text())if known_bootstrap and record_path.is_file()else{}
    aliases=[];files=[];issues=[];declared=set(artifact.get('extracted',[]));present=set()
    for entry in sorted(root.iterdir()):
        present.add(entry.name)
        if entry.is_symlink():
            alias={'name':entry.name,'linkText':os.readlink(entry)}
            try:
                target=entry.resolve(strict=True)
                if not target.is_relative_to(root):raise ValueError('Symlink leaves dependency root')
                alias['target']=str(target.relative_to(root));alias['safeAndPresent']=target.is_file()
            except (OSError,ValueError,RuntimeError):alias['safeAndPresent']=False;issues.append('Unsafe or broken alias: '+entry.name)
            aliases.append(alias);continue
        if not entry.is_file():issues.append('Unexpected non-file: '+entry.name);continue
        item={'name':entry.name,'bytes':entry.stat().st_size,'sha256':sha256(entry),'projectFamilyLead':family(entry.name),'versionHints':{'filename':re.findall(r'\d+(?:\.\d+)+',entry.name),'areExactSourceVersions':False},'sourceEvidence':{'exactSourceVersion':None,'exactSourceRevision':None,'sourceArchiveSHA256':None,'patchSet':None,'dependencyBuildRecipe':None,'binaryToSourceCorrespondenceVerified':False},'binaryRedistributionReady':False,'blockers':['exact_dependency_source_and_patch_set_not_recorded','dependency_build_recipe_and_link_flags_not_recorded','binary_specific_license_notices_not_recorded','binary_to_source_mapping_not_verified']}
        if item['projectFamilyLead']['name']=='MacPorts Legacy Support':item['blockers'].append('mixed_license_compiled_file_subset_not_verified')
        try:item['binary']=binary_headers(entry)
        except (OSError,ValueError,struct.error)as error:item['binary']={'format':'malformed','error':str(error)}
        if item['binary'].get('format')!='Mach-O' or not item['binary'].get('dynamicLibrary'):item['blockers'].append('not_a_valid_macos_dynamic_library')
        files.append(item)
    canonical={p.name:p.name for p in root.iterdir()if p.is_file()and not p.is_symlink()}
    canonical.update({a['name']:a['target']for a in aliases if a['safeAndPresent']})
    graph={item['name']:set()for item in files};unresolved=[]
    for item in files:
        for part in item['binary'].get('slices',[]):
            for dependency in part['dependencies']:
                name=dependency['name']
                if name.startswith(('/usr/lib/','/System/Library/')):dependency['resolution']='macOS-system-not-bundled';continue
                basename=pathlib.PurePosixPath(name).name
                if name.startswith('@loader_path/')and name!='@loader_path/'+basename:
                    dependency['resolution']='unresolved';unresolved.append({'from':item['name'],'name':name});continue
                target=canonical.get(basename)
                if target is not None:
                    dependency['resolution']='bundle-local-candidate';dependency['target']=target;graph[item['name']].add(target)
                else:dependency['resolution']='unresolved';unresolved.append({'from':item['name'],'name':name})
    entries=[canonical[name]for name in ['libgnutls.30.dylib','libfreetype.6.dylib']if name in canonical]
    reached=set();todo=list(entries)
    while todo:
        node=todo.pop()
        if node in reached:continue
        reached.add(node);todo.extend(graph.get(node,[]))
    notices=[str(p.relative_to(root.parent))for p in root.parent.rglob('*')if p.is_file()and any(token in p.name.lower()for token in ('license','copying','notice','copyright'))]
    headers=ROOT/'Runtime/dependency-headers'
    header_packages={name:sorted(p.name for p in (headers/name).iterdir()if p.is_dir())if(headers/name).is_dir()else[]for name in ('gnutls','freetype')}
    summary={'physicalFiles':len(files),'machODylibs':sum(i['binary'].get('format')=='Mach-O'and i['binary'].get('dynamicLibrary',False)for i in files),'elfFiles':sum(i['binary'].get('format')=='ELF'for i in files),'symlinkAliases':len(aliases),'payloadBytes':sum(i['bytes']for i in files),'projectFamilies':len({i['projectFamilyLead']['name']for i in files}),'licenseNoticeFiles':len(notices),'filesWithVerifiedCorrespondingSource':0}
    return {'schema':1,'provenanceKind':'known-community-bootstrap'if known_bootstrap else'unknown-bootstrap','generatedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'community dependency dylibs only; not a complete launcher/runtime release audit','root':str(root),'binaryRedistributionReady':False,'gateReasons':['community_binary_container_provenance_is_not_exact_dependency_source_provenance','per_dependency_sources_patches_build_recipes_and_notices_not_retained','source_rebuild_and_binary_to_source_mapping_required_before_release'],'summary':summary,'containerRecord':artifact,'containerRecordSHA256':sha256(record_path)if record_path.is_file()else None,'recordDigestMatchesPublisherDigestChecked20261028':artifact.get('url')==ORIGINAL_URL and artifact.get('sha256')==ORIGINAL_DIGEST,'publisherEvidenceURL':'https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/tags/11.18','originalArchiveRetainedForPerFileReverification':False,'localNoticeFiles':notices,'extractionNameAudit':{'missingFromCurrentDirectory':sorted(declared-present),'notListedInExtractionRecord':sorted(present-declared)},'headerPackages':{'packages':header_packages,'headerArtifactRecordPresent':(ROOT/'Runtime/dependency-headers.artifact.json').is_file(),'note':'Homebrew header bottles are separate build inputs, not corresponding source for the community dependency dylibs.'},'configuredGnuTLSAndFreeTypeLinkClosure':{'entrypoints':sorted(set(entries)),'physicalLibrariesReached':sorted(reached),'note':'Static load-command closure of these two known configure inputs only; not a complete dlopen/runtime reachability proof.'},'unresolvedNonSystemDependencies':unresolved,'issues':issues,'files':files,'symlinks':aliases}


REQUIRED_RUNTIME_CHECKS={
    'platform.wine1120.pe64','platform.wine1120.pe32',
    'platform.winecx1119.pe64','platform.winecx1119.pe32',
    'gpu.wine1120.pe64','gpu.wine1120.pe32',
}

def source_inventory(prefix):
    prefix=prefix.resolve(strict=True);errors=[];cache={}
    def checked(relative):
        raw=pathlib.Path(relative)
        if raw.is_absolute()or '..'in raw.parts:raise ValueError('Unsafe source manifest path')
        path=(prefix/raw).resolve(strict=True)
        if not path.is_relative_to(prefix)or not path.is_file():raise ValueError('Source manifest path leaves prefix')
        return path
    def hashed(path):
        path=path.resolve(strict=True)
        if path not in cache:cache[path]=sha256(path)
        return cache[path]
    selection_path=prefix/'selected-runtime-files.json';selection=None
    if selection_path.is_file():
        selection=json.loads(checked('selected-runtime-files.json').read_text())
        if selection.get('schema')!=1:errors.append('unsupported_subset_selection_schema')
        manifest_path=checked(selection['originManifestPath'])
    else:manifest_path=prefix/'manifest.json'
    manifest=json.loads(manifest_path.read_text());manifest_hash=hashed(manifest_path)
    wanted={}
    for item in manifest.get('binaryFiles',[]):
        parts=item.get('binary',{}).get('slices',[])
        if item['path'].startswith('lib/')and item.get('binary',{}).get('format')=='Mach-O'and parts and all(part.get('fileType')in(6,8)for part in parts):wanted[item['path']]=item['sha256']
    if selection:
        excluded={item['path']:item['sha256']for item in manifest['binaryFiles']if item['path']not in wanted}
        if selection.get('originManifestSHA256')!=manifest_hash or selection.get('dependencySetID')!=manifest.get('dependencySetID'):errors.append('subset_origin_manifest_mismatch')
        if selection.get('selectedBinaryHashes')!=wanted or selection.get('excludedCodeInputs')!=excluded:errors.append('subset_selection_does_not_match_shared_library_policy')
    if manifest.get('sourceEvidenceComplete')is not True:errors.append('source_evidence_not_complete')
    provenance=manifest.get('provenanceFiles',{})
    for relative,expected in provenance.items():
        if hashed(checked(relative))!=expected:errors.append('provenance_hash_mismatch:'+relative)
    lock_path=checked('share/ready/sources.lock.json')
    if hashed(lock_path)!=manifest.get('sourcesLockSHA256'):errors.append('source_lock_hash_mismatch')
    source_lock=json.loads(lock_path.read_text());inputs={item['name']:item for item in source_lock['sources']}
    components={}
    for name,relative in manifest.get('componentReceipts',{}).items():
        path=checked(relative)
        if relative not in provenance:errors.append('unbound_component_receipt:'+name)
        item=json.loads(path.read_text());components[name]=item;source=inputs.get(name,{})
        if item.get('sourceSHA256')!=source.get('sha256')or item.get('version')!=source.get('version'):errors.append('component_source_mismatch:'+name)
        recipe='share/ready/recipes/'+item.get('recipeScriptSHA256','')+'.py'
        if hashed(checked(recipe))!=item.get('recipeScriptSHA256'):errors.append('component_recipe_mismatch:'+name)
        if not item.get('notices'):errors.append('missing_component_notices:'+name)
        for notice in item.get('notices',[]):
            if notice not in provenance:errors.append('unbound_component_notice:'+name)
        if item.get('notices')and not any(checked(notice).stat().st_size for notice in item['notices']):errors.append('no_nonempty_component_notice:'+name)
        archive=checked(item['sourceArchiveRelative'])
        if hashed(archive)!=source.get('sha256'):errors.append('source_archive_mismatch:'+name)
    if set(inputs)!=set(components)or len(components)!=manifest.get('componentCount'):errors.append('source_component_set_incomplete')
    all_binaries={};approved=[];other=[];actual_shared=set();all_code=set();records={}
    for entry in manifest.get('binaryFiles',[]):
        relative=entry['path']
        if selection and relative not in wanted:
            if (prefix/relative).exists()or(prefix/relative).is_symlink():errors.append('excluded_code_present:'+relative)
            actual=entry['sha256'];other.append(relative)
        else:actual=hashed(checked(relative))
        all_binaries[relative]=actual
        if actual!=entry['sha256']:errors.append('binary_hash_mismatch:'+relative)
        component=components.get(entry.get('component'),{})
        if not component or component.get('installedFiles',{}).get(relative)!=actual:errors.append('binary_receipt_mapping_mismatch:'+relative)
        if component.get('sourceSHA256')!=entry.get('sourceSHA256')or component.get('recipeScriptSHA256')!=entry.get('recipeSHA256'):errors.append('binary_source_mapping_mismatch:'+relative)
        if entry.get('notices')!=component.get('notices'):errors.append('binary_notices_mismatch:'+relative)
    for file in prefix.rglob('*'):
        if not file.is_file()or file.is_symlink():continue
        with file.open('rb')as stream:magic=stream.read(8)
        if magic[:4]in MACH or magic[:4]in FAT:
            relative=str(file.relative_to(prefix));all_code.add(relative);info=binary_headers(file)
            if relative not in all_binaries:errors.append('unmapped_code_file:'+relative)
            if info['architectures']!=['x86_64']:errors.append('unexpected_architecture:'+relative)
            for part in info['slices']:
                minimum=part.get('buildVersion',{}).get('minimumOS')
                if minimum is None or tuple(map(int,minimum.split('.')))>(14,0,0):errors.append('deployment_target_not_mac14:'+relative)
            if relative.startswith('lib/')and all(part['fileType']in(6,8)for part in info['slices']):
                actual_shared.add(file.resolve());records[relative]=info;approved.append(relative)
            else:other.append(relative)
        elif magic==b'!<arch>\n':all_code.add(str(file.relative_to(prefix)));other.append(str(file.relative_to(prefix)))
    if all_code!=(set(wanted)if selection else set(all_binaries)):errors.append('binary_manifest_set_mismatch')
    if set(approved)!=set(wanted):errors.append('actual_shared_library_selection_mismatch')
    fingerprint=hashlib.sha256(json.dumps(all_binaries,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    if fingerprint!=manifest.get('binaryFingerprint'):errors.append('binary_fingerprint_mismatch')
    aliases=[];system=[];links=[]
    for alias in (prefix/'lib').rglob('*'):
        if not alias.is_symlink():continue
        target=alias.resolve(strict=True)
        if not target.is_relative_to(prefix/'lib'):errors.append('dependency_alias_leaves_lib:'+str(alias.relative_to(prefix)))
        aliases.append({'path':str(alias.relative_to(prefix)),'linkText':os.readlink(alias),'target':str(target.relative_to(prefix))if target.is_relative_to(prefix)else None})
    for relative,info in records.items():
        file=prefix/relative
        for part in info['slices']:
            for item in part['dependencies']:
                name=item['name']
                if 'MacportsLegacy'in name:errors.append('legacy_support_dependency:'+relative)
                if name.startswith(('/usr/lib/','/System/Library/')):
                    system.append({'from':relative,'name':name,'weak':item.get('weak',False),'redistributed':False});continue
                if name.startswith('@loader_path/'):
                    target=(file.parent/name[len('@loader_path/'):]).resolve(strict=True)
                    if target not in actual_shared:errors.append('dependency_outside_scoped_payload:'+relative+':'+name)
                    links.append({'from':relative,'name':name,'target':str(target.relative_to(prefix))if target.is_relative_to(prefix)else None})
                else:errors.append('unresolved_or_nonrelocatable_dependency:'+relative+':'+name)
    corresponding=not errors
    runtime_errors=[];receipt_path=checked(selection['originReceiptPath'])if selection else prefix/'runtime-validation.json';receipt=None
    if receipt_path.is_file():
        receipt=json.loads(receipt_path.read_text())
        if selection and hashed(receipt_path)!=selection.get('originReceiptSHA256'):runtime_errors.append('subset_origin_receipt_mismatch')
        if receipt.get('dependencySetID')!=manifest.get('dependencySetID'):runtime_errors.append('runtime_dependency_set_id_mismatch')
        if receipt.get('dependencyManifestSHA256')!=manifest_hash:runtime_errors.append('runtime_manifest_hash_mismatch')
        if receipt.get('binaryFingerprint')!=fingerprint:runtime_errors.append('runtime_binary_fingerprint_mismatch')
        if receipt.get('testedBinaryHashes')!=all_binaries:runtime_errors.append('runtime_binary_inputs_mismatch')
        if receipt.get('passed')is not True or receipt.get('candidateInputsUnchanged')is not True:runtime_errors.append('runtime_validation_not_passed')
        tests=receipt.get('tests',{})
        if not REQUIRED_RUNTIME_CHECKS.issubset(tests)or any(tests[name]is not True for name in REQUIRED_RUNTIME_CHECKS):runtime_errors.append('runtime_required_matrix_incomplete')
        if any(value is not True for value in tests.values()):runtime_errors.append('runtime_matrix_has_failure')
        evidence=receipt.get('evidenceFiles',[])
        if not evidence:runtime_errors.append('runtime_evidence_files_missing')
        for item in evidence:
            raw=pathlib.Path(item['path']);path=(raw if raw.is_absolute()else ROOT/raw).resolve(strict=True)
            if not path.is_relative_to((ROOT/'Evidence').resolve())or not path.is_file():runtime_errors.append('runtime_evidence_path_outside_owned_logs');continue
            if hashed(path)!=item.get('sha256'):runtime_errors.append('runtime_evidence_hash_mismatch:'+path.name)
            if path.suffix=='.json':
                raw_report=json.loads(path.read_text())
                if 'testedBinaryHashes'in raw_report:
                    if raw_report['testedBinaryHashes']!=all_binaries:runtime_errors.append('runtime_log_binary_inputs_mismatch:'+path.name)
                    if raw_report.get('candidateInputsUnchanged')is not True:runtime_errors.append('runtime_log_inputs_changed:'+path.name)
                    for field in ('binaryFingerprint','dependencyBinaryFingerprint'):
                        if field in raw_report and raw_report[field]!=fingerprint:runtime_errors.append('runtime_log_fingerprint_mismatch:'+path.name)
                    if 'dependencyManifestSHA256'in raw_report and raw_report['dependencyManifestSHA256']!=manifest_hash:runtime_errors.append('runtime_log_manifest_mismatch:'+path.name)
                    if 'allPassed'in raw_report and raw_report['allPassed']is not True:runtime_errors.append('runtime_log_test_failed:'+path.name)
                    if 'allOpenGPUPathsPassed'in raw_report and raw_report['allOpenGPUPathsPassed']is not True:runtime_errors.append('runtime_log_gpu_test_failed:'+path.name)
                    if raw_report.get('certificateValidationBypassUsed',False)is not False:runtime_errors.append('runtime_tls_validation_bypassed:'+path.name)

    else:runtime_errors.append('runtime_validation_receipt_missing')
    return {'schema':2,'provenanceKind':'source-runtime-subset'if selection else'source-build-manifest','scope':'dependency shared-library/module payload only; does not approve app, tools, static libraries, fonts/assets, or optional proprietary system/runtime files','root':str(prefix),'dependencySetID':manifest.get('dependencySetID'),'dependencyManifestSHA256':manifest_hash,'binaryFingerprint':fingerprint,'payloadFingerprint':hashlib.sha256(json.dumps({path:all_binaries[path]for path in sorted(approved)},sort_keys=True,separators=(',',':')).encode()).hexdigest(),'selectionSHA256':hashed(selection_path)if selection else None,'correspondingSourceComplete':corresponding,'runtimeValidationPending':bool(runtime_errors),'binaryRedistributionReady':corresponding and not runtime_errors,'gateReasons':errors+runtime_errors,'summary':{'sourceComponents':len(components),'mappedCodeInputs':len(all_binaries),'approvedPayloadLibrariesAndModules':len(approved),'unapprovedOtherCodeInputs':len(other),'provenanceFilesVerified':len(provenance),'runtimeChecks':len(receipt.get('tests',{}))if receipt else 0},'approvedPayloadFiles':sorted(approved),'outsideScopeCodeFiles':sorted(other),'systemDependenciesNotRedistributed':system,'actualSharedLibraryClosure':links,'aliases':aliases,'runtimeValidationReceiptSHA256':hashed(receipt_path)if receipt else None}

def inventory(root):
    path=root.resolve(strict=True)
    if (path/'manifest.json').is_file()or(path/'selected-runtime-files.json').is_file():return source_inventory(path)
    if path.name=='lib'and((path.parent/'manifest.json').is_file()or(path.parent/'selected-runtime-files.json').is_file()):return source_inventory(path.parent)
    return bootstrap_inventory(path)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=pathlib.Path,default=ROOT/'Runtime/wine-deps/lib')
    parser.add_argument('--output',type=pathlib.Path)
    parser.add_argument('--gate',action='store_true',help='Exit 3 while binary redistribution is not ready')
    args=parser.parse_args()
    try:report=inventory(args.root)
    except (OSError,ValueError,KeyError,TypeError,struct.error):report={'schema':2,'binaryRedistributionReady':False,'gateReasons':['invalid_or_incomplete_dependency_evidence'],'summary':{}}
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps({'binaryRedistributionReady':report['binaryRedistributionReady'],'summary':report['summary'],'output':str(args.output)}))
    else:print(json.dumps(report,indent=2))
    return 3 if args.gate and not report['binaryRedistributionReady'] else 0

if __name__=='__main__':raise SystemExit(main())
