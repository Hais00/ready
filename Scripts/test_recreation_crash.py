#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile matching Core and prove save bindings survive a real recreation crash."""
import json
from pathlib import Path
import subprocess
from swift_probe_support import prepare_core

ROOT = Path(__file__).resolve().parents[1]


def main():
    _, modules, archive = prepare_core()
    executable = ROOT / 'Build/ReadyPrefixRecreationProbe'
    executable.parent.mkdir(exist_ok=True)
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
        '-I', str(modules), str(ROOT / 'Synthetic/ReadyPrefixRecreationProbe.swift'),
        str(archive), '-o', str(executable),
    ], cwd=ROOT, check=True)
    report_path = ROOT / 'Evidence/recreation-crash.json'
    report_path.parent.mkdir(exist_ok=True)
    result = subprocess.run([str(executable), '--output', str(report_path)],
                            cwd=ROOT, capture_output=True, text=True, timeout=60)
    (ROOT / 'Evidence/recreation-crash.log').write_text(result.stdout + '\n' + result.stderr)
    if result.returncode:
        raise RuntimeError('Recreation crash probe failed; inspect Evidence/recreation-crash.log')
    report = json.loads(result.stdout)
    assert report['passed'] and report['realSIGKILLCount'] == 1
    assert report['fixtureCleanedAfterVerification']
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
