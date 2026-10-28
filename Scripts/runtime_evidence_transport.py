#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Transport immutable dependency-gate evidence in a PRIVATE local diagnostic packet.

The index changes only evidence location, never source/receipt/report bytes or the
existing 25 shared-library/module gate scope. No upload or activation is performed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
PACKETS = ROOT / 'Runtime/DiagnosticEvidencePackets'
KIND = 'ready-dependency-evidence-transport-v1'
MARKER = '.ready-private-evidence-packet'


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError('transport_duplicate_json_key')
        result[name] = value
    return result


def read_json(path, limit=4 * 1024 * 1024):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError('transport_nonregular_or_oversized_json')
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('transport_oversized_json')
    return json.loads(data, object_pairs_hook=_unique_object)


def confined(root, relative):
    if not isinstance(relative, str) or not relative or relative.startswith('/') or '\\' in relative or '\0' in relative:
        raise ValueError('transport_unsafe_relative_path')
    if any(part in ('', '.', '..') for part in relative.split('/')):
        raise ValueError('transport_unsafe_relative_path')
    path = (root / relative).resolve(strict=True)
    if not path.is_relative_to(root.resolve(strict=True)) or not path.is_file():
        raise ValueError('transport_path_escape_or_nonfile')
    return path


def receipt_evidence(receipt):
    evidence = receipt.get('evidenceFiles')
    if not isinstance(evidence, list) or not evidence:
        raise ValueError('transport_missing_receipt_evidence')
    result = {}
    for item in evidence:
        if not isinstance(item, dict) or set(item) != {'path', 'sha256'}:
            raise ValueError('transport_malformed_receipt_reference')
        reference, expected = item['path'], item['sha256']
        if not isinstance(reference, str) or not reference or not isinstance(expected, str) or len(expected) != 64 or any(x not in '0123456789abcdef' for x in expected):
            raise ValueError('transport_malformed_receipt_reference')
        if reference in result:
            raise ValueError('transport_duplicate_receipt_reference')
        result[reference] = expected
    return result


def resolve_evidence_index(index_file, receipt, receipt_sha256, manifest_sha256):
    """Resolve the COMPLETE original reference set; never falls back to source logs."""
    index_file = Path(index_file)
    index = read_json(index_file, limit=1024 * 1024)
    if not isinstance(index, dict) or index.get('schema') != 1 or index.get('kind') != KIND:
        raise ValueError('transport_unsupported_index')
    if index.get('originManifestSHA256') != manifest_sha256:
        raise ValueError('transport_manifest_binding_mismatch')
    if index.get('originReceiptSHA256') != receipt_sha256:
        raise ValueError('transport_receipt_binding_mismatch')
    expected = receipt_evidence(receipt)
    entries = index.get('references')
    if not isinstance(entries, dict):
        raise ValueError('transport_references_not_object')
    if set(entries) - set(expected):
        raise ValueError('transport_unknown_reference')
    if set(expected) - set(entries):
        raise ValueError('transport_missing_reference')
    root = index_file.parent.resolve(strict=True)
    resolved, used_paths = {}, set()
    for reference, expected_hash in expected.items():
        item = entries[reference]
        if not isinstance(item, dict) or set(item) != {'path', 'sha256'} or item.get('sha256') != expected_hash:
            raise ValueError('transport_evidence_hash_binding_mismatch')
        path = confined(root, item['path'])
        if path in used_paths:
            raise ValueError('transport_reference_alias')
        used_paths.add(path)
        # The original receipt, not a transported filename, determines raw JSON
        # validation. Preserve its suffix too to avoid accidental type changes.
        if path.suffix != Path(reference).suffix:
            raise ValueError('transport_evidence_type_mismatch')
        if digest(path) != expected_hash:
            raise ValueError('transport_evidence_bytes_changed')
        resolved[reference] = path
    return resolved


