#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile actual Swift SSO/StoreClient; synthetic helpers and an in-memory vault."""
import hashlib,json,pathlib,subprocess,os
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
products,modules,archive=prepare_core()
sources=[ROOT/'Sources/M1Launcher'/name for name in ['Credentials.swift','StoreClient.swift','SteamAccountCoordinator.swift']]
sources.append(ROOT/'Synthetic/ReadySteamAccountProbe.swift')
output=ROOT/'Build/ReadySteamAccountProbe'
subprocess.run(['xcrun','swiftc','-swift-version','5','-I',str(modules),'-framework','Security',*map(str,sources),str(archive),'-o',str(output)],cwd=ROOT,check=True)
env={**os.environ,'READY_STORE_TOOLS_ROOT':str(ROOT/'Build/ReadySSOFixtureTools')}
run=subprocess.run([str(output),str(ROOT)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=60)
if run.returncode:raise SystemExit('Steam SSO synthetic process checks failed; no private IPC was logged.')
report=json.loads(run.stdout);report['sourceHashes']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}
(ROOT/'Evidence/steam-account-coordinator-tests.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
