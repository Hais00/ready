#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile the real StoreClient.swift and exercise Foundation.Process with a memory vault."""
import json,pathlib,subprocess
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
products,modules,archive=prepare_core()
output=ROOT/'Build/ReadyStoreClientProbe'
output.parent.mkdir(parents=True,exist_ok=True)
objects=[archive]
subprocess.run(['xcrun','swiftc','-swift-version','5','-I',str(modules),'-framework','Security',str(ROOT/'Sources/M1Launcher/StoreClient.swift'),str(ROOT/'Sources/M1Launcher/Credentials.swift'),str(ROOT/'Synthetic/ReadyStoreClientProbe.swift'),*map(str,objects),'-o',str(output)],cwd=ROOT,check=True)
result=subprocess.run([str(output),str(ROOT)],cwd=ROOT,capture_output=True,text=True,timeout=90)
if result.returncode:
    # Do not echo private IPC or memory-vault contents on failure.
    raise SystemExit('StoreClient real-process probe failed; no private IPC was logged.')
report=json.loads(result.stdout)
(ROOT/'Evidence/store-client-tests.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
