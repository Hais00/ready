#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Kill an actual LauncherCore copy, recover its journal, then retry the migration.

Only a fresh UUID fixture beneath this project's Runtime/TestPrefixes is touched.
No real prefix, account or save data is used. This is crash recovery evidence for
the copy transaction, not proof that a commercial game's migrated saves work.
"""
import hashlib, json, os, pathlib, shutil, signal, subprocess, time, uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]

def main():
    subprocess.run(['swift', 'build', '--product', 'ReadyCoreProbe', '--jobs', '2'], cwd=ROOT, check=True, capture_output=True)
    directory = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    probe = directory/'ReadyCoreProbe'
    scratch = ROOT/'Runtime/TestPrefixes'/('migration-crash-'+uuid.uuid4().hex)
    scratch.mkdir(parents=True, mode=0o700)
    marker = scratch/'.ready-synthetic-migration'
    marker.write_text('Disposable synthetic migration crash fixture\n')
    report = {'passed': False, 'scope': 'actual LauncherCore FileManager copy, SIGKILL, journal recovery and retry; synthetic files only', 'checks': {}}
    process = None
    try:
        legacy = scratch/'SharedPrefix'
        game_root = legacy/'drive_c/LegacyGame'
        game_root.mkdir(parents=True)
        (game_root/'game.exe').write_bytes(b'MZ synthetic executable, not launched\n')
        payload = b'ready migration synthetic data\n'*64
        for index in range(6000):
            (game_root/f'fixture-{index:05d}.dat').write_bytes(payload)
        (legacy/'user.reg').write_text('synthetic registry, original must remain intact\n')
        def treehash(folder):
            digest = hashlib.sha256()
            for path in sorted(folder.rglob('*')):
                if path.is_file() and not path.is_symlink():
                    digest.update(str(path.relative_to(folder)).encode()); digest.update(path.read_bytes())
            return digest.hexdigest()
        original_hash = treehash(legacy)
        profile = str(uuid.uuid4()).upper()
        variant = {'id':'windows', 'platform':'windows', 'architecture':'x86_64', 'executable':str(game_root/'game.exe'), 'workingDirectory':str(game_root), 'installationRoot':str(game_root), 'arguments':[], 'installed':True, 'verification':'synthetic fixture'}
        games = [{'id':name,'store':'local','storeID':name,'title':'Migration fixture '+name,'variants':[variant],'engine':'automatic','saveRules':[]} for name in ['A','B']]
        library = {'schema':1,'profiles':[{'id':profile,'name':'Migration QA','createdAt':0}],'activeProfile':profile,'games':games}
        (scratch/'library.json').write_text(json.dumps(library))
        process = subprocess.Popen([str(probe),'--execute-migration-fixture',str(scratch)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic()+15
        journal = scratch/'Migration/journal.json'
        partial = None
        while time.monotonic()<deadline and process.poll() is None:
            if journal.exists():
                try:
                    created = json.loads(journal.read_text())
                    for value in created:
                        candidate = pathlib.Path(value)
                        if any(candidate.rglob('fixture-*.dat')):
                            partial = candidate; break
                except (OSError,ValueError):
                    pass
                if partial is not None:
                    os.kill(process.pid, signal.SIGKILL)
                    break
            time.sleep(.002)
        stdout, stderr = process.communicate(timeout=10)
        assert partial is not None and process.returncode == -signal.SIGKILL, 'Copy was not interrupted during actual file creation'
        assert str(partial).startswith(str(scratch/'Prefixes')+'/')
        report['checks']['copyKilledWithActualPartialFiles'] = True
        plan = json.loads((scratch/'Migration/plan.json').read_text())
        assert plan['status']=='prepared-original-untouched'
        report['checks']['uncommittedCopyNotMarkedComplete'] = True
        before = len(list(partial.rglob('fixture-*.dat')))
        recovered = subprocess.run([str(probe),'--recover-migration-fixture',str(scratch)],cwd=ROOT,check=True,capture_output=True,text=True)
        recovery = json.loads(recovered.stdout)
        archive = pathlib.Path(recovery['archive'])
        assert archive.is_relative_to(scratch/'Backups') and archive.is_dir()
        assert not partial.exists() and not recovery['recoveryRequired']
        assert len(list(archive.rglob('fixture-*.dat')))>=before>0
        report['checks']['partialDataArchivedWithoutDeletion'] = True
        assert treehash(legacy)==original_hash
        report['checks']['originalUnchangedAfterCrashAndRecovery'] = True
        retried = subprocess.run([str(probe),'--execute-migration-fixture',str(scratch)],cwd=ROOT,check=True,capture_output=True,text=True,timeout=45)
        completed = json.loads(retried.stdout)
        assert completed['status']=='copied-awaiting-real-validation-original-retained'
        for value in completed['destinations'].values():
            assert len(list((pathlib.Path(value)/'drive_c/LegacyGame').glob('fixture-*.dat')))==6000
        report['checks']['retryCopiesBothGames'] = True
        current = json.loads((scratch/'library.json').read_text())
        assert len(current['gamePreferences'])==2
        assert all(p['variants'][0]['executable'].startswith(str(scratch/'Prefixes')+'/') for p in current['gamePreferences'].values())
        report['checks']['libraryBoundToPrivateCopiesAfterCommit'] = True
        assert treehash(legacy)==original_hash
        report['checks']['originalUnchangedAfterRetry'] = True
        report.update(passed=True, partialFileCount=before, originalSHA256=original_hash, fixtureRemoved=True)
    finally:
        if process is not None and process.poll() is None:
            process.kill(); process.wait(timeout=5)
        if report['passed']:
            assert scratch.parent==ROOT/'Runtime/TestPrefixes' and marker.is_file()
            shutil.rmtree(scratch)
        else:
            report.update(fixtureRemoved=False, fixture=str(scratch))
        (ROOT/'Evidence/migration-crash.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__': main()
