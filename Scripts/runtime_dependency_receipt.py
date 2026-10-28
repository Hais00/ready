#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Bind completed Wine/API/GPU evidence to exact source-built dependency bytes."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prefix',required=True,type=Path);p.add_argument('--output',type=Path,default=ROOT/'Evidence/runtime-source-dependency-validation.json');a=p.parse_args();prefix=a.prefix.resolve();manifest_path=prefix/'manifest.json';manifest=json.loads(manifest_path.read_text());manifest_sha=digest(manifest_path);expected={v['path']:v['sha256'] for v in manifest['binaryFiles']}
    if not manifest.get('sourceEvidenceComplete') or manifest.get('legacySupportIncluded') or manifest.get('oldCommunityInputsUsed'):raise RuntimeError('Complete independent source provenance required')
    for name,sha in {**expected,**manifest['provenanceFiles']}.items():
        path=(prefix/name).resolve()
        if not path.is_relative_to(prefix) or not path.is_file() or digest(path)!=sha:raise RuntimeError('Source/provenance or binary file changed: '+name)
    evidence=[];tests={};scope={}
    def load(relative):
        path=ROOT/relative;j=json.loads(path.read_text());evidence.append({'path':str(path),'sha256':digest(path)})
        if j.get('testedBinaryHashes')!=expected or not j.get('candidateInputsUnchanged'):raise RuntimeError('Test does not cover the unchanged candidate bytes: '+relative)
        fingerprint=j.get('binaryFingerprint',j.get('dependencyBinaryFingerprint'))
        if fingerprint!=manifest['binaryFingerprint']:raise RuntimeError('Evidence names another dependency set: '+relative)
        if j.get('dependencyManifestSHA256',manifest_sha)!=manifest_sha:raise RuntimeError('Evidence manifest mismatch: '+relative)
        return j
    for host in ['wine1120','winecx1119']:
        for bits,tag in [(64,'source-'+host),(32,'source-'+host+'-pe32')]:
            record=load('Evidence/runtime-dependencies-'+tag+'.json')
            required=['tls','untrusted','gdi','dwrite']
            passed=record.get('allPassed') is True and all(record['tests'].get(name,{}).get('passed') is True and not record['tests'][name].get('unexpectedNonSystemDylibs') for name in required)
            if not passed:raise RuntimeError('Platform evidence incomplete: '+tag)
            key='platform.'+host+'.pe'+str(bits);tests[key]=True;scope[key]=required
            for test in record['tests'].values():
                path=Path(test['log']);evidence.append({'path':str(path),'sha256':digest(path)})
    gpu=load('Evidence/runtime-dependencies-gpu.json')
    groups={64:['dx9','vulkanKosmic','vulkanMolten','dxmt-buffer-64','dxmt-shader-64','dxmt-present-64'],32:['dxmt-buffer-32','dxmt-present-32']}
    for bits,names in groups.items():
        if not gpu.get('allOpenGPUPathsPassed') or not all(gpu['tests'].get(name,{}).get('passed') for name in names):raise RuntimeError('Existing GPU paths regressed')
        key='gpu.wine1120.pe'+str(bits);tests[key]=True;scope[key]=names
    optional={name:value['passed'] for name,value in gpu['tests'].items() if name.startswith('apple-')}
    for value in gpu['tests'].values():
        path=Path(value['log']);evidence.append({'path':str(path),'sha256':digest(path)})
    module=ROOT/'Evidence/runtime-dwrite-source-rebuild.json';evidence.append({'path':str(module),'sha256':digest(module)})
    result={'schema':1,'dependencySetID':manifest['dependencySetID'],'dependencyManifestSHA256':manifest_sha,'binaryFingerprint':manifest['binaryFingerprint'],'passed':True,'candidateInputsUnchanged':True,'tests':tests,'testScopes':scope,'optionalLocalAppleEvaluationTests':optional,'testedBinaryHashes':expected,'evidenceFiles':evidence,'signatureOrCertificationClaimed':False,'consumerAppleEnabled':False,'wineModuleAdjustment':json.loads(module.read_text())}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'passed':True,'tests':tests,'binaryFilesBound':len(expected),'provenanceFilesVerified':len(manifest['provenanceFiles']),'output':str(a.output)},indent=2))

if __name__=='__main__':main()
