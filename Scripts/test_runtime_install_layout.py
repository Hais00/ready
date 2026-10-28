#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Small source/layout fixtures only; no Wine, renderer, GPU or compiler."""
import hashlib,json,os,shutil,tempfile
from pathlib import Path
import runtime_install_layout as layout

def put(path,text,mode=0o644):
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text);path.chmod(mode)
def write(path,value):put(path,json.dumps(value))
def make_fixture(root):
    providers={}
    for role in ['base','dxmt']:
        wine=root/role/'wine';put(wine/'bin/wine','fake Wine ABI',0o755);put(wine/'bin/wineserver','fake server',0o755);put(wine/'bin/ready-wine','#!/bin/sh\n# source wrapper\n',0o755)
        hashes={};known={}
        for arch in ['i386','x86_64']:
            for name in ['xinput1_1','xinput1_2','xinput1_3','xinput1_4','xinput9_1_0']:
                rel=arch+'-windows/'+name+'.dll';put(wine/'lib/wine'/rel,'fake-input-'+rel);hashes[rel]=layout.sha(wine/'lib/wine'/rel);known[rel]=[hashes[rel]]
        rel='x86_64-unix/xinput-capture.so';put(wine/'lib/wine'/rel,'fake native reader');hashes[rel]=layout.sha(wine/'lib/wine'/rel)
        aliases={}
        for name in ['xinput1_1','xinput1_2','xinput1_3','xinput1_4']:
            rel='x86_64-unix/'+name+'.so';(wine/'lib/wine'/rel).symlink_to('xinput-capture.so');aliases[rel]='xinput-capture.so'
        providers[role]={'wineRoot':str(wine),'wineBinarySHA256':layout.sha(wine/'bin/wine'),'wineLauncherSHA256':layout.sha(wine/'bin/ready-wine'),'payloadHashes':hashes,'unixAliases':aliases,'knownBuiltinHashes':known}
    support=root/'support';native=root/'native';meta=root/'e6';meta.mkdir();put(support/'source-generation.json','{"historicalRoot":"/original/never/rewrite"}')
    for rel in ['dependency-root/lib/libsource.dylib','vulkan/libvulkan.1.dylib','kosmic-x64/libvulkan_kosmickrisp.dylib','molten/libMoltenVK.dylib','dxvk/d3d11.dll','dxvk-x86/d3d11.dll','vkd3d/d3d12.dll','vkd3d-x86/d3d12.dll']:put(support/rel,'fixture source bytes')
    for name,rel in [('kosmic','kosmic-x64/libvulkan_kosmickrisp.dylib'),('molten','molten/libMoltenVK.dylib')]:write(support/'icd'/(name+'.json'),{'ICD':{'library_path':str(support/rel),'api_version':'1.4.0'}})
    put(native/'lib/libvulkan.1.dylib','fake ARM loader');put(native/'lib/libvulkan_kosmickrisp.dylib','fake ARM renderer');write(native/'icd/kosmic-arm64.json',{'ICD':{'library_path':'../lib/libvulkan_kosmickrisp.dylib'}});write(native/'native-renderer-manifest.json',{'identity':'fixture-native','runtimeValidationPending':True})
    validation=root/'evidence/native-validation.json';write(validation,{'candidate':'/historical/candidate/path','allPassed':True,'fixtureOnly':True})
    cap={'protocolVersion':2,'providerID':'fixture-e6','engineProviders':{'wineD3D':'base','vulkanKosmic':'base','dxmtMetal':'dxmt'},'providers':providers,'requiredEnvironment':{'M1L_XINPUT_CAPTURE':'1'}}
    capfile=meta/'controller-capability.json';write(capfile,cap);write(meta/'manifest.json',{'historicalRoot':'/original/e6','fixtureOnly':True});put(meta/'notices/NOTICE','Original fixture notices')
    cfg={'fixtureOnly':True,'wine':str(root/'base/wine/bin/ready-wine'),'wineServer':str(root/'base/wine/bin/wineserver'),'wineBinary':str(root/'base/wine/bin/wine'),'wineVersion':'fixture','runtimeID':'fixture-original','immutableRuntimeSet':str(support),'sourceDependencyPrefix':str(support/'dependency-root'),'engineWineBinaries':{'dxmtMetal':str(root/'dxmt/wine/bin/ready-wine')},'engineSearchPaths':{'dxmtMetal':str(root/'dxmt/wine/lib/wine')},'builtin32Directory':str(root/'base/wine/lib/wine/i386-windows'),'engineDLLs':{},'kosmicICD':str(support/'icd/kosmic.json'),'moltenICD':str(support/'icd/molten.json'),'vulkanLibrary':str(support/'vulkan/libvulkan.1.dylib'),'kosmicNativeICD':str(native/'icd/kosmic-arm64.json'),'nativeVulkanLibrary':str(native/'lib/libvulkan.1.dylib'),'nativeRendererID':'fixture-native','nativeRendererManifestPath':str(native/'native-renderer-manifest.json'),'nativeRendererValidationPath':str(validation),'nativeRendererValidationSHA256':layout.sha(validation),'overlayInputCapture':{**cap,'manifestPath':str(capfile),'manifestSHA256':layout.sha(capfile)},'evaluationModeEnabled':False}
    source=root/'runtime.json';write(source,cfg);return source

