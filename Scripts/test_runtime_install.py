#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Small isolated installer fixtures, including real SIGKILL/resume boundaries.

No runtime binary, compiler, game, account, active config or user pointer is used.
The synthetic layout has its own recipe hash and cannot approve a real install.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
import runtime_install as install


def put(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())
    path.chmod(mode)


class FixtureLayout:
    __file__ = __file__

    @staticmethod
    def make_plan(configuration):
        document = json.loads(configuration.read_bytes())
        root = configuration.parent / 'payload'
        files = install.inventory(root)
        return {'schema': 1, 'sourceConfig': {'path': str(configuration), 'sha256': install.digest(configuration), 'document': document},
                'recipeSHA256': install.digest(__file__), 'components': [{'id': install.fingerprint(files), 'role': 'fixture', 'sourceRoot': str(root), 'files': files}]}

    @staticmethod
    def materialize(stage, objects, plan):
        component = plan['components'][0]
        shutil.copytree(objects[component['id']], stage / 'component', symlinks=True, copy_function=shutil.copy2)
        install.atomic(stage / 'runtime.json', install.encoded({'fixtureOnly': True, 'pathFormat': 'runtime-relative-v1', 'wine': 'component/bin/tool'}))
        manifest = {'fixtureOnly': True, 'files': install.inventory(stage, exclude=(install.STAGE_MARKER,))}
        install.atomic(stage / 'derivation-manifest.json', install.encoded(manifest))
        return {'candidateConfigPath': 'runtime.json', 'fileInventory': install.inventory(stage, exclude=(install.STAGE_MARKER,))}

    @staticmethod
    def validate(stage, plan):
        manifest = install.load(stage / 'derivation-manifest.json')
        if manifest['files'] != install.inventory(stage, exclude=(install.STAGE_MARKER, 'derivation-manifest.json')):
            raise ValueError('Fixture derivation changed')
        return {'verificationKind': 'fixture-derivation-static', 'passed': True, 'fixtureOnly': True, 'relocatedRuntimeVerified': False}


def installer(work, store='store', fixture=True, **kwargs):
    return install.Installer(work / store, work_root=work, fixture=fixture, layout=FixtureLayout, **kwargs)


def source(work):
    root = work / 'source'
    put(root / 'payload/bin/tool', '#!/bin/sh\nexit 0\n', 0o755)
    put(root / 'payload/lib/data', b'fixture data\x00\xff')
    (root / 'payload/a-link').symlink_to('bin/tool')
    put(root / 'runtime.json', '{"fixtureOnly":true,"historicalRoot":"/preserve/original"}\n')
    return root / 'runtime.json'


def expect_refusal(action):
    try:
        action()
    except (ValueError, OSError, KeyError, TypeError):
        return
    raise AssertionError('Unsafe operation unexpectedly accepted')


def worker(work, transaction, phase, action, receipt):
    instance = installer(work)
    def pause(name, count):
        if name == phase:
            install.atomic(work / 'stopped.json', install.encoded({'phase': name, 'count': count}))
            os.kill(os.getpid(), signal.SIGSTOP)
    if action == 'stage': instance.stage(transaction, pause)
    elif action == 'publish': instance.publish(transaction, receipt, pause)
    else: instance.rollback(transaction, pause)
    raise AssertionError('Expected checkpoint was not reached')


