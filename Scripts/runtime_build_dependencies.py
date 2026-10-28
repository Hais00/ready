#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build an isolated x86_64/macOS14 dependency prefix from hash-pinned public source.

Never mutates Runtime/wine-deps, active Wine, provider sets, or default config.
Every installed component has source, patch, command, toolchain and notice receipts.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT=pathlib.Path(__file__).resolve().parents[1]
LOCK=ROOT/'Scripts/runtime_dependencies.lock.json'
BASE=ROOT/'Runtime/SourceDependencies'

def digest(path):
    with path.open('rb')as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def canonical(data):return json.dumps(data,sort_keys=True,separators=(',',':')).encode()
def load():
    data=json.loads(LOCK.read_text());identity=hashlib.sha256(canonical(data)).hexdigest()[:20]
    return data,'source-deps-'+identity

class Builder:
    def __init__(self,jobs):
        self.lock,self.id=load();self.prefix=BASE/self.id;self.work=BASE/'Work'/self.id;self.archives=BASE/'Archives';self.jobs=jobs
        if (self.prefix/'manifest.json').is_file():raise RuntimeError('Finalized source prefix is immutable; use verify or increment the locked recipe revision for a new build')
        for p in [self.prefix,self.work,self.archives,self.prefix/'share/ready/receipts',self.prefix/'share/ready/notices',self.prefix/'share/ready/recipes']:p.mkdir(parents=True,exist_ok=True)
        self.script_sha=digest(pathlib.Path(__file__));snapshot=self.prefix/'share/ready/recipes'/(self.script_sha+'.py')
        if not snapshot.exists():shutil.copy2(__file__,snapshot)
        shutil.copy2(LOCK,self.prefix/'share/ready/sources.lock.json')
        self.sdk=subprocess.run(['xcrun','--show-sdk-path'],capture_output=True,text=True,check=True).stdout.strip()
        self.tools={name:subprocess.run(argv,capture_output=True,text=True,check=True).stdout.strip()for name,argv in {'clang':['/usr/bin/clang','--version'],'sdkVersion':['xcrun','--show-sdk-version'],'host':['uname','-a'],'cmake':['cmake','--version'],'meson':['meson','--version'],'make':['/opt/homebrew/bin/gmake','--version']}.items()}
        self.env=os.environ.copy()
        for key in list(self.env):
            if key.startswith('DYLD_') or key in ('C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','PKG_CONFIG_PATH','CPATH'):self.env.pop(key,None)
        flags='-arch x86_64 -mmacosx-version-min=14.0 -O2 -g0'
        self.env.update(CC='/usr/bin/clang',CXX='/usr/bin/clang++',CFLAGS=flags,CXXFLAGS=flags,OBJCFLAGS=flags,CPPFLAGS='-I'+str(self.prefix/'include'),LDFLAGS=f'-arch x86_64 -mmacosx-version-min=14.0 -L{self.prefix}/lib -Wl,-rpath,{self.prefix}/lib',MACOSX_DEPLOYMENT_TARGET='14.0',SDKROOT=self.sdk,PKG_CONFIG_LIBDIR=f'{self.prefix}/lib/pkgconfig:{self.prefix}/share/pkgconfig',PKG_CONFIG_PATH='',CMAKE_PREFIX_PATH=str(self.prefix),SOURCE_DATE_EPOCH='1780000000',PATH='/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin')
        # Source/work paths may contain spaces; compiler flags use a short owned alias.
        self.alias=pathlib.Path('/tmp')/('ready-source-deps-'+str(os.getuid()))
        if self.alias.is_symlink():
            if self.alias.resolve()!=BASE.resolve():raise RuntimeError('Dependency build alias belongs to another directory')
        elif self.alias.exists():raise RuntimeError('Refusing to replace dependency build alias')
        else:self.alias.symlink_to(BASE,target_is_directory=True)
        self.short=self.alias/self.id
        self.work=self.alias/'Work'/self.id
        self.env['CPPFLAGS']='-I'+str(self.short/'include')
        self.env['LDFLAGS']=f'-arch x86_64 -mmacosx-version-min=14.0 -L{self.short}/lib -Wl,-rpath,{self.short}/lib'
        self.env['PATH']=str(self.short/'bin')+':'+self.env['PATH']
        self.env['PKG_CONFIG_LIBDIR']=f'{self.short}/lib/pkgconfig:{self.short}/share/pkgconfig';self.env['CMAKE_PREFIX_PATH']=str(self.short)
        self.current=None;self.commands=[]
    def archive_path(self,item):return self.archives/(item['name']+'-'+item['version']+''.join(pathlib.Path(item['url']).suffixes[-2:]))
    def fetch_one(self,item):
        target=self.archive_path(item)
        if target.is_file()and digest(target)==item['sha256']:return target
        partial=target.with_name(target.name+'.partial')
        request=urllib.request.Request(item['url'],headers={'User-Agent':'ready-public-source-builder'})
        with urllib.request.urlopen(request,timeout=120)as response,partial.open('wb')as output:shutil.copyfileobj(response,output)
        if digest(partial)!=item['sha256']:partial.unlink();raise RuntimeError('Source checksum mismatch: '+item['name'])
        partial.replace(target);print('Fetched source',item['name'],item['version'],flush=True);return target
    def fetch(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2)as pool:list(pool.map(self.fetch_one,self.lock['sources']))
    def source(self,item):
        destination=self.work/'Sources'/(item['name']+'-'+item['version'])
        if destination.is_dir():return destination
        staging=destination.with_name(destination.name+'.extracting');staging.mkdir(parents=True,exist_ok=True)
        with tarfile.open(self.fetch_one(item))as source:source.extractall(staging,filter='data')
        members=list(staging.iterdir())
        if len(members)==1 and members[0].is_dir():members[0].rename(destination);staging.rmdir()
        else:staging.rename(destination)
        return destination
    def run(self,argv,cwd,env=None):
        argv=list(map(str,argv));self.commands.append({'argv':argv,'cwd':str(cwd)})
        log=self.work/(self.current+'.log')
        with log.open('ab')as stream:
            stream.write(('\nCOMMAND '+json.dumps(argv)+'\n').encode());stream.flush()
            command_env=dict(env or self.env);command_env['PWD']=str(cwd)
            subprocess.run(argv,cwd=cwd,env=command_env,stdout=stream,stderr=subprocess.STDOUT,check=True)
    def cmake(self,source,build,options):
        self.run(['cmake','-S',source,'-B',build,'-G','Ninja','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_INSTALL_PREFIX='+str(self.short),'-DCMAKE_OSX_ARCHITECTURES=x86_64','-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0','-DCMAKE_OSX_SYSROOT='+self.sdk,'-DCMAKE_C_COMPILER=/usr/bin/clang','-DCMAKE_CXX_COMPILER=/usr/bin/clang++','-DCMAKE_PREFIX_PATH='+str(self.short),'-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local;/opt/local','-DCMAKE_INSTALL_RPATH=@loader_path','-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON',*options],ROOT)
        self.run(['cmake','--build',build,'--parallel',self.jobs],ROOT);self.run(['cmake','--install',build],ROOT)
    def autotools(self,source,build,options):
        build.mkdir(parents=True,exist_ok=True)
        self.run([source/'configure','--prefix='+str(self.short),'--build=x86_64-apple-darwin','--host=x86_64-apple-darwin','--enable-shared','--disable-static',*options],build)
        self.run(['/opt/homebrew/bin/gmake','-j'+str(self.jobs)],build);self.run(['/opt/homebrew/bin/gmake','install'],build)
    def build_one(self,item,force=False):
        name=item['name'];self.current=name;self.commands=[]
        receipt=self.prefix/'share/ready/receipts'/(name+'.json')
        previous_files=set()
        if receipt.exists():
            old=json.loads(receipt.read_text())
            if force:
                previous_files=set(old['installedFiles'])
                history=self.prefix/'share/ready/receipt-history'/name;history.mkdir(parents=True,exist_ok=True)
                shutil.copy2(receipt,history/(digest(receipt)+'.json'));receipt.unlink()
                if name=='libpng':shutil.rmtree(self.prefix/'lib/png.framework',ignore_errors=True)
            elif old.get('sourceSHA256')==item['sha256']and all((self.prefix/path).is_file()and digest(self.prefix/path)==sha for path,sha in old.get('installedFiles',{}).items()):print('Verified existing',name,flush=True);return
            else:raise RuntimeError('Installed component differs from receipt: '+name)
        print('Building',name,item['version'],flush=True);source=self.source(item);build=self.work/'Build'/name;build.mkdir(parents=True,exist_ok=True)
        before={str(p.relative_to(self.prefix)):(p.stat().st_size,p.stat().st_mtime_ns)for p in self.prefix.rglob('*')if p.is_file()and not p.is_symlink()}
        p=self.short
        if name=='zlib':
            self.run([source/'configure','--prefix='+str(p),'--shared'],build);self.run(['/opt/homebrew/bin/gmake','-j'+str(self.jobs)],build);self.run(['/opt/homebrew/bin/gmake','install'],build)
        elif name=='bzip2':
            objects=[]
            for part in ['blocksort','huffman','crctable','randtable','compress','decompress','bzlib']:
                obj=build/(part+'.o');self.run(['/usr/bin/clang','-arch','x86_64','-mmacosx-version-min=14.0','-O2','-g0','-fPIC','-I',source,'-c',source/(part+'.c'),'-o',obj],ROOT);objects.append(obj)
            target=p/'lib/libbz2.1.0.8.dylib';target.parent.mkdir(exist_ok=True)
            self.run(['/usr/bin/clang','-arch','x86_64','-mmacosx-version-min=14.0','-dynamiclib','-Wl,-install_name,@rpath/libbz2.1.0.dylib','-Wl,-current_version,1.0.8','-Wl,-compatibility_version,1.0.0',*objects,'-o',target],ROOT)
            (p/'include').mkdir(exist_ok=True);shutil.copy2(source/'bzlib.h',p/'include/bzlib.h')
            for alias in ['libbz2.dylib','libbz2.1.dylib','libbz2.1.0.dylib']:(p/'lib'/alias).symlink_to(target.name)
        elif name=='brotli':self.cmake(source,build,['-DBUILD_SHARED_LIBS=ON','-DBROTLI_DISABLE_TESTS=ON'])
        elif name=='zstd':self.cmake(source/'build/cmake',build,['-DZSTD_BUILD_SHARED=ON','-DZSTD_BUILD_STATIC=OFF','-DZSTD_BUILD_PROGRAMS=OFF','-DZSTD_BUILD_TESTS=OFF'])
        elif name=='libpng':self.cmake(source,build,['-DPNG_SHARED=ON','-DPNG_STATIC=OFF','-DPNG_FRAMEWORK=OFF','-DPNG_TESTS=OFF','-DPNG_TOOLS=OFF','-DZLIB_ROOT='+str(p),'-DZLIB_INCLUDE_DIR='+str(p/'include'),'-DZLIB_LIBRARY='+str(p/'lib/libz.dylib')])
        elif name=='libffi':self.autotools(source,build,[])
        elif name=='libiconv':self.autotools(source,build,['--disable-nls'])
        elif name=='libunistring':self.autotools(source,build,['--with-libiconv-prefix='+str(p)])
        elif name=='gettext':self.autotools(source/'gettext-runtime',build,['--disable-java','--disable-csharp','--disable-openmp','--disable-libasprintf','--with-libiconv-prefix='+str(p),'--with-libunistring-prefix='+str(p)])
        elif name=='gmp':self.autotools(source,build,['--enable-cxx'])
        elif name=='nettle':self.autotools(source,build,[])
        elif name=='libtasn1':self.autotools(source,build,['--disable-doc'])
        elif name=='libidn2':self.autotools(source,build,['--with-libiconv-prefix='+str(p),'--with-libunistring-prefix='+str(p),'--disable-doc'])
        elif name=='p11-kit':
            cross=build/'cross.ini';cross.write_text("[binaries]\nc = ['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=14.0']\ncpp = ['/usr/bin/clang++', '-arch', 'x86_64', '-mmacosx-version-min=14.0']\nar = '/usr/bin/ar'\nstrip = '/usr/bin/strip'\npkg-config = '/opt/homebrew/bin/pkg-config'\n[host_machine]\nsystem = 'darwin'\ncpu_family = 'x86_64'\ncpu = 'x86_64'\nendian = 'little'\n[properties]\nneeds_exe_wrapper = false\n")
            self.run(['meson','setup',build/'out',source,'--cross-file',cross,'--prefix',p,'--buildtype','release','-Dgtk_doc=false','-Dman=false','-Dtest=false','-Dtrust_module=enabled','-Dlibffi=enabled','-Denv_override_paths=enabled'],ROOT);self.run(['meson','compile','-C',build/'out','-j',self.jobs],ROOT);self.run(['meson','install','-C',build/'out'],ROOT)
        elif name=='freetype':self.cmake(source,build,['-DBUILD_SHARED_LIBS=ON','-DFT_REQUIRE_ZLIB=ON','-DFT_REQUIRE_BZIP2=ON','-DFT_REQUIRE_PNG=ON','-DFT_REQUIRE_BROTLI=ON','-DFT_DISABLE_HARFBUZZ=ON','-DPNG_LIBRARY='+str(p/'lib/libpng16.dylib'),'-DPNG_LIBRARY_RELEASE='+str(p/'lib/libpng16.dylib'),'-DPNG_PNG_INCLUDE_DIR='+str(p/'include/libpng16'),'-DZLIB_ROOT='+str(p)])
        elif name=='gnutls':self.autotools(source,build,['--disable-doc','--disable-tests','--disable-libdane','--with-p11-kit','--with-idn','--with-zlib=link','--with-zstd=link','--with-brotli=link','--enable-cxx'])
        elif name=='libpcap':self.cmake(source,build,['-DBUILD_SHARED_LIBS=ON','-DBUILD_WITH_LIBNL=OFF'])
        else:raise RuntimeError('No public recipe: '+name)
        notices=self.prefix/'share/ready/notices'/name;notices.mkdir(parents=True,exist_ok=True)
        for file in source.rglob('*'):
            if file.is_file()and not file.is_symlink()and (any(word in file.name.upper()for word in ['COPYING','LICENSE','LICENCE','COPYRIGHT','NOTICE']) or file.name in ('README','README.md','README.txt')):
                relative=file.relative_to(source);target=notices/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,target)
        after={str(file.relative_to(self.prefix)):digest(file)for file in self.prefix.rglob('*')if file.is_file()and not file.is_symlink()and (str(file.relative_to(self.prefix))in previous_files or str(file.relative_to(self.prefix))not in before or before[str(file.relative_to(self.prefix))]!=(file.stat().st_size,file.stat().st_mtime_ns))}
        data={'schema':1,'component':name,'version':item['version'],'sourceURL':item['url'],'sourceSHA256':item['sha256'],'sourceArchive':str(self.archive_path(item)),'patches':item.get('patches',[]),'recipeScriptSHA256':self.script_sha,'commands':self.commands,'buildEnvironment':{key:self.env[key]for key in ['CC','CXX','CFLAGS','CXXFLAGS','CPPFLAGS','LDFLAGS','SDKROOT','MACOSX_DEPLOYMENT_TARGET','PKG_CONFIG_LIBDIR','PKG_CONFIG_PATH','SOURCE_DATE_EPOCH','PATH']},'toolchain':self.tools,'installedFiles':after,'notices':sorted(str(file.relative_to(self.prefix))for file in notices.rglob('*')if file.is_file()),'builtAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
        receipt.write_text(json.dumps(data,indent=2)+'\n');print('Installed source component',name,flush=True)
    def build(self,until=None):
        for item in self.lock['sources']:
            self.build_one(item)
            if until==item['name']:break
        print('Staging prefix',self.prefix,flush=True)

def inspector():
    import importlib.util
    spec=importlib.util.spec_from_file_location('ready_dependency_inventory',ROOT/'Scripts/runtime_dependency_inventory.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

def finalize(builder):
    """Only an unselected source staging prefix is changed here."""
    module=inspector();builder.current='finalize';builder.commands=[];prefix=builder.prefix
    components={};owners={};notices_root=prefix/'share/ready/notices';sources=prefix/'share/ready/sources';sources.mkdir(exist_ok=True)
    for item in builder.lock['sources']:
        name=item['name'];receipt=prefix/'share/ready/receipts'/(name+'.json')
        if not receipt.is_file():raise RuntimeError('Component not built: '+name)
        data=json.loads(receipt.read_text())
        for path,expected in data['installedFiles'].items():
            file=prefix/path
            if not file.is_file()or digest(file)!=expected:raise RuntimeError('Installed file changed before finalize: '+path)
            owners[path]=name
        archive=builder.archive_path(item)
        if digest(archive)!=item['sha256']:raise RuntimeError('Source archive differs: '+name)
        target=sources/archive.name
        if not target.exists():shutil.copy2(archive,target)
        source=builder.source(item);notices=notices_root/name
        for file in source.rglob('*'):
            if file.is_file()and not file.is_symlink()and any(word in file.name.upper()for word in ['COPYING','LICENSE','LICENCE','COPYRIGHT','NOTICE','AUTHORS','CONTRIBUTORS']):
                output=notices/file.relative_to(source);output.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,output)
        data['sourceArchiveRelative']=str(target.relative_to(prefix));data['notices']=sorted(str(file.relative_to(prefix))for file in notices.rglob('*')if file.is_file())
        if not data['notices']:raise RuntimeError('No retained license/notices: '+name)
        components[name]=data
    code_files=[]
    for file in prefix.rglob('*'):
        if not file.is_file()or file.is_symlink()or file.is_relative_to(prefix/'share/ready'):continue
        with file.open('rb')as stream:magic=stream.read(8)
        if magic[:4]in module.MACH or magic[:4]in module.FAT:
            info=module.binary_headers(file)
            if info['architectures']!=['x86_64']:raise RuntimeError('Unexpected runtime architecture: '+str(file))
            for part in info['slices']:
                minimum=part.get('buildVersion',{}).get('minimumOS')
                if minimum is None or tuple(map(int,minimum.split('.')))>(14,0,0):raise RuntimeError('Deployment target exceeds macOS14: '+str(file))
            code_files.append((file,info))
        elif magic==b'!<arch>\n':
            arch=subprocess.run(['lipo','-archs',str(file)],capture_output=True,text=True,check=True).stdout.split()
            if arch!=['x86_64']:raise RuntimeError('Unexpected static archive architecture: '+str(file))
            code_files.append((file,{'format':'archive','architectures':arch,'slices':[]}))
    backup=builder.work/'NormalizationBackup';backup.mkdir(parents=True,exist_ok=True)
    for file,info in code_files:
        if info['format']=='Mach-O':
            saved=backup/file.relative_to(prefix);saved.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,saved)
    try:
        changes=[]
        for file,info in code_files:
            for part in info.get('slices',[]):
                arguments=['/usr/bin/install_name_tool'];changed=False
                if 'installID'in part:
                    arguments+=['-id','@rpath/'+pathlib.PurePosixPath(part['installID']['name']).name];changed=True
                for dependency in part['dependencies']:
                    old=dependency['name']
                    if old.startswith(('/usr/lib/','/System/Library/')):continue
                    basename=pathlib.PurePosixPath(old).name;local=prefix/'lib'/basename
                    if not local.exists():
                        if old.startswith('@loader_path/')and (file.parent/old[len('@loader_path/'):]).resolve().is_relative_to(prefix)and(file.parent/old[len('@loader_path/'):]).exists():continue
                        raise RuntimeError('Unresolved non-system dependency: '+old)
                    new='@loader_path/'+os.path.relpath(local,file.parent)
                    if old!=new:arguments+=['-change',old,new];changed=True
                for rpath in part['rpaths']:
                    if rpath.startswith(('/tmp/ready-source-deps-',str(prefix),str(BASE))):arguments+=['-delete_rpath',rpath];changed=True
                    elif rpath.startswith(('/opt/homebrew','/opt/local','/usr/local')):raise RuntimeError('External package rpath in '+str(file))
                if changed:
                    arguments.append(file);builder.run(arguments,ROOT)
                    changes.append({'path':str(file.relative_to(prefix)),'argv':list(map(str,arguments))})
                builder.run(['/usr/bin/codesign','--force','--sign','-',file],ROOT)
    except BaseException:
        for file,info in code_files:
            if info['format']=='Mach-O':shutil.copy2(backup/file.relative_to(prefix),file)
        raise
    binaries=[]
    for file,old_info in code_files:
        relative=str(file.relative_to(prefix));owner=owners.get(relative)
        if owner is None:raise RuntimeError('No source receipt owns binary: '+relative)
        info=module.binary_headers(file)if old_info['format']=='Mach-O'else old_info
        data=components[owner]
        binaries.append({'path':relative,'sha256':digest(file),'component':owner,'version':data['version'],'sourceSHA256':data['sourceSHA256'],'sourceArchive':data['sourceArchiveRelative'],'recipeSHA256':data['recipeScriptSHA256'],'notices':data['notices'],'binary':info})
    for file in (prefix/'lib/pkgconfig').glob('*.pc'):
        text=file.read_text()
        text=text.replace('prefix='+str(builder.short),'prefix=${pcfiledir}/../..').replace('prefix='+str(prefix),'prefix=${pcfiledir}/../..')
        file.write_text(text)
    for name,data in components.items():
        for relative in data['installedFiles']:data['installedFiles'][relative]=digest(prefix/relative)
        receipt=prefix/'share/ready/receipts'/(name+'.json');receipt.write_text(json.dumps(data,indent=2)+'\n')
    helper=ROOT/'Scripts/runtime_dependency_inventory.py'
    helper_hash=digest(helper);shutil.copy2(helper,prefix/'share/ready/recipes'/(helper_hash+'-inventory.py'))
    shutil.copy2(ROOT/'LICENSE',prefix/'share/ready/recipes/LICENSE')
    manifests={str(path.relative_to(prefix)):digest(path)for path in (prefix/'share/ready').rglob('*')if path.is_file()and not path.is_symlink()}
    report={'schema':1,'dependencySetID':builder.id,'prefix':str(prefix),'target':builder.lock['target'],'sourceEvidenceComplete':True,'binaryRedistributionReady':False,'runtimeValidationPending':True,'runtimeValidationNote':'Candidate source-derived stack; no active provider/configuration changed. Runtime matrix must validate before promotion.','legacySupportIncluded':False,'componentCount':len(components),'sourcesLockSHA256':digest(LOCK),'finalizerRecipeSHA256':builder.script_sha,'binaryFiles':sorted(binaries,key=lambda x:x['path']),'componentReceipts':{name:'share/ready/receipts/'+name+'.json'for name in components},'provenanceFiles':manifests,'normalization':changes,'inspectorRecipeSHA256':helper_hash,'binaryFingerprint':hashlib.sha256(canonical({entry['path']:entry['sha256']for entry in binaries})).hexdigest(),'runtimeEnvironmentForRelocation':{'P11_MODULE_PATH':'${prefix}/lib/pkcs11','P11_PACKAGE_CONFIG_MODULES':'${prefix}/share/p11-kit/modules','P11_SYSTEM_CONFIG_MODULES':'${prefix}/etc/pkcs11/modules'},'archivePinVerification':'Actual bytes fetched from upstream URLs match retained SHA256 pins. Independent expected pins are documented Homebrew source records; OpenPGP signatures were not verified.','oldCommunityInputsUsed':False}
    (prefix/'manifest.json').write_text(json.dumps(report,indent=2)+'\n');verify(prefix)
    print(json.dumps({'dependencySetID':builder.id,'prefix':str(prefix),'sourceEvidenceComplete':True,'binaryRedistributionReady':False,'binaryFiles':len(binaries),'runtimeValidationPending':True}))

