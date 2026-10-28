#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Activate only a hash-verified, wrapper-tested source dependency generation.

Touches two project config pointers only. All old runtime/provider trees and all
per-user configuration/prefixes remain unchanged. Before-images permit rollback.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]

def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def atomic(path,data):
    pending=path.with_name(path.name+'.'+uuid.uuid4().hex+'.pending')
    with pending.open('xb') as stream:os.chmod(pending,0o600);stream.write(data);stream.flush();os.fsync(stream.fileno())
    os.replace(pending,path)

def main():
    runtime=ROOT/'Runtime';candidate=runtime/'candidate-runtime.json';evaluation=runtime/'candidate-evaluation-runtime.json';proof_path=ROOT/'Evidence/runtime-source-candidate-e2e.json';proof=json.loads(proof_path.read_text())
    if not proof.get('passed') or not proof.get('candidateAndLiveConfigsUnchanged') or not proof.get('selectedDependencyBytesUnchanged'):raise RuntimeError('Actual candidate wrapper E2E proof is required')
    if sha(candidate)!=proof['candidateConfigSHA256'] or sha(evaluation)!=proof['candidateEvaluationConfigSHA256']:raise RuntimeError('Candidate configuration differs from the tested bytes')
    core_path=ROOT/'Evidence/runtime-source-core-switch.json';core=json.loads(core_path.read_text())
    if core.get('passed') is not True or core['candidateConfigSHA256']!=sha(candidate) or core['candidateEvaluationConfigSHA256']!=sha(evaluation):raise RuntimeError('Real candidate SessionManager proof is required')
    normal=json.loads(candidate.read_text());eval_data=json.loads(evaluation.read_text());prefix=Path(normal['sourceDependencyPrefix']);selection=json.loads((prefix/'selected-runtime-files.json').read_text())
    if len(selection['selectedBinaryHashes'])!=25 or normal.get('sourceDependencySelectedScope')!='25shared-libraries/modules':raise RuntimeError('Only reviewed shared dependency scope is authorized')
    if eval_data.get('evaluationModeEnabled') is not False or eval_data['appleOptional'].get('enabledForConsumerPlay') is not False or eval_data['appleOptional'].get('enabled') is not False:raise RuntimeError('Apple evaluation must stay disabled for consumers')
    gate=ROOT/'Evidence/runtime-source-activation-dependency-gate.json';subprocess.run(['python3',str(ROOT/'Scripts/runtime_dependency_inventory.py'),'--root',str(prefix),'--output',str(gate),'--gate'],check=True)
    backup=runtime/'ActivationBackups'/('source-'+uuid.uuid4().hex);backup.mkdir(parents=True,mode=0o700)
    pairs=[(runtime/'runtime.json',candidate),(runtime/'evaluation-runtime.json',evaluation)];records=[]
    for live,source in pairs:
        if live.is_symlink():raise RuntimeError('Project runtime pointer must be a regular owned file')
        image=backup/live.name;atomic(image,live.read_bytes());records.append({'path':str(live),'beforeImage':str(image),'beforeSHA256':sha(live),'afterSHA256':sha(source)})
    result={'schema':1,'oldRuntimeID':json.loads((backup/'runtime.json').read_text()).get('runtimeID'),'newRuntimeID':normal['runtimeID'],'newEvaluationRuntimeID':eval_data['runtimeID'],'configurations':records,'wrapperE2EProofSHA256':sha(proof_path),'coreProviderSwitchProofSHA256':sha(core_path),'configurationResolutionSource':'Sources/M1Launcher/SessionManager.swift: per-user override first, project Runtime/runtime.json fallback','configurationResolutionSourceSHA256':sha(ROOT/'Sources/M1Launcher/SessionManager.swift'),'dependencyGateSHA256':sha(gate),'approvedDistributionScope':'25 dependency shared libraries/modules only','wholeApplicationBinaryDistributionApproved':False,'consumerAppleEnabled':False,'oldRuntimeTreesModified':False,'userConfigurationsOrPrefixesModified':False,'state':'prepared'}
    output=ROOT/'Evidence/runtime-source-activation.json';atomic(output,json.dumps(result,indent=2).encode()+b'\n')
    try:
        for live,source in pairs:atomic(live,source.read_bytes())
        if any(sha(Path(item['path']))!=item['afterSHA256'] for item in records):raise RuntimeError('Atomic pointer verification failed')
        result['state']='committed';atomic(output,json.dumps(result,indent=2).encode()+b'\n')
    except Exception as error:
        for item in records:atomic(Path(item['path']),Path(item['beforeImage']).read_bytes())
        result.update(state='rolled-back',error=str(error));atomic(output,json.dumps(result,indent=2).encode()+b'\n');raise
    print(json.dumps({'state':result['state'],'newRuntimeID':result['newRuntimeID'],'beforeImages':str(backup),'consumerAppleEnabled':False,'userConfigurationChanged':False},indent=2))

if __name__=='__main__':main()
