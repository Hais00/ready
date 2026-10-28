#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Pure controller policy tests. Does not create NSApplication, windows, or fake input."""
import json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
probe=ROOT/'Build/ReadyControllerNavigationProbe'
probe.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(ROOT/'Sources/M1Launcher/ControllerNavigation.swift'),str(ROOT/'Synthetic/ReadyControllerNavigationProbe.swift'),'-framework','AppKit','-o',str(probe)],check=True,cwd=ROOT)
run=subprocess.run([str(probe)],capture_output=True,text=True,check=True,cwd=ROOT)
report=json.loads(run.stdout);assert report['passed']
(ROOT/'Evidence/controller-navigation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
