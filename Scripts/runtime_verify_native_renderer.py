#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read-only integrity/closure verifier; needs neither old build trees nor loading code."""
import argparse
import hashlib
import json
from pathlib import Path
import os
from runtime_dependency_inventory import binary_headers


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inside(root, relative):
    if not isinstance(relative, str) or relative.startswith('/') or '\\' in relative or '\0' in relative or any(x in ('', '.', '..') for x in relative.split('/')):
        raise ValueError('Unsafe native renderer path')
    path = root / relative
    if not path.resolve(strict=True).is_relative_to(root):
        raise ValueError('Native renderer path escapes provider')
    return path


def version(value):
    parts = tuple(int(x) for x in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def verify(candidate, validation=None):
    root = Path(candidate).resolve(strict=True)
    manifest_path = root / 'native-renderer-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    expected = manifest['files']
    if manifest.get('schema') != 1 or manifest.get('binaryRedistributionReady') is not False:
        raise ValueError('Unsupported native renderer manifest or expanded release claim')
    actual = {}
    for path in sorted(root.rglob('*')):
        if path == manifest_path:
            continue
        name = str(path.relative_to(root))
        inside(root, name)
        if path.is_symlink():
            link = os.readlink(path)
            if os.path.isabs(link):
                raise ValueError('Absolute provider alias')
            actual[name] = {'symlink': link}
        elif path.is_file():
            actual[name] = {'sha256': sha(path)}
    if actual != expected:
        raise ValueError('Native renderer file membership/hash differs')
    fingerprint = hashlib.sha256(json.dumps(actual, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if manifest['fingerprint'] != fingerprint or manifest['identity'] != 'ready-native-renderer-' + fingerprint[:20]:
        raise ValueError('Native renderer identity differs')
    binaries = manifest['nativeBinaries']
    discovered = {name for name, record in actual.items() if 'sha256' in record and binary_headers(root / name).get('format') == 'Mach-O'}
    if set(binaries) != discovered or len(binaries) != 4:
        raise ValueError('Native code inventory differs from the four-library closure')
    minimum = (0, 0, 0)
    for name in sorted(binaries):
        path = inside(root, name)
        header = binary_headers(path)
        if header != binaries[name] or header.get('architectures') != ['arm64']:
            raise ValueError('Native renderer architecture/metadata differs')
        for item in header['slices']:
            minimum = max(minimum, version(item['buildVersion']['minimumOS']))
            if any(not p.startswith(('/System/', '/usr/lib/')) for p in item.get('rpaths', [])):
                raise ValueError('Native renderer has non-system rpaths')
            for dependency in item.get('dependencies', []):
                value = dependency['name']
                if value.startswith(('/System/', '/usr/lib/')):
                    continue
                if not value.startswith('@loader_path/'):
                    raise ValueError('Native renderer has external load command')
                resolved = (path.parent / value.removeprefix('@loader_path/')).resolve(strict=True)
                if not resolved.is_relative_to(root) or str(resolved.relative_to(root)) not in binaries:
                    raise ValueError('Native renderer dependency is outside its code inventory')
    if minimum != version(manifest['minimumMacOS']):
        raise ValueError('Native renderer minimum OS differs')
    icd = json.loads(inside(root, 'icd/kosmic-arm64.json').read_text())['ICD']['library_path']
    target = (root / 'icd' / icd).resolve(strict=True)
    if Path(icd).is_absolute() or '/' not in icd or target != root / 'lib/libvulkan_kosmickrisp.dylib':
        raise ValueError('Native ICD does not use its contained relative library')
    runtime_verified = False
    if validation is not None:
        proof = json.loads(Path(validation).read_text())
        if proof['candidateManifestSHA256'] != sha(manifest_path) or proof['candidateFingerprint'] != fingerprint:
            raise ValueError('Native runtime proof binds a different candidate')
        if not proof['allPassed'] or not proof['candidateUnchanged'] or proof['architecture'] != 'arm64' or proof['advertisedFeaturesModified'] or proof['appleEvaluationUsed']:
            raise ValueError('Native runtime proof is incomplete or bypassed')
        if len(proof['sandboxControls']) != 5 or not all(x['passed'] for x in proof['sandboxControls'].values()):
            raise ValueError('Native runtime proof lacks sandbox controls')
        if len(proof['tests']) < 19 or not all(x['passed'] and not x['unexpectedImages'] for x in proof['tests'].values()):
            raise ValueError('Native GPU/property matrix did not pass')
        for name, item in proof['tests'].items():
            log = Path(item['log'])
            images = log.with_suffix('.images.jsonl')
            if sha(log) != item['logSHA256'] or sha(images) != item['imagesSHA256']:
                raise ValueError('Native runtime log/image bytes differ: ' + name)
            observed = []
            for line in log.read_text().splitlines():
                try:
                    observed.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
            if observed != item['observations']:
                raise ValueError('Native runtime observations differ from raw output: ' + name)
            loaded = sorted({json.loads(line)['path'] for line in images.read_text().splitlines()})
            if loaded != item['loadedImages']:
                raise ValueError('Native runtime images differ from raw audit: ' + name)
        runtime_verified = True
    return {'verified': True, 'fingerprint': fingerprint, 'filesVerified': len(actual), 'nativeLibraries': len(binaries),
            'minimumMacOS': manifest['minimumMacOS'], 'runtimeValidationVerified': runtime_verified,
            'scope': 'source-built four-library native ARM64 renderer only', 'binaryDistributionReady': False, 'activationPerformed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--validation', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.candidate, args.validation), indent=2))
