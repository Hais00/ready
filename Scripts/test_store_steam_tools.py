#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Owned tiny patch/selector/locator fixtures; optional real local helper checks.
No account login, engine mutation, compiler or network dependency in this suite.
"""
import argparse,hashlib,json,os,pathlib,shutil,subprocess,sys,tempfile,uuid
from unittest.mock import patch
sys.dont_write_bytecode=True
import store_steam_tools as tools
ROOT=tools.ROOT
sys.path.insert(0,str(ROOT/'StoreBridge'));import runtime_paths
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')

def refuse(action):
    try:action()
    except (ValueError,OSError):return
    raise AssertionError('Unsafe fixture accepted')
def fake_version(parent,name,payload):
    version=parent/name;(version/'SteamBridge').mkdir(parents=True,mode=0o700)
    p=version/'SteamBridge/ReadySteamBridge.dll';p.write_text(payload);p.chmod(0o444)
    files=tools.inventory(version);tools.write_new(version/'manifest.json',{'schema':1,'kind':'ready-local-steam-tools-v1','version':name,'files':files,'payloadFingerprintSHA256':tools.identity(files),'localOnly':True,'externalReadOnlyDependencies':{},'binaryDistributionApproved':False})
    return version

def main(version=None):
    checks={}
    with tempfile.TemporaryDirectory(prefix='steam-tools-fixture-',dir=WORK/'tests') as raw:
        temp=pathlib.Path(raw);temp.chmod(0o700)
        lock=json.loads((ROOT/'Scripts/steamkit_websocket_close.lock.json').read_text());original=ROOT/'Vendor/steamkit'/lock['path'];before=tools.sha(original)
        vendor=temp/'vendor';target=vendor/lock['path'];target.parent.mkdir(parents=True);shutil.copy2(original,target)
        tools.apply_steamkit_patch(vendor);assert tools.sha(target)==lock['patchedSHA256'];checks['normal-recipe-exact-pinned-source-patch']=True
        tools.apply_steamkit_patch(vendor);checks['verified-patch-idempotent']=True
        target.write_text('unknown edited source');refuse(lambda:tools.apply_steamkit_patch(vendor));assert tools.sha(original)==before;checks['tamper-refused-upstream-preserved']=True
        refuse(lambda:tools.apply_steamkit_patch(ROOT/'Vendor/steamkit'));checks['normal-upstream-never-patched']=True
        first=fake_version(temp,'v1','original owned fake assembly');tools.verify_version(first)
        p=first/'SteamBridge/ReadySteamBridge.dll';saved=p.read_bytes();p.chmod(0o644);p.write_text('changed');refuse(lambda:tools.verify_version(first));p.write_bytes(saved);p.chmod(0o444);checks['manifest-rejects-byte-or-mode-change']=True
        extra=first/'unknown';extra.write_text('keep unknown data');refuse(lambda:tools.verify_version(first));extra.unlink();checks['manifest-rejects-extra-data']=True
        project=temp/'project';base=project/'Runtime/Tools/StoreBridge';base.mkdir(parents=True,mode=0o700)
        fallback=project/'StoreBridge/SteamBridge/bin/Release/net10.0/ReadySteamBridge.dll';fallback.parent.mkdir(parents=True);fallback.write_text('old retained fallback')
        second=fake_version(temp,'v2','new owned fake assembly')
        # This publication is confined to this fresh fixture data root. It never
        # executes the fake payload, seeds an engine, or touches actual user data.
        data=temp/'user-data';data.mkdir(mode=0o700)
        sentinel=data/'runtime.json';sentinel.write_text('unchanged user engine configuration')
        version_before=tools.inventory(first)
        selected=tools.select_user(first,data);selector=data/'Components/StoreBridge/selected.json'
        assert json.loads(selector.read_text())=={'schema':1,'kind':'ready-store-tools-location-v1','toolsRoot':str(first),'manifestSHA256':tools.sha(first/'manifest.json')}
        assert selector.stat().st_mode&0o777==0o600 and selector.parent.stat().st_mode&0o777==0o700
        assert tools.inventory(first)==version_before and sentinel.read_text()=='unchanged user engine configuration'
        checks['user-selection-pins-canonical-version-and-manifest-without-copying-or-engine-mutation']=True
        initial=selector.read_bytes();published=tools.select_user(second,data)
        assert published['previousSelector']==json.loads(initial) and first.is_dir() and second.is_dir()
        checks['user-selection-update-retains-previous-pointer-and-both-versions']=True
        rollback=tools.rollback_user(pathlib.Path(published['historyRecord']),data)
        assert selector.read_bytes()==initial and pathlib.Path(rollback['rollbackRecord']).is_file() and rollback['codeDeleted']is False
        checks['user-rollback-restores-reviewed-pointer-with-a-durable-marker']=True
        state_before=tools.inventory(data)
        refuse(lambda:tools.rollback_user(pathlib.Path(published['historyRecord']),data))
        assert tools.inventory(data)==state_before;checks['stale-user-rollback-refused-without-mutation']=True
        tools.rollback_user(pathlib.Path(selected['historyRecord']),data)
        assert not selector.exists() and first.is_dir() and second.is_dir()
        checks['first-user-selection-rollback-archives-selector-without-removing-code']=True

        dependency=temp/'external-dependency';dependency.mkdir(mode=0o700)
        payload=dependency/'fixture.bin';payload.write_bytes(b'private controlled dependency')
        aliased=fake_version(temp,'v3','owned controlled alias version')
        (aliased/'venv').symlink_to(dependency,target_is_directory=True)
        manifest=json.loads((aliased/'manifest.json').read_text());manifest['files']=tools.inventory(aliased);manifest['files'].pop('manifest.json')
        manifest['payloadFingerprintSHA256']=tools.identity(manifest['files'])
        manifest['externalReadOnlyDependencies']={'venv':{'path':str(dependency),'inventorySHA256':tools.identity(tools.inventory(dependency)),'readOnlyUseContract':True,'portable':False}}
        (aliased/'manifest.json').write_bytes(tools.encoded(manifest));tools.verify_user_version(aliased)
        alias_selection=tools.select_user(aliased,data);current=tools.inventory(data)
        payload.write_bytes(b'changed external payload')
        refuse(lambda:tools.select_user(second,data));refuse(lambda:tools.select_user(aliased,data))
        assert tools.inventory(data)==current;checks['external-payload-change-fails-closed-with-user-state-unchanged']=True
        payload.write_bytes(b'private controlled dependency')
        original_link=os.readlink(aliased/'venv');(aliased/'venv').unlink();(aliased/'venv').symlink_to(first,target_is_directory=True)
        refuse(lambda:tools.select_user(aliased,data));assert tools.inventory(data)==current
        (aliased/'venv').unlink();(aliased/'venv').symlink_to(original_link,target_is_directory=True)
        checks['external-alias-target-change-refused-before-publication']=True

        unsafe=temp/'unsafe-user-data';unsafe.mkdir(mode=0o755)
        unsafe_before=tools.inventory(unsafe);refuse(lambda:tools.select_user(first,unsafe));assert tools.inventory(unsafe)==unsafe_before
        unsafe.chmod(0o700);(unsafe/'Components').symlink_to(data/'Components',target_is_directory=True)
        current=tools.inventory(data);refuse(lambda:tools.select_user(first,unsafe));assert tools.inventory(data)==current
        checks['unsafe-root-mode-or-aliased-component-never-mutated']=True
        pointer_backup=selector.read_bytes();selector.chmod(0o644)
        refuse(lambda:tools.select_user(second,data));assert selector.read_bytes()==pointer_backup;selector.chmod(0o600)
        selector.unlink();selector.symlink_to(temp/'unknown-selector.json');current=tools.inventory(data)
        refuse(lambda:tools.select_user(second,data));assert tools.inventory(data)==current;selector.unlink();tools.write_new(selector,json.loads(pointer_backup))
        checks['unsafe-existing-selector-mode-or-alias-refused']=True
        selected_manifest=aliased/'manifest.json';old_manifest=selected_manifest.read_bytes()
        changed=json.loads(old_manifest);changed['localOnly']=False;selected_manifest.write_bytes(tools.encoded(changed));current=tools.inventory(data)
        refuse(lambda:tools.select_user(aliased,data));assert tools.inventory(data)==current
        selected_manifest.write_bytes(old_manifest);checks['non-local-version-cannot-be-selected']=True
        changed=json.loads(old_manifest);changed['binaryDistributionApproved']=True;selected_manifest.write_bytes(tools.encoded(changed));current=tools.inventory(data)
        refuse(lambda:tools.select_user(aliased,data));assert tools.inventory(data)==current
        selected_manifest.write_bytes(old_manifest);checks['distribution-approved-flag-cannot-be-inferred-or-accepted']=True
        changed=json.loads(old_manifest);changed['extraUnreviewedManifestField']='changed';selected_manifest.write_bytes(tools.encoded(changed));current=tools.inventory(data)
        refuse(lambda:tools.select_user(second,data));assert tools.inventory(data)==current
        selected_manifest.write_bytes(old_manifest);checks['previous-selector-manifest-pin-mismatch-preserves-user-state']=True
        hardlink=temp/'selector-hardlink';os.link(selector,hardlink);current=tools.inventory(data)
        refuse(lambda:tools.select_user(second,data));assert tools.inventory(data)==current;hardlink.unlink()
        checks['hardlinked-user-selector-refused-without-changing-either-link']=True
        current=tools.inventory(data);version_alias=temp/'version-alias';version_alias.symlink_to(first,target_is_directory=True)
        refuse(lambda:tools.select_user(version_alias,data));assert tools.inventory(data)==current
        checks['aliased-version-root-never-published']=True
        original_pin=selector.read_bytes();wrong_pin=json.loads(original_pin);wrong_pin['manifestSHA256']='0'*64
        selector.write_bytes(tools.encoded(wrong_pin));current=tools.inventory(data)
        refuse(lambda:tools.select_user(second,data));assert tools.inventory(data)==current;selector.write_bytes(original_pin)
        checks['existing-selector-pin-mismatch-never-overwritten']=True
        undeclared=fake_version(temp,'undeclared','controlled fixture with escaped link');(undeclared/'external').symlink_to('../external-dependency',target_is_directory=True)
        undeclared_manifest=json.loads((undeclared/'manifest.json').read_text());undeclared_manifest['files']=tools.inventory(undeclared);undeclared_manifest['files'].pop('manifest.json')
        undeclared_manifest['payloadFingerprintSHA256']=tools.identity(undeclared_manifest['files']);(undeclared/'manifest.json').write_bytes(tools.encoded(undeclared_manifest))
        current=tools.inventory(data);refuse(lambda:tools.select_user(undeclared,data));assert tools.inventory(data)==current
        checks['undeclared-relative-external-alias-refused']=True
        untouched=temp/'untouched-user-data';untouched.mkdir(mode=0o700);current=tools.inventory(untouched)
        extra=second/'extra';extra.write_text('unreviewed tool payload')
        refuse(lambda:tools.select_user(second,untouched));assert tools.inventory(untouched)==current and not (untouched/'Components').exists();extra.unlink()
        checks['invalid-version-fails-before-creating-user-component-directories']=True
        cli_data=temp/'cli-data';cli_data.mkdir(mode=0o700)
        cli=subprocess.run([sys.executable,str(ROOT/'Scripts/store_steam_tools.py'),'--select-user','--state-root',str(cli_data),'--version-root',str(first)],capture_output=True,text=True,check=True)
        assert json.loads(cli.stdout)['selected']['toolsRoot']==str(first);checks['explicit-user-selection-cli-operates-only-on-given-fixture-root']=True
        cli_before=tools.inventory(cli_data)
        invalid_cli=subprocess.run([sys.executable,str(ROOT/'Scripts/store_steam_tools.py'),'--select-user','--state-root',str(cli_data),'--version-root',str(first),'verify',str(first)],capture_output=True,text=True)
        assert invalid_cli.returncode==2 and tools.inventory(cli_data)==cli_before;checks['user-cli-rejects-mixed-operations-before-mutation']=True
        with patch.object(tools,'ROOT',project),patch.object(runtime_paths,'CODE_ROOT',project),patch.object(runtime_paths,'BUNDLED',False),patch.dict(os.environ,{'READY_RUNTIME_ROOT':str(project/'Runtime')},clear=True):
            old=runtime_paths.tool_payload('SteamBridge/ReadySteamBridge.dll','StoreBridge/SteamBridge/bin/Release/net10.0/ReadySteamBridge.dll');assert old==fallback
            selection=tools.select_project(first);assert (base/'SteamBridge').is_symlink();checks['first-canonical-selection-atomic-link']=True
            pinned=runtime_paths.tool_payload('SteamBridge/ReadySteamBridge.dll','StoreBridge/SteamBridge/bin/Release/net10.0/ReadySteamBridge.dll');assert pinned==first/'SteamBridge/ReadySteamBridge.dll'
            selection=tools.select_project(second);assert selection['previousTarget']==str(first/'SteamBridge') and pinned.read_bytes()==saved;checks['selected-version-pinned-before-sibling-resolution']=True
            assert fallback.read_text()=='old retained fallback' and first.is_dir();checks['previous-code-and-fallback-retained']=True
            latest=next(p for p in (base/'SteamBridgeSelectionHistory').glob('*.json') if json.loads(p.read_text()).get('target')==str(second/'SteamBridge'))
            restored=tools.rollback_project(latest);assert restored['restoredTarget']==str(first/'SteamBridge') and second.is_dir();checks['rollback-restores-reviewed-prior-version-without-deleting-code']=True
            os.environ['READY_STORE_TOOLS_ROOT']=str(first)
            assert runtime_paths.tools_root()==first and runtime_paths.tool_payload('SteamBridge/ReadySteamBridge.dll','unavailable')==first/'SteamBridge/ReadySteamBridge.dll';checks['explicit-tools-root-independent-of-engine']=True
            missing=temp/'missing-tools';os.environ['READY_STORE_TOOLS_ROOT']=str(missing)
            assert runtime_paths.tool_payload('SteamBridge/ReadySteamBridge.dll',str(fallback.relative_to(project)))==missing/'SteamBridge/ReadySteamBridge.dll';checks['explicit-missing-root-never-old-fallback']=True
            os.environ['READY_STORE_TOOLS_ROOT']='relative';refuse(runtime_paths.tools_root);checks['relative-tools-root-refused']=True
            alias=temp/'alias';alias.symlink_to(first,target_is_directory=True);os.environ['READY_STORE_TOOLS_ROOT']=str(alias);refuse(runtime_paths.tools_root);checks['aliased-tools-root-refused']=True
            # Unknown existing canonical directory is never moved or deleted.
            (base/'SteamBridge').unlink();(base/'SteamBridge').mkdir();(base/'SteamBridge/user-file').write_text('preserve')
            refuse(lambda:tools.select_project(first));assert (base/'SteamBridge/user-file').read_text()=='preserve';checks['unknown-canonical-data-preserved']=True
        if version:
            version=pathlib.Path(version);manifest=tools.verify_version(version);checks['actual-version-full-manifest-verified']=True
            root_data=temp/'isolated-data';root_data.mkdir(mode=0o700)
            environment={k:v for k,v in os.environ.items() if not k.startswith(('READY_','DYLD_','STEAM','Steam','SB_'))}
            environment.update(READY_STORE_TOOLS_ROOT=str(version),READY_RUNTIME_ROOT=str(temp/'unavailable-engines'),READY_DATA_ROOT=str(root_data),PYTHONDONTWRITEBYTECODE='1',TMPDIR=str(WORK/'tmp')+'/')
            command=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)','/usr/bin/env','python3',str(ROOT/'StoreBridge/bridge.py')]
            request={'operation':'authorize_game','store':'steam','profileID':str(uuid.uuid4()),'credentials':{},'options':{'gameID':'0'}}
            result=subprocess.run(command,input=json.dumps(request)+'\n',env=environment,capture_output=True,text=True,timeout=30)
            lines=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            assert len(lines)==1 and lines[0].get('type')=='error' and lines[0].get('code')=='invalid_game_id';checks['actual-bridge-uses-corrected-central-helper-without-engine-root']=True
            assert not (temp/'unavailable-engines').exists();checks['engine-root-never-seeded-or-edited']=True
    report={'schema':1,'fixtureOnly':True,'passed':all(checks.values()),'checks':checks,'checkCount':len(checks),'realAuthenticationAttempted':False,'normalSourceBuildTestedSeparately':True,'testSourceSHA256':tools.sha(pathlib.Path(__file__))}
    (ROOT/'Evidence/store-steam-tools-fixtures.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--version',type=pathlib.Path);a=p.parse_args();main(a.version)
