#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Small synthetic recipe/staging tests. No real compiler or app publication."""
import json,os
from pathlib import Path
import shutil,subprocess,sys,tempfile
sys.dont_write_bytecode=True
import package_frontend
ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')

def main():
    assert WORK.stat().st_uid==os.getuid()and(WORK/'.ready-external-workspace').is_file()
    run=Path(tempfile.mkdtemp(prefix='hosted-game-packaging-',dir=WORK/'tests'));run.chmod(0o700)
    project=run/'owned-project';(project/'Scripts').mkdir(parents=True)
    recipe=project/'Scripts/build_hosted_game_shim.sh';recipe.write_bytes((ROOT/'Scripts/build_hosted_game_shim.sh').read_bytes())
    files=['LICENSE','LICENSES/LGPL-2.1.txt','THIRD_PARTY_NOTICES.md','README.md','Package.swift','sources.lock.json','StoreBridge/NOTICE','StoreBridge/dependencies.lock.json','Scripts/build_app.sh','Scripts/build_overlay.sh','Scripts/build_session_host.sh','Scripts/package_frontend.py','Scripts/test_frontend_package.py','Scripts/frontend_snapshot.py','Scripts/test_frontend_snapshot.py','Sources/M1Launcher/main.swift','Sources/LauncherCore/Own.swift','Sources/ReadyHostedView/ReadyHostedView.m','Sources/ReadyHostedView/include/ReadyHostedView.h','Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h','NativeEmbedding/ReadyHostedGameShim.m','Build/libReadyOverlay.dylib','Build/ReadySessionHost']
    for name in files:
        p=project/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('Owned synthetic fixture only: '+name+'\n')
    # Deliberate data outside the original-source allowlist must not be copied.
    for name in ['Runtime/runtime.json','Vendor/private-file','NativeEmbedding/UnrelatedLab.m']:
        p=project/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('Excluded fixture\n')
    fakebin=run/'fakebin';fakebin.mkdir();sdk=run/'own-sdk-placeholder';sdk.mkdir();log=run/'commands.jsonl'
    xcrun=fakebin/'xcrun';xcrun.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['FIXTURE_LOG'],'a')as f:f.write(json.dumps({'tool':'xcrun','args':args})+'\\n')
if args==['--show-sdk-path']:print(os.environ['FIXTURE_SDK']);raise SystemExit(0)
if args[0]=='clang':
 Path(args[args.index('-o')+1]).write_text('SYNTHETIC NEVER NATIVE SHIM\\n')
 if os.environ.get('FIXTURE_FAIL')=='source':
  source=Path(args[args.index('-o')-1]);source.write_text(source.read_text()+'changed while compiling\\n')
 raise SystemExit(73 if os.environ.get('FIXTURE_FAIL')=='compile'else 0)
if args[0]=='lipo':
 print('arm64 x86_64');raise SystemExit(74 if os.environ.get('FIXTURE_FAIL')=='arch'else 0)
