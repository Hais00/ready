#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Summarize local verification without uploading raw logs, tokens or local user paths."""
import datetime, hashlib, json, pathlib, re
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
wow64_shader=read('runtime-wow64-shader-proof.json')
store_client=read('store-client-tests.json')
migration_crash=read('migration-crash.json')
copy_recovery_crash=read('copy-recovery-crash.json')
recreation_crash=read('recreation-crash.json')
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
xinput_provider=read('runtime-xinput-e6-provider.json')
xinput_optin=read('runtime-xinput-e6-native-optin.json')
snapshot_tests=read('frontend-snapshot-v2-final-tests.json')
integrated_proposal=read('runtime-integrated-proposal.json')
integrated_check=read('runtime-integrated-check.json')
controller_e2e_guard=read('controller-policy-e2e-guard.json')
controller_e2e_path=ROOT/'Evidence/controller-policy-e2e.json'
controller_e2e=json.loads(controller_e2e_path.read_text()) if controller_e2e_path.exists() else {}
projection=read('runtime-projection-tests.json')
projection_resources=read('runtime-projection-resource-resume-tests.json')
transport=read('runtime-evidence-transport-tests.json')
core_sources=read('runtime-core-source-acquisition.json')
core_sources_negative=read('runtime-core-source-negative-checks.json')
renderer_sources=read('runtime-renderer-distribution-audit.json')['correspondingSourceAcquisition']
native_renderer=read('runtime-native-renderer-validation.json')
native_renderer_verify=read('runtime-native-renderer-independent-verification.json')
store_log=(ROOT/'Evidence/stores-parent-tests.log').read_text()
match=re.search(r'Ran (\d+) tests',store_log)
assert core['pass'] and host['passed'] and manager['passed']
assert wine_sessions['passed'] and wow64['verified']
assert wow64_shader['passed'] and wow64_shader['shaderRasterization32Verified']
assert wow64_shader['abiObservation']['pointerBits'] == 32
assert wow64_shader['centralEnginesUnchanged'] and wow64_shader['exactPrefixStopped'] and not wow64_shader['scratchRetained']
assert not wow64_shader['defaultConfigurationChanged'] and not wow64_shader['runtimeRebuilt']
assert store_client['passed'] and migration_crash['passed']
assert copy_recovery_crash['passed'] and recreation_crash['passed']
assert copy_recovery_crash['actualSIGKILLCount'] == 6 and recreation_crash['realSIGKILLCount'] == 1
assert apple_gpu['dx12Verified'] and apple_overlay['passed'] and provider_switch['passed'] and controller['passed']
assert frontend_lifecycle['passed']
assert rollback_crash['passed']
assert custom_saves['passed']
assert source_activation['state']=='committed' and source_e2e['passed'] and source_core['passed']
assert source_gate['binaryRedistributionReady'] and not source_gate['runtimeValidationPending']
assert frontend_package['passed']
assert xinput['passed'] and xinput['twoSessionIsolation']['passed'] and xinput_overlay['passed']
assert not xinput['defaultRuntimeModified'] and not xinput_overlay['defaultRuntimeModified']
assert xinput_provider['protocolVersion']==2 and xinput_provider['diagnosticOnly'] and not xinput_provider['activated']
assert len(xinput['cases'])==10 and len(xinput['optOutCases'])==30 and all(c['passed'] for c in xinput['optOutCases'])
assert sum(len(c['negativeProtocolCases']) for c in xinput['cases'])==24
assert len(xinput['twoSessionIsolation']['cases'])==4 and xinput_optin['passedCases']==5
assert snapshot_tests['passed'] and len(snapshot_tests['checks'])==14 and snapshot_tests['legacyV1Refused']
assert not snapshot_tests['realV2AssemblyExecuted']
assert not integrated_proposal['actualActivationCommandAvailable'] and not integrated_check['activationImplemented']
assert projection['passed'] and not projection['staticOnly'] and projection['sourceAndProjectionBytesUnchanged']
assert projection['ownedPrefixFixturesRemoved'] and not projection['binaryDistributionApproved']
assert projection_resources['passed'] and projection_resources['sourceAndProjectionBytesUnchanged']
assert projection_resources['ownedPrefixFixturesRemoved'] and not projection_resources.get('skippedChecks')
assert len(projection_resources['tests']) == 13 and all(value['passed'] for value in projection_resources['tests'].values())
assert projection_resources['historicalBaseRelocationReportSHA256'] == hashlib.sha256((ROOT/'Evidence/runtime-projection-tests.json').read_bytes()).hexdigest()
assert not projection_resources['additionalProbeScope']['certificateValidationBypassUsed']
assert not projection_resources['additionalProbeScope']['directToDisplayClaimed']
assert transport['passed'] and transport['originalEvidenceDeniedOnlyToVerifier']
assert transport['originalAndPacketPayloadReceiptEvidenceUnchanged'] and not transport['binaryDistributionApproved']
assert core_sources['finalized'] and core_sources['allSourceMaterialAcquired'] and core_sources['immutableVerificationPassed']
assert core_sources_negative['passed'] and not core_sources['artifactCorrespondenceVerified'] and not core_sources['licenseApproval']
assert renderer_sources['completeRecursiveGitSources'] and not renderer_sources['artifactBinaryBuildAttested']
assert native_renderer['allPassed'] and native_renderer['candidateUnchanged']
assert native_renderer_verify['verified'] and native_renderer_verify['runtimeValidationVerified']
assert not native_renderer['activationPerformed'] and not native_renderer['advertisedFeaturesModified']
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
 'copyRecoveryCrash':{'passed':True,'checks':copy_recovery_crash['checks'],
  'realSIGKILLCount':copy_recovery_crash['actualSIGKILLCount'],'scope':copy_recovery_crash['scope']},
 'prefixRecreationCrash':{'passed':True,'checks':recreation_crash['checks'],
  'realSIGKILLCount':recreation_crash['realSIGKILLCount'],'scope':recreation_crash['scope']},
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
 'sessionHost':{'passed':host['passed'],'checks':host['checks'],'skippedChecks':host.get('skippedChecks',[]),
  'scope':'real processes, file locks, native wrapper group lifetime, crash handoff and exact-prefix waiter'},
 'sessionManager':{'passed':manager['passed'],'checks':manager['checks'],'scope':manager['testType']},
 'realWineSessions':{'passed':wine_sessions['passed'],'checks':wine_sessions['checks'],
  'scope':wine_sessions['testType'],'runtimeID':wine_sessions['runtimeID']},
 'winePE32':{'verified':wow64['verified'],'scope':'real Win32 + DXMT DX11 device/buffer readback + 600-frame presentation',
  'shaderRasterizationVerified':True,'shaderProofRuntimeID':wow64_shader['runtimeID'],
  'shaderProofScope':'real i386 PE32, SM5/FL11_0 HLSL triangle, 1152 colored and 2944 background pixels with center/corner checks',
  'historicalBufferPresentationReportUnchanged':True,'centralEnginesAndConfigurationsUnchanged':True,
  'commercialGameVerified':False},
 'winePrefixAPIs':{'verified':True,'steps':len(prefix['steps']),'canonicalWindowsPaths':True,
  'scope':'Synthetic games, real Wine Windows registry and folder APIs, independent profile/game prefixes, recreation retains data'},
 'frontendMemory':frontend,
 'frontendLifecycle':{'passed':True,'checks':frontend_lifecycle['checks'],'scope':frontend_lifecycle['scope'],
  'visualVerificationPerformed':False,'directToDisplayVerified':False},
 'frontendPackage':{'passed':True,'checks':len(frontend_package['checks']),
  'scope':frontend_package['scope'],'externalRuntimesBundled':False,
  'proprietaryAppleFilesBundled':False,'runtimeLocationGUIVerified':False,
  'wholeApplicationDistributionApproved':False},
 'diagnosticXInputCapture':{'passed':True,'protocolVersion':2,'providerID':xinput_provider['providerID'],
  'dllArchitectureCases':len(xinput['cases']),'optOutCases':len(xinput['optOutCases']),
  'totalAPICases':len(xinput['cases'])+len(xinput['optOutCases']),
  'negativeProtocolChecks':sum(len(c['negativeProtocolCases']) for c in xinput['cases']),
  'sessionPairCases':len(xinput['twoSessionIsolation']['cases']),'nativeOptInUnitCases':xinput_optin['passedCases'],
  'separateSessionsVerified':True,'actualInjectedOverlayStatusVerified':True,
  'physicalControllerVerified':False,'activated':False,
  'scope':'Wine 11.20 builtin XInput with simulated device input; other input APIs and WineCX unverified'},
 'frontendSnapshotV2':{'fixtureChecks':len(snapshot_tests['checks']),'passed':True,
  'legacyV1Refused':True,'freshV2BuildAndAssemblyVerified':False,
  'scope':'Synthetic source/recipe/binary/module tamper fixtures only; current-source normal build and actual v2 assembly pending'},
 'integratedRuntimeProposal':{'prepared':True,'fixtureChecks':integrated_proposal['fixtureTests'],
  'activationImplemented':False,'activeProjectConfigurationsChanged':False,
  'userConfigurationsOrPrefixesChanged':False,'controllerBindingsPreserved':True,'WineCXInputCaptureApplied':False,
  'lastCheckReady':integrated_check['readyForRootReview'],
  'remainingCheckGates':[k for k,v in integrated_check['checks'].items() if not v['passed']]},
 'productionControllerPolicyE2E':{'passed':controller_e2e.get('passed',False),'requiredCases':5,
  'completedCases':len(controller_e2e.get('cases',[])), 'productionPolicyVerified':controller_e2e.get('passed',False),
  'guardTriggered':controller_e2e_guard['guardTriggered'],'terminalCondition':controller_e2e_guard['terminalCondition'],
  'reserveMiB':512,'phase':controller_e2e_guard['phase'],'phaseKnown':False,
  'elapsedAtGuardMonotonicSeconds':None,'freeBytesAtGuard':None,
  'softwareFailureEstablished':controller_e2e_guard['softwareFailureObserved'],
  'retryPendingSpace':True,'newTelemetryExecuted':False,'physicalControllerVerified':False},
 'portableRuntimeProjection':{'passed':True,'checks':len(projection['tests']),
  'additionalResourceChecks':len(projection_resources['tests']),
  'resourceScope':'DXMT PE64 shader/readback; 600 DXMT PE64/PE32 fullscreen-requested presents; Vulkan600 presents; TLS/certificate rejection/GDI/DirectWrite PE64/PE32',
  'PE32ShaderRasterizationVerified':False,'directToDisplayVerified':False,
  'minimumMacOS':projection['minimumMacOS'],'diagnosticOnly':True,
  'oldRuntimeRootsDenied':True,'sourceAndProjectionBytesUnchanged':True,
  'scope':'real relocated open Wine/Windows synthetic programs with per-game/profile save bindings and native image audit',
  'nativeARM64HomebrewClosureResolved':False,'separateSourceBuiltNativeCandidateClosureResolved':True,
  'wholeRuntimeDistributionApproved':False},
 'transportedDependencyEvidence':{'passed':True,'checks':len(transport['tests']),
  'evidenceFiles':transport['evidenceFiles'],'originalEvidenceDeniedToVerifier':True,
  'scope':transport['scope'],'approvedLibrariesAndModules':transport['transportedGateSummary']['approvedPayloadLibrariesAndModules'],
  'originalPayloadReceiptEvidenceUnchanged':True,'wholeApplicationDistributionApproved':False},
 'sourceAcquisition':{'coreInputArchives':core_sources['componentsAcquired'],
  'previouslyRetainedDXMTArchives':core_sources['previouslyRetainedDXMTSourceArchives'],
  'coreSourcePacketIntegrityVerified':True,'coreIntegrityChecks':len(core_sources_negative['checks']),
  'rendererRepositoryRevisions':renderer_sources['repositoryRevisions'],
  'rendererVerifiedGitBlobFiles':renderer_sources['verifiedGitBlobFiles'],
  'rendererNoticeDocuments':renderer_sources['indexedNoticeDocuments'],
  'rendererCompleteRecursiveGitSources':True,'historicalBinaryBuildCorrespondenceVerified':False,
  'wholeRuntimeLicenseApproval':False},
 'sourceBuiltNativeARM64Renderer':{'passed':True,'gpuAndPropertyChecks':len(native_renderer['tests']),
  'sandboxControls':len(native_renderer['sandboxControls']),'architecture':native_renderer['architecture'],
  'minimumMacOS':native_renderer['minimumMacOS'],'candidateFingerprint':native_renderer['candidateFingerprint'],
  'sourceBuiltLibraries':4,'strongHomebrewDependencies':0,'candidateBytesUnchanged':True,
  'activated':False,'wholeRuntimeDistributionApproved':False},
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
  'Integrate the separately verified source ARM64 renderer and finish the portable installer without changing defaults prematurely',
  'Five-case production controller-policy E2E and current-source fresh frontend v2 build/assembly; retry pending additional disk space',
  'Historical static-input/binary source correspondence and exact release notices beyond acquired source archives',
  'Whole-application packaging and remaining third-party distribution inventory beyond the approved 25-library dependency payload']
}
out=ROOT/'Validation';out.mkdir(exist_ok=True)
(out/'checkpoint.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'coreChecks':report['core']['checks'],'storeChecks':report['storeProtocols']['checks'],'goalComplete':False}))
