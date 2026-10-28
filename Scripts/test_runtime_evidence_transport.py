#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify transported gate25 evidence with originals denied and private negatives.

No Wine/GPU execution, activation, report rewriting, or public log upload occurs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
import runtime_evidence_transport as transport
ROOT = transport.ROOT


def inspect(prefix, index=None, sandbox=None):
    command = [sys.executable, '-B', str(ROOT / 'Scripts/runtime_dependency_inventory.py'), '--root', str(prefix), '--gate']
    if index is not None:
        command += ['--evidence-index', str(index)]
    if sandbox is not None:
        command = ['/usr/bin/sandbox-exec', '-f', str(sandbox), *command]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    try:
        report = json.loads(result.stdout)
    except ValueError:
        raise AssertionError('Verifier did not return a gate report: ' + result.stderr[-1000:]) from None
    return result.returncode, report


def write_report(path, report):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.pending')
    transport.write_private(temporary, transport.encoded(report))
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packet', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'Evidence/runtime-evidence-transport-tests.json')
    args = parser.parse_args()
    packet = args.packet.resolve(strict=True) if args.packet else transport.create_packet('Private evidence transport ' + uuid.uuid4().hex)
    if packet.parent != transport.PACKETS.resolve() or not (packet / transport.MARKER).is_file():
        raise ValueError('Only explicitly marked owned local diagnostic packets are accepted')
    metadata = transport.read_json(packet / 'packet-manifest.json')
    assert metadata['diagnosticOnly'] is True and metadata['binaryDistributionApproved'] is False and metadata['publicArchiveApproved'] is False
    source = Path(metadata['sourceRoot'])
    prefix = packet / 'dependency-root'
    _, original_manifest, original_receipt, receipt = transport.source_documents(source)
    _, copied_manifest, copied_receipt, copied_receipt_data = transport.source_documents(prefix)
    assert original_manifest.read_bytes() == copied_manifest.read_bytes()
    assert original_receipt.read_bytes() == copied_receipt.read_bytes()
    source_tree = transport.tree_hashes(source)
    prefix_tree = transport.tree_hashes(prefix)
    assert source_tree == prefix_tree
    index = packet / 'evidence-index.json'
    index_bytes = index.read_bytes()
    expected = transport.receipt_evidence(receipt)
    reference_hashes = {ref: transport.digest(Path(ref) if Path(ref).is_absolute() else ROOT / ref) for ref in expected}
    assert reference_hashes == expected and len(expected) == 32
    fixtures = transport.PACKETS / ('.negative-fixtures-' + uuid.uuid4().hex)
    fixtures.mkdir(mode=0o700)
    transport.write_private(fixtures / '.ready-private-evidence-transport-tests', b'Owned COW evidence/index fixtures only\n')
    profile = fixtures / 'deny-originals.sb'
    denied = [ROOT / 'Evidence', ROOT / 'Runtime/Sets', ROOT / 'Runtime/Providers', ROOT / 'Runtime/SourceDependencies']
    profile.write_text('(version 1)\n(allow default)\n(deny file-read*\n' + ''.join(' (subpath ' + json.dumps(str(path)) + ')\n' for path in denied) + ')\n')
    first = next(iter(expected))
    result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile), '/bin/cat', first], capture_output=True, timeout=15)
    assert result.returncode != 0 and b'Operation not permitted' in result.stderr
    report = {'passed': False, 'diagnosticOnly': True, 'binaryDistributionApproved': False, 'publicArchiveApproved': False,
              'scope': 'existing25 dependency shared libraries/modules gate only; no whole runtime/application approval',
              'packet': str(packet), 'fixtureRoot': str(fixtures), 'originalEvidenceDeniedOnlyToVerifier': True,
              'tests': {}, 'evidenceFiles': len(expected), 'originManifestSHA256': transport.digest(copied_manifest),
              'originReceiptSHA256': transport.digest(copied_receipt)}
    try:
        code, baseline = inspect(source)
        assert code == 0 and baseline['binaryRedistributionReady'] is True and baseline['summary']['approvedPayloadLibrariesAndModules'] == 25
        report['tests']['legacyOwnedEvidenceResolutionStillPasses25'] = True
        code, gate = inspect(prefix, index=index, sandbox=profile)
        assert code == 0 and gate['binaryRedistributionReady'] is True and gate['summary']['approvedPayloadLibrariesAndModules'] == 25
        assert gate['evidenceResolution'] == 'transport-index'
        assert gate['payloadFingerprint'] == baseline['payloadFingerprint']
        report['tests']['transportedRootAnd32EvidencePassWithOriginalsDenied'] = True
        report['transportedGateSummary'] = gate['summary']
        report['payloadFingerprint'] = gate['payloadFingerprint']
        code, absent_index = inspect(prefix, sandbox=profile)
        assert code == 3 and absent_index['binaryRedistributionReady'] is False
        report['tests']['sameRootCannotPassWithoutIndexWhenOriginalLogsDenied'] = True
        template = transport.read_json(index)
        log_ref = next(ref for ref in template['references'] if Path(ref).suffix == '.log')
        outside = fixtures / 'outside.log'
        transport.write_private(outside, (packet / template['references'][log_ref]['path']).read_bytes())
        def negative(name, mutate, reason):
            fixture = fixtures / name
            fixture.mkdir(mode=0o700)
            subprocess.run(['/bin/cp', '-cR', str(packet / 'evidence'), str(fixture / 'evidence')], check=True)
            changed = json.loads(json.dumps(template))
            mutate(fixture, changed)
            local_index = fixture / 'evidence-index.json'
            transport.write_private(local_index, transport.encoded(changed))
            code, failure = inspect(prefix, index=local_index, sandbox=profile)
            assert code == 3 and failure['binaryRedistributionReady'] is False, name
            assert any(reason in item for item in failure['gateReasons']), (name, failure['gateReasons'])
            report['tests'][name] = True
            print(name + ': rejected as required', flush=True)
        def missing_file(fixture, value):
            (fixture / value['references'][log_ref]['path']).unlink()
        def changed_file(fixture, value):
            with (fixture / value['references'][log_ref]['path']).open('ab') as stream:
                stream.write(b'\nOwned negative-fixture mutation\n')
        def stale_receipt(fixture, value):
            value['originReceiptSHA256'] = '0' * 64
        def stale_manifest(fixture, value):
            value['originManifestSHA256'] = '0' * 64
        def unknown_reference(fixture, value):
            value['references']['/unknown/not-in-original-receipt.log'] = dict(value['references'][log_ref])
        def missing_reference(fixture, value):
            del value['references'][log_ref]
        def traversal(fixture, value):
            value['references'][log_ref]['path'] = '../outside.log'
        def symlink_escape(fixture, value):
            target = fixture / value['references'][log_ref]['path']
            target.unlink(); target.symlink_to(outside)
        for name, mutate, reason in [
            ('missingTransportedFileCannotFallBack', missing_file, 'runtime_evidence_transport_invalid:'),
            ('changedTransportedLogRejected', changed_file, 'transport_evidence_bytes_changed'),
            ('staleReceiptBindingRejected', stale_receipt, 'transport_receipt_binding_mismatch'),
            ('staleManifestBindingRejected', stale_manifest, 'transport_manifest_binding_mismatch'),
            ('unknownOriginalReferenceRejected', unknown_reference, 'transport_unknown_reference'),
            ('missingIndexReferenceCannotFallBack', missing_reference, 'transport_missing_reference'),
            ('parentTraversalRejectedDespiteMatchingOutsideBytes', traversal, 'transport_unsafe_relative_path'),
            ('symlinkEscapeRejectedDespiteMatchingOutsideBytes', symlink_escape, 'transport_path_escape_or_nonfile'),
        ]:
            negative(name, mutate, reason)
        assert source_tree == transport.tree_hashes(source) and prefix_tree == transport.tree_hashes(prefix)
        assert index.read_bytes() == index_bytes
        assert len(transport.resolve_evidence_index(index, copied_receipt_data, transport.digest(copied_receipt), transport.digest(copied_manifest))) == 32
        assert original_manifest.read_bytes() == copied_manifest.read_bytes() and original_receipt.read_bytes() == copied_receipt.read_bytes()
        assert {ref: transport.digest(Path(ref) if Path(ref).is_absolute() else ROOT / ref) for ref in expected} == reference_hashes
        report['originalAndPacketPayloadReceiptEvidenceUnchanged'] = True
        report['passed'] = all(report['tests'].values())
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        write_report(args.output, report)
        print(json.dumps({'passed': report['passed'], 'checks': len(report['tests']), 'evidenceFiles': len(expected),
                          'diagnosticOnly': True, 'binaryDistributionApproved': False, 'report': str(args.output)}, indent=2), flush=True)


if __name__ == '__main__':
    main()
