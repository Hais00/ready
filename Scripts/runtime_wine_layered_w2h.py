#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Regenerate/build the minimal Wine layered-properties input fix in private copies.

No Vendor edit, installation, runtime configuration change, hardware override,
observer, poison, or upstream contribution occurs. The output .so is a candidate
asset for a future separately tested immutable provider, never a live hotfix.
"""
import argparse,difflib,hashlib,json,os
from pathlib import Path
import re,shlex,shutil,subprocess,urllib.request,uuid
ROOT=Path(__file__).resolve().parents[1]
LOCK=ROOT/'Scripts/runtime_wine_layered_w2h.lock.json'
CACHE=ROOT/'Runtime/VulkanW2HGenerator'
FLAGS=['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0','i386_CFLAGS=-O2 -g0','x86_64_CFLAGS=-O2 -g0']
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def checked_replace(source,old,new):
    if source.count(old)!=1:raise RuntimeError('Pinned generator anchor changed')
    return source.replace(old,new)
def patched_generator(original):
    source=checked_replace(original,'if not self.is_pointer() and self.returnedonly:\n                return False','if not self.is_pointer() and self.returnedonly and not (self.is_struct() and self.struct.chain_next):\n                return False')
    source=checked_replace(source,'if m.returnedonly:\n                        continue','if m.returnedonly and not (m.is_struct() and m.struct.chain_next):\n                        continue')
    anchor='        f.write("static void convert_VkPhysicalDeviceProperties2_host_to_win32('
    start=source.index(anchor)
    declarations='''        f.write("static void convert_VkPhysicalDeviceProperties2_win32_to_host(struct conversion_context *ctx, const VkPhysicalDeviceProperties232 *in, VkPhysicalDeviceProperties2 *out);\\n")
        f.write("#ifdef _WIN64\\n")
        f.write("static void convert_VkPhysicalDeviceProperties2_win64_to_host(struct conversion_context *ctx, const VkPhysicalDeviceProperties2 *in, VkPhysicalDeviceProperties2 *out);\\n")
        f.write("#endif\\n")
'''
    return source[:start]+declarations+source[start:]
def prepare():
    lock=json.loads(LOCK.read_text());CACHE.mkdir(exist_ok=True)
    for relative,expected in lock['vendorInputs'].items():
        if digest(ROOT/relative)!=expected:raise RuntimeError('Pinned Wine source changed: '+relative)
    xmls={}
    for name,record in lock['registryInputs'].items():
        path=CACHE/('1.4.363-'+name)
        if not path.is_file()or digest(path)!=record['sha256']:
            request=urllib.request.Request(record['url'],headers={'User-Agent':'ready-layered-w2h-source-recipe'})
            data=urllib.request.urlopen(request,timeout=60).read()
            if hashlib.sha256(data).hexdigest()!=record['sha256']:raise RuntimeError('Registry checksum mismatch')
            path.write_bytes(data)
        xmls[name]=path
    original=(ROOT/'Vendor/wine/dlls/winevulkan/make_vulkan').read_text();modified=patched_generator(original)
    outputs={}
    for variant,script in [('original',original),('fixed',modified)]:
        folder=CACHE/variant/'dlls/winevulkan';folder.mkdir(parents=True,exist_ok=True)
        (CACHE/variant/'include/wine').mkdir(parents=True,exist_ok=True);(CACHE/variant/'dlls/vulkan-1').mkdir(exist_ok=True)
        (folder/'make_vulkan').write_text(script);shutil.copy2(ROOT/'Vendor/wine/dlls/winevulkan/winevk.xml',folder/'winevk.xml')
        with (CACHE/(variant+'.log')).open('wb')as log:
            subprocess.run(['python3',str(folder/'make_vulkan'),'-x',str(xmls['vk.xml']),'-X',str(xmls['video.xml'])],env={**os.environ,'XDG_CACHE_HOME':str(CACHE/'cache')},stdout=log,stderr=subprocess.STDOUT,check=True)
        outputs[variant]=folder/'vulkan_thunks.c'
    if digest(outputs['original'])!=lock['vendorInputs']['Vendor/wine/dlls/winevulkan/vulkan_thunks.c']:raise RuntimeError('Unmodified regeneration differs from pinned C')
    if digest(outputs['fixed'])!=lock['fixedGeneratedSHA256']:raise RuntimeError('Fixed generator output differs from reviewed minimal C')
    unchanged=[]
    for path in (CACHE/'original').rglob('*'):
        if not path.is_file():continue
        relative=path.relative_to(CACHE/'original')
        if str(relative)in['dlls/winevulkan/make_vulkan','dlls/winevulkan/vulkan_thunks.c']:continue
        if path.read_bytes()!=(CACHE/'fixed'/relative).read_bytes():raise RuntimeError('Unexpected generated interface change: '+str(relative))
        unchanged.append(str(relative))
    patch=''
    for relative,a,b in [('dlls/winevulkan/make_vulkan',original,modified),('dlls/winevulkan/vulkan_thunks.c',outputs['original'].read_text(),outputs['fixed'].read_text())]:
        patch+=''.join(difflib.unified_diff(a.splitlines(True),b.splitlines(True),fromfile='a/'+relative,tofile='b/'+relative))
    destination=ROOT/'Scripts/runtime_wine_layered_w2h.patch'
    if destination.is_file()and destination.read_text()!=patch:raise RuntimeError('Published patch differs; review explicitly before replacing')
    destination.write_text(patch)
    record={'wineSource':json.loads((ROOT/'Vendor/wine.source.json').read_text()),'registryInputs':lock['registryInputs'],'originalRegenerationMatchesPinnedC':True,'fixedGeneratedSHA256':digest(outputs['fixed']),'generatorPatchSHA256':digest(destination),'fixedGeneratorSHA256':digest(CACHE/'fixed/dlls/winevulkan/make_vulkan'),'generatedInterfacesUnchanged':unchanged,'vendorInputsUnchanged':True,'defaultRuntimeModified':False,'hardwareFeatureOverrides':False,'observerOrPoisonIncluded':False,'generator':str(CACHE/'fixed/dlls/winevulkan/make_vulkan'),'fixedGeneratedC':str(outputs['fixed'])}
    (CACHE/'generator-proof.json').write_text(json.dumps(record,indent=2)+'\n');return record

def build(record):
    folder=ROOT/'Runtime'/('build-layered-w2h-'+uuid.uuid4().hex[:12]);template=ROOT/'Runtime/build-wine-11.20'
    subprocess.run(['/bin/cp','-cR',str(template),str(folder)],check=True)
    source=folder/'fixed-source';source.mkdir();shutil.copy2(record['fixedGeneratedC'],source/'vulkan_thunks.c')
    env={**os.environ,'PATH':'/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin','DYLD_LIBRARY_PATH':str(ROOT/'Runtime/vulkan-sdk-1.4.366/lib')+':'+str(ROOT/'Runtime/wine-deps/lib')}
    dry=subprocess.check_output(['/opt/homebrew/bin/gmake','-n','-W','../../Vendor/wine/dlls/winevulkan/vulkan_thunks.c',*FLAGS,'dlls/winevulkan/winevulkan.so'],cwd=folder,env=env,text=True).replace('\\\n',' ').splitlines()
    original='../../Vendor/wine/dlls/winevulkan/vulkan_thunks.c';commands=[]
    command=next(line for line in dry if '-c -o dlls/winevulkan/vulkan_thunks.o 'in line)
    argv=[str(source/'vulkan_thunks.c')if value==original else value for value in shlex.split(command)];commands.append(argv)
    subprocess.run(argv,cwd=folder,env=env,check=True)
    link=shlex.split(next(line for line in dry if '-o dlls/winevulkan/winevulkan.so -dynamiclib'in line))
    for value in link:
        if value.endswith('.o')and not(folder/value).is_file():
            argv=shlex.split(next(line for line in dry if '-c -o '+value+' 'in line));commands.append(argv);subprocess.run(argv,cwd=folder,env=env,check=True)
    commands.append(link);subprocess.run(link,cwd=folder,env=env,check=True)
    module=folder/'dlls/winevulkan/winevulkan.so'
    result={**record,'build':str(folder),'module':str(module),'moduleSHA256':digest(module),'buildCommands':commands,'buildEnvironment':{key:env[key]for key in ['PATH','DYLD_LIBRARY_PATH']},'configHeaderSHA256':digest(folder/'include/config.h'),'wineVulkanHeaderSHA256':digest(ROOT/'Vendor/wine/include/wine/vulkan.h'),'recipeSHA256':digest(Path(__file__)),'targetedRegressionRequiredBeforeAnyProviderPromotion':True,'installedIntoAnyRuntime':False}
    (folder/'layered-w2h-asset.json').write_text(json.dumps(result,indent=2)+'\n')
    (ROOT/'Evidence/runtime-wine-layered-w2h-asset.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'module':str(module),'moduleSHA256':result['moduleSHA256'],'observerOrPoisonIncluded':False,'installedIntoAnyRuntime':False}))

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--build',action='store_true');args=parser.parse_args();record=prepare()
    if args.build:build(record)
    else:print(json.dumps({'originalRegenerationMatchesPinnedC':True,'fixedGeneratedSHA256':record['fixedGeneratedSHA256'],'generatedInterfaceFilesUnchanged':len(record['generatedInterfacesUnchanged'])}))
if __name__=='__main__':main()