def main():
    parent=Path(tempfile.gettempdir()).resolve()
    with tempfile.TemporaryDirectory(prefix='install-layout-fixture-',dir=parent) as temporary:
        root=Path(temporary);source=root/'source';source.mkdir();configuration=make_fixture(source);plan=layout.make_plan(configuration);objects={c['id']:Path(c['sourceRoot']) for c in plan['components']}
        before={str(p):layout.sha(p) for p in source.rglob('*') if p.is_file() and not p.is_symlink()}
        stage=root/'stage with spaces';result=layout.materialize(stage,objects,plan);assert result['staticValidation']['passed']
        moved=root/'moved layout with spaces';stage.rename(moved);verified=layout.validate(moved,plan);assert verified['candidateTreeFingerprint']==result['staticValidation']['candidateTreeFingerprint']
        original=configuration.read_bytes();assert json.loads(original)['runtimeID']=='fixture-original';assert before=={str(p):layout.sha(p) for p in source.rglob('*') if p.is_file() and not p.is_symlink()}
        cfg=json.load(open(moved/'runtime.json'));history=moved/cfg['nativeRendererValidationPath'];assert json.load(open(history))['candidate']=='/historical/candidate/path'
        raw_store=root/'objects';raw_store.mkdir();stored={}
        for component in plan['components']:
            target=raw_store/component['id']
            if not target.exists():layout.copy_view(Path(component['sourceRoot']),target,component['files'])
            stored[component['id']]=target
        source.rename(root/'source temporarily unavailable')
        offline=root/'offline materialization';layout.materialize(offline,stored,plan);assert layout.validate(offline,plan)['passed']
        (root/'source temporarily unavailable').rename(source)
        checks={'smallMaterialization':True,'offlineMaterializationFromObjects':True,'movePreservesFingerprint':True,'sourceObjectsUnchanged':True,'historicalNativeReceiptUnchanged':True}
        for name,target in [('wrapper',moved/'components/base/wine/bin/ready-wine'),('payload',moved/'components/base/wine/lib/wine/i386-windows/xinput1_4.dll'),('capability',moved/'controller-capability.json')]:
            saved=target.read_bytes();target.write_bytes(saved+b'changed')
            try:layout.validate(moved,plan)
            except Exception:checks['reject-'+name]=True
            else:raise AssertionError('Tamper accepted: '+name)
            target.write_bytes(saved)
        checks['staticOnlyNoRuntimeClaim']=verified['verificationKind']=='derivation-static-v1' and verified['relocatedRuntimeVerified'] is False
        report={'schema':1,'verificationKind':'fixture-v1','passed':all(checks.values()),'checks':checks,'realPayloadCopied':False,'wineStarted':False,'compilerStarted':False}
        (layout.ROOT/'Evidence/runtime-install-layout-fixtures.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
