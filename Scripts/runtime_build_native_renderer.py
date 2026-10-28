#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a separate source-pinned ARM64 Kosmic closure. Never activate it.

Upstream source remains unchanged. Homebrew tools may compile code; no Homebrew
library is permitted in the final dynamic/static runtime closure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = Path(__file__).with_suffix('.lock.json')
RESERVE = 512 * 1024 * 1024
PACKET = ROOT / 'Runtime/CorrespondingSources/renderer-sources-4d0f21c8f6e04e228035'
TOOL_ID = 'ca138f6c2ea253a84ca4'
HEADER_ID = 'daa06787b2dcec7bf28e'


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.pending')
    temp.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    os.replace(temp, path)


def plan():
    sources = json.loads((ROOT / 'Scripts/runtime_fetch_renderer_sources.lock.json').read_text())
    tools, headers = sources['nodes'][TOOL_ID], sources['nodes'][HEADER_ID]
    deps = (PACKET / 'repositories' / TOOL_ID / 'DEPS').read_text()
    assert re.search(r"'spirv_headers_revision':\s*'" + headers['commit'] + "'", deps)
    mesa = json.loads((ROOT / 'Vendor/mesa.source.json').read_text())
    assert mesa['version'] == '26.3.0-rc2'
    zstd = next(x for x in json.loads((ROOT / 'Scripts/runtime_dependencies.lock.json').read_text())['sources'] if x['name'] == 'zstd')
    def source_record(name, record, archive=None, source=None):
        return {'name': name, **record, 'retainedArchive': archive, 'readOnlySource': source}
    result = {'schema': 1, 'architecture': 'arm64', 'minimumMacOS': '27.0', 'optimization': '-O2 -g0', 'reserveBytes': RESERVE,
      'sources': [source_record('mesa', {k: mesa[k] for k in ['url', 'sha256', 'version']}, source='Vendor/mesa'),
        source_record('zstd', {k: zstd[k] for k in ['url', 'sha256', 'version']}, archive='Runtime/SourceDependencies/source-deps-839dc852b05e28e8b67d/share/ready/sources/zstd-1.5.7.tar.gz'),
        source_record('spirv-tools', {'url': tools['archiveURL'], 'sha256': tools['archiveSHA256'], 'commit': tools['commit'], 'version': '2026.3'}, archive=str((PACKET / 'archives' / (TOOL_ID + '.tar.gz')).relative_to(ROOT)), source=str((PACKET / 'repositories' / TOOL_ID).relative_to(ROOT))),
        source_record('spirv-headers', {'url': headers['archiveURL'], 'sha256': headers['archiveSHA256'], 'commit': headers['commit']}, archive=str((PACKET / 'archives' / (HEADER_ID + '.tar.gz')).relative_to(ROOT)), source=str((PACKET / 'repositories' / HEADER_ID).relative_to(ROOT))),
        *[source_record(name, {k: json.loads((ROOT / ('Runtime/' + version + '.artifact.json')).read_text())[k] for k in ['url', 'sha256']}, source='Runtime/' + version) for name, version in [('vulkan-loader', 'vulkan-loader-1.4.366'), ('vulkan-headers', 'vulkan-headers-1.4.366')]]],
      'compatibilityEvidence': {'mesaRequiredSPIRVTools': '>=2024.1', 'mesaLinkerAPICheck': 'SetAllowPtrTypeMismatch(true)', 'spirvToolsDEPSHeadersCommit': headers['commit'], 'depLibclcEnabledForKosmic': False, 'abiAssumedFromSoname': False},
      'forbiddenRuntimeInputs': ['Homebrew dylibs/static libraries', 'Runtime68 binaries', 'old Mesa/old community dependencies', 'Apple evaluation runtime'],
      'hostToolsOnly': ['Apple clang/SDK27', 'Homebrew Meson/Ninja/CMake/Python', 'LLVM/clang-cpp/LLVMSPIRVLib for Mesa CLC tools only'],
      'staticClosureRequiresLinkMap': True, 'activationAllowed': False, 'binaryRedistributionReady': False}
    return result


