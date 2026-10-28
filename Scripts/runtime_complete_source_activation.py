#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Continue an already-running candidate E2E, then Core proof and gated activation.

Never restarts an observed E2E. An actual failed proof stops this workflow.
"""
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    lock=(ROOT/'Runtime/.source-activation-pipeline.lock').open('a+b');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    candidate=ROOT/'Runtime/candidate-runtime.json';evaluation=ROOT/'Runtime/candidate-evaluation-runtime.json';normal_sha=digest(candidate);eval_sha=digest(evaluation);expected=json.loads(candidate.read_text())['runtimeID'];progress=ROOT/'Evidence/runtime-source-activation-pipeline.json'
    state={'runtimeID':expected,'stage':'waiting-existing-e2e','e2eRestarted':False,'defaultActivationAuthorizedAfterProof':True}
    def save(stage):state['stage']=stage;progress.write_text(json.dumps(state,indent=2)+'\n');print(stage,flush=True)
    try:
        save('waiting-existing-e2e');deadline=time.monotonic()+1200
        while True:
            if digest(candidate)!=normal_sha or digest(evaluation)!=eval_sha:raise RuntimeError('Candidate changed during the pipeline')
            try:proof=json.loads((ROOT/'Evidence/runtime-source-candidate-e2e.json').read_text())
            except (FileNotFoundError,json.JSONDecodeError):proof={}
            if proof.get('runtimeID')==expected:
                if proof.get('error'):raise RuntimeError('Existing candidate E2E failed: '+proof['error'])
                if proof.get('passed') is True:break
            if time.monotonic()>deadline:raise RuntimeError('Observation deadline expired; E2E was not restarted')
            time.sleep(3)
        save('running-real-core-provider-switch')
        subprocess.run(['python3',str(ROOT/'Scripts/runtime_candidate_core.py')],cwd=ROOT,check=True,timeout=400)
        save('activating-proved-project-pointers')
        subprocess.run(['python3',str(ROOT/'Scripts/runtime_activate_source_stack.py')],cwd=ROOT,check=True,timeout=120)
        save('complete')
    except Exception as error:state['error']=str(error);save('stopped-on-failure');raise
    finally:lock.close()

if __name__=='__main__':main()
