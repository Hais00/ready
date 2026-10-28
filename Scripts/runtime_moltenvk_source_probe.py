#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real isolated native/Wine Vulkan proof of a source MoltenVK candidate only."""
import hashlib,json,os,pathlib,shutil,subprocess,sys,time,uuid
sys.dont_write_bytecode=True
from runtime_build_moltenvk import Builder,EXTERNAL,ROOT,inventory,sha,write


def main():
    b=Builder();candidate=pathlib.Path(json.load(open(b.work/'candidate.json'))['path']);manifest=json.load(open(candidate/'moltenvk-source-manifest.json'));before=inventory(candidate);before.pop('moltenvk-source-manifest.json');assert before==manifest['files']
    config=json.load(open(ROOT/'Runtime/runtime.json'));default_hashes={n:sha(ROOT/'Runtime'/n)for n in ['runtime.json','evaluation-runtime.json']};directory=b.work/'probes';directory.mkdir(exist_ok=True);logs=EXTERNAL/'retained'/('moltenvk-proof-'+uuid.uuid4().hex);logs.mkdir(mode=0o700)
    headers=ROOT/'Runtime/vulkan-headers-1.4.366/include';common=['/usr/bin/clang','-O2','-g0','-mmacosx-version-min=27.0','-I',str(headers)]
    b.run('probe-native-buffer',common+['-arch','arm64',ROOT/'Scripts/runtime_vulkan_probe.c','-o',directory/'buffer'],cwd=b.work)
    b.run('probe-native-properties',common+['-arch','arm64',ROOT/'Scripts/runtime_vulkan_properties_probe.c','-o',directory/'properties'],cwd=b.work)
    b.run('probe-native-shader-present',common+['-arch','arm64','-fobjc-arc',ROOT/'Scripts/runtime_moltenvk_native_probe.m','-framework','AppKit','-framework','QuartzCore','-framework','Metal','-o',directory/'shader-present'],cwd=b.work)
    b.run('probe-image-observer',['/usr/bin/clang','-arch','arm64','-arch','x86_64','-dynamiclib','-O2','-mmacosx-version-min=27.0',ROOT/'Scripts/runtime_native_audit.c','-o',directory/'observer.dylib'],cwd=b.work)
    shader_tools=ROOT/'Runtime/NativeRendererWork/d007c6360f9f8be7e542/prefix'
    for name in ['vertex','fragment']:
        env=dict(b.env,DYLD_LIBRARY_PATH=str(shader_tools/'lib'))
        command=[shader_tools/'bin/spirv-as','--target-env','vulkan1.0',ROOT/('Scripts/runtime_native_renderer_'+name+'.spvasm'),'-o',directory/(name+'.spv')]
        subprocess.run(list(map(str,command)),env=env,check=True)
    report={'schema':1,'candidate':str(candidate),'candidateManifestSHA256':sha(candidate/'moltenvk-source-manifest.json'),'candidateFingerprint':manifest['fingerprint'],'tests':{},'allPassed':False,'configurationModified':False,'existingProviderOrDLLModified':False,'activationPerformed':False,'advertisedFeaturesModified':False,'binaryRedistributionReady':False,'minimumMacOS':'27.0','nativeARM64Included':True,'retainedLogs':str(logs)}
    clean={k:v for k,v in os.environ.items()if not k.startswith(('WINE','DYLD_','VK_','MESA_','MVK_','READY_','M1L_','D3DM_','CX_'))}
    clean.update(TMPDIR=str(b.tmp),MESA_SHADER_CACHE_DIR=str(directory/'cache'),VK_DRIVER_FILES=str(candidate/'icd/moltenvk.json'),VK_ICD_FILENAMES=str(candidate/'icd/moltenvk.json'))
    def execute(name,args,env,expected,wine=False):
        images=logs/(name+'.images.jsonl');images.unlink(missing_ok=True);current=dict(env,DYLD_INSERT_LIBRARIES=str(directory/'observer.dylib'),READY_NATIVE_AUDIT_LOG=str(images));began=time.monotonic()
        result=subprocess.run(list(map(str,args)),cwd=directory,env=current,capture_output=True,text=True,timeout=100)
        path=logs/(name+'.log');path.write_text(result.stdout+'\n'+result.stderr);observations=[]
        for line in result.stdout.splitlines():
            try:observations.append(json.loads(line))
            except ValueError:pass
        loaded=sorted({json.loads(line)['path']for line in images.read_text().splitlines()})if images.exists()else[]
        allowed=('/System/','/usr/lib/',str(candidate)+'/',str(directory)+'/',str(pathlib.Path(config['nativeVulkanLibrary']).parent)+'/')
        if wine:allowed+=(str(pathlib.Path(config['wineBinary']).parent.parent)+'/',str(pathlib.Path(config['immutableRuntimeSet'])/'vulkan')+'/',str(pathlib.Path(config['sourceDependencyPrefix']))+'/')
        unexpected=[p for p in loaded if not p.startswith(allowed)];passed=result.returncode==0 and any(expected(v)for v in observations)and bool(loaded)and not unexpected
        report['tests'][name]={'exitCode':result.returncode,'passed':passed,'seconds':round(time.monotonic()-began,3),'observations':observations,'loadedImages':loaded,'unexpectedImages':unexpected,'log':str(path),'logSHA256':sha(path),'imagesSHA256':sha(images)if images.exists()else None}
        write(ROOT/'Evidence/runtime-moltenvk-source-validation.json',report);print(name,passed,flush=True)
        if not passed:raise RuntimeError('Actual MoltenVK candidate probe failed: '+name+'; '+result.stderr[-1400:])
        return observations
    native_loader=pathlib.Path(config['nativeVulkanLibrary'])
    execute('native-buffer',[directory/'buffer',native_loader],clean,lambda x:x.get('readbackVerified')is True)
    execute('native-shader-present',[directory/'shader-present',native_loader,directory/'vertex.spv',directory/'fragment.spv'],clean,lambda x:x.get('shaderRasterizationVerified')is True and x.get('presentedFrames',0)>=60)
    for case in ['base','core','full']:execute('native-properties-'+case,[directory/'properties',native_loader,case],clean,lambda x:x.get('guardAndHeadersIntact')is True and x.get('baseMatchesLegacy')is True)
    # One owned initialized copy; source template/provider DLLs are never edited.
    scratch=EXTERNAL/'tests'/('moltenvk-'+uuid.uuid4().hex);scratch.mkdir(mode=0o700);marker=scratch/'.ready-moltenvk-test';marker.write_text('Owned synthetic Vulkan fixture\n');prefix=scratch/'prefix';template=ROOT/'Runtime/TestPrefixes/wine-11.20';shutil.copytree(template,prefix,symlinks=True,copy_function=shutil.copy2)
    users=prefix/'drive_c/users';personal=scratch/'personal';personal.mkdir()
    for path in users.rglob('*'):
        if path.is_symlink()and not path.resolve(strict=False).is_relative_to(prefix.resolve()):
            target=personal/path.relative_to(users);target.mkdir(parents=True,exist_ok=True);path.unlink();path.symlink_to(target,target_is_directory=True)
    wine=pathlib.Path(config['wineBinary']);server=pathlib.Path(config['wineServer']);env=dict(clean,WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d',DYLD_LIBRARY_PATH=str(pathlib.Path(config['vulkanLibrary']).parent)+':'+str(pathlib.Path(config['sourceDependencyPrefix'])/'lib'))
    def stop():
        subprocess.run([str(server),'-k'],env=env,capture_output=True,timeout=10);subprocess.run([str(server),'-w'],env=env,capture_output=True,check=True,timeout=30)
    try:
        execute('wine-vulkan-buffer',[wine,ROOT/'Runtime/Probes/runtime_vulkan_probe.exe'],env,lambda x:x.get('readbackVerified')is True,wine=True);stop()
        execute('wine-vulkan-present',[wine,ROOT/'Runtime/Probes/runtime_vulkan_present.exe'],env,lambda x:x.get('presentedFrames',0)>=600,wine=True);stop()
        report['allPassed']=True
    finally:
        stop();assert scratch.parent==EXTERNAL/'tests'and marker.is_file();shutil.rmtree(scratch);report['exactPrefixStoppedAndRemoved']=True
        after=inventory(candidate);after.pop('moltenvk-source-manifest.json');report['candidateUnchanged']=before==after;report['defaultConfigurationsUnchanged']=all(sha(ROOT/'Runtime'/n)==h for n,h in default_hashes.items());report['sourceProbeHashes']={str(p.relative_to(ROOT)):sha(p)for p in [pathlib.Path(__file__),ROOT/'Scripts/runtime_moltenvk_native_probe.m',ROOT/'Scripts/runtime_vulkan_probe.c',ROOT/'Scripts/runtime_vulkan_present.c',ROOT/'Scripts/runtime_native_audit.c']};write(ROOT/'Evidence/runtime-moltenvk-source-validation.json',report)
    if not report['allPassed']or not report['candidateUnchanged']or not report['defaultConfigurationsUnchanged']:raise RuntimeError('Source candidate proof not complete')
    print(json.dumps({'passed':True,'candidate':str(candidate),'tests':len(report['tests']),'promoted':False},indent=2))
if __name__=='__main__':main()
