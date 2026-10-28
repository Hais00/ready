#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Unchanged-source MoltenVK1.4.2 candidate on the authorized external APFS root.
No active configuration, existing provider, prefix, DLL or Vendor is modified.
"""
import argparse, hashlib, json, os, pathlib, plistlib, shutil, signal, stat, subprocess, sys, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
EXTERNAL=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
PACKET=ROOT/'Runtime/CorrespondingSources/renderer-sources-4d0f21c8f6e04e228035'
LOCK=pathlib.Path(__file__).with_suffix('.lock.json')
RESERVE=2*1024**3
CPM_FILE='78ba32abdf798bc616bab7c73aac32a17bbd7b06ad9e26a6add69de8f3ae4791'
CPM_SOURCE='d2c42818e748e2bfad983b485beeb228e4271eb5167ba3e1ea9a64f6542c3e14'


def sha(p):
    with pathlib.Path(p).open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()

def write(p,value):
    p.parent.mkdir(parents=True,exist_ok=True);temporary=p.with_name(p.name+'.pending')
    with temporary.open('w')as f:json.dump(value,f,indent=2,sort_keys=True);f.write('\n');f.flush();os.fsync(f.fileno())
    os.replace(temporary,p)

def external():
    info=EXTERNAL.lstat();marker=EXTERNAL/'.ready-external-workspace';m=marker.lstat()
    if not stat.S_ISDIR(info.st_mode)or info.st_uid!=os.geteuid()or info.st_mode&0o077 or not stat.S_ISREG(m.st_mode)or m.st_uid!=os.geteuid()or marker.read_text()!='ready project work for thread01a17e79\n':raise ValueError('External root is not the authorized private workspace')
    volume=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/Volumes/Dati APFS']))
    if volume.get('FilesystemType')!='apfs':raise ValueError('APFS workspace required')
    if shutil.disk_usage(EXTERNAL).free<RESERVE:raise OSError('External source build reserve reached')

def binary(path):
    sys.dont_write_bytecode=True
    sys.path.insert(0,str(ROOT/'Scripts'))
    from runtime_dependency_inventory import binary_headers
    return binary_headers(path)

def inventory(directory):
    return {str(p.relative_to(directory)):{'link':os.readlink(p)}if p.is_symlink()else{'sha256':sha(p),'mode':stat.S_IMODE(p.stat().st_mode)}for p in sorted(directory.rglob('*'))if p.is_file()or p.is_symlink()}

def plan():
    external();packet=json.loads((PACKET/'source.lock.json').read_text());root=next(r for r in packet['roots']if r['name']=='moltenvk');node=packet['nodes'][root['node']]
    if node['commit']!='db66022459ffb663aa2b50f6b018bc2e124f5edf':raise ValueError('Unexpected MoltenVK source commit')
    selected={root['node'],*[c['node']for c in node['children']]}
    return {'schema':1,'component':'MoltenVK1.4.2','commit':node['commit'],'rootNode':root['node'],'sourcePacketFingerprint':json.loads((PACKET/'packet-manifest.json').read_text())['fingerprint'],'sourceNodes':{key:packet['nodes'][key]for key in sorted(selected)},'architectures':['x86_64','arm64'],'minimumMacOS':'27.0','sourceRootRelative':'trees/moltenvk-v1.4.2','CPM':{'version':'0.40.8','bootstrapURL':'https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.40.8/CPM.cmake','bootstrapSHA256':CPM_FILE,'sourceArchiveURL':'https://codeload.github.com/cpm-cmake/CPM.cmake/tar.gz/refs/tags/v0.40.8','sourceArchiveSHA256':CPM_SOURCE},'features':{'SPIRVTools':True,'cerealPipelineCache':True,'MetalPrivateAPI':False,'shaderConverterCLIIncluded':False},'upstreamSourceModified':False,'activationAllowed':False,'binaryRedistributionReady':False}


class Builder:
    def __init__(self):
        external();self.lock=json.loads(LOCK.read_text());self.identity=sha(LOCK)[:20];self.work=EXTERNAL/'build'/('moltenvk-'+self.identity);self.work.mkdir(mode=0o700,parents=True,exist_ok=True)
        (self.work/'.ready-moltenvk-build').write_text('Owned isolated source-built renderer candidate\n');self.source=self.work/'source';self.logs=self.work/'logs';self.logs.mkdir(exist_ok=True);self.tmp=self.work/'tmp';self.tmp.mkdir(exist_ok=True)
        self.records=json.loads((self.work/'commands.json').read_text())if(self.work/'commands.json').exists()else[];self.recipeSHA=sha(pathlib.Path(__file__));recipes=self.work/'recipes';recipes.mkdir(exist_ok=True);shutil.copy2(__file__,recipes/(self.recipeSHA+'.py'));shutil.copy2(ROOT/'LICENSE',recipes/'LICENSE')
        self.env={k:v for k,v in os.environ.items()if k not in ['CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','SDKROOT','CFLAGS','CXXFLAGS','CPPFLAGS','LDFLAGS','ARCHFLAGS']and not k.startswith(('DYLD_','PKG_CONFIG','CMAKE_','CPM_','VK_','MESA_'))}
        self.env.update(PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',CC='/usr/bin/clang',CXX='/usr/bin/clang++',OBJC='/usr/bin/clang',OBJCXX='/usr/bin/clang++',MACOSX_DEPLOYMENT_TARGET='27.0',TMPDIR=str(self.tmp),PYTHONDONTWRITEBYTECODE='1',CPM_SOURCE_CACHE=str(self.work/'cache'))
    def run(self,name,args,cwd=None):
        external();log=self.logs/(str(len(self.records)).zfill(3)+'-'+name+'.log');began=time.monotonic()
        with log.open('wb')as f:
            proc=subprocess.Popen(list(map(str,args)),cwd=cwd or self.source,env=self.env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
            while proc.poll()is None:
                if shutil.disk_usage(EXTERNAL).free<RESERVE:
                    os.killpg(proc.pid,signal.SIGTERM);time.sleep(1)
                    try:os.killpg(proc.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                    proc.wait();raise OSError('External reserve reached; only this source build was stopped')
                time.sleep(.5)
        self.records.append({'name':name,'command':list(map(str,args)),'cwd':str(cwd or self.source),'recipeSHA256':self.recipeSHA,'exitCode':proc.returncode,'log':str(log),'logSHA256':sha(log),'seconds':round(time.monotonic()-began,3)})
        write(self.work/'commands.json',self.records);print(name,proc.returncode,flush=True)
        if proc.returncode:raise RuntimeError('Actual source build step failed: '+name+'; '+str(log))
    def prepare(self):
        # Verify the immutable packet before using any code; no fetch/finalize path.
        self.run('packet-verify',[sys.executable,ROOT/'Scripts/runtime_fetch_renderer_sources.py','verify','--packet',PACKET],cwd=ROOT)
        if not self.source.exists():shutil.copytree(PACKET/self.lock['sourceRootRelative'],self.source,copy_function=shutil.copy2,symlinks=True)
        for node in self.lock['sourceNodes'].values():
            archive=PACKET/'archives'/(node['id']+'.tar.gz')
            if sha(archive)!=node['archiveSHA256']:raise ValueError('Pinned source archive changed')
        bootstrap=EXTERNAL/'cache/moltenvk-bootstrap/CPM_0.40.8.cmake';archive=EXTERNAL/'cache/moltenvk-bootstrap/cpm-source-0.40.8.tar.gz'
        if sha(bootstrap)!=CPM_FILE or sha(archive)!=CPM_SOURCE:raise ValueError('CPM source/bootstrap pin mismatch')
        cache=self.work/'cache/cpm';cache.mkdir(parents=True,exist_ok=True);shutil.copy2(bootstrap,cache/'CPM_0.40.8.cmake')
        # Each dependency needs its own exact Git metadata: otherwise upstream
        # version generators incorrectly inherit the parent MoltenVK revision.
        main=self.lock['sourceNodes'][self.lock['rootNode']]
        roots=[(self.source,main)]+[(self.source/child['path'],self.lock['sourceNodes'][child['node']])for child in main['children']]
        for directory,node in roots:
            label=node['id']
            if not(directory/'.git').exists():
                self.run('git-init-'+label,['git','init',directory],cwd=directory)
                self.run('git-origin-'+label,['git','remote','add','origin','https://github.com/'+node['repository']+'.git'],cwd=directory)
                self.run('git-commit-'+label,['git','fetch','--filter=blob:none','--depth=1','origin',node['commit']],cwd=directory)
                self.run('git-index-'+label,['git','reset','--mixed','FETCH_HEAD'],cwd=directory)
            head=subprocess.check_output(['git','-C',str(directory),'rev-parse','HEAD'],text=True).strip()
            if head!=node['commit']:raise ValueError('Upstream revision metadata mismatch')
            for entry in node['treeObject']['tree']:
                if entry['type']!='blob':continue
                p=directory/entry['path'];data=os.readlink(p).encode()if p.is_symlink()else p.read_bytes();gitsha=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
                if gitsha!=entry['sha']:raise ValueError('Upstream source changed: '+str(p))
        head=self.lock['commit']
        write(self.work/'prepared.json',{'sourceLockSHA256':sha(LOCK),'sourceCommit':head,'sourcePacketFingerprint':self.lock['sourcePacketFingerprint'],'upstreamSourceModified':False,'MetalCLIRequiredByInspectedCMakePath':False,'HomebrewRuntimeLibrariesPermitted':False})
    def configure(self,arch):
        prefix=self.work/('prefix-'+arch);build=self.work/('build-'+arch);linkmap=self.work/('link-map-'+arch+'.txt')
        args=['cmake','-S',self.source,'-B',build,'-G','Ninja','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_C_FLAGS_RELEASE=-O2 -g0','-DCMAKE_CXX_FLAGS_RELEASE=-O2 -g0','-DCMAKE_OBJC_FLAGS_RELEASE=-O2 -g0','-DCMAKE_OBJCXX_FLAGS_RELEASE=-O2 -g0','-DCMAKE_OSX_ARCHITECTURES='+arch,'-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0','-DCMAKE_INSTALL_PREFIX='+str(prefix),'-DCMAKE_EXPORT_COMPILE_COMMANDS=ON','-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF','-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF','-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local','-DCMAKE_POLICY_VERSION_MINIMUM=3.5','-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-map,"'+str(linkmap)+'"','-DCPM_SOURCE_CACHE='+str(self.work/'cache'),'-DFETCHCONTENT_FULLY_DISCONNECTED=ON','-DMVK_EXCLUDE_SPIRV_TOOLS=OFF','-DMVK_EXCLUDE_CEREAL=OFF','-DMVK_USE_METAL_PRIVATE_API=OFF','-DMVK_BUILD_SHADER_CONVERTER_TOOL=OFF','-DSPIRV_SKIP_TESTS=ON','-DSPIRV_SKIP_EXECUTABLES=ON','-DSPIRV_TOOLS_USE_MIMALLOC=OFF','-DBUILD_TESTS=OFF','-DBUILD_DOC=OFF','-DBUILD_SANDBOX=OFF','-DSKIP_PORTABILITY_TEST=ON','-DMOLTEN_VK_WITH_CCACHE=OFF']
        overrides={'SPIRV-Cross':'External/SPIRV-Cross','SPIRV-Headers':'External/SPIRV-Tools/external/spirv-headers','SPIRV-Tools':'External/SPIRV-Tools','Vulkan-Headers':'External/Vulkan-Headers','cereal':'External/cereal'}
        args+=['-DCPM_'+name+'_SOURCE='+str(self.source/value)for name,value in overrides.items()]
        args+=['-DSPIRV-Headers_SOURCE_DIR='+str(self.source/overrides['SPIRV-Headers'])]
        self.run('configure-'+arch,args)
    def build(self,arch):
        self.run('build-'+arch,['cmake','--build',self.work/('build-'+arch),'--target','MoltenVK','-j2'])
        self.run('install-'+arch,['cmake','--install',self.work/('build-'+arch)])


def freeze(b):
    external();stage=b.work/'candidate.staging'
    if stage.exists():raise ValueError('Previous candidate stage requires inspection')
    (stage/'lib').mkdir(parents=True)
    inputs=[];maps={};compilation={}
    for arch in b.lock['architectures']:
        path=b.work/('prefix-'+arch)/'lib/libMoltenVK.1.4.2.dylib'
        header=binary(path)
        if header.get('architectures')!=[arch]:raise ValueError('Built MoltenVK architecture mismatch')
        inputs.append(path)
        text=(b.work/('link-map-'+arch+'.txt')).read_text()
        import re
        objects=re.findall(r'^\[\s*\d+\]\s+(.+)$',text,re.M)
        if not objects or any('/opt/homebrew/'in x for x in objects):raise ValueError('Unproven Homebrew/static object in MoltenVK link map')
        maps[arch]={'objects':objects,'mapSHA256':sha(b.work/('link-map-'+arch+'.txt')),'HomebrewStaticObjects':[]}
        units=json.loads((b.work/('build-'+arch)/'compile_commands.json').read_text())
        compiled=[]
        for unit in units:
            source=pathlib.Path(unit['file'])
            if not source.is_absolute():source=pathlib.Path(unit['directory'])/source
            source=source.resolve(strict=True)
            if not source.is_relative_to(b.work):raise ValueError('Compilation input outside isolated source/generated build')
            compiled.append({'source':str(source),'sha256':sha(source),'command':unit.get('command'),'directory':unit['directory'],'generated':not source.is_relative_to(b.source)})
        compilation[arch]=compiled
    output=stage/'lib/libMoltenVK.dylib'
    subprocess.run(['/usr/bin/lipo','-create',*map(str,inputs),'-output',str(output)],check=True)
    before=sha(output);header=binary(output);commands=[['/usr/bin/install_name_tool','-id','@rpath/libMoltenVK.dylib',str(output)]]
    for value in sorted({r for part in header['slices']for r in part['rpaths']}):commands.append(['/usr/bin/install_name_tool','-delete_rpath',value,str(output)])
    for command in commands:subprocess.run(command,check=True,capture_output=True)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(output)],check=True,capture_output=True)
    final=binary(output)
    if final['architectures']!=['arm64','x86_64']:raise ValueError('Universal renderer slice mismatch')
    for part in final['slices']:
        for dependency in part['dependencies']:
            if not dependency['name'].startswith(('/System/','/usr/lib/')):raise ValueError('MoltenVK candidate still has non-system dylib dependency')
        if part['rpaths']or part['buildVersion']['minimumOS']!='27.0.0':raise ValueError('Unexpected native deployment/path metadata')
    write(stage/'icd/moltenvk.json',{'file_format_version':'1.0.1','ICD':{'library_path':'../lib/libMoltenVK.dylib','api_version':'1.4.0','is_portability_driver':True}})
    material=stage/'share/ready';(material/'sources').mkdir(parents=True)
    for key,node in b.lock['sourceNodes'].items():
        source=PACKET/'archives'/(key+'.tar.gz');shutil.copy2(source,material/'sources'/(key+'.tar.gz'))
        shutil.copytree(PACKET/'notices'/key,material/'notices'/key)
    bootstrap=EXTERNAL/'cache/moltenvk-bootstrap'
    shutil.copy2(bootstrap/'cpm-source-0.40.8.tar.gz',material/'sources/cpm-source-0.40.8.tar.gz')
    shutil.copy2(bootstrap/'CPM_0.40.8.cmake',material/'sources/CPM_0.40.8.cmake')
    shutil.copytree(b.work/'recipes',material/'recipes')
    receipts=material/'receipts';receipts.mkdir()
    shutil.copy2(LOCK,receipts/LOCK.name);shutil.copy2(b.work/'commands.json',receipts/'commands.json');shutil.copy2(b.work/'prepared.json',receipts/'prepared.json');shutil.copytree(b.logs,receipts/'logs')
    for arch in b.lock['architectures']:
        shutil.copy2(b.work/('build-'+arch)/'CMakeCache.txt',receipts/(arch+'-CMakeCache.txt'))
        shutil.copy2(b.work/('build-'+arch)/'compile_commands.json',receipts/(arch+'-compile_commands.json'))
        shutil.copy2(b.work/('link-map-'+arch+'.txt'),receipts/(arch+'-link-map.txt'))
    write(receipts/'source-compilation.json',compilation);write(receipts/'static-object-maps.json',maps)
    write(receipts/'post-link.json',{'thinInputs':{arch:sha(path)for arch,path in zip(b.lock['architectures'],inputs)},'universalBeforeNormalizationSHA256':before,'finalSHA256':sha(output),'commands':commands,'adHocSigned':True,'upstreamSourceModified':False})
    files=inventory(stage);fingerprint=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest();identity='ready-source-moltenvk-'+fingerprint[:20]
    write(stage/'moltenvk-source-manifest.json',{'schema':1,'identity':identity,'fingerprint':fingerprint,'files':files,'binary':final,'sourceLockSHA256':sha(LOCK),'upstreamSourceModified':False,'minimumMacOS':'27.0','runtimeValidationPending':True,'binaryRedistributionReady':False,'activationPerformed':False,'sourceGitMetadataCreatedForVersionHeaderOnly':True,'historicalArtifactBuildAttested':False})
    target=EXTERNAL/'retained'/identity
    if target.exists():raise ValueError('Refusing to overwrite immutable source candidate')
    stage.rename(target);write(b.work/'candidate.json',{'path':str(target),'identity':identity,'fingerprint':fingerprint});return target


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('operation',choices=['plan','prepare','configure','build','freeze']);p.add_argument('--arch',choices=['x86_64','arm64','all'],default='all');a=p.parse_args()
    if a.operation=='plan':value=plan();write(LOCK,value);print(json.dumps({'sourcePackages':len(value['sourceNodes']),'architectures':value['architectures'],'minimumMacOS':'27.0','binaryRedistributionReady':False},indent=2));return
    b=Builder()
    if a.operation=='prepare':b.prepare()
    elif a.operation=='configure':
        for arch in(b.lock['architectures']if a.arch=='all'else[a.arch]):b.configure(arch)
    elif a.operation=='freeze':print(json.dumps({'candidate':str(freeze(b))}))
    else:
        for arch in(b.lock['architectures']if a.arch=='all'else[a.arch]):b.build(arch)
    print(json.dumps({'work':str(b.work),'candidateOnly':True,'activationPerformed':False},indent=2))
if __name__=='__main__':main()