class Builder:
    def __init__(self):
        self.lock = json.loads(LOCK.read_text())
        seed = {'lockSHA256': sha(LOCK), 'recipeSHA256': sha(Path(__file__))}
        self.identity = seed['lockSHA256'][:20]
        self.work = ROOT / 'Runtime/NativeRendererWork' / self.identity
        self.prefix = self.work / 'prefix'
        self.logs = self.work / 'logs'
        self.logs.mkdir(parents=True, exist_ok=True)
        (self.work / '.ready-native-renderer-build').write_text('Owned source-built renderer staging, no activation\n')
        self.records = json.loads((self.work / 'commands.json').read_text()) if (self.work / 'commands.json').exists() else []
        recipes=self.work/'recipes';recipes.mkdir(exist_ok=True)
        shutil.copy2(Path(__file__), recipes/(seed['recipeSHA256']+'.py'))
        shutil.copy2(ROOT/'LICENSE', recipes/'LICENSE')
        self.recipeHash=seed['recipeSHA256']
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'VK_', 'MESA_', 'LLVM_', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'CPPFLAGS', 'PKG_CONFIG', 'CMAKE_'))}
        self.env.update(PATH='/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', CC='/usr/bin/clang', CXX='/usr/bin/clang++', OBJC='/usr/bin/clang', OBJCXX='/usr/bin/clang++', MACOSX_DEPLOYMENT_TARGET='27.0', PYTHONDONTWRITEBYTECODE='1', CFLAGS='-arch arm64 -O2 -g0 -mmacosx-version-min=27.0', CXXFLAGS='-arch arm64 -O2 -g0 -mmacosx-version-min=27.0', LLVM_CONFIG='/opt/homebrew/opt/llvm/bin/llvm-config', PKG_CONFIG_LIBDIR=str(self.prefix/'lib/pkgconfig')+':/opt/homebrew/opt/spirv-llvm-translator/lib/pkgconfig', PKG_CONFIG_PATH='', CMAKE_PREFIX_PATH=str(self.prefix))
        write(self.work / 'inputs.json', {'identity': self.identity, **seed, 'sourceLock': self.lock})

    def space(self):
        free = shutil.disk_usage(self.work).free
        if free < RESERVE + 64 * 1024 * 1024:
            raise RuntimeError('Source build stopped to preserve512MiB reserve; ask coordinator for safe cache cleanup')
        return free

    def run(self, name, command, env=None):
        self.space()
        path = self.logs / (str(len(self.records)).zfill(3) + '-' + name + '.log')
        print(name, flush=True)
        began = time.monotonic()
        with path.open('wb') as stream:
            proc = subprocess.Popen(list(map(str, command)), cwd=ROOT, env=env or self.env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            while proc.poll() is None:
                if shutil.disk_usage(self.work).free < RESERVE + 64 * 1024 * 1024:
                    # Leader is not reaped; its PID/group cannot have been reused.
                    os.killpg(proc.pid, signal.SIGTERM)
                    time.sleep(1)
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    proc.wait()
                    raise RuntimeError('Build stopped at disk reserve; existing outputs retained for review')
                time.sleep(.5)
            code = proc.returncode
        self.records.append({'name': name, 'recipeSHA256': self.recipeHash, 'command': list(map(str, command)), 'exitCode': code, 'seconds': round(time.monotonic()-began, 3), 'log': str(path.relative_to(ROOT)), 'logSHA256': sha(path)})
        write(self.work / 'commands.json', self.records)
        if code:
            raise RuntimeError('Build step failed: ' + name + '; see ' + str(path))

    def sources(self):
        directory = self.work / 'sources'
        directory.mkdir(exist_ok=True)
        for item in self.lock['sources']:
            name = item['name']
            archive = directory / (name + ('.tar.xz' if item['url'].endswith('.xz') else '.tar.gz'))
            if not archive.exists():
                if item.get('retainedArchive'):
                    shutil.copy2(ROOT/item['retainedArchive'], archive)
                else:
                    self.space()
                    with urllib.request.urlopen(item['url'], timeout=120) as source, archive.open('wb') as out:
                        shutil.copyfileobj(source, out, 1024*1024)
            if sha(archive) != item['sha256']:
                raise RuntimeError('Source archive hash mismatch: ' + name)
            source = ROOT/item['readOnlySource'] if item.get('readOnlySource') else directory/(name+'-source')
            if not item.get('readOnlySource') and not source.exists():
                temp = directory/(name+'-extracting');temp.mkdir()
                with tarfile.open(archive) as tf:tf.extractall(temp, filter='data')
                children=list(temp.iterdir());assert len(children)==1
                children[0].rename(source);temp.rmdir()
            if item.get('readOnlySource'):
                # Verify each archive file against the read-only source actually compiled.
                with tarfile.open(archive) as tf:
                    for member in tf:
                        parts=Path(member.name).parts[1:]
                        if not parts or not member.isfile():continue
                        target=source.joinpath(*parts)
                        with tf.extractfile(member) as stream:expected=hashlib.file_digest(stream,'sha256').hexdigest()
                        if not target.is_file() or sha(target)!=expected:raise RuntimeError('Read-only source differs from pinned archive: '+str(target))
            item['buildSourcePath']=str(source)
        write(self.work/'verified-sources.json', self.lock['sources'])

    def source(self, name):
        return Path(next(x['buildSourcePath'] for x in self.lock['sources'] if x['name']==name))

    def cmake(self, name, source, flags):
        build=self.work/('build-'+name)
        base=['cmake','-S',source,'-B',build,'-G','Ninja', '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_C_FLAGS_RELEASE=-O2 -g0','-DCMAKE_CXX_FLAGS_RELEASE=-O2 -g0','-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0','-DCMAKE_INSTALL_PREFIX='+str(self.prefix),'-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF','-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew']
        self.run(name+'-configure',base+flags)
        self.run(name+'-build',['cmake','--build',build,'-j2'])
        self.run(name+'-install',['cmake','--install',build])

    def dependencies(self):
        self.cmake('zstd',self.source('zstd')/'build/cmake',['-DZSTD_BUILD_PROGRAMS=OFF','-DZSTD_BUILD_TESTS=OFF','-DZSTD_BUILD_SHARED=ON','-DZSTD_BUILD_STATIC=OFF'])
        self.cmake('spirv',self.source('spirv-tools'),['-DSPIRV-Headers_SOURCE_DIR='+str(self.source('spirv-headers')),'-DBUILD_SHARED_LIBS=ON','-DSPIRV_TOOLS_BUILD_STATIC=OFF','-DSPIRV_TOOLS_LIBRARY_TYPE=SHARED','-DSPIRV_SKIP_TESTS=ON','-DSPIRV_TOOLS_BUILD_FUZZER=OFF','-DSPIRV_TOOLS_USE_MIMALLOC=OFF'])
        header=self.work/'headers'
        self.run('vulkan-headers-configure',['cmake','-S',self.source('vulkan-headers'),'-B',self.work/'build-headers','-DCMAKE_INSTALL_PREFIX='+str(header)])
        self.run('vulkan-headers-install',['cmake','--install',self.work/'build-headers'])
        self.cmake('loader',self.source('vulkan-loader'),['-DBUILD_TESTS=OFF','-DVULKAN_HEADERS_INSTALL_DIR='+str(header)])

    def pkg_metadata(self):
        path=self.work/'pkgconfig-normalization.json'
        records=json.loads(path.read_text()) if path.exists() else []
        for item in (self.prefix/'lib/pkgconfig').glob('*.pc'):
            original=item.read_text();changed=original.replace(str(self.prefix),str(self.prefix).replace(' ',r'\ '))
            if changed!=original:
                before=sha(item);item.write_text(changed)
                records.append({'path':str(item.relative_to(self.work)),'originalSHA256':before,'finalSHA256':sha(item),'change':'Escape build-prefix spaces in pkg-config variable text, no source or binary change'})
        write(path,records)

    def mesa(self):
        self.pkg_metadata()
        build=self.work/'build-mesa'
        flags=['-Dbuildtype=release','-Doptimization=2','-Ddebug=false','-Dplatforms=macos','-Dvulkan-drivers=kosmickrisp','-Dgallium-drivers=','-Dopengl=false','-Degl=disabled','-Dgbm=disabled','-Dglx=disabled','-Dbuild-tests=false','-Dllvm=enabled','-Dshared-llvm=enabled','-Dzstd=enabled','-Dspirv-tools=enabled','-Dc_args=-arch arm64 -g0 -mmacosx-version-min=27.0','-Dcpp_args=-arch arm64 -g0 -mmacosx-version-min=27.0','-Dobjc_args=-arch arm64 -g0 -mmacosx-version-min=27.0','-Dobjcpp_args=-arch arm64 -g0 -mmacosx-version-min=27.0','-Dc_link_args='+json.dumps(['-Wl,-map,'+str(self.work/'mesa-link-map.txt')]),'-Dcpp_link_args='+json.dumps(['-Wl,-map,'+str(self.work/'mesa-link-map.txt')])]
        self.run('mesa-configure',['meson','setup',build,self.source('mesa'),'--prefix='+str(self.prefix),*flags])
        self.run('mesa-build',['ninja','-C',build,'-j2','src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib','src/kosmickrisp/vulkan/kosmickrisp_mesa_icd.aarch64.json'])
        self.run('mesa-install',['meson','install','-C',build,'--no-rebuild','--tags','runtime'])


def binary(path):
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT/'Scripts'))
    from runtime_dependency_inventory import binary_headers
    return binary_headers(path)