def write_private(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()


def tree_hashes(root):
    result = {}
    for path in sorted(root.rglob('*')):
        name = str(path.relative_to(root))
        if path.is_symlink():
            result[name] = {'symlink': os.readlink(path)}
        elif path.is_file():
            result[name] = {'sha256': digest(path)}
    return result


def source_documents(prefix):
    selection = read_json(prefix / 'selected-runtime-files.json')
    if selection.get('schema') != 1 or len(selection.get('selectedBinaryHashes', {})) != 25:
        raise ValueError('Transport recipe requires the selected25 dependency subset')
    manifest_path = confined(prefix, selection['originManifestPath'])
    receipt_path = confined(prefix, selection['originReceiptPath'])
    if digest(manifest_path) != selection['originManifestSHA256'] or digest(receipt_path) != selection['originReceiptSHA256']:
        raise ValueError('Original manifest/receipt binding changed')
    return selection, manifest_path, receipt_path, read_json(receipt_path)


def create_packet(name, source_root=None):
    if not name or Path(name).name != name or name in ('.', '..'):
        raise ValueError('A new diagnostic packet name is required')
    if source_root is None:
        source_root = Path(read_json(ROOT / 'Runtime/runtime.json')['sourceDependencyPrefix'])
    source_root = Path(source_root).resolve(strict=True)
    selection, manifest_path, receipt_path, receipt = source_documents(source_root)
    expected = receipt_evidence(receipt)
    if len(expected) != 32:
        raise ValueError('This local transport recipe expects the audited32 evidence references')
    original_tree = tree_hashes(source_root)
    if PACKETS.is_symlink():
        raise ValueError('Diagnostic packet parent cannot be a symlink')
    PACKETS.mkdir(parents=True, exist_ok=True, mode=0o700)
    if PACKETS.stat().st_uid != os.getuid():
        raise ValueError('Diagnostic packet parent must be owned')
    packet = PACKETS / name
    if packet.exists() or packet.is_symlink():
        raise ValueError('Diagnostic packet destination must be new')
    packet.mkdir(mode=0o700)
    write_private(packet / MARKER, b'PRIVATE local dependency evidence packet; no public archive or activation\n')
    subprocess.run(['/bin/cp', '-cR', str(source_root), str(packet / 'dependency-root')], check=True)
    references = {}
    owned_logs = (ROOT / 'Evidence').resolve(strict=True)
    for reference, expected_hash in expected.items():
        raw = Path(reference)
        source = (raw if raw.is_absolute() else ROOT / raw).resolve(strict=True)
        if not source.is_relative_to(owned_logs) or not source.is_file() or digest(source) != expected_hash:
            raise ValueError('Original evidence is unavailable, outside owned logs, or changed')
        name = hashlib.sha256(reference.encode()).hexdigest()[:16] + '-' + source.name
        relative = 'evidence/' + name
        target = packet / relative
        target.parent.mkdir(exist_ok=True, mode=0o700)
        subprocess.run(['/bin/cp', '-c', str(source), str(target)], check=True)
        target.chmod(0o600)
        if digest(target) != expected_hash:
            raise ValueError('Evidence copy changed')
        references[reference] = {'path': relative, 'sha256': expected_hash}
    index = {'schema': 1, 'kind': KIND, 'originManifestSHA256': digest(manifest_path),
             'originReceiptSHA256': digest(receipt_path), 'references': references}
    index_path = packet / 'evidence-index.json'
    write_private(index_path, encoded(index))
    copied_selection, copied_manifest, copied_receipt, copied_receipt_data = source_documents(packet / 'dependency-root')
    resolve_evidence_index(index_path, copied_receipt_data, digest(copied_receipt), digest(copied_manifest))
    if tree_hashes(packet / 'dependency-root') != original_tree or tree_hashes(source_root) != original_tree:
        raise ValueError('Dependency payload or original provenance changed during transport')
    metadata = {'schema': 1, 'diagnosticOnly': True, 'binaryDistributionApproved': False,
                'publicArchiveApproved': False, 'activationPerformed': False,
                'scope': 'existing25 dependency shared libraries/modules and unchanged original evidence only',
                'evidenceFiles': len(references), 'sourceRoot': str(source_root),
                'sourceTreeFingerprint': hashlib.sha256(encoded(original_tree)).hexdigest(),
                'originManifestSHA256': digest(copied_manifest), 'originReceiptSHA256': digest(copied_receipt),
                'selectionSHA256': digest(packet / 'dependency-root/selected-runtime-files.json'),
                'evidenceIndexSHA256': digest(index_path),
                'note': 'Historical logs may mention optional Apple evaluation; no Apple payload is transported and gate scope is unchanged'}
    write_private(packet / 'packet-manifest.json', encoded(metadata))
    return packet


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', default='Private evidence packet with spaces ' + uuid.uuid4().hex)
    parser.add_argument('--root', type=Path)
    args = parser.parse_args()
    packet = create_packet(args.name, args.root)
    print(json.dumps({'packet': str(packet), 'evidenceFiles': 32, 'diagnosticOnly': True, 'binaryDistributionApproved': False}))