def verify(prefix):
    report=json.loads((prefix/'manifest.json').read_text())
    for relative,expected in report['provenanceFiles'].items():
        if digest(prefix/relative)!=expected:raise RuntimeError('Source/provenance file differs: '+relative)
    for entry in report['binaryFiles']:
        if digest(prefix/entry['path'])!=entry['sha256']:raise RuntimeError('Binary differs: '+entry['path'])
        if digest(prefix/entry['sourceArchive'])!=entry['sourceSHA256']:raise RuntimeError('Corresponding source differs: '+entry['component'])
    print('Verified exact source, recipe, notices and binary mapping for',report['dependencySetID'],flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('operation',choices=['fetch','build','finalize','verify']);parser.add_argument('--jobs',type=int,default=3);parser.add_argument('--until');parser.add_argument('--rebuild',action='append',default=[]);args=parser.parse_args()
    if args.operation=='verify':
        _,identity=load();verify(BASE/identity);return
    builder=Builder(args.jobs)
    if args.operation=='fetch':builder.fetch()
    elif args.operation=='build':
        if args.rebuild:
            for item in builder.lock['sources']:
                if item['name']in args.rebuild:builder.build_one(item,force=True)
        else:builder.build(args.until)
    elif args.operation=='finalize':finalize(builder)
    else:verify(builder.prefix)
if __name__=='__main__':main()
