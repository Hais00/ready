#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Freeze a diagnostic XInput provider after hash-bound API and actual-overlay proof.

Creates base/DXMT Wine11.20 copies and a separate test-only payload. Never changes
Runtime/runtime.json, the evaluation configuration, or any user/game prefix.
"""
import hashlib,json,os,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
STAGING=ROOT/'Runtime/XInputDiagnostic'

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':')).encode()
def copytree(source,target):subprocess.run(['/bin/cp','-cR',str(source),str(target)],check=True)
def project(payload,wine):
    for arch in ['x86_64','i386']:
        for source in (payload/(arch+'-windows')).glob('*.dll'):shutil.copy2(source,wine/'lib/wine'/(arch+'-windows')/source.name)
    for source in (payload/'x86_64-unix').iterdir():
        target=wine/'lib/wine/x86_64-unix'/source.name;target.unlink(missing_ok=True)
        if source.is_symlink():target.symlink_to(os.readlink(source))
        else:shutil.copy2(source,target)

def main():
    paths=[ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json'];before={str(p):sha(p) for p in paths};cfg=json.loads(paths[0].read_text())
    build_path=ROOT/'Evidence/runtime-xinput-build.json';api_path=ROOT/'Evidence/runtime-xinput-capture.json';overlay_path=ROOT/'Evidence/runtime-xinput-real-overlay.json'
    build=json.loads(build_path.read_text());api=json.loads(api_path.read_text());overlay=json.loads(overlay_path.read_text())
    assert api['passed'] and len(api['cases'])==10 and api['twoSessionIsolation']['passed']
    assert api['buildEvidenceSHA256']==sha(build_path) and overlay['passed'] and overlay['nativeStatusWrittenByOverlay'] and not overlay['defaultRuntimeModified'] and overlay['buildEvidenceSHA256']==sha(build_path)
    assert build['nativeMinimumMacOS']=='14.0'
    assert sha(STAGING/'x86_64-ready-test-device.dll')==overlay['testDeviceSHA256']
    assert not build['productionContainsTestBackend'] and all(e['exportsEqual'] for e in build['productionExportParity'])
    for relative,digest in build['sourceInputs'].items():assert sha(ROOT/relative)==digest,relative
    for relative,digest in build['payloadHashes'].items():assert sha(STAGING/relative)==digest,relative
    api_binary_names={arch+'-'+name for arch in ['x86_64','i386'] for name in ['xinput-probe.exe','ready-test-device.dll']}
    # The API harness observes other staging files but executes only these four.
    # Presentation files are independently bound by the actual-overlay receipt.
    for relative,digest in api['testBinaryHashes'].items():
        if Path(relative).name in api_binary_names:assert sha(ROOT/relative)==digest,relative
    assert sha(STAGING/'xinput-overlay-probe.exe')==overlay['probeSHA256']
    assert sha(STAGING/'ready-present-test.dll')==overlay['presenterSHA256']
    for case in api['cases']:
        trace=case['moduleProvenance'];assert sha(ROOT/trace['log'])==trace['sha256']
    assert sha(ROOT/overlay['moduleLog']['path'])==overlay['moduleLog']['sha256']
    origin_base=Path(cfg['immutableRuntimeSet'])/'wine';origin_dxmt=Path(cfg['engineWineBinaries']['dxmtMetal']).parent.parent
    inputs={'schema':1,'wineVersion':'11.20','baseRuntimeID':cfg['runtimeID'],'baseSourceGenerationSHA256':sha(origin_base.parent/'source-generation.json'),'dxmtSourceGenerationSHA256':sha(origin_dxmt.parent/'source-generation.json'),'buildEvidenceSHA256':sha(build_path),'apiEvidenceSHA256':sha(api_path),'apiTestBinaryScope':sorted(api_binary_names),'overlayEvidenceSHA256':sha(overlay_path),'freezeRecipeSHA256':sha(__file__)}
    identity='ready-xinput-wine1120-'+hashlib.sha256(canonical(inputs)).hexdigest()[:20];provider=ROOT/'Runtime/Providers'/identity
    if provider.exists():raise RuntimeError('Provider already exists; frozen providers are never overwritten')
    provider.mkdir();sources=provider/'sources';sources.mkdir();(sources/'Vendor').mkdir();copytree(ROOT/'Vendor/wine',sources/'Vendor/wine');shutil.copy2(ROOT/'Vendor/wine.source.json',sources/'Vendor/wine.source.json')
    scripts=sources/'Scripts';scripts.mkdir()
    names=['runtime_build_xinput.py','runtime_freeze_xinput.py','runtime_xinput_protocol.h','runtime_xinput_unix.c','runtime_xinput_gate.h','runtime_wine_xinput_capture.patch','runtime_build.py','runtime_fetch.py','runtime_xinput_test.py','runtime_xinput_probe.c','runtime_xinput_test_device.c','runtime_xinput_overlay_test.py','runtime_xinput_overlay_probe.c','runtime_xinput_present_test.c','runtime_vulkan_present.c']
    for name in names:shutil.copy2(ROOT/'Scripts'/name,scripts/name)
    shutil.copy2(STAGING/'main.c',sources/'adapted-xinput-main.c')
    configuration=sources/'configuration';configuration.mkdir()
    for name in ['config.status','Makefile','include/config.h']:
        original=ROOT/'Runtime/build-wine-input-11.20'/name;destination=configuration/name;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(original,destination)
    notices=provider/'notices';notices.mkdir();shutil.copy2(ROOT/'Vendor/wine/COPYING.LIB',notices/'Wine-LGPL-2.1.txt');shutil.copy2(ROOT/'LICENSE',notices/'Ready-GPL-3.0.txt')
    (notices/'NOTICE.txt').write_text('Wine XInput original authors: Andrew Fenn (2008), Aric Stewart (2018), Rémi Bernon / CodeWeavers (2021). Original Wine copyright/license headers remain intact. Wine source adaptations, native Unix reader and protocol are LGPL-2.1-or-later. Original Ready test programs and freeze orchestration are GPL-3.0-only. The production payload has no deterministic device backend or test exports. This is a local diagnostic provider, not a claim that every inherited runtime binary is ready for distribution. No Apple proprietary component is included.\n')
    providers={}
    for kind,original in [('base',origin_base),('dxmt',origin_dxmt)]:
        directory=provider/kind;directory.mkdir();wine=directory/'wine';copytree(original,wine);project(STAGING/'production',wine)
        providers[kind]={'wine':str(wine/'bin/ready-wine'),'wineBinary':str(wine/'bin/wine'),'wineServer':str(wine/'bin/wineserver'),'builtin32Directory':str(wine/'lib/wine/i386-windows'),'originalWine':str(original),'originalWineBinarySHA256':sha(original/'bin/wine'),'wineBinaryUnchanged':sha(wine/'bin/wine')==sha(original/'bin/wine')}
    tests=provider/'test-only';tests.mkdir();copytree(STAGING/'test',tests/'variant')
    for name in ['x86_64-ready-test-device.dll','i386-ready-test-device.dll','x86_64-xinput-probe.exe','i386-xinput-probe.exe','xinput-overlay-probe.exe','ready-present-test.dll']:shutil.copy2(STAGING/name,tests/name)
    evidence=provider/'evidence';evidence.mkdir()
    shutil.copy2(origin_base.parent/'source-generation.json',evidence/'base-source-generation.json');shutil.copy2(origin_dxmt.parent/'source-generation.json',evidence/'dxmt-source-generation.json')
    for path in [build_path,api_path,overlay_path]:shutil.copy2(path,evidence/path.name)
    for case in api['cases']:shutil.copy2(ROOT/case['moduleProvenance']['log'],evidence/Path(case['moduleProvenance']['log']).name)
    shutil.copy2(ROOT/overlay['moduleLog']['path'],evidence/Path(overlay['moduleLog']['path']).name)
    config=json.loads(json.dumps(cfg));config.update(wine=providers['base']['wine'],wineBinary=providers['base']['wineBinary'],wineServer=providers['base']['wineServer'],builtin32Directory=providers['base']['builtin32Directory'],runtimeID=cfg['runtimeID']+'+'+identity)
    for key in ['engineWineBinaries','engineWineServers','engineSearchPaths','engineDLLs','engineDLLs32','engineBuiltin32Dirs','engineProviderIDs']:
        value=config.setdefault(key,{})
        if key=='engineWineBinaries':value['dxmtMetal']=providers['dxmt']['wine']
        elif key=='engineWineServers':value['dxmtMetal']=providers['dxmt']['wineServer']
        elif key=='engineSearchPaths':value['dxmtMetal']=str(provider/'dxmt/wine/lib/wine')
        elif key=='engineProviderIDs':value['dxmtMetal']=identity+'-dxmt'
        else:value['dxmtMetal']=str(provider/'dxmt/wine/lib/wine'/('x86_64-windows' if key=='engineDLLs' else 'i386-windows'))
    config['overlayInputCapture']={'diagnosticOnly':True,'providerID':identity,'api':'Wine builtin XInput','requiresBuiltinXInputSelection':True,'requiredBuiltinOverride':'xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0=b','verifiedArchitectures':['i386','x86_64'],'physicalControllerVerified':False,'directInputCovered':False,'rawInputCovered':False,'hidCovered':False}
    candidate=ROOT/'Runtime/candidate-xinput.json';candidate.write_text(json.dumps(config,indent=2)+'\n')
    manifest={'schema':1,'providerID':identity,'diagnosticOnly':True,'activated':False,'inputs':inputs,'providers':providers,'productionPayloadHashes':{k:v for k,v in build['payloadHashes'].items() if k.startswith('production/')},'sourceLicense':'LGPL-2.1-or-later','testLicense':'GPL-3.0-only','fullWineUpstreamSourceSupplied':True,'upstreamSource':json.loads((ROOT/'Vendor/wine.source.json').read_text()),'sourceFiles':{str(p.relative_to(provider)):sha(p) for p in sources.rglob('*') if p.is_file() and not p.is_symlink()},'scope':{'xinputVersions':build['versions'],'architectures':['i386','x86_64'],'rawDevice':'unchanged production Wine; deterministic backend only under test-only/','winecxVerified':False,'physicalControllerVerified':False,'otherInputAPIsCovered':False,'wholeRuntimeDistributionReadiness':False},'candidateConfiguration':str(candidate),'candidateSHA256':sha(candidate),'defaultConfigHashesBefore':before,'defaultConfigHashesAfter':{str(p):sha(p) for p in paths}}
    assert manifest['defaultConfigHashesAfter']==before
    (provider/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    record={'providerID':identity,'provider':str(provider),'manifestSHA256':sha(provider/'manifest.json'),'diagnosticOnly':True,'activated':False,'defaultRuntimeModified':False,'candidate':str(candidate),'candidateSHA256':sha(candidate),'apiMatrixPassed':True,'realOverlayPassed':True,'sourceLicense':'LGPL-2.1-or-later'}
    (ROOT/'Evidence/runtime-xinput-provider.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))
if __name__=='__main__':main()
