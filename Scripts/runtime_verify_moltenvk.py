#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read-only source MoltenVK integrity/closure/runtime-receipt verification."""
import argparse,hashlib,json,os,pathlib,sys
sys.dont_write_bytecode=True
from runtime_dependency_inventory import binary_headers


def sha(path):
    with path.open('rb')as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def inventory(root):
    result={}
    for path in sorted(root.rglob('*')):
        relative=str(path.relative_to(root))
        if relative=='moltenvk-source-manifest.json':continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(root):raise ValueError('Escaping source renderer alias')
            result[relative]={'link':os.readlink(path)}
        elif path.is_file():result[relative]={'sha256':sha(path),'mode':path.stat().st_mode&0o7777}
    return result

def verify(root,validation=None):
    root=pathlib.Path(root).resolve(strict=True);manifest=json.load(open(root/'moltenvk-source-manifest.json'));files=inventory(root)
    if files!=manifest['files']or hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest()!=manifest['fingerprint']:raise ValueError('Source MoltenVK file/fingerprint mismatch')
    code=binary_headers(root/'lib/libMoltenVK.dylib')
    if code!=manifest['binary']or code['architectures']!=['arm64','x86_64']:raise ValueError('Universal renderer header mismatch')
    for part in code['slices']:
        if part['rpaths']or part['buildVersion']['minimumOS']!='27.0.0':raise ValueError('Unexpected source renderer deployment/path metadata')
        if any(not d['name'].startswith(('/System/','/usr/lib/'))for d in part['dependencies']):raise ValueError('Non-system dynamic renderer dependency')
    receipt=root/'share/ready/receipts';lock=json.load(open(receipt/'runtime_build_moltenvk.lock.json'))
    if sha(receipt/'runtime_build_moltenvk.lock.json')!=manifest['sourceLockSHA256']:raise ValueError('Source lock changed')
    for key,node in lock['sourceNodes'].items():
        if sha(root/'share/ready/sources'/(key+'.tar.gz'))!=node['archiveSHA256']:raise ValueError('Retained upstream source archive changed')
    if sha(root/'share/ready/sources/CPM_0.40.8.cmake')!=lock['CPM']['bootstrapSHA256']or sha(root/'share/ready/sources/cpm-source-0.40.8.tar.gz')!=lock['CPM']['sourceArchiveSHA256']:raise ValueError('Pinned build bootstrap/source changed')
    maps=json.load(open(receipt/'static-object-maps.json'))
    for arch,item in maps.items():
        if sha(receipt/(arch+'-link-map.txt'))!=item['mapSHA256']or item['HomebrewStaticObjects']or any('/opt/homebrew/'in p for p in item['objects']):raise ValueError('Static link-map closure failed')
    proof_verified=False
    if validation:
        proof_path=pathlib.Path(validation);proof=json.load(open(proof_path))
        if proof['candidateManifestSHA256']!=sha(root/'moltenvk-source-manifest.json')or proof['candidateFingerprint']!=manifest['fingerprint']:raise ValueError('Runtime proof belongs to different renderer bytes')
        if not proof['allPassed']or not proof['candidateUnchanged']or not proof['defaultConfigurationsUnchanged']or not proof['exactPrefixStoppedAndRemoved']or proof['advertisedFeaturesModified']:raise ValueError('Source renderer runtime proof incomplete')
        required={'native-buffer','native-shader-present','native-properties-base','native-properties-core','native-properties-full','wine-vulkan-buffer','wine-vulkan-present'}
        if set(proof['tests'])!=required:raise ValueError('Real native/Wine matrix is incomplete')
        for name,test in proof['tests'].items():
            if not test['passed']or test['unexpectedImages']or sha(pathlib.Path(test['log']))!=test['logSHA256']:raise ValueError('Runtime observation/log changed')
            images=pathlib.Path(test['log']).with_suffix('.images.jsonl')
            if sha(images)!=test['imagesSHA256']:raise ValueError('Native image-audit evidence changed')
            if not any('ready-source-moltenvk-'in p and p.endswith('/lib/libMoltenVK.dylib')for p in test['loadedImages']):raise ValueError('Candidate implementation was not observed loaded')
        proof_verified=True
    return {'verified':True,'fingerprint':manifest['fingerprint'],'filesVerified':len(files),'architectures':code['architectures'],'runtimeValidationVerified':proof_verified,'binaryRedistributionReady':False,'activationPerformed':False,'scope':'source MoltenVK component only'}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('root',type=pathlib.Path);parser.add_argument('--validation',type=pathlib.Path);args=parser.parse_args();print(json.dumps(verify(args.root,args.validation),indent=2))
