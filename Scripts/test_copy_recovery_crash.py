#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""SIGKILL during copy-recovery renames and commit; marked UUID fixtures only.

This tests process interruption, not machine power loss. No account, real game,
user prefix, or production environment fault hook is involved.
"""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def treehash(folder):
    digest = hashlib.sha256()
    for path in sorted(folder.rglob('*')):
        digest.update(str(path.relative_to(folder)).encode())
        if path.is_symlink():
            digest.update(b'link:' + os.readlink(path).encode())
        elif path.is_file():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-build', action='store_true')
    arguments = parser.parse_args()
    if not arguments.skip_build:
        subprocess.run(['swift', 'build', '--product', 'ReadyCoreProbe', '--jobs', '2'], cwd=ROOT, check=True, capture_output=True)
    products = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    probe = products / 'ReadyCoreProbe'
    root = ROOT / 'Runtime/TestPrefixes' / ('copy-recovery-crash-' + uuid.uuid4().hex)
    root.mkdir(parents=True, mode=0o700)
    marker = root / '.ready-synthetic-migration'
    marker.write_text('Disposable synthetic copy recovery crash fixture\n')
    marker.chmod(0o600)
    processes, checks = [], {}
    report = {'passed': False, 'scope': 'actual multi-prefix copy, recovery renames and commit interrupted by SIGKILL; synthetic files only'}
    kills = 0

    def command(operation, check=True):
        return subprocess.run([str(probe), operation, str(root)], cwd=ROOT, capture_output=True, text=True, check=check, timeout=45)

    def kill(process):
        nonlocal kills
        assert process.poll() is None
        os.kill(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        assert process.returncode == -signal.SIGKILL
        kills += 1

    def pause(phase, count):
        point_file = root / '.rollback-probe-pause.json'
        point_file.unlink(missing_ok=True)
        process = subprocess.Popen([str(probe), '--recover-rollback-fixture', str(root), '--pause-phase', phase, '--pause-count', str(count)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(process)
        until = time.monotonic() + 15
        while time.monotonic() < until and process.poll() is None:
            try:
                point = json.loads(point_file.read_text())
            except (OSError, ValueError):
                point = None
            if point is not None:
                assert point == {'phase': phase, 'count': count, 'pid': process.pid}
                return process
            time.sleep(.002)
        if process.poll() is None:
            process.kill()
        out, err = process.communicate(timeout=5)
        raise AssertionError('Real recovery checkpoint not reached: ' + phase + ': ' + err.decode()[-1800:])

    def pending():
        value = json.loads(command('--migration-status-fixture').stdout)
        assert value['recoveryRequired'] and value['kind'] == 'copy' and all(value['blocked'].values())
        return value

    try:
        legacy = root / 'SharedPrefix'
        game = legacy / 'drive_c/Fixture'
        game.mkdir(parents=True)
        (game / 'game.exe').write_bytes(b'MZ synthetic; never executed\n')
        (legacy / 'user.reg').write_text('Original registry retained\n')
        for index in range(6000):
            (game / f'fixture-{index:05d}.dat').write_bytes((str(index) + ':original\n').encode() * 32)
        original = treehash(legacy)
        owner = str(uuid.uuid4()).upper()
        variant = {'id': 'windows', 'platform': 'windows', 'architecture': 'x86_64', 'executable': str(game / 'game.exe'), 'workingDirectory': str(game), 'installationRoot': str(game), 'arguments': [], 'installed': True, 'verification': 'Synthetic fixture only'}
        games = [{'id': item, 'store': 'local', 'storeID': item, 'title': 'Recovery fixture ' + item, 'variants': [variant], 'engine': 'automatic', 'saveRules': []} for item in ['A', 'B']]
        (root / 'library.json').write_text(json.dumps({'schema': 1, 'profiles': [{'id': owner, 'name': 'Recovery QA', 'createdAt': 0}], 'activeProfile': owner, 'games': games}))
        process = subprocess.Popen([str(probe), '--execute-migration-fixture', str(root)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(process)
        until = time.monotonic() + 25
        found = False
        while time.monotonic() < until and process.poll() is None:
            try:
                created = json.loads((root / 'Migration/journal.json').read_text())
                if len(created) == 2 and any(pathlib.Path(created[1]).rglob('fixture-*.dat')):
                    found = True
                    kill(process)
                    break
            except (OSError, ValueError):
                pass
            time.sleep(.002)
        assert found, 'Actual multi-prefix copy did not reach its second partial destination'
        plan = json.loads((root / 'Migration/plan.json').read_text())
        assert plan['status'] == 'prepared-original-untouched'
        hashes = {item: treehash(pathlib.Path(path)) for item, path in plan['destinations'].items()}
        assert all(pathlib.Path(path).is_dir() for path in plan['destinations'].values())
        pending()
        checks['actualCopyKilledWithTwoCreatedPrefixes'] = True

        process = pause('copy-recovery.moved', 1)
        journal_path = root / 'Migration/copy-recovery-journal.json'
        journal = json.loads(journal_path.read_text())
        archive = root / 'Backups' / ('migration-interrupted-' + journal['transaction'])
        moved_id = sorted(plan['destinations'])[0]
        moved_path = pathlib.Path(plan['destinations'][moved_id])
        assert not moved_path.exists() and (archive / moved_path.name).is_dir()
        assert json.loads((root / 'Migration/plan.json').read_text())['status'] == 'prepared-original-untouched'
        before = treehash(archive)
        busy = command('--recover-rollback-fixture', check=False)
        assert busy.returncode != 0 and treehash(archive) == before
        checks['liveRecoveryLeasesPreventConcurrentMutation'] = True
        kill(process)
        pending()
        checks['firstRenameCrashRetainsCompleteArchiveIntent'] = True

        # A malformed durable journal fails closed and keeps all existing files.
        saved = journal_path.read_bytes()
        journal_path.write_text('{broken')
        before = treehash(root)
        assert command('--recover-rollback-fixture', check=False).returncode != 0
        assert treehash(root) == before
        pending()
        journal_path.write_bytes(saved)
        checks['corruptIntentFailsClosedWithoutMovingData'] = True

        # A new prefix occupying a vacated path is retained under its own write-ahead identity.
        moved_path.mkdir()
        (moved_path / 'post-crash-replacement.dat').write_text('Separate new data must survive\n')
        process = pause('copy-recovery.conflict-moved', 1)
        conflict = json.loads(journal_path.read_text())['conflicts']
        assert len(conflict) == 1 and len(list((archive / 'Conflicts').rglob('post-crash-replacement.dat'))) == 1
        kill(process)
        pending()
        checks['conflictRenameCrashPreservesReplacementAndOriginalCopy'] = True

        process = pause('copy-recovery.plan-recorded', 2)
        assert json.loads((root / 'Migration/plan.json').read_text())['status'] == 'interrupted-copies-archived-original-retained'
        kill(process)
        pending()
        checks['planCommitCrashStillRequiresCopyRecovery'] = True

        process = pause('copy-recovery.journal-archived', 2)
        assert not (root / 'Migration/journal.json').exists() and (archive / 'copy-journal.json').is_file()
        kill(process)
        pending()
        checks['originalJournalArchiveCrashStillRequiresRecovery'] = True

        process = pause('copy-recovery.commit-pending', 2)
        assert (archive / 'recovery-result.json').is_file()
        kill(process)
        pending()
        checks['finalCommitBoundaryRemainsRecoverable'] = True

        recovered = json.loads(command('--recover-rollback-fixture').stdout)
        assert pathlib.Path(recovered['archive']) == archive and not recovered['recoveryRequired']
        assert not journal_path.exists() and (archive / 'recovery-journal.json').is_file()
        assert len(list((root / 'Backups').glob('migration-interrupted-*'))) == 1
        for item, path in plan['destinations'].items():
            assert not pathlib.Path(path).exists() and treehash(archive / pathlib.Path(path).name) == hashes[item]
        assert len(list((archive / 'Conflicts').rglob('post-crash-replacement.dat'))) == 1
        assert treehash(legacy) == original
        checks['retriesUseOneArchiveAndPreserveEveryPartialCopyAndOriginal'] = True

        completed = json.loads(command('--execute-migration-fixture').stdout)
        assert completed['status'] == 'copied-awaiting-real-validation-original-retained'
        assert all(len(list((pathlib.Path(path) / 'drive_c/Fixture').glob('fixture-*.dat'))) == 6000 for path in completed['destinations'].values())
        assert treehash(legacy) == original
        checks['freshRetryCopiesBothGamesAfterRecoveryCommit'] = True
        report.update(passed=True, checks=checks, actualSIGKILLCount=kills, originalSHA256=original, fixtureRemoved=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
        if report['passed']:
            assert root.parent == ROOT / 'Runtime/TestPrefixes' and marker.is_file()
            shutil.rmtree(root)
        else:
            report.update(checks=checks, actualSIGKILLCount=kills, fixtureRemoved=False, fixture=str(root))
        (ROOT / 'Evidence/copy-recovery-crash.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
