#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Owned LOCAL runtime installation transactions. No release/archive approval.

Copies immutable raw objects once by inventory hash, delegates derived layout to
runtime_install_layout, and publishes runtime.json LAST. Never activates a user
or project configuration. Fixture/static checks cannot authorize real publish.
"""
import argparse
import contextlib
import fcntl
import hashlib
import importlib
import json
import os
from pathlib import Path
import posixpath
import shutil
import stat
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
WORK = Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
STORE_MARKER = '.ready-local-runtime-store'
STAGE_MARKER = '.ready-runtime-install-stage'
FIXTURE_MARKER = '.ready-runtime-install-fixture'
ACTUAL_CHECKS = {'configResolved', 'windowsWinAPI64', 'windowsWinAPI32', 'controllerAuto', 'controllerOff', 'nativeARM64Readback'}
RESERVE = 512 * 1024 * 1024


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode()


def fingerprint(value):
    # IDs agreed with layout: canonical compact JSON, without a trailing newline.
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def sha(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def owned(path, directory=False):
    info = Path(path).lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('Owned regular path required: ' + str(path))
    return info


def canonical(path):
    path = Path(path)
    if not path.is_absolute() or path.resolve(strict=False) != path.absolute() or path == Path('/'):
        raise ValueError('Canonical absolute path required')
    return path


def relative(value):
    if not isinstance(value, str) or not value or value.startswith('/') or '\\' in value or '\0' in value or any(x in ('', '.', '..') for x in value.split('/')):
        raise ValueError('Unsafe relative installation path')
    return value


def sync(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try: os.fsync(fd)
    finally: os.close(fd)


def atomic(path, data, mode=0o600, temporary_root=None):
    if path.exists() or path.is_symlink(): owned(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = (temporary_root or path.parent) / ('.' + path.name + '.' + uuid.uuid4().hex + '.pending')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path); sync(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def load(path):
    owned(path)
    if path.stat().st_size > 32 * 1024 * 1024: raise ValueError('Installation metadata too large')
    return json.loads(path.read_bytes())


def normalize_files(files):
    if not isinstance(files, dict) or not files: raise ValueError('Nonempty explicit component inventory required')
    result = {}
    for name, item in files.items():
        relative(name)
        if not isinstance(item, dict): raise ValueError('Malformed inventory entry')
        if item.get('kind') == 'file':
            if not sha(item.get('sha256')) or not isinstance(item.get('bytes'), int) or item['bytes'] < 0 or not isinstance(item.get('mode'), int) or item['mode'] & ~0o777:
                raise ValueError('Malformed file inventory')
            result[name] = {k: item[k] for k in ('kind', 'sha256', 'mode', 'bytes')}
        elif item.get('kind') == 'symlink':
            target = item.get('target')
            if not isinstance(target, str) or not target or target.startswith('/') or '\\' in target or '\0' in target:
                raise ValueError('Unsafe component symlink')
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            if resolved == '..' or resolved.startswith('../'): raise ValueError('Component symlink escapes object')
            result[name] = {'kind': 'symlink', 'target': target}
        else: raise ValueError('Unsupported component entry')
    for name in result:
        parts = name.split('/')
        if any('/'.join(parts[:i]) in result for i in range(1, len(parts))):
            raise ValueError('File/symlink is an ancestor of another entry')
    return result


def inventory(root, exclude=()):
    result = {}
    for path in sorted(Path(root).rglob('*')):
        name = str(path.relative_to(root))
        if name in exclude: continue
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode): result[name] = {'kind': 'symlink', 'target': os.readlink(path)}
        elif stat.S_ISREG(info.st_mode): result[name] = {'kind': 'file', 'sha256': digest(path), 'mode': stat.S_IMODE(info.st_mode), 'bytes': info.st_size}
        elif not stat.S_ISDIR(info.st_mode): raise ValueError('Special files are not installable')
    return normalize_files(result) if result else {}


class Installer:
    def __init__(self, store, *, work_root=WORK, layout=None, fixture=False, reserve=RESERVE):
        self.work = canonical(work_root); owned(self.work, True)
        marker = self.work / (FIXTURE_MARKER if fixture else '.ready-external-workspace')
        owned(marker)
        if not fixture and marker.read_text().strip() != 'ready project work for thread01a17e79': raise ValueError('Authorized workspace marker mismatch')
        self.store = canonical(store)
        if self.store == self.work or not self.store.is_relative_to(self.work): raise ValueError('Store must stay inside authorized work root')
        self.fixture, self.reserve, self._layout = fixture, reserve, layout
        if self.store.exists() and not (self.store / STORE_MARKER).exists() and any(self.store.iterdir()):
            raise ValueError('Existing unmarked store is never adopted')
        self.store.mkdir(parents=True, exist_ok=True, mode=0o700); owned(self.store, True)
        self.device = self.store.stat().st_dev
        if self.device != self.work.stat().st_dev: raise ValueError('Store must use the authorized workspace filesystem')
        if stat.S_IMODE(self.store.stat().st_mode) & 0o077: raise ValueError('Private store required')
        if not (self.store / STORE_MARKER).exists(): atomic(self.store / STORE_MARKER, encoded({'schema': 1, 'storeID': str(uuid.uuid4()), 'fixtureOnly': fixture}))
        store_record = load(self.store / STORE_MARKER)
        if store_record.get('schema') != 1 or store_record.get('fixtureOnly') is not fixture: raise ValueError('Fixture and real stores cannot be interchanged')
        self.store_id = str(uuid.UUID(store_record['storeID']))
        for name in ('objects', 'object-records', 'staging', 'transactions', 'installations', 'quarantine'):
            path = self.store / name; path.mkdir(exist_ok=True, mode=0o700); owned(path, True)
            if path.resolve() != path or path.stat().st_dev != self.device: raise ValueError('Store child aliases or filesystem changes rejected')

    @property
    def layout(self):
        if self._layout is None: self._layout = importlib.import_module('runtime_install_layout')
        return self._layout

    @contextlib.contextmanager
    def lease(self):
        fd = os.open(self.store / 'operation.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode): raise ValueError('Unowned/special operation lock')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); yield
        finally: os.close(fd)

    def directory(self, identifier):
        if str(uuid.UUID(identifier)) != identifier: raise ValueError('Invalid transaction ID')
        path = self.store / 'transactions' / identifier; owned(path, True)
        if path.resolve() != path or path.stat().st_dev != self.device: raise ValueError('Transaction alias/filesystem change rejected')
        return path

    def journal(self, identifier):
        directory = self.directory(identifier); value = load(directory / 'journal.json')
        if value.get('schema') != 1 or value.get('transaction') != identifier or value.get('storeID') != self.store_id:
            raise ValueError('Journal identity mismatch')
        if value.get('fixtureOnly') is not self.fixture: raise ValueError('Transaction execution class changed')
        if digest(directory / 'plan.json') != value['planSHA256']: raise ValueError('Plan changed')
        plan = load(directory / 'plan.json')
        self._recipe(plan)
        return directory, value, plan

    def save(self, directory, value): atomic(directory / 'journal.json', encoded(value))

    def checkpoint(self, callback, name, count=0):
        if callback:
            if not self.fixture: raise ValueError('Fault checkpoints are fixture-only')
            callback(name, count)

    def space(self, needed=0):
        # All writes occur on this one store filesystem. Source filesystems are
        # read-only; temporary files and views are never placed on the OS volume.
        if shutil.disk_usage(self.store).free < self.reserve + needed:
            raise OSError('Insufficient store filesystem space including reserve')

    def plan(self, configuration):
        with self.lease():
            value = self.layout.make_plan(Path(configuration))
            return self._plan(value)

    def _recipe(self, plan):
        recipe = canonical(Path(self.layout.__file__).resolve()); owned(recipe)
        if digest(recipe) != plan.get('recipeSHA256'): raise ValueError('Layout recipe changed; new plan required')

    def _plan(self, value):
        if value.get('schema') != 1: raise ValueError('Unsupported layout plan')
        source = value['sourceConfig']; path = canonical(source['path']); owned(path)
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != source['sha256']: raise ValueError('Source config changed while planning')
        if json.loads(raw) != source['document']: raise ValueError('Source config document mismatch')
        components = value.get('components')
        if not isinstance(components, list) or not components: raise ValueError('Components required')
        roles = set()
        for component in components:
            component['files'] = normalize_files(component['files'])
            if not sha(component['id']) or component['id'] != fingerprint(component['files']): raise ValueError('Object ID does not bind its complete inventory')
            if component['role'] in roles: raise ValueError('Duplicate component role')
            roles.add(component['role']); source_root = canonical(component['sourceRoot']); owned(source_root, True)
            if source_root.is_relative_to(self.store) or self.store.is_relative_to(source_root): raise ValueError('Source/object store overlap rejected')
        if not sha(value.get('recipeSHA256')): raise ValueError('Layout recipe hash required')
        self._recipe(value)
        identifier = str(uuid.uuid4()); directory = self.store / 'transactions' / identifier; directory.mkdir(mode=0o700)
        atomic(directory / 'source-config.before.json', raw)
        atomic(directory / 'plan.json', encoded(value))
        journal = {'schema': 1, 'transaction': identifier, 'storeID': self.store_id, 'state': 'planned',
                   'planSHA256': digest(directory / 'plan.json'), 'fixtureOnly': self.fixture,
                   'stage': identifier, 'installation': identifier, 'diagnosticOnly': True,
                   'binaryDistributionApproved': False, 'userPointerChanged': False}
        self.save(directory, journal)
        return {'transaction': identifier, 'planSHA256': journal['planSHA256'], 'state': 'planned'}

    def _stage_path(self, journal): return self.store / 'staging' / journal['transaction']
    def _final_path(self, journal): return self.store / 'installations' / journal['transaction']

    def _owned_stage(self, path, journal):
        owned(path, True)
        marker = load(path / STAGE_MARKER)
        if marker != {'schema': 1, 'transaction': journal['transaction'], 'storeID': self.store_id}: raise ValueError('Stage ownership marker mismatch')

    def _ensure_object(self, directory, journal, component, callback):
        identity = component['id']; final = self.store / 'objects' / identity
        record_path = self.store / 'object-records' / (identity + '.json')
        expected = component['files']
        if final.exists():
            owned(final, True)
            record = load(record_path)
            if record.get('id') != identity or inventory(final) != expected: raise ValueError('Existing immutable object changed; never overwritten')
            if record.get('state') != 'complete':
                record['state'] = 'complete'; atomic(record_path, encoded(record))
            return final
        pending = self.store / 'objects' / ('.pending-' + identity + '-' + journal['transaction'])
        payload = pending / 'payload'
        if not pending.exists():
            # Publish a complete ownership scaffold atomically. A kill during
            # its construction leaves an inert private scratch, never an
            # unmarked deterministic path that resume might adopt or delete.
            scaffold = pending.with_name('.new-object-' + uuid.uuid4().hex)
            scaffold.mkdir(mode=0o700)
            atomic(scaffold / 'owner.json', encoded({'transaction': journal['transaction'], 'id': identity}))
            (scaffold / 'payload').mkdir(mode=0o700); sync(scaffold)
            os.rename(scaffold, pending); sync(pending.parent)
        if load(pending / 'owner.json') != {'transaction': journal['transaction'], 'id': identity}: raise ValueError('Object scratch marker mismatch')
        owned(pending, True); owned(payload, True)
        if pending.resolve() != pending or payload.resolve() != payload: raise ValueError('Object scratch aliases rejected')
        for index, (name, item) in enumerate(sorted(expected.items())):
            target = payload / name; target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if target.parent.resolve() != target.parent: raise ValueError('Object parent aliases rejected')
            if target.exists() or target.is_symlink():
                if inventory_entry(target) != item: raise ValueError('Partial object tampered; original kept')
                continue
            self.space(item.get('bytes', 0))
            temporary = target.with_name('.copy-' + hashlib.sha256(name.encode()).hexdigest())
            if temporary.exists() or temporary.is_symlink():
                info = temporary.lstat()
                if info.st_uid != os.getuid() or not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)): raise ValueError('Unowned/special copy scratch')
                if inventory_entry(temporary) != item: temporary.unlink() # Only this marked transaction's exact private temporary.
            if not temporary.exists() and not temporary.is_symlink():
                source = Path(component['sourceRoot']) / name
                if item['kind'] == 'symlink':
                    if os.readlink(source) != item['target']: raise ValueError('Source alias changed')
                    temporary.symlink_to(item['target'])
                else:
                    if source.resolve(strict=True).is_relative_to(Path(component['sourceRoot'])) is False: raise ValueError('Source path escapes component')
                    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, 'rb') as src:
                        if not stat.S_ISREG(os.fstat(src.fileno()).st_mode): raise ValueError('Source is not regular')
                        with temporary.open('xb') as dst:
                            shutil.copyfileobj(src, dst, 1024 * 1024); dst.flush(); os.fsync(dst.fileno())
                    temporary.chmod(item['mode'])
                if inventory_entry(temporary) != item: raise ValueError('Copied file differs from locked plan')
            self.checkpoint(callback, 'copy-temp-verified', index + 1)
            os.rename(temporary, target); sync(target.parent)
            self.checkpoint(callback, 'copy-file-published', index + 1)
        if inventory(payload) != expected: raise ValueError('Raw object membership mismatch')
        atomic(record_path, encoded({'schema': 1, 'id': identity, 'state': 'prepared', 'transaction': journal['transaction']}))
        os.rename(payload, final); sync(final.parent)
        self.checkpoint(callback, 'raw-object-renamed', 1)
        atomic(record_path, encoded({'schema': 1, 'id': identity, 'state': 'complete', 'transaction': journal['transaction']}))
        return final

    def stage(self, identifier, callback=None):
        if callback and not self.fixture: raise ValueError('Fault callbacks are fixture-only')
        with self.lease():
            directory, journal, plan = self.journal(identifier)
            if journal['state'] == 'publishing': return self._complete_publish(directory, journal, plan, callback)
            if journal['state'] == 'published': return self._status_locked(directory, journal, plan)
            if journal['state'] not in ('planned', 'copying', 'materializing', 'staged', 'verified-static', 'verified-actual', 'verified-fixture'): raise ValueError('Transaction cannot be resumed')
            if journal['state'] in ('staged', 'verified-static', 'verified-actual', 'verified-fixture'):
                self._candidate(journal); return self._status_locked(directory, journal, plan)
            journal['state'] = 'copying'; self.save(directory, journal)
            objects = {component['id']: self._ensure_object(directory, journal, component, callback) for component in plan['components']}
            stage = self._stage_path(journal)
            if stage.exists():
                self._owned_stage(stage, journal)
                archived = self.store / 'quarantine' / (identifier + '-partial-' + uuid.uuid4().hex)
                os.rename(stage, archived) # Preserve interrupted/tampered derived views, never overwrite them.
            scaffold = stage.with_name('.new-stage-' + uuid.uuid4().hex)
            scaffold.mkdir(mode=0o700)
            atomic(scaffold / STAGE_MARKER, encoded({'schema': 1, 'transaction': identifier, 'storeID': self.store_id}))
            sync(scaffold); os.rename(scaffold, stage); sync(stage.parent)
            journal['state'] = 'materializing'; self.save(directory, journal)
            self.space(sum(item.get('bytes', 0) for component in plan['components'] for item in component['files'].values()))
            result = self.layout.materialize(stage, objects, plan)
            self.checkpoint(callback, 'layout-materialized', 1)
            if result.get('candidateConfigPath') != 'runtime.json': raise ValueError('Only root runtime.json may be published')
            self.layout.validate(stage, plan)
            actual = inventory(stage, exclude=(STAGE_MARKER,))
            if result.get('fileInventory') is not None and normalize_files(result['fileInventory']) != actual: raise ValueError('Layout inventory does not bind produced bytes')
            if inventory(stage, exclude=(STAGE_MARKER,)).get('runtime.json', {}).get('kind') != 'file': raise ValueError('Regular staged runtime.json required')
            for component in plan['components']:
                if inventory(objects[component['id']]) != component['files']: raise ValueError('Layout modified immutable raw object')
            journal.update(state='staged', candidateInventory=actual, candidateFingerprintSHA256=fingerprint(actual), candidateConfigSHA256=actual['runtime.json']['sha256'])
            self.save(directory, journal)
            return self._status_locked(directory, journal, plan)

    resume = stage

    def _candidate(self, journal):
        path = self._final_path(journal) if journal['state'] == 'published' else self._stage_path(journal)
        self._owned_stage(path, journal)
        if inventory(path, exclude=(STAGE_MARKER,)) != journal['candidateInventory']: raise ValueError('Candidate tree changed')
        return path

    def verify(self, identifier, runtime_proof=None):
        with self.lease():
            directory, journal, plan = self.journal(identifier); stage = self._candidate(journal)
            if journal['state'] not in ('staged', 'verified-fixture', 'verified-static', 'verified-actual'): raise ValueError('Only staged candidates may be verified')
            static = self.layout.validate(stage, plan)
            kind = 'fixture-only' if self.fixture else 'static-only'; actual = None
            if runtime_proof is not None:
                proof_path = canonical(runtime_proof)
                if not proof_path.is_relative_to(self.work): raise ValueError('Actual proof must stay in owned workspace')
                proof = load(proof_path); self._actual_proof(proof, journal)
                raw_proof = proof_path.read_bytes()
                if json.loads(raw_proof) != proof: raise ValueError('Actual proof changed while reading')
                proof_copy = directory / ('actual-proof-' + uuid.uuid4().hex + '.json')
                atomic(proof_copy, raw_proof)
                actual = {'sha256': digest(proof_copy), 'file': proof_copy.name, 'proof': proof}; kind = 'actual-runtime'
            receipt = {'schema': 1, 'kind': 'ready-local-runtime-install-verification-v1', 'verificationKind': kind,
                       'transaction': identifier, 'storeID': self.store_id, 'planSHA256': journal['planSHA256'],
                       'candidateFingerprintSHA256': journal['candidateFingerprintSHA256'], 'staticValidation': static,
                       'actualVerification': actual, 'readyForPublish': kind == 'actual-runtime' or self.fixture,
                       'diagnosticOnly': True, 'binaryDistributionApproved': False, 'userPointerChanged': False}
            path = directory / ('verify-' + uuid.uuid4().hex + '.json'); atomic(path, encoded(receipt))
            journal.update(state='verified-fixture' if self.fixture else ('verified-actual' if actual else 'verified-static'), verification={'file': path.name, 'sha256': digest(path)})
            self.save(directory, journal)
            return {**receipt, 'receipt': str(path), 'receiptSHA256': digest(path)}

    def _actual_proof(self, proof, journal):
        if self.fixture or proof.get('schema') != 1 or proof.get('verificationKind') != 'actual-runtime' or proof.get('actualRuntimeExecuted') is not True or proof.get('fixtureOnly') is not False:
            raise ValueError('Fixture/static proof cannot authorize real installation')
        expected = journal['candidateFingerprintSHA256']
        if proof.get('passed') is not True or proof.get('transaction') != journal['transaction'] or proof.get('planSHA256') != journal['planSHA256'] or proof.get('testControllerBackendUsed') is not False or any(proof.get(key) != expected for key in ('candidateFingerprintSHA256', 'candidateFingerprintBefore', 'candidateFingerprintAfter')):
            raise ValueError('Actual runtime proof does not bind this exact candidate before and after execution')
        checks = proof.get('checks', {})
        if not isinstance(checks, dict) or not ACTUAL_CHECKS.issubset(checks) or any(not isinstance(checks[name], dict) or checks[name].get('passed') is not True for name in ACTUAL_CHECKS): raise ValueError('Actual runtime matrix incomplete')
        evidence = proof.get('evidenceFiles', [])
        if not isinstance(evidence, list) or not evidence: raise ValueError('Hash-bound actual evidence required')
        seen = set()
        for record in evidence:
            path = canonical(record['path']); owned(path)
            if path in seen or not path.is_relative_to(self.work) or not sha(record['sha256']) or digest(path) != record['sha256']: raise ValueError('Actual proof evidence changed, duplicated or escaped workspace')
            seen.add(path)

    def _authorization(self, directory, journal, expected):
        record = journal.get('verification')
        if not record or expected != record['sha256']: raise ValueError('Exact verification receipt SHA256 required')
        path = directory / relative(record['file']); receipt = load(path)
        if digest(path) != expected or receipt.get('readyForPublish') is not True or receipt.get('candidateFingerprintSHA256') != journal['candidateFingerprintSHA256'] or receipt.get('planSHA256') != journal['planSHA256']: raise ValueError('Verification receipt changed')
        if receipt.get('verificationKind') != ('fixture-only' if self.fixture else 'actual-runtime'): raise ValueError('Static/fixture receipt cannot publish a real installation')
        if receipt.get('storeID') != self.store_id or receipt.get('transaction') != journal['transaction']: raise ValueError('Receipt identity mismatch')
        if not self.fixture:
            actual = receipt['actualVerification']
            proof_copy = directory / relative(actual['file'])
            if digest(proof_copy) != actual['sha256'] or load(proof_copy) != actual['proof']: raise ValueError('Original actual proof changed')
            self._actual_proof(actual['proof'], journal)
        return receipt

    def publish(self, identifier, verified_sha256, callback=None):
        if callback and not self.fixture: raise ValueError('Fault callbacks are fixture-only')
        with self.lease():
            directory, journal, plan = self.journal(identifier)
            if journal['state'] == 'published':
                if journal.get('publishAuthorization') != verified_sha256: raise ValueError('Different publication authorization')
                self._candidate(journal); return self._status_locked(directory, journal, plan)
            self._authorization(directory, journal, verified_sha256)
            if journal['state'] not in ('verified-actual', 'verified-fixture', 'publishing'): raise ValueError('Actual verification required before publish')
            if journal['state'] != 'publishing': self._candidate(journal)
            journal.update(state='publishing', publishAuthorization=verified_sha256); self.save(directory, journal)
            return self._complete_publish(directory, journal, plan, callback)

    def _complete_publish(self, directory, journal, plan, callback):
        self._authorization(directory, journal, journal['publishAuthorization'])
        stage, final = self._stage_path(journal), self._final_path(journal)
        image = directory / 'ready-runtime.json'
        if not image.exists():
            self._owned_stage(stage, journal)
            if digest(stage / 'runtime.json') != journal['candidateConfigSHA256']: raise ValueError('Staged config changed')
            os.rename(stage / 'runtime.json', image); sync(stage); sync(directory)
        owned(image)
        if digest(image) != journal['candidateConfigSHA256']: raise ValueError('Ready configuration before-image changed')
        self.checkpoint(callback, 'publish-config-hidden', 1)
        without = {k: v for k, v in journal['candidateInventory'].items() if k != 'runtime.json'}
        if final.exists():
            self._owned_stage(final, journal)
            current = inventory(final, exclude=(STAGE_MARKER,))
            if current not in (without, journal['candidateInventory']): raise ValueError('Published directory changed; preserved')
        else:
            self._owned_stage(stage, journal)
            if inventory(stage, exclude=(STAGE_MARKER,)) != without: raise ValueError('Stage changed before publication')
            os.rename(stage, final); sync(final.parent)
        self.checkpoint(callback, 'publish-directory-renamed', 1)
        if not (final / 'runtime.json').exists(): atomic(final / 'runtime.json', image.read_bytes(), journal['candidateInventory']['runtime.json']['mode'], temporary_root=directory)
        self.checkpoint(callback, 'publish-runtime-config-last', 1)
        if inventory(final, exclude=(STAGE_MARKER,)) != journal['candidateInventory']: raise ValueError('Final fingerprint mismatch')
        journal['state'] = 'published'; self.save(directory, journal)
        return self._status_locked(directory, journal, plan)

    def rollback(self, identifier, callback=None):
        if callback and not self.fixture: raise ValueError('Fault callbacks are fixture-only')
        with self.lease():
            directory, journal, plan = self.journal(identifier)
            if journal['state'] == 'rolled-back': return self._status_locked(directory, journal, plan)
            if journal['state'] == 'rolling-back':
                source = self.store / relative(journal['rollbackSource']); quarantine = self.store / relative(journal['rollbackDestination'])
                if source not in (self._stage_path(journal), self._final_path(journal)) or quarantine.parent != self.store / 'quarantine' or not quarantine.name.startswith(identifier + '-rollback-'): raise ValueError('Invalid rollback paths')
                if source.exists() and quarantine.exists(): raise ValueError('Ambiguous rollback; both trees preserved')
                if not source.exists():
                    self._owned_stage(quarantine, journal)
                    if inventory(quarantine, exclude=(STAGE_MARKER,)) != journal['rollbackInventory']: raise ValueError('Rollback destination changed')
                    journal['state'] = 'rolled-back'; self.save(directory, journal)
                    return self._status_locked(directory, journal, plan)
            source = self._final_path(journal) if self._final_path(journal).exists() else self._stage_path(journal)
            if source.exists():
                self._owned_stage(source, journal)
                # Unknown user modifications are preserved in place, never deleted.
                if journal.get('candidateInventory'):
                    actual = inventory(source, exclude=(STAGE_MARKER,)); expected = journal['candidateInventory']
                    if actual not in (expected, {k: v for k, v in expected.items() if k != 'runtime.json'}): raise ValueError('Unknown installation changes; rollback refused')
                quarantine = self.store / 'quarantine' / (identifier + '-rollback-' + uuid.uuid4().hex)
                journal.update(rollbackSource=str(source.relative_to(self.store)), rollbackDestination=str(quarantine.relative_to(self.store)), rollbackInventory=inventory(source, exclude=(STAGE_MARKER,)), state='rolling-back'); self.save(directory, journal)
                os.rename(source, quarantine); sync(quarantine.parent)
                self.checkpoint(callback, 'rollback-directory-renamed', 1)
            journal['state'] = 'rolled-back'; self.save(directory, journal)
            return self._status_locked(directory, journal, plan)

    def _status_locked(self, directory, journal, plan):
        return {'transaction': journal['transaction'], 'state': journal['state'], 'planSHA256': journal['planSHA256'],
                'candidateFingerprintSHA256': journal.get('candidateFingerprintSHA256'),
                'candidateRoot': str(self._final_path(journal) if journal['state'] == 'published' else self._stage_path(journal)) if journal.get('candidateInventory') else None,
                'verification': journal.get('verification'),
                'locationRoot': str(self._final_path(journal)) if journal['state'] == 'published' else None,
                'diagnosticOnly': True, 'binaryDistributionApproved': False, 'userPointerChanged': False}

    def status(self, identifier):
        with self.lease():
            directory, journal, plan = self.journal(identifier)
            return self._status_locked(directory, journal, plan)


def inventory_entry(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode): return {'kind': 'symlink', 'target': os.readlink(path)}
    if stat.S_ISREG(info.st_mode): return {'kind': 'file', 'sha256': digest(path), 'mode': stat.S_IMODE(info.st_mode), 'bytes': info.st_size}
    raise ValueError('Expected file or symlink')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', type=Path, required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('plan'); p.add_argument('--config', type=Path, required=True)
    for name in ('stage', 'resume', 'status', 'rollback', 'verify', 'publish'):
        p = commands.add_parser(name); p.add_argument('--transaction', required=True)
        if name == 'verify': p.add_argument('--runtime-proof', type=Path)
        if name == 'publish': p.add_argument('--verified-sha256', required=True)
    args = parser.parse_args()
    try:
        installer = Installer(args.store)
        if args.command == 'plan': result = installer.plan(args.config)
        elif args.command == 'verify': result = installer.verify(args.transaction, args.runtime_proof)
        elif args.command == 'publish': result = installer.publish(args.transaction, args.verified_sha256)
        else: result = getattr(installer, args.command)(args.transaction)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print('Local runtime installer refused: ' + str(error), file=sys.stderr); raise SystemExit(65)