raise SystemExit(99)
''');xcrun.chmod(0o700)
    codesign=fakebin/'codesign';codesign.write_text('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['FIXTURE_LOG'],'a')as f:f.write(json.dumps({'tool':'codesign','args':sys.argv[1:]})+'\\n')
raise SystemExit(75 if os.environ.get('FIXTURE_FAIL')=='sign'else 0)
''');codesign.chmod(0o700)
    environment=dict(os.environ,PATH=str(fakebin)+':'+os.environ.get('PATH',''),FIXTURE_LOG=str(log),FIXTURE_SDK=str(sdk),TMPDIR=str(WORK/'tmp')+'/',PYTHONDONTWRITEBYTECODE='1')
    binary=project/'Build/libReadyHostedGame.dylib';binary.write_text('OLD IMMUTABLE FIXTURE\n')
    checks={}
    for failure in ['compile','arch','sign','source']:
        old=binary.read_bytes();old_inode=binary.stat().st_ino
        p=subprocess.run(['/bin/sh',str(recipe)],env=dict(environment,FIXTURE_FAIL=failure),capture_output=True,text=True)
        assert p.returncode!=0 and binary.read_bytes()==old and binary.stat().st_ino==old_inode
        assert not list((project/'Build').glob('.ready-hosted-game-build.*'))
        checks[failure+'FailurePreservesPublishedInodeAndCleansOnlyOwnStage']=True
    with binary.open('rb')as old:
        inode=os.fstat(old.fileno()).st_ino
        subprocess.run(['/bin/sh',str(recipe)],env=environment,capture_output=True,text=True,check=True)
        assert binary.stat().st_ino!=inode and old.read()==b'OLD IMMUTABLE FIXTURE\n'and binary.read_text()=='SYNTHETIC NEVER NATIVE SHIM\n'
    checks['verifiedNewInodePublicationPreservesExistingMappings']=True
    records=[json.loads(x)for x in log.read_text().splitlines()]
    compile_args=next(x['args']for x in records if x['tool']=='xcrun'and x['args'][0]=='clang')
    assert all(flag in compile_args for flag in ['-fobjc-arc','-fblocks','-std=gnu11','-dynamiclib','arm64','x86_64','Cocoa','Metal','QuartzCore','IOSurface','CoreGraphics'])
    assert compile_args[compile_args.index('-I')+1]==str(project/'Sources/ReadyHostedView/include')
    assert compile_args[compile_args.index('-install_name')+1]=='@rpath/libReadyHostedGame.dylib'
    assert [x['tool']for x in records[-5:]]==['xcrun','xcrun','xcrun','codesign','codesign']
    checks['universalPublicFrameworkFlagsAndVerifyBeforePublish']=True
    original=package_frontend.ROOT;package_frontend.ROOT=project
    try:
        staged=run/'ReadySupport';package_frontend.stage(staged)
        manifest=json.loads((staged/'frontend-package.json').read_text());names={x['path']for x in manifest['files']}
        expected={'Build/libReadyHostedGame.dylib','NativeEmbedding/ReadyHostedGameShim.m','Scripts/build_hosted_game_shim.sh','Sources/ReadyHostedView/ReadyHostedView.m','Sources/ReadyHostedView/include/ReadyHostedView.h','Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h'}
        assert expected.issubset(names)and not any(name.startswith(('Runtime/','Vendor/'))for name in names)and'NativeEmbedding/UnrelatedLab.m'not in names
        assert not manifest['externalRuntimeIncluded']and not manifest['proprietaryAppleFilesIncluded']and not manifest['wholeApplicationRedistributionApproved']
        checks['ownedHostedSourcesHeadersRecipeAndShimStagedWithoutExternalPayload']=True
        binary.unlink();binary.symlink_to(project/'Build/libReadyOverlay.dylib')
        try:package_frontend.stage(run/'aliased-support')
        except RuntimeError:checks['aliasedNativeShimRejected']=True
        else:raise AssertionError('Linked native shim accepted')
        binary.unlink();binary.write_text('SYNTHETIC NEVER NATIVE SHIM\n')
        outside=run/'outside-source';outside.mkdir();(outside/'ReadyHostedGameShim.m').write_text('Own alias fixture source\n')
        original_embedding=project/'NativeEmbedding';shutil.rmtree(original_embedding);original_embedding.symlink_to(outside,target_is_directory=True)
        try:package_frontend.stage(run/'aliased-source-parent')
        except RuntimeError:checks['sourceParentAliasRejected']=True
        else:raise AssertionError('Linked source parent accepted')
    finally:package_frontend.ROOT=original
    report={'schema':1,'fixtureOnly':True,'passed':all(checks.values()),'count':len(checks),'checks':checks,'realCompilerInvoked':False,'productionBundlePublished':False,'existingAppsModified':False,'fixtureRoot':str(run)}
    path=run/'report.json';path.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
