#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real SIGKILL between rename/progress commit; owned UUID fixtures only.

The production transaction contains no sleeps. ReadyCoreProbe alone opts into
an owned-marker checkpoint which SIGSTOPs after a real filesystem rename.
"""
import hashlib,json,os,pathlib,shutil,signal,subprocess,time,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]


def treehash(folder):
    result=hashlib.sha256()
    for path in sorted(folder.rglob('*')):
        relative=str(path.relative_to(folder));result.update(relative.encode())
        if path.is_symlink():result.update(b'link:'+os.readlink(path).encode())
        elif path.is_file():result.update(path.read_bytes())
    return result.hexdigest()


def main():
    subprocess.run(['swift','build','--product','ReadyCoreProbe','--jobs','2'],cwd=ROOT,check=True,capture_output=True)
    products=pathlib.Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=ROOT,text=True).strip());probe=products/'ReadyCoreProbe'
    fixtures=[];processes=[];checks={};report={'passed':False,'scope':'actual rollback and recovery renames with SIGKILL, before progress commit; synthetic prefixes only'}
    def command(operation,root,*args,check=True):
        return subprocess.run([str(probe),operation,str(root),*map(str,args)],cwd=ROOT,capture_output=True,text=True,check=check,timeout=15)
    def create_fixture():
        root=ROOT/'Runtime/TestPrefixes'/('rollback-crash-'+uuid.uuid4().hex);root.mkdir(parents=True,mode=0o700);fixtures.append(root)
        (root/'.ready-synthetic-migration').write_text('Disposable owned rollback fixture\n');(root/'.ready-synthetic-migration').chmod(0o600)
        legacy=root/'SharedPrefix';game=legacy/'drive_c/Fixture';game.mkdir(parents=True)
        (game/'game.exe').write_bytes(b'MZ synthetic; never executed\n');(legacy/'user.reg').write_text('original legacy registry\n')
        for index in range(50):(game/f'file-{index}.dat').write_bytes(('source-'+str(index)).encode()*64)
        owner=str(uuid.uuid4()).upper();variant={'id':'windows','platform':'windows','architecture':'x86_64','executable':str(game/'game.exe'),'workingDirectory':str(game),'installationRoot':str(game),'arguments':[],'installed':True,'verification':'Synthetic only'}
        games=[{'id':id,'store':'local','storeID':id,'title':'Rollback fixture '+id,'variants':[variant],'engine':'automatic','saveRules':[]}for id in ['A','B','C']]
        (root/'library.json').write_text(json.dumps({'schema':1,'profiles':[{'id':owner,'name':'Rollback QA','createdAt':0}],'activeProfile':owner,'games':games}))
        original=treehash(legacy);plan=json.loads(command('--execute-migration-fixture',root).stdout)
        for id,path in plan['destinations'].items():
            target=pathlib.Path(path);(target/'user.reg').write_text('new modified registry '+id);(target/'after-migration.dat').write_text('private new data '+id)
        hashes={id:treehash(pathlib.Path(path))for id,path in plan['destinations'].items()}
        return root,plan,original,hashes
    def pause(operation,root,phase,count):
        marker=root/'.rollback-probe-pause.json';marker.unlink(missing_ok=True)
        process=subprocess.Popen([str(probe),operation,str(root),'--pause-phase',phase,'--pause-count',str(count)],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE);processes.append(process)
        until=time.monotonic()+8
        while time.monotonic()<until and process.poll()is None:
            try:point=json.loads(marker.read_text())
            except (OSError,ValueError):point=None
            if point is not None:
                assert point=={'phase':phase,'count':count,'pid':process.pid};return process
            time.sleep(.002)
        if process.poll()is None:process.kill()
        process.communicate(timeout=5);raise AssertionError('Owned real-rename checkpoint was not reached')
    def kill(process):
        assert process.poll()is None;os.kill(process.pid,signal.SIGKILL);process.communicate(timeout=5);assert process.returncode==-signal.SIGKILL
    def status(root):return json.loads(command('--migration-status-fixture',root).stdout)
    try:
        root,plan,original,hashes=create_fixture()
        process=pause('--rollback-migration-fixture',root,'rollback.moved',2)
        journal=json.loads((root/'Migration/rollback-journal.json').read_text());archive=root/'Backups'/('migration-rollback-'+journal['transaction'])
        ordered=sorted(plan['destinations']);assert not pathlib.Path(plan['destinations'][ordered[0]]).exists();assert not pathlib.Path(plan['destinations'][ordered[1]]).exists();assert pathlib.Path(plan['destinations'][ordered[2]]).exists()
        assert journal['copies'][1]['archiveIntent']is True and journal['copies'][1]['archived']is False
        checks['killedAfterTwoActualRenamesBeforeProgressCommit']=True
        # The live transaction still holds all leases, even for an unmoved game.
        before=treehash(archive);busy=command('--recover-rollback-fixture',root,check=False);assert busy.returncode!=0 and treehash(archive)==before
        checks['liveTransactionPreventsRecoveryMutation']=True
        kill(process);pending=status(root);assert pending['recoveryRequired']and pending['kind']=='rollback'and all(pending['blocked'].values())
        checks['pendingRollbackBlocksAffectedSessions']=True
        conflict=pathlib.Path(plan['destinations']['A']);conflict.mkdir();(conflict/'created-after-crash.dat').write_text('separate replacement data')
        process=pause('--recover-rollback-fixture',root,'recovery.conflict-moved',0)
        assert len(list((archive/'Conflicts').rglob('created-after-crash.dat')))==1;kill(process)
        checks['conflictMoveCrashKeepsBothCopiesJournaled']=True
        process=pause('--recover-rollback-fixture',root,'recovery.restored',1);kill(process)
        checks['recoveryItselfCanCrashAfterActualRestore']=True
        process=pause('--recover-rollback-fixture',root,'recovery.commit-pending',1);kill(process)
        checks['recoveryCommitBoundaryCanResumeWithoutRepeatingMoves']=True
        recovered=json.loads(command('--recover-rollback-fixture',root).stdout)
        assert not recovered['recoveryRequired']and recovered['planStatus']=='copied-awaiting-real-validation-original-retained'
        assert all(treehash(pathlib.Path(path))==hashes[id]for id,path in plan['destinations'].items())
        assert treehash(root/'SharedPrefix')==original
        assert len(list((archive/'Conflicts').rglob('created-after-crash.dat')))==1
        outcome=json.loads((archive/'recovery-result.json').read_text());assert outcome['outcome']=='rollback-interrupted-copies-restored-original-retained'
        checks['repeatedRecoveryRestoresEveryModifiedCopyAndOriginal']=True
        library=json.loads((root/'library.json').read_text());assert all(pathlib.Path(p['variants'][0]['executable']).exists()for p in library['gamePreferences'].values())
        checks['libraryBindingsRemainValidAfterRollbackAbort']=True
        retried=json.loads(command('--rollback-migration-fixture',root).stdout);committed=pathlib.Path(retried['archive'])
        assert not retried['recoveryRequired']and all(not pathlib.Path(path).exists()for path in plan['destinations'].values())
        # Archive names use the same safe component as the original destination basename.
        assert all(treehash(committed/pathlib.Path(path).name)==hashes[id]for id,path in plan['destinations'].items())
        assert all(not p['variants'][0]['installed']for p in json.loads((root/'library.json').read_text())['gamePreferences'].values())
        assert treehash(root/'SharedPrefix')==original
        checks['retryCommitsArchiveWithoutDeletingNewOrOriginalData']=True
        # Commit boundary: all copies moved and plan says rolled back, but pending journal wins.
        root,plan,original,hashes=create_fixture();process=pause('--rollback-migration-fixture',root,'rollback.commit-pending',3)
        assert json.loads((root/'Migration/plan.json').read_text())['status']=='rolled-back-copies-archived-original-retained';kill(process)
        assert status(root)['recoveryRequired']
        recovered=json.loads(command('--recover-rollback-fixture',root).stdout)
        assert recovered['planStatus']=='copied-awaiting-real-validation-original-retained'and not recovered['recoveryRequired']
        assert all(treehash(pathlib.Path(path))==hashes[id]for id,path in plan['destinations'].items())and treehash(root/'SharedPrefix')==original
        checks['commitBoundaryCrashAbortsSafelyAndRestoresBindings']=True
        # A fully committed Core rollback can precede the UI's library save.
        root,plan,original,hashes=create_fixture();process=pause('--rollback-migration-fixture',root,'rollback.returned',3);kill(process)
        assert not status(root)['recoveryRequired']
        stale=json.loads((root/'library.json').read_text());assert all(p['variants'][0]['installed']for p in stale['gamePreferences'].values())
        command('--reconcile-migration-fixture',root)
        fixed=json.loads((root/'library.json').read_text());assert all(not p['variants'][0]['installed']and not p['variants'][0].get('executable')for p in fixed['gamePreferences'].values())
        assert treehash(root/'SharedPrefix')==original
        checks['postCommitCrashReconcilesStaleLibraryWithoutPrefixMutation']=True
        report.update(passed=True,checks=checks,realSIGKILLCount=6,fixturesRemoved=True,noRealUserDataTouched=True)
    finally:
        for process in processes:
            if process.poll()is None:process.kill();process.wait(timeout=5)
        if report['passed']:
            for root in fixtures:
                assert root.parent==ROOT/'Runtime/TestPrefixes'and root.name.startswith('rollback-crash-')and(root/'.ready-synthetic-migration').is_file();shutil.rmtree(root)
        else:report.update(checks=checks,fixturesRemoved=False,fixtures=[str(root)for root in fixtures])
        (ROOT/'Evidence/rollback-crash.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
