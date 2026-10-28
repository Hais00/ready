#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build/run Wine conversion diagnostics in COW clones; immutable providers stay intact.

Only copies of the pinned generated Wine translation unit are instrumented. The
original Apache-2.0 OR MIT notice is retained; observer source is LGPL-2.1-or-later.
This is local diagnosis, not an upstream contribution or a product runtime change.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

from runtime_vulkan_properties_windows_probe import execute_wine, bounded, compile_probe
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Vendor/wine/dlls/winevulkan/vulkan_thunks.c'
TEMPLATE=ROOT/'Runtime/build-wine-11.20'
HEADER=ROOT/'Scripts/runtime_vkd3d_call_trace.h'
FLAGS=['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0','i386_CFLAGS=-O2 -g0','x86_64_CFLAGS=-O2 -g0']

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def command(args,**kw):return subprocess.run(list(map(str,args)),check=True,**kw)

def type_header(destination):
    text=(ROOT/'Vendor/vkd3d-proton/libs/vkd3d/device.c').read_text()
    begin=text.index('static void vkd3d_physical_device_info_init(')
    end=text.index('VK_CALL(vkGetPhysicalDeviceProperties2',begin)
    values=set(re.findall(r'\.sType\s*=\s*(VK_STRUCTURE_TYPE_\w+)',text[begin:end]))
    values.update(['VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2','VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2','VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES','VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES'])
    xml=ET.parse(ROOT/'Runtime/vulkan-headers-1.4.366/registry/vk.xml')
    wine_header=(ROOT/'Vendor/wine/include/wine/vulkan.h').read_text()
    aliases={node.get('name'):node.get('alias') for node in xml.findall('.//enum') if node.get('alias')}
    def canonical(value):
        visited=set()
        while value in aliases and value not in visited:visited.add(value);value=aliases[value]
        return value
    wanted={canonical(value) for value in values}
    rows=[]
    for node in xml.findall('.//types/type[@category="struct"]'):
        name=node.get('name')
        if not name:continue
        stype=next((member.get('values') for member in node.findall('member') if member.get('values')),None)
        if canonical(stype) in wanted and re.search(r'\b'+re.escape(name)+r'\b',wine_header):rows.append((stype,name))
    lines=['/* Generated from public vk.xml and sizeof Wine declarations. No layout guesses. */',
           'static size_t ready_type_size(VkStructureType type){']
    for stype,name in rows:lines.append(f'if(type=={stype})return sizeof({name});')
    lines+=['return 0;}','static const char *ready_type_name(VkStructureType type){']
    for stype,name in rows:lines.append(f'if(type=={stype})return "{name}";')
    lines+=['return "unmapped-public-type";}']
    destination.write_text('\n'.join(lines)+'\n')
    return rows

def fix_layered_w2h(original):
    # The embedded output structure still has input sType/pNext to preserve.
    # Use existing typed converters; never memcpy pointers across WOW64 layouts.
    declarations=(
        'static void convert_VkPhysicalDeviceProperties2_win32_to_host(struct conversion_context *ctx, const VkPhysicalDeviceProperties232 *in, VkPhysicalDeviceProperties2 *out);\n'
        '#ifdef _WIN64\n'
        'static void convert_VkPhysicalDeviceProperties2_win64_to_host(struct conversion_context *ctx, const VkPhysicalDeviceProperties2 *in, VkPhysicalDeviceProperties2 *out);\n'
        '#endif\n')
    anchor='static void convert_VkPhysicalDeviceProperties2_host_to_win32('
    position=original.index(anchor);source=original[:position]+declarations+original[position:]
    for bits in (64,32):
        function=f'convert_VkPhysicalDeviceLayeredApiPropertiesKHR_win{bits}_to_host'
        start=source.index('static void '+function+'(');end=source.index('\n}\n',start)+3
        body=source[start:end]
        allocation='            VkPhysicalDeviceLayeredApiVulkanPropertiesKHR *out_ext = conversion_context_alloc(ctx, sizeof(*out_ext));'
        incoming='VkPhysicalDeviceLayeredApiVulkanPropertiesKHR32'if bits==32 else'VkPhysicalDeviceLayeredApiVulkanPropertiesKHR'
        replacement=allocation+f'\n            const {incoming} *in_ext = (const {incoming} *)in_header;'
        assert body.count(allocation)==1
        body=body.replace(allocation,replacement)
        anchor='            out_ext->pNext = NULL;'
        assert body.count(anchor)==1
        body=body.replace(anchor,anchor+f'\n            convert_VkPhysicalDeviceProperties2_win{bits}_to_host(ctx, &in_ext->properties, &out_ext->properties);')
        source=source[:start]+body+source[end:]
    return source