def kill_at(work, transaction, phase, action='stage', receipt=''):
    event = work / 'stopped.json'; event.unlink(missing_ok=True)
    process = subprocess.Popen([sys.executable, __file__, '--worker', str(work), transaction, phase, action, receipt], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 15
        while not event.exists():
            if process.poll() is not None:
                raise AssertionError('Worker exited before checkpoint: ' + process.communicate()[1].decode())
            if time.monotonic() > deadline: raise AssertionError('Checkpoint timeout')
            time.sleep(0.01)
        assert json.loads(event.read_text())['phase'] == phase
        os.kill(process.pid, signal.SIGKILL)
        assert process.wait(timeout=5) == -signal.SIGKILL
    finally:
        if process.poll() is None: process.kill(); process.wait()
        process.stdout.close(); process.stderr.close()


def new_work(parent, name):
    work = parent / name; work.mkdir(mode=0o700)
    put(work / install.FIXTURE_MARKER, 'private synthetic installer fixture', 0o600)
    return work


def stage_new(work):
    config = source(work); instance = installer(work)
    transaction = instance.plan(config)['transaction']
    return instance, config, transaction


def main():
    parent = Path(tempfile.mkdtemp(prefix='runtime-install-fixtures-')).resolve()
    parent.chmod(0o700)
    checks = {}; crashes = []
    def check(name, action):
        action(); checks[name] = True

    for phase in ['copy-temp-verified', 'copy-file-published', 'raw-object-renamed', 'layout-materialized']:
        work = new_work(parent, phase); instance, config, transaction = stage_new(work)
        before = install.inventory(config.parent)
        kill_at(work, transaction, phase); crashes.append(phase)
        resumed = instance.resume(transaction)
        assert resumed['state'] == 'staged'
        checks['resume-' + phase] = True
        assert install.inventory(config.parent) == before
        component = install.load(instance.directory(transaction) / 'plan.json')['components'][0]
        assert install.inventory(instance.store / 'objects' / component['id']) == component['files']
        assert os.readlink(instance.store / 'objects' / component['id'] / 'a-link') == 'bin/tool'
        checks['source-mode-alias-preserved-' + phase] = True

    for phase in ['publish-config-hidden', 'publish-directory-renamed', 'publish-runtime-config-last']:
        work = new_work(parent, phase); instance, config, transaction = stage_new(work)
        instance.stage(transaction); proof = instance.verify(transaction)
        assert proof['verificationKind'] == 'fixture-only' and proof['binaryDistributionApproved'] is False
        kill_at(work, transaction, phase, 'publish', proof['receiptSHA256']); crashes.append(phase)
        final = instance.store / 'installations' / transaction
        assert (final / 'runtime.json').exists() is (phase == 'publish-runtime-config-last')
        result = instance.resume(transaction)
        assert result['state'] == 'published'
        assert result['candidateFingerprintSHA256'] == install.fingerprint(install.inventory(final, exclude=(install.STAGE_MARKER,)))
        checks['publish-last-resume-' + phase] = True

    work = new_work(parent, 'rollback'); instance, config, transaction = stage_new(work)
    instance.stage(transaction); receipt = instance.verify(transaction)
    instance.publish(transaction, receipt['receiptSHA256'])
    kill_at(work, transaction, 'rollback-directory-renamed', 'rollback'); crashes.append('rollback-directory-renamed')
    assert instance.rollback(transaction)['state'] == 'rolled-back'
    assert not (instance.store / 'installations' / transaction).exists()
    assert list((instance.store / 'quarantine').glob(transaction + '-rollback-*'))
    checks['rollback-kill-resume-retains-bytes'] = True

    work = new_work(parent, 'reuse'); instance, config, first = stage_new(work)
    source_before = install.inventory(config.parent)
    instance.stage(first); receipt = instance.verify(first); instance.publish(first, receipt['receiptSHA256'])
    objects = {p.name: install.inventory(p) for p in (instance.store / 'objects').iterdir() if not p.name.startswith('.')}
    object_stats = {p: p.stat().st_ino for p in (instance.store / 'objects').rglob('tool')}
    first_before = install.inventory(instance.store / 'installations' / first)
    second = instance.plan(config)['transaction']; instance.stage(second)
    assert objects == {p.name: install.inventory(p) for p in (instance.store / 'objects').iterdir() if not p.name.startswith('.')}
    assert object_stats == {p: p.stat().st_ino for p in (instance.store / 'objects').rglob('tool')}
    assert first_before == install.inventory(instance.store / 'installations' / first)
    view = instance.store / 'staging' / second / 'component/bin/tool'
    assert view.stat().st_ino not in object_stats.values()
    view.write_text('altered private derived view')
    assert objects == {p.name: install.inventory(p) for p in (instance.store / 'objects').iterdir() if not p.name.startswith('.')}
    expect_refusal(lambda: instance.resume(second))
    checks['raw-objects-once-independent-views-old-version-retained'] = True
    assert source_before == install.inventory(config.parent)
    checks['sources-unchanged'] = True

    def tamper_case(name, mutate, action):
        work = new_work(parent, name); instance, config, transaction = stage_new(work)
        instance.stage(transaction); receipt = instance.verify(transaction)
        mutate(instance, transaction, receipt)
        expect_refusal(lambda: action(instance, transaction, receipt))
        checks[name] = True
    tamper_case('reject-stage-byte-tamper', lambda i,t,r: (i.store/'staging'/t/'component/lib/data').write_text('tamper'), lambda i,t,r: i.publish(t,r['receiptSHA256']))
    tamper_case('reject-plan-tamper', lambda i,t,r: (i.directory(t)/'plan.json').write_text('{}'), lambda i,t,r: i.resume(t))
    tamper_case('reject-receipt-tamper', lambda i,t,r: Path(r['receipt']).write_text('{}'), lambda i,t,r: i.publish(t,r['receiptSHA256']))
    tamper_case('reject-unknown-publication-sha', lambda i,t,r: None, lambda i,t,r: i.publish(t,'0'*64))
    tamper_case('reject-fixture-store-as-real', lambda i,t,r: put(i.work/'.ready-external-workspace','ready project work for thread01a17e79'), lambda i,t,r: installer(i.work,fixture=False))
    def raw_tamper(i,t,r):
        component=install.load(i.directory(t)/'plan.json')['components'][0]
        (i.store/'objects'/component['id']/'lib/data').write_text('tampered raw object')
    tamper_case('reject-raw-object-tamper-on-reuse', raw_tamper, lambda i,t,r: i.stage(i.plan(i.work/'source/runtime.json')['transaction']))
    tamper_case('reject-rollback-unknown-user-data', lambda i,t,r: put(i.store/'staging'/t/'unknown-user-file','retained'), lambda i,t,r: i.rollback(t))

    work = new_work(parent,'path-and-space'); config=source(work); instance=installer(work)
    initial=FixtureLayout.make_plan(config)
    for name, bad in [('parent-escape','../outside'),('absolute-path','/outside'),('empty-component','a//b')]:
        invalid=copy.deepcopy(initial); invalid['components'][0]['files']={bad:next(v for v in initial['components'][0]['files'].values() if v['kind']=='file')}
        invalid['components'][0]['id']=install.fingerprint(invalid['components'][0]['files'])
        expect_refusal(lambda: instance._plan(invalid)); checks['reject-'+name]=True
    invalid=copy.deepcopy(initial); invalid['components'][0]['files']['a-link']['target']='../../outside'; invalid['components'][0]['id']=install.fingerprint(invalid['components'][0]['files'])
    expect_refusal(lambda: instance._plan(invalid)); checks['reject-symlink-escape']=True
    invalid=copy.deepcopy(initial); invalid['recipeSHA256']='0'*64
    expect_refusal(lambda: instance._plan(invalid)); checks['reject-stale-layout-recipe']=True
    transaction=instance.plan(config)['transaction']
    expect_refusal(lambda: installer(work,reserve=shutil.disk_usage(work).free+1).stage(transaction)); checks['reject-insufficient-reserve']=True
    assert not (instance.store/'installations'/transaction/'runtime.json').exists()
    checks['reserve-failure-not-published']=True

    work=new_work(parent,'production-proof-negatives'); config=source(work)
    put(work/'.ready-external-workspace','ready project work for thread01a17e79',0o600)
    instance=installer(work,fixture=False); transaction=instance.plan(config)['transaction']; status=instance.stage(transaction)
    static=instance.verify(transaction)
    assert static['verificationKind']=='static-only' and static['readyForPublish'] is False
    expect_refusal(lambda:instance.publish(transaction,static['receiptSHA256'])); checks['static-proof-cannot-publish-real-store']=True
    evidence=work/'evidence.txt';put(evidence,'synthetic negative fixture evidence')
    proof={'schema':1,'verificationKind':'actual-runtime','actualRuntimeExecuted':True,'fixtureOnly':False,'passed':True,'transaction':transaction,'planSHA256':status['planSHA256'],'testControllerBackendUsed':False,'checks':{name:{'passed':True} for name in install.ACTUAL_CHECKS},'evidenceFiles':[{'path':str(evidence),'sha256':install.digest(evidence)}]}
    proof.update({key:status['candidateFingerprintSHA256'] for key in ['candidateFingerprintSHA256','candidateFingerprintBefore','candidateFingerprintAfter']})
    # Deliberately invalid synthetic documents test validation ONLY. No positive
    # synthetic "actual" proof is submitted, verified or published.
    for name,mutate in [
        ('fixture-proof',lambda p:p.update(fixtureOnly=True)),
        ('wrong-before-hash',lambda p:p.update(candidateFingerprintBefore='0'*64)),
        ('wrong-after-hash',lambda p:p.update(candidateFingerprintAfter='0'*64)),
        ('test-controller-backend',lambda p:p.update(testControllerBackendUsed=True)),
        ('missing-real-check',lambda p:p['checks'].pop('windowsWinAPI32')),
        ('changed-evidence',lambda p:p['evidenceFiles'][0].update(sha256='0'*64)),
        ('unknown-transaction',lambda p:p.update(transaction='not-this-transaction')),
    ]:
        invalid=copy.deepcopy(proof); mutate(invalid); path=work/(name+'.json');install.atomic(path,install.encoded(invalid))
        expect_refusal(lambda:instance.verify(transaction,path));checks['reject-'+name]=True
    assert not (instance.store/'installations'/transaction/'runtime.json').exists()
    checks['synthetic-proof-never-publishes-real-store']=True

    # Use the production adapter with tiny explicitly fake PE/native bytes. This
    # exercises the actual five-role contract, origin preservation and relative
    # capability layout without running or copying a real engine.
    import runtime_install_layout as real_layout
    from test_runtime_install_layout import make_fixture
    work=new_work(parent,'production-adapter-integration')
    original=work/'source';original.mkdir(mode=0o700);configuration=make_fixture(original)
    source_before=install.inventory(original)
    instance=install.Installer(work/'store',work_root=work,fixture=True,layout=real_layout)
    first=instance.plan(configuration)['transaction']; first_status=instance.stage(first)
    receipt=instance.verify(first); assert receipt['staticValidation']['verificationKind']=='derivation-static-v1'
    assert receipt['staticValidation']['candidateTreeFingerprint']==first_status['candidateFingerprintSHA256']
    published=instance.publish(first,receipt['receiptSHA256']); final=Path(published['locationRoot'])
    assert real_layout.validate(final,install.load(instance.directory(first)/'plan.json'))['passed']
    assert install.fingerprint(install.inventory(final,exclude=(install.STAGE_MARKER,)))==first_status['candidateFingerprintSHA256']
    checks['production-adapter-five-role-fixture-publish-and-relocation']=True
    second=instance.plan(configuration)['transaction']
    hidden=work/'original source temporarily absent';original.rename(hidden)
    try:
        offline=instance.stage(second)
        assert offline['state']=='staged'
    finally:hidden.rename(original)
    assert install.inventory(original)==source_before
    checks['production-adapter-raw-object-reuse-with-origin-offline']=True
    current=json.loads((final/'runtime.json').read_bytes())
    assert current['pathFormat']=='runtime-relative-v1'
    assert (final/current['nativeRendererValidationPath']).read_bytes()==(original/'evidence/native-validation.json').read_bytes()
    checks['production-adapter-historical-receipt-byte-preserved']=True

    report={'schema':1,'verificationKind':'fixture-only','fixtureOnly':True,'passed':all(checks.values()),'checks':checks,'checkCount':len(checks),'realSIGKILLBoundaries':crashes,'realRuntimeExecuted':False,'realPayloadCopied':False,'compilerStarted':False,'sourceAndUserConfigurationTouched':False,'binaryDistributionApproved':False,'fixtureRoot':str(parent)}
    output=install.ROOT/'Evidence/runtime-install-transaction-fixtures.json'
    install.atomic(output,install.encoded(report))
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--worker',nargs=5);args=parser.parse_args()
    if args.worker:
        work,transaction,phase,action,receipt=args.worker
        worker(Path(work),transaction,phase,action,receipt)
    else:main()