def filemap(directory):
    return {str(p.relative_to(directory)): {'symlink': os.readlink(p)} if p.is_symlink() else {'sha256': sha(p)}
            for p in sorted(directory.rglob('*')) if p.is_file() or p.is_symlink()}


def freeze(b):
    library = b.prefix/'lib/libvulkan_kosmickrisp.dylib'
    if not library.is_file():
        raise RuntimeError('Mesa ICD not built')
    linkmap = b.work/'mesa-link-map.txt'
    objects = re.findall(r'^\[\s*\d+\]\s+(.+)$', linkmap.read_text(), re.M)
    if not objects or any('/opt/homebrew/' in value for value in objects):
        raise RuntimeError('Unproven/Homebrew static object in final ICD link map')
    # Every non-OS static object must originate in this source-only work tree.
    unexpected = [value for value in objects if value != 'linker synthesized' and
                  str(b.work) not in value and not value.startswith(('src/', '/Library/Developer/', '/Applications/Xcode'))]
    if unexpected:
        raise RuntimeError('Static object origin not classified: '+repr(unexpected[:5]))
    all_libraries = {p.name: p.resolve() for p in (b.prefix/'lib').glob('*.dylib') if p.is_file()}
    selected, pending = {}, ['libvulkan_kosmickrisp.dylib', 'libvulkan.1.dylib']
    while pending:
        name = pending.pop()
        path = all_libraries[name]
        if path.name in selected:
            continue
        header = binary(path)
        if header.get('architectures') != ['arm64']:
            raise RuntimeError('Unexpected native candidate architecture')
        selected[path.name] = path
        for part in header['slices']:
            for dependency in part['dependencies']:
                value = dependency['name']
                if value.startswith(('/System/', '/usr/lib/')):
                    continue
                if value.startswith('/opt/homebrew/'):
                    raise RuntimeError('Runtime still loads Homebrew: '+value)
                leaf = Path(value).name
                if leaf not in all_libraries:
                    raise RuntimeError('Unresolved native candidate dependency: '+value)
                pending.append(leaf)
    stage = b.work/'provider.staging'
    if stage.exists():
        raise RuntimeError('Previous provider stage needs review')
    (stage/'lib').mkdir(parents=True)
    modifications = []
    for name, source in selected.items():
        destination = stage/'lib'/name
        subprocess.run(['/bin/cp', '-c', str(source), str(destination)], check=True)
        header = binary(destination)
        commands = [['/usr/bin/install_name_tool', '-id', '@rpath/'+name, str(destination)]]
        for part in header['slices']:
            for dependency in part['dependencies']:
                value = dependency['name']
                if not value.startswith(('/System/', '/usr/lib/')):
                    commands.append(['/usr/bin/install_name_tool', '-change', value, '@loader_path/'+Path(value).name, str(destination)])
            for value in part['rpaths']:
                commands.append(['/usr/bin/install_name_tool', '-delete_rpath', value, str(destination)])
        for command in commands:
            subprocess.run(command, check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(destination)], check=True, capture_output=True)
        modifications.append({'path':'lib/'+name,'sourceSHA256':sha(source),'finalSHA256':sha(destination),'commands':commands,'adHocSigned':True})
    for alias, source in all_libraries.items():
        if source.name in selected and alias != source.name:
            (stage/'lib'/alias).symlink_to(source.name)
    share = stage/'share/ready'
    (share/'sources').mkdir(parents=True)
    for source in (b.work/'sources').glob('*.tar.*'):
        subprocess.run(['/bin/cp', '-c', str(source), str(share/'sources'/source.name)], check=True)
    shutil.copytree(b.work/'recipes', share/'recipes')
    # Preserve primary source notices; full archives also retain every source header.
    for record in b.lock['sources']:
        source = b.source(record['name'])
        for p in source.rglob('*'):
            if p.is_file() and not p.is_symlink() and (re.search(r'(?i)(license|copying|copyright|notice|authors)', p.name) or any(x.lower()=='licenses' for x in p.parts)):
                target = share/'notices'/record['name']/p.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, target)
    receipts = share/'receipts'
    receipts.mkdir()
    for source in [LOCK, b.work/'commands.json', b.work/'verified-sources.json', b.work/'pkgconfig-normalization.json', linkmap,
                   b.work/'build-mesa/compile_commands.json', b.work/'build-mesa/meson-info/intro-dependencies.json',
                   b.work/'build-mesa/meson-info/intro-buildoptions.json']:
        shutil.copy2(source, receipts/source.name)
    shutil.copytree(b.logs, receipts/'logs')
    for folder in ['zstd', 'spirv', 'loader']:
        shutil.copy2(b.work/('build-'+folder)/'CMakeCache.txt', receipts/(folder+'-CMakeCache.txt'))
    commands = subprocess.check_output(['ninja', '-C', str(b.work/'build-mesa'), '-t', 'commands', 'src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib'], text=True)
    (receipts/'mesa-final-target-commands.txt').write_text(commands)
    write(receipts/'normalization.json', modifications)
    write(receipts/'static-closure.json', {'finalICDObjectFiles':objects,'homebrewStaticObjects':[],'allObjectsFromMesaBuildOrSystemToolchain':True,'libclcEnabled':False,'hostLLVMAndTranslatorNotDistributed':True})
    generated = b.prefix/'share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json'
    icd = json.loads(generated.read_text())
    icd['ICD']['library_path'] = '../lib/libvulkan_kosmickrisp.dylib'
    write(stage/'icd/kosmic-arm64.json', icd)
    drirc = b.prefix/'share/drirc.d'
    if drirc.is_dir():
        shutil.copytree(drirc, stage/'share/drirc.d')
    inspected = {}
    for name in selected:
        path = stage/'lib'/name
        inspected['lib/'+name] = binary(path)
        for part in inspected['lib/'+name]['slices']:
            for dependency in part['dependencies']:
                value = dependency['name']
                if not value.startswith(('/System/', '/usr/lib/', '@loader_path/')):
                    raise RuntimeError('Native normalization left an external path')
    files = filemap(stage)
    fingerprint = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',',':')).encode()).hexdigest()
    identity = 'ready-native-renderer-'+fingerprint[:20]
    write(stage/'native-renderer-manifest.json', {'schema':1,'identity':identity,'fingerprint':fingerprint,'files':files,'nativeBinaries':inspected,'sourceLockSHA256':sha(LOCK),'minimumMacOS':'27.0','runtimeValidationPending':True,'binaryRedistributionReady':False,'appleEntirelyExcluded':True,'activationAllowed':False})
    target = ROOT/'Runtime/Providers'/identity
    if target.exists():
        raise RuntimeError('Refusing to overwrite an existing native provider')
    target.parent.mkdir(exist_ok=True)
    stage.rename(target)
    write(b.work/'candidate.json', {'path':str(target),'identity':identity,'fingerprint':fingerprint})
    return target


