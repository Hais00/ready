#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own component fixtures; genuine external files may be HASHED, never executed."""
import argparse,json,os,shutil,sys,tempfile
from pathlib import Path
from unittest import mock
sys.dont_write_bytecode=True
import steam_native_component as component
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
CLIENT=Path('/Users/jasonpolizzi/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib')
SDK=Path('/Volumes/Dati APFS/SteamLibrary/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app/Contents/Frameworks/libsteam_api.dylib')
def sha(p):return component.digest(Path(p).read_bytes())
def expect_failure(action):
    try:action()
    except(Exception):return True
    raise AssertionError('Expected fail-closed rejection')
def snapshot(root):
    return {str(p.relative_to(root)):('link',os.readlink(p))if p.is_symlink()else('file',sha(p))for p in root.rglob('*')if p.is_symlink()or p.is_file()}
def mutable_copy(source,destination):
    shutil.copytree(source,destination)
    for p in [destination,*destination.rglob('*')]:
        if p.is_dir():p.chmod(0o700)
    return destination

def overwrite(path,data):
    mode=path.stat().st_mode&0o777
    path.chmod(mode|0o200)
    try:path.write_bytes(data)
    finally:path.chmod(mode)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--unit-only',action='store_true');parser.add_argument('--client',type=Path,default=CLIENT);parser.add_argument('--sdk',type=Path,default=SDK);a=parser.parse_args()
    component.workspace(WORK)
    run=Path(tempfile.mkdtemp(prefix='steam-native-component-',dir=WORK/'tests'));run.chmod(0o700)
    workspace=run/'workspace';workspace.mkdir(mode=0o700)
    marker=workspace/'.ready-external-workspace';marker.write_text(component.WORKSPACE_MARKER+'\n');marker.chmod(0o600)
    before_sources=component.source_capture();checks={}
    alias=run/'workspace-alias';alias.symlink_to(workspace)
    checks['workspaceAliasRejected']=expect_failure(lambda:component.prepare(alias,alias/'store'))
    marker.write_text('not our workspace');checks['wrongWorkspaceMarkerRejected']=expect_failure(lambda:component.workspace(workspace));marker.write_text(component.WORKSPACE_MARKER)
    workspace.chmod(0o755);checks['nonprivateWorkspaceRejected']=expect_failure(lambda:component.workspace(workspace));workspace.chmod(0o700)
    source=run/'private-source';source.mkdir(mode=0o700);(source/'one').write_bytes(b'first');captured={'one':b'first'};component.assert_sources(captured,source);(source/'one').write_bytes(b'second');checks['sourceChangeDetectedBeforePublication']=expect_failure(lambda:component.assert_sources(captured,source))
    left=run/'exclusive-source';left.mkdir(mode=0o700);right=run/'exclusive-existing';right.mkdir(mode=0o700);(right/'retained').write_bytes(b'never overwrite')
    checks['exclusivePublishNeverOverwritesVersion']=expect_failure(lambda:component.publish_directory(left,right));assert(left.is_dir()and(right/'retained').read_bytes()==b'never overwrite')
    bad_client=run/'steamclient.dylib';bad_client.write_bytes(b'not a genuine library');checks['arbitraryExternalImageRejected']=expect_failure(lambda:component.external_asset(bad_client,component.CLIENT_SHA,'steamclient.dylib'))
    checks['relativeManifestEscapeRejected']=expect_failure(lambda:component.relative_manifest(workspace,'versions/../escape/binding.json'))
    for value in ('0','-1','01','4294967296',True):checks['invalidAppID-'+str(value)]=expect_failure(lambda value=value:component.game_id(value))
    if not a.unit_only:
        result=component.prepare(workspace,workspace/'store');root=Path(result['componentRoot']);doc=component.verify_component(root);original=snapshot(root)
        assert doc['fixtureOnly']is False and doc['localOnly']and not doc['binaryDistributionApproved'];assert set(doc['assets'])==set(component.ROLES)
        assert not any(p.is_symlink()for p in root.rglob('*'));assert all(r['sha256']not in (component.CLIENT_SHA,component.SDK_SHA)for r in doc['inventory'].values());checks['ownOnlyRealComponentBuiltAndVerified']=True
        reused=component.prepare(workspace,workspace/'store');assert reused['reused']and reused['componentRoot']==str(root)and snapshot(root)==original;checks['sameSourcesReuseImmutableVersion']=True
        # Failure after actual compilation must never create a published version.
        with mock.patch.object(component,'assert_sources',side_effect=component.ComponentError('private injected source-change decision')):
            checks['failedBuildNeverPublishesOrSelects']=expect_failure(lambda:component.prepare(workspace,workspace/'failed-store'))
        assert not list((workspace/'failed-store/versions').iterdir())
        for case in ('binary','source','extra','alias','missing','fixture-label','role-escape'):
            copy=mutable_copy(root,workspace/('tampered-'+case));component.verify_component(copy)
            if case=='binary':p=copy/doc['assets']['host']['path'];overwrite(p,p.read_bytes()+b'changed')
            elif case=='source':p=copy/'sources/Scripts/steam_native_state_fs.c';overwrite(p,p.read_bytes()+b'\n/* changed */\n')
            elif case=='extra':(copy/'unknown-payload').write_bytes(b'unknown')
            elif case=='alias':p=copy/doc['assets']['fsAdapter']['path'];p.unlink();p.symlink_to(bad_client)
            elif case=='missing':(copy/doc['assets']['sdkProbe']['path']).unlink()
            else:
                m=copy/'component.json';v=json.loads(m.read_text())
                if case=='fixture-label':v['fixtureOnly']=True
                else:v['assets']['host']['path']='../outside'
                overwrite(m,component.encoded(v))
            checks['componentTamper-'+case]=expect_failure(lambda copy=copy:component.verify_component(copy))
        external_before={str(p):sha(p)for p in (a.client,a.sdk)}
        state=workspace/'scratch-state';state.mkdir(mode=0o700)
        rejected=workspace/'rejected-state';rejected.mkdir(mode=0o700)
        checks['badExternalDoesNotCreateStateMarker']=expect_failure(lambda:component.bind_game(root,bad_client,a.sdk,1091500,rejected));assert not(rejected/'.ready-steam-native-component-state').exists()
        bound=component.bind_game(root,a.client,a.sdk,1091500,state);selection=Path(bound['selection']);old_selection=selection.read_bytes();b1=Path(bound['binding']);assert component.verify_binding(b1)['genuineSDKInteropVerified']is False
        checks['genuineImagesReferencedOnlyInScratchBinding']=True
        # Move/copy our OWN bytes only; no proprietary binary is copied.
        relocated=workspace/'relocated';relocated.mkdir(mode=0o700);second=relocated/root.name;shutil.copytree(root,second);component.verify_component(second)
        bound2=component.bind_game(second,a.client,a.sdk,1091500,state);b2=Path(bound2['binding']);assert b1!=b2 and b1.exists()
        histories=list(selection.parent.joinpath('history').glob('*.json'));assert any(p.read_bytes()==old_selection for p in histories);checks['selectionHistoryByteExactAndVersionsRetained']=True
        restored=component.rollback(state,1091500,b1.parent.name);assert Path(restored['binding'])==b1 and selection.read_bytes()==old_selection;checks['rollbackRevalidatesAndRestoresPriorBinding']=True
        # Tamper an old version's own payload. Rollback must reject, preserve
        # the current selector, and never silently fall back to legacy tools.
        target=second/doc['assets']['lookupAdapter']['path'];overwrite(target,target.read_bytes()+b'changed')
        checks['rollbackTamperedComponentRejected']=expect_failure(lambda:component.rollback(state,1091500,b2.parent.name));assert selection.read_bytes()==old_selection
        other=workspace/'outside-state-target';other.mkdir(mode=0o700);(other/'sentinel').write_bytes(b'untouched');outside_before=snapshot(other)
        aliased_state=workspace/'aliased-state';aliased_state.mkdir(mode=0o700);(aliased_state/'Components').symlink_to(other)
        checks['stateAliasRejectedWithoutExternalWrites']=expect_failure(lambda:component.bind_game(root,a.client,a.sdk,1091500,aliased_state));assert snapshot(other)==outside_before and not(aliased_state/'.ready-steam-native-component-state').exists()
        assert external_before=={str(p):sha(p)for p in (a.client,a.sdk)};assert snapshot(root)==original;checks['externalReferencesAndOriginalComponentBytesUnchanged']=True
    component.assert_sources(before_sources)
    report={'schema':1,'kind':'steam-native-component-local-fixtures','passed':all(checks.values()),'count':len(checks),'checks':checks,'unitOnly':a.unit_only,'ValveOrSDKExecuted':False,'realAccountUsed':False,'actualUserSelectorChanged':False,'runRoot':str(run),'installerSHA256':sha(Path(component.__file__)),'testSHA256':sha(Path(__file__))}
    if not a.unit_only:report.update(component=result,scratchBinding=bound,componentManifestSHA256=sha(root/'component.json'))
    p=run/'report.json';p.write_bytes(component.encoded(report));p.chmod(0o600);print(json.dumps({'passed':True,'count':len(checks),'report':str(p),'reportSHA256':sha(p),'component':report.get('component')}))
if __name__=='__main__':main()
