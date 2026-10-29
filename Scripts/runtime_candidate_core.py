#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run the real SessionManager round trip on candidate project config copies."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

from swift_probe_support import prepare_core
from test_provider_switch import cleanup
ROOT=Path(__file__).resolve().parents[1]

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    subprocess.run(['swift','build','--product','M1Launcher','--jobs','2'],cwd=ROOT,check=True,capture_output=True)
    subprocess.run(['sh',str(ROOT/'Scripts/build_session_host.sh')],cwd=ROOT,check=True,capture_output=True)
    _,modules,archive=prepare_core();exe=ROOT/'Build/ReadyProviderSwitchProbe'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',str(modules),str(ROOT/'Sources/M1Launcher/SessionScratchDirectory.swift'),str(ROOT/'Sources/M1Launcher/SessionManager.swift'),str(ROOT/'Synthetic/ReadyProviderSwitchProbe.swift'),str(archive),'-framework','AppKit','-o',str(exe)],cwd=ROOT,check=True,capture_output=True)
    scratch=ROOT/'Runtime/TestPrefixes'/('source-core-switch-'+uuid.uuid4().hex);scratch.mkdir();(scratch/'.ready-provider-switch').write_text('Disposable synthetic provider-switch fixture\n');project=scratch/'project';(project/'Runtime').mkdir(parents=True);(project/'Build').symlink_to(ROOT/'Build',target_is_directory=True);(project/'Runtime/Probes').symlink_to(ROOT/'Runtime/Probes',target_is_directory=True)
    normal=ROOT/'Runtime/candidate-runtime.json';evaluation=ROOT/'Runtime/candidate-evaluation-runtime.json';(project/'Runtime/runtime.json').write_bytes(normal.read_bytes());(project/'Runtime/evaluation-runtime.json').write_bytes(evaluation.read_bytes());passed=False
    try:
        env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))}
        run=subprocess.run([str(exe),str(project),str(scratch)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=320)
        (ROOT/'Evidence/runtime-source-core-switch.log').write_text(run.stdout+'\n'+run.stderr)
        result={'returncode':run.returncode,'candidateConfigSHA256':digest(normal),'candidateEvaluationConfigSHA256':digest(evaluation),'realProjectUserConfigModified':False,'evaluationEnabledOnlyInSyntheticRoot':True}
        if run.returncode==0:result.update(json.loads(run.stdout));passed=result.get('passed') is True
        (ROOT/'Evidence/runtime-source-core-switch.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
        if not passed:raise RuntimeError('Real candidate Core provider switch failed; inspect private log')
    finally:cleanup(scratch,remove=passed)

if __name__=='__main__':main()