def probe(b):
    candidate = Path(json.loads((b.work/'candidate.json').read_text())['path'])
    manifest = json.loads((candidate/'native-renderer-manifest.json').read_text())
    before = filemap(candidate)
    before.pop('native-renderer-manifest.json')
    if before != manifest['files']:
        raise RuntimeError('Candidate changed before native probes')
    directory = b.work/'probes'
    directory.mkdir(exist_ok=True)
    headers = b.work/'headers/include'
    common = ['/usr/bin/clang', '-arch', 'arm64', '-O2', '-g0', '-mmacosx-version-min=27.0', '-I', str(headers)]
    b.run('native-buffer-compile', common+[ROOT/'Scripts/runtime_vulkan_probe.c', '-o', directory/'buffer'])
    b.run('native-properties-compile', common+[ROOT/'Scripts/runtime_vulkan_properties_probe.c', '-o', directory/'properties'])
    b.run('native-shader-present-compile', common+['-fobjc-arc', ROOT/'Scripts/runtime_native_renderer_probe.m', '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'Metal', '-o', directory/'shader-present'])
    b.run('native-image-observer-compile', ['/usr/bin/clang', '-arch', 'arm64', '-O2', '-dynamiclib', '-mmacosx-version-min=27.0', ROOT/'Scripts/runtime_native_audit.c', '-o', directory/'image-observer.dylib'])
    for name in ['vertex', 'fragment']:
        env = dict(b.env, DYLD_LIBRARY_PATH=str(b.prefix/'lib'))
        b.run('native-'+name+'-assemble', [b.prefix/'bin/spirv-as', '--target-env', 'vulkan1.0', ROOT/('Scripts/runtime_native_renderer_'+name+'.spvasm'), '-o', directory/(name+'.spv')], env=env)
        b.run('native-'+name+'-validate', [b.prefix/'bin/spirv-val', '--target-env', 'vulkan1.0', directory/(name+'.spv')], env=env)
    denied = ['/opt/homebrew', str(ROOT/'Runtime/Sets'), str(ROOT/'Runtime/wine-deps'), str(ROOT/'Runtime/mesa-26.3.0-rc2'), str(ROOT/'Runtime/mesa-x64-26.3.0-rc2'), str(ROOT/'Runtime/vulkan-sdk-1.4.366'), str(b.prefix), str(ROOT/'Vendor')]
    profile = '(version 1)(allow default)' + ''.join('(deny file-read* (subpath '+json.dumps(path)+'))' for path in denied)
    (directory/'deny-external.sb').write_text(profile+'\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('DYLD_', 'VK_', 'MESA_', 'READY_', 'D3DM_', 'CX_', 'WINE'))}
    loader = candidate/'lib/libvulkan.1.dylib'
    runtime_env = {'VK_DRIVER_FILES':str(candidate/'icd/kosmic-arm64.json'), 'VK_ICD_FILENAMES':str(candidate/'icd/kosmic-arm64.json'), 'DRIRC_CONFIGDIR':str(candidate/'share/drirc.d'), 'MESA_SHADER_CACHE_DIR':str(directory/'shader-cache'), 'DYLD_INSERT_LIBRARIES':str(directory/'image-observer.dylib')}
    report = {'schema':1, 'candidate':str(candidate), 'candidateManifestSHA256':sha(candidate/'native-renderer-manifest.json'), 'candidateFingerprint':manifest['fingerprint'], 'architecture':'arm64', 'minimumMacOS':'27.0', 'deniedRoots':denied, 'sandboxProfileSHA256':sha(directory/'deny-external.sb'), 'tests':{}, 'allPassed':False, 'activationPerformed':False, 'advertisedFeaturesModified':False, 'appleEvaluationUsed':False, 'binaryRedistributionReady':False}
    controls = {'homebrew':Path('/opt/homebrew/opt/zstd/lib/libzstd.1.dylib'),
                'old-runtime':ROOT/'Runtime/Sets/ready-source-runtime-68c00b7d3878699829eb/kosmic-arm64/libvulkan_kosmickrisp.dylib',
                'build-prefix':b.prefix/'lib/libvulkan_kosmickrisp.dylib',
                'vendor-source':ROOT/'Vendor/mesa/meson.build',
                'candidate-allowed':candidate/'lib/libvulkan_kosmickrisp.dylib'}
    report['sandboxControls'] = {}
    for name, path in controls.items():
        if not path.is_file():
            raise RuntimeError('Sandbox control input is absent')
        trial = subprocess.run(['/usr/bin/sandbox-exec','-p',profile,'/bin/dd','if='+str(path),'of=/dev/null','bs=1','count=1'],capture_output=True,text=True)
        passed = trial.returncode == 0 if name == 'candidate-allowed' else trial.returncode != 0 and 'Operation not permitted' in trial.stderr
        report['sandboxControls'][name] = {'path':str(path),'inputSHA256':sha(path),'exitCode':trial.returncode,'passed':passed}
        if not passed:
            raise RuntimeError('Sandbox denial/allow control failed: '+name)
    def execute(name, arguments):
        images = directory/(name+'.images.jsonl')
        images.unlink(missing_ok=True)
        assignments = [k+'='+v for k,v in dict(runtime_env, READY_NATIVE_AUDIT_LOG=str(images)).items()]
        command = ['/usr/bin/sandbox-exec', '-p', profile, '/usr/bin/env', *assignments, *map(str,arguments)]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
        log = directory/(name+'.log');log.write_text(result.stdout+'\n'+result.stderr)
        observations = []
        for line in result.stdout.splitlines():
            try: observations.append(json.loads(line))
            except ValueError: pass
        loaded = []
        if images.is_file():
            loaded = sorted({json.loads(line)['path'] for line in images.read_text().splitlines()})
        unexpected = [p for p in loaded if not p.startswith(('/System/', '/usr/lib/', str(candidate)+'/', str(directory)+'/'))]
        passed = result.returncode == 0 and bool(observations) and bool(loaded) and not unexpected
        report['tests'][name] = {'exitCode':result.returncode,'observations':observations,'loadedImages':loaded,'unexpectedImages':unexpected,'passed':passed,'log':str(log),'logSHA256':sha(log),'imagesSHA256':sha(images) if images.is_file() else None}
        write(ROOT/'Evidence/runtime-native-renderer-validation.json', report)
        if not passed:
            raise RuntimeError('Native sandbox probe failed: '+name+'; '+result.stderr[-1000:])
        return observations
    transfer = execute('buffer', [directory/'buffer', loader])
    if not any(v.get('readbackVerified') for v in transfer):
        raise RuntimeError('Native GPU buffer readback not verified')
    graphics = execute('shader-present', [directory/'shader-present', loader, directory/'vertex.spv', directory/'fragment.spv'])
    if not any(v.get('shaderRasterizationVerified') and v.get('presentedFrames',0)>=60 for v in graphics):
        raise RuntimeError('Native GPU shader/presentation not verified')
    inventory = execute('properties-list', [directory/'properties', loader, 'list'])
    cases = inventory[-1]['cases']
    modes = ['base', 'core', 'full']+[case['name'] for case in cases if case['supported']]
    for mode in modes:
        execute('properties-'+mode, [directory/'properties', loader, mode])
    after = filemap(candidate);after.pop('native-renderer-manifest.json')
    report['candidateUnchanged'] = after == before
    report['allPassed'] = report['candidateUnchanged'] and all(t['passed'] for t in report['tests'].values()) and all(t['passed'] for t in report['sandboxControls'].values())
    report['probeSources'] = {str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__), ROOT/'Scripts/runtime_native_renderer_probe.m', ROOT/'Scripts/runtime_native_renderer_vertex.spvasm', ROOT/'Scripts/runtime_native_renderer_fragment.spvasm', ROOT/'Scripts/runtime_native_audit.c', ROOT/'Scripts/runtime_vulkan_probe.c', ROOT/'Scripts/runtime_vulkan_properties_probe.c']}
    write(ROOT/'Evidence/runtime-native-renderer-validation.json', report)
    print(json.dumps({'nativeCandidate':str(candidate),'allPassed':report['allPassed'],'tests':len(report['tests'])}, indent=2))


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('operation',choices=['plan','sources','dependencies','mesa','freeze','probe']);a=p.parse_args()
    if a.operation=='plan':
        result=plan();write(LOCK,result);print(json.dumps(result,indent=2));return
    b=Builder();b.sources()
    if a.operation=='dependencies':b.dependencies()
    elif a.operation=='mesa':b.mesa()
    elif a.operation=='freeze':print(json.dumps({'candidate':str(freeze(b))}))
    elif a.operation=='probe':probe(b)
    print(json.dumps({'identity':b.identity,'work':str(b.work),'prefix':str(b.prefix),'minimumMacOS':'27.0','activationAllowed':False},indent=2))

if __name__=='__main__':main()