def adapt(original, variant="observer"):
    if variant.startswith('fixed'):original=fix_layered_w2h(original)
    source=original.replace('WINE_DEFAULT_DEBUG_CHANNEL(vulkan);','WINE_DEFAULT_DEBUG_CHANNEL(vulkan);\n#include "runtime_vkd3d_call_trace.h"',1)
    for suffix in ['','KHR']:
        feature='thunk64_vkGetPhysicalDeviceFeatures2'+suffix
        start=source.index('static NTSTATUS '+feature+'(')
        end=source.index('\n}\n',start)+3
        body=source[start:end]
        anchor=next(line for line in body.splitlines() if 'p_vkGetPhysicalDeviceFeatures2'+suffix+'(' in line)
        target='vulkan_physical_device_from_handle(params->physicalDevice)->instance->p_vkGetPhysicalDeviceFeatures2'+suffix
        before=f'    ready_call_trace("{feature}-caller-before",params->physicalDevice,params->pFeatures,(void*){target});\n'
        after=f'\n    ready_call_trace("{feature}-caller-after",params->physicalDevice,params->pFeatures,(void*){target});'
        body=body.replace(anchor,before+anchor+after)
        source=source[:start]+body+source[end:]
        properties='thunk64_vkGetPhysicalDeviceProperties2'+suffix
        start=source.index('static NTSTATUS '+properties+'(');end=source.index('\n}\n',start)+3
        body=source[start:end];target='vk_funcs->p_vkGetPhysicalDeviceProperties2'+suffix
        anchor='    init_conversion_context(ctx);'
        body=body.replace(anchor,f'    ready_call_trace("{properties}-caller-before",params->physicalDevice,params->pProperties,(void*){target});\n'+anchor)
        anchor=f'    {target}(params->physicalDevice, &pProperties_host);'
        body=body.replace(anchor,f'    ready_call_trace("{properties}-host-before",params->physicalDevice,&pProperties_host,(void*){target});\n'+anchor+f'\n    ready_call_trace("{properties}-host-after",params->physicalDevice,&pProperties_host,(void*){target});')
        anchor='    free_conversion_context(ctx);'
        body=body.replace(anchor,f'    ready_call_trace("{properties}-caller-after",params->physicalDevice,params->pProperties,(void*){target});\n'+anchor)
        source=source[:start]+body+source[end:]
    for suffix in ['', 'KHR']:
        name='thunk32_vkGetPhysicalDeviceProperties2'+suffix
        begin=source.index('static NTSTATUS '+name+'(');end=source.index('\n}\n',begin)+3
        body=source[begin:end];target='vk_funcs->p_vkGetPhysicalDeviceProperties2'+suffix
        anchor=f'    {target}((VkPhysicalDevice)UlongToPtr(params->physicalDevice), &pProperties_host);'
        assert anchor in body
        before=f'    ready_call_trace("{name}-host-before",(VkPhysicalDevice)UlongToPtr(params->physicalDevice),&pProperties_host,(void*){target});\n'
        after=f'\n    ready_call_trace("{name}-host-after",(VkPhysicalDevice)UlongToPtr(params->physicalDevice),&pProperties_host,(void*){target});'
        body=body.replace(anchor,before+anchor+after);source=source[:begin]+body+source[end:]
    if 'poison' in variant:
        for suffix in ['', 'KHR']:
          for bits in (64,32):
            name=f'thunk{bits}_vkGetPhysicalDeviceProperties2'+suffix
            begin=source.index('static NTSTATUS '+name+'(');end=source.index('\n}\n',begin)+3
            body=source[begin:end].replace('    init_conversion_context(ctx);','    init_conversion_context(ctx);\n    memset(ctx->buffer,0xa5,sizeof(ctx->buffer)); /* DIAGNOSTIC scratch poison only */')
            source=source[:begin]+body+source[end:]
    return source

