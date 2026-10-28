#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Summarize local verification without uploading raw logs, tokens or local user paths."""
import datetime, json, pathlib, re
from zoneinfo import ZoneInfo
ROOT=pathlib.Path(__file__).resolve().parents[1]
def read(name):return json.loads((ROOT/'Evidence'/name).read_text())
core=read('core-probe.json')
host=read('session-host-tests.json')
manager=read('session-host-manager.json')
overlay=read('overlay-summary.json')
wine_overlay=read('overlay-wine-present.json')
frontend=read('frontend-memory.json')
prefix=read('runtime-prefix-isolation.json')
canonical=read('runtime-prefix-canonical-paths.json')
wine_sessions=read('session-host-wine-real.json')
wow64=read('runtime-wow64-proof.json')
store_client=read('store-client-tests.json')
migration_crash=read('migration-crash.json')
apple_gpu=read('runtime-winecx-probes.json')
apple_overlay=read('overlay-apple-d3d12.json')
provider_switch=read('provider-switch.json')
controller=read('controller-navigation.json')
frontend_lifecycle=read('frontend-lifecycle.json')
rollback_crash=read('rollback-crash.json')
custom_saves=read('custom-saves.json')
source_activation=read('runtime-source-activation.json')
source_e2e=read('runtime-source-candidate-e2e.json')
source_core=read('runtime-source-core-switch.json')
source_gate=read('runtime-source-activation-dependency-gate.json')
frontend_package=read('frontend-package-tests.json')
xinput=read('runtime-xinput-capture.json')
xinput_overlay=read('runtime-xinput-real-overlay.json')
xinput_provider=read('runtime-xinput-provider.json')
store_log=(ROOT/'Evidence/stores-parent-tests.log').read_text()
match=re.search(r'Ran (\d+) tests',store_log)
assert core['pass'] and host['passed'] and manager['passed']
assert wine_sessions['passed'] and wow64['verified']
assert store_client['passed'] and migration_crash['passed']
assert apple_gpu['dx12Verified'] and apple_overlay['passed'] and provider_switch['passed'] and controller['passed']
assert frontend_lifecycle['passed']
assert rollback_crash['passed']
assert custom_saves['passed']
assert source_activation['state']=='committed' and source_e2e['passed'] and source_core['passed']
assert source_gate['binaryRedistributionReady'] and not source_gate['runtimeValidationPending']
assert frontend_package['passed']
assert xinput['passed'] and xinput['twoSessionIsolation']['passed'] and xinput_overlay['passed']
assert not xinput['defaultRuntimeModified'] and not xinput_overlay['defaultRuntimeModified']
assert xinput_provider['diagnosticOnly'] and not xinput_provider['activated']
assert apple_gpu['evaluationOnly'] and not apple_gpu['enabledForConsumerPlay']
assert prefix['verified'] and canonical['verified'] and wine_overlay['passed'] and frontend['pass']
gpu_paths=[path for path in overlay if 'architecture' in path]
assert len(gpu_paths)==6 and all(path['passed'] for path in gpu_paths)
assert match and re.search(r'\nOK\s*$',store_log)
report={
 'createdAt':datetime.datetime.now(ZoneInfo('Europe/Rome')).isoformat(),
 'goalComplete':False,
 'core':{'checks':len(core['checks']),'passed':core['pass'],'names':[c['name'] for c in core['checks']]},
 'storeProtocols':{'checks':int(match.group(1)),'passed':True,'realAccountsVerified':False},
 'storeClient':{'passed':store_client['passed'],'checks':store_client['checks'],'realKeychainUsed':False},
 'migrationCrash':{'passed':migration_crash['passed'],'checks':migration_crash['checks'],'scope':migration_crash['scope']},
 'rollbackCrash':{'passed':True,'checks':rollback_crash['checks'],'realSIGKILLCount':rollback_crash['realSIGKILLCount'],'scope':rollback_crash['scope']},
 'customSaveFolders':{'passed':True,'checks':custom_saves['checks'],'scope':custom_saves['scope']},
 'controllerPolicy':{'passed':True,'checks':controller['checks'],'physicalDeviceVerified':False,'actualModalInteractionVerified':False},
 'appleEvaluation':{'dx12GPUVerified':True,'wineVersion':apple_gpu['reportedVersion'],
  'consumerPlayEnabled':False,'binaryRedistributionEnabled':False,'actualOverlayPaths':apple_overlay['actualOverlayPaths'],
  'overlayGPUCompleted':apple_overlay['hiddenStable']['completedGPUOverlaySubmissions'],
  'overlayGPUFailures':apple_overlay['hiddenStable']['failedGPUOverlaySubmissions'],
  'hiddenTextureBytes':apple_overlay['hiddenStable']['trackedTextureBytes'],
  'appleEndToEndPixelReadbackVerified':False,'directToDisplayVerified':False},
 'providerRoundTrip':{'passed':True,'checks':provider_switch['checks'],'scope':provider_switch['scope']},
 'runtimeBinaryRedistributionReady':False,
 'sourceBuiltRuntimeActivation':{'committed':True,'runtimeID':source_activation['newRuntimeID'],
  'wrapperChecks':len(source_e2e['tests']),'coreChecks':len(source_core['checks']),
  'dependencyDistributionScope':source_activation['approvedDistributionScope'],
  'dependencyBinaryRedistributionReady':True,'wholeApplicationBinaryDistributionApproved':False,
  'consumerAppleEnabled':False,'oldRuntimeTreesModified':False,'userConfigurationsOrPrefixesModified':False},
 'sessionHost':{'passed':host['passed'],'checks':host['checks'],'scope':'real processes, file locks, crash handoff and exact-prefix waiter'},
 'sessionManager':{'passed':manager['passed'],'checks':manager['checks'],'scope':manager['testType']},
 'realWineSessions':{'passed':wine_sessions['passed'],'checks':wine_sessions['checks'],
  'scope':wine_sessions['testType'],'runtimeID':wine_sessions['runtimeID']},
 'winePE32':{'verified':wow64['verified'],'scope':'real Win32 + DXMT DX11 device/buffer readback + 600-frame presentation',
  'shaderRasterizationVerified':wow64['shaderRasterization32Verified'],'commercialGameVerified':False},
 'winePrefixAPIs':{'verified':True,'steps':len(prefix['steps']),'canonicalWindowsPaths':True,
  'scope':'Synthetic games, real Wine Windows registry and folder APIs, independent profile/game prefixes, recreation retains data'},
 'frontendMemory':frontend,
 'frontendLifecycle':{'passed':True,'checks':frontend_lifecycle['checks'],'scope':frontend_lifecycle['scope'],
  'visualVerificationPerformed':False,'directToDisplayVerified':False},
 'frontendPackage':{'passed':True,'checks':len(frontend_package['checks']),
  'scope':frontend_package['scope'],'externalRuntimesBundled':False,
  'proprietaryAppleFilesBundled':False,'runtimeLocationGUIVerified':False,
  'wholeApplicationDistributionApproved':False},
 'diagnosticXInputCapture':{'passed':True,'dllArchitectureCases':len(xinput['cases']),
  'separateSessionsVerified':True,'actualInjectedOverlayStatusVerified':True,
  'physicalControllerVerified':False,'activated':False,
  'scope':'Wine 11.20 builtin XInput with simulated device input; other input APIs and WineCX unverified'},
 'overlay':{'gpuPaths':len(gpu_paths),
  'wineVulkanMetalVerified':True,'shownTrackedTextureBytes':835584,'hiddenTrackedTextureBytes':0,
  'directToDisplayVerified':False,'observedHUDMode':'Composited in both native baseline and overlay samples'},
 'openGates':['Real account login, entitlement downloads and commercial game launch',
  'Actual direct-to-display mode; current tested fullscreen baseline is Composited',
  'Open DX12 production path; Apple GPU path is verified only for local evaluation under its license',
  'Physical-controller behavior and in-game input suppression',
  'Native macOS game save/account isolation and complete release packaging',
  'Guided migration UI visual verification (Mac locked during current attempt)',
  'Real legacy user-data/game migration beyond synthetic copy and rollback crash fixtures',
  'External updaters that do not participate in the installation lease protocol',
  'Whole-application packaging and remaining third-party distribution inventory beyond the approved 25-library dependency payload']
}
out=ROOT/'Validation';out.mkdir(exist_ok=True)
(out/'checkpoint.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'coreChecks':report['core']['checks'],'storeChecks':report['storeProtocols']['checks'],'goalComplete':False}))
