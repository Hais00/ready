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
store_log=(ROOT/'Evidence/stores-parent-tests.log').read_text()
match=re.search(r'Ran (\d+) tests',store_log)
assert core['pass'] and host['passed'] and manager['passed']
assert wine_sessions['passed'] and wow64['verified']
assert prefix['verified'] and canonical['verified'] and wine_overlay['passed'] and frontend['pass']
gpu_paths=[path for path in overlay if 'architecture' in path]
assert len(gpu_paths)==6 and all(path['passed'] for path in gpu_paths)
assert match and re.search(r'\nOK\s*$',store_log)
report={
 'createdAt':datetime.datetime.now(ZoneInfo('Europe/Rome')).isoformat(),
 'goalComplete':False,
 'core':{'checks':len(core['checks']),'passed':core['pass'],'names':[c['name'] for c in core['checks']]},
 'storeProtocols':{'checks':int(match.group(1)),'passed':True,'realAccountsVerified':False},
 'sessionHost':{'passed':host['passed'],'checks':host['checks'],'scope':'real processes, file locks, crash handoff and exact-prefix waiter'},
 'sessionManager':{'passed':manager['passed'],'checks':manager['checks'],'scope':manager['testType']},
 'realWineSessions':{'passed':wine_sessions['passed'],'checks':wine_sessions['checks'],
  'scope':wine_sessions['testType'],'runtimeID':wine_sessions['runtimeID']},
 'winePE32':{'verified':wow64['verified'],'scope':'real Win32 + DXMT DX11 device/buffer readback + 600-frame presentation',
  'shaderRasterizationVerified':wow64['shaderRasterization32Verified'],'commercialGameVerified':False},
 'winePrefixAPIs':{'verified':True,'steps':len(prefix['steps']),'canonicalWindowsPaths':True,
  'scope':'Synthetic games, real Wine Windows registry and folder APIs, independent profile/game prefixes, recreation retains data'},
 'frontendMemory':frontend,
 'overlay':{'gpuPaths':len(gpu_paths),
  'wineVulkanMetalVerified':True,'shownTrackedTextureBytes':835584,'hiddenTrackedTextureBytes':0,
  'directToDisplayVerified':False,'observedHUDMode':'Composited in both native baseline and overlay samples'},
 'openGates':['Real account login, entitlement downloads and commercial game launch',
  'Actual direct-to-display mode; current tested fullscreen baseline is Composited',
  'D3D12 / latest proprietary Apple runtime ABI integration',
  'Physical-controller behavior and in-game input suppression',
  'Native macOS game save/account isolation and complete release packaging',
  'Real legacy user-data migration beyond synthetic copies; guided UI and interrupted-copy recovery',
  'Shared game update coordination with already-running consumers']
}
out=ROOT/'Validation';out.mkdir(exist_ok=True)
(out/'checkpoint.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'coreChecks':report['core']['checks'],'storeChecks':report['storeProtocols']['checks'],'goalComplete':False}))