def build_observer(variant="observer"):

    identity=uuid.uuid4().hex[:12]
    build=ROOT/'Runtime'/('build-vkd3d-call-trace-'+identity)
    command(['/bin/cp','-cR',TEMPLATE,build])
    snapshot=build/'diagnostic-source';snapshot.mkdir()
    original=SOURCE.read_text();observed=adapt(original,variant)
    (snapshot/'vulkan_thunks.c').write_text(observed)
    shutil.copy2(HEADER,snapshot/HEADER.name)
    rows=type_header(snapshot/'ready_vulkan_type_sizes.h')
    (snapshot/'observer.patch').write_text(''.join(difflib.unified_diff(original.splitlines(keepends=True),observed.splitlines(keepends=True),fromfile='a/dlls/winevulkan/vulkan_thunks.c',tofile='diagnostic/dlls/winevulkan/vulkan_thunks.c')))
    env={**os.environ,'PATH':'/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin',
         'DYLD_LIBRARY_PATH':str(ROOT/'Runtime/vulkan-sdk-1.4.366/lib')+':'+str(ROOT/'Runtime/wine-deps/lib')}
    dry=subprocess.check_output(['/opt/homebrew/bin/gmake','-n','-W','../../Vendor/wine/dlls/winevulkan/vulkan_thunks.c',*FLAGS,'dlls/winevulkan/winevulkan.so'],cwd=build,env=env,text=True)
    lines=dry.replace('\\\n',' ').splitlines()
    compile_line=next(line for line in lines if '-c -o dlls/winevulkan/vulkan_thunks.o ' in line)
    args=shlex.split(compile_line)
    args=[str(snapshot/'vulkan_thunks.c') if value=='../../Vendor/wine/dlls/winevulkan/vulkan_thunks.c' else value for value in args]
    command(args,cwd=build,env=env)
    link_line=next(line for line in lines if '-o dlls/winevulkan/winevulkan.so -dynamiclib' in line)
    link_args=shlex.split(link_line)
    for item in link_args:
        if item.endswith('.o') and not (build/item).exists():
            object_line=next(line for line in lines if '-c -o '+item+' ' in line)
            command(shlex.split(object_line),cwd=build,env=env)
    command(link_args,cwd=build,env=env)
    module=build/'dlls/winevulkan/winevulkan.so'
    record={'variant':variant,'diagnosticScratchPoison':('poison' in variant),'w2hRecursiveFix':variant.startswith('fixed'),'sourceSHA256':digest(SOURCE),'observerHeaderSHA256':digest(HEADER),
        'adaptedSHA256':digest(snapshot/'vulkan_thunks.c'),'moduleSHA256':digest(module),
        'wineVulkanHeaderSHA256':digest(ROOT/'Vendor/wine/include/wine/vulkan.h'),
        'vkXMLSHA256':digest(ROOT/'Runtime/vulkan-headers-1.4.366/registry/vk.xml'),
        'wineSource':json.loads((ROOT/'Vendor/wine.source.json').read_text()),'vendorSourceUnchanged':digest(SOURCE)==hashlib.sha256(original.encode()).hexdigest(),
        'generatedSourceSnapshotOnly':True,'mappedPublicTypes':len(rows),'build':str(build),'module':str(module)}
    (build/'observer.json').write_text(json.dumps(record,indent=2)+'\n')
    return build,module,record

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icd',choices=['kosmic','molten'],default='kosmic')
    parser.add_argument('--keep',action='store_true')
    parser.add_argument('--timeout',type=float,default=60)
    parser.add_argument('--variant',choices=['observer','poison','original','fixed','fixed-poison','fixed-asset'],default='observer')
    parser.add_argument('--program',choices=['vkd3d','layered','layered-valid','base'],default='vkd3d')
    parser.add_argument('--reuse-build',type=Path)
    parser.add_argument('--bits',type=int,choices=[32,64],default=64)
    parser.add_argument('--module',type=Path,help='Uninstrumented reviewed asset; requires --variant fixed-asset')
    args=parser.parse_args()
    if bool(args.module)!=(args.variant=='fixed-asset'):parser.error('fixed-asset and --module must be used together')
    if args.bits==32 and args.program=='vkd3d':parser.error('32-bit control uses the public typed properties probe')
    cfg=json.loads((ROOT/'Runtime/runtime.json').read_text());base=Path(cfg['immutableRuntimeSet']);original_wine=base/'wine'
    if args.module:
        module=args.module.resolve();build=module.parents[2];record=json.loads((build/'layered-w2h-asset.json').read_text());assert digest(module)==record['moduleSHA256'] and not record['observerOrPoisonIncluded'];record={**record,'variant':'fixed-asset'}
    elif args.variant=='original':build=None;module=None;record={'variant':'original','moduleSHA256':digest(original_wine/'lib/wine/x86_64-unix/winevulkan.so')}
    elif args.reuse_build:
        build=args.reuse_build.resolve();record=json.loads((build/'observer.json').read_text());module=Path(record['module']);assert record['variant']==args.variant and digest(module)==record['moduleSHA256']
    else:build,module,record=build_observer(args.variant)
    work=ROOT/'Runtime/TestPrefixes'/('vkd3d-call-'+uuid.uuid4().hex);work.mkdir(parents=True,mode=0o700)
    wine=work/'wine';prefix=work/'prefix';prefix.mkdir(mode=0o700)
    command(['/bin/cp','-cR',original_wine,wine]);target=wine/'lib/wine/x86_64-unix/winevulkan.so'
    if module:target.unlink();shutil.copy2(module,target)
    trace=work/'calls.jsonl';trace.touch(mode=0o600)
    env={key:value for key,value in os.environ.items() if not key.startswith(('WINE','VK_','VKD3D_','DXVK_','D3DM_','MESA_','MVK_','KOSMIC_','DYLD_','CX_','READY_','M1L_','MTL_'))}
    env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all,+seh,err+vulkan,warn+vulkan',
        DYLD_LIBRARY_PATH=str(base/'vulkan')+':'+str(base/'dependencies'),
        VK_DRIVER_FILES=cfg['kosmicICD'] if args.icd=='kosmic' else cfg['moltenICD'])
    env['VK_ICD_FILENAMES']=env['VK_DRIVER_FILES']
    tag=args.variant+'-'+args.program+'-'+args.icd+('-pe32'if args.bits==32 else'')
    report={'pointerBits':args.bits,'program':args.program,'variant':args.variant,'observer':record,'wineRootClone':str(wine),'prefix':str(prefix),'icd':args.icd,'hardwareOverrides':False,'defaultRuntimeModified':False}
    output=ROOT/('Evidence/runtime-vkd3d-call-'+tag+'.json')
    try:
        wow=prefix/'drive_c/windows/syswow64';wow.mkdir(parents=True)
        command(['/bin/cp','-cR',str(original_wine/'lib/wine/i386-windows')+'/.',wow])
        boot=execute_wine([wine/'bin/wine','wineboot','-u'],{**env,'WINEDLLOVERRIDES':'mscoree,mshtml=d'},120)
        report['bootExitCode']=boot['exitCode'];assert boot['exitCode']==0
        report['nativeDLLSHA256']={}
        for name in ['d3d12.dll','d3d12core.dll']:
            source=base/'vkd3d'/name;dest=prefix/'drive_c/windows/system32'/name;dest.unlink(missing_ok=True);shutil.copy2(source,dest);report['nativeDLLSHA256'][name]=digest(source)
        game_env={**env,'WINEDLLOVERRIDES':'d3d12,d3d12core=n;dxgi=b;mscoree,mshtml=d',
            'VKD3D_DEBUG':'trace','VKD3D_SHADER_CACHE_PATH':str(work/'shader-cache'),'READY_VKD3D_CALL_TRACE':str(trace)}
        executable=ROOT/'Runtime/Probes/runtime_d3d12_probe.exe'
        if args.program!='vkd3d':
            executable,_=compile_probe(original_wine,args.bits)
            game_env['READY_PROPERTIES_CASE']={'layered':'layered_props_list','layered-valid':'layered_props_list_initialized','base':'base'}[args.program]
        trial=execute_wine([wine/'bin/wine',executable],game_env,args.timeout)
        log=ROOT/('Evidence/runtime-vkd3d-call-'+tag+'.log');log.write_text(trial['stdout']+'\n'+trial['stderr'])
        report['trial']={**trial,'stderr':bounded(trial['stderr'],12000)};report['log']=str(log)
        records=[]
        for line in trace.read_text().splitlines():
            try:records.append(json.loads(line))
            except ValueError:pass
        report['calls']=records
        shutil.copy2(trace,ROOT/('Evidence/runtime-vkd3d-calls-'+tag+'.jsonl'))
        report['properties2Exception']='vkGetPhysicalDeviceProperties2 Exception' in trial['stderr']
        print(json.dumps({'exitCode':trial['exitCode'],'properties2Exception':report['properties2Exception'],'phases':[item['phase'] for item in records]},indent=2))
    finally:
        subprocess.run([str(wine/'bin/wineserver'),'-k'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
        subprocess.run([str(wine/'bin/wineserver'),'-w'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
        report['scratchRetained']=args.keep
        output.write_text(json.dumps(report,indent=2)+'\n')
        if not args.keep:shutil.rmtree(work)
    print('observer build retained for review:',build)

if __name__=='__main__':main()
