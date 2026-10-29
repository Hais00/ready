#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real splash view, own hidden window and synthetic HTTPS images; no activation/game/login.
Uses the exact PRIVATE Core product from the verified library UI fixture."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--core-root',type=pathlib.Path);args=parser.parse_args()
 if args.core_root:
  core=args.core_root.resolve();receipt=core/'core-build.json';provenance=json.loads(receipt.read_text())
  assert core.is_relative_to(WORK/'tests')and sha(core/'libLauncherCore.dylib')==provenance['librarySHA256']and sha(core/'LauncherCore.swiftmodule')==provenance['moduleSHA256']
 else:
  pointer=json.loads((ROOT/'Evidence/library-detail-ui-tests.json').read_text());receipt=pathlib.Path(pointer['retainedReport'])
  assert receipt.is_relative_to(WORK/'tests')and sha(receipt)==pointer['retainedReportSHA256']
  core=receipt.parent;provenance=json.loads(receipt.read_text())
 for name,digest in provenance['sourceHashes'].items():
  if name.startswith('Sources/LauncherCore/'):assert sha(ROOT/name)==digest
 assert (core/'LauncherCore.swiftmodule').is_file()and(core/'libLauncherCore.dylib').is_file()
 run=pathlib.Path(tempfile.mkdtemp(prefix='launch-splash-ui-',dir=WORK/'tests'));run.chmod(0o700)
 files=[ROOT/'Sources/M1Launcher/GameLaunchSplash.swift',ROOT/'Sources/M1Launcher/ArtworkCache.swift',ROOT/'Synthetic/ReadyLaunchSplashProbe.swift',ROOT/'Sources/M1Launcher/GameArtwork.swift',ROOT/'Sources/M1Launcher/ArtworkIndexStore.swift',ROOT/'Synthetic/ReadySplashAnimationObserver.m',ROOT/'Synthetic/ReadySplashAnimationObserver.h',pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','MTL_HUD_','RHG_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/launch-splash-swift'))
 (run/'module.modulemap').write_text('module SplashAnimationObserver { header '+json.dumps(str(ROOT/'Synthetic/ReadySplashAnimationObserver.h'))+' export * }\n')
 observer=subprocess.run(['xcrun','clang','-fobjc-arc','-c',str(ROOT/'Synthetic/ReadySplashAnimationObserver.m'),'-o',str(run/'observer.o')],capture_output=True,text=True);assert observer.returncode==0,observer.stderr
 command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/hosted-controller-typecheck'),'-I',str(core),str(files[0]),str(files[1]),str(files[2]),str(files[3]),str(ROOT/'Sources/M1Launcher/ArtworkIndexStore.swift'),'-Xcc','-fmodule-map-file='+str(run/'module.modulemap'),str(run/'observer.o'),'-L',str(core),'-lLauncherCore','-Xlinker','-rpath','-Xlinker',str(core),'-framework','AppKit','-framework','QuartzCore','-o',str(run/'probe')]
 p=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Owned splash fixture compile failed: '+str(run/'build.log'))
 p=subprocess.run([str(run/'probe'),str(run)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20);(run/'probe.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Owned splash fixture failed: '+str(run/'probe.log'))
 result=json.loads(p.stdout);assert result['passed']and before=={str(p.relative_to(ROOT)):sha(p)for p in files}
 result.update(sourceHashes=before,privateCoreReceiptSHA256=sha(receipt),privateCoreLibrarySHA256=sha(core/'libLauncherCore.dylib'),privateCoreModuleSHA256=sha(core/'LauncherCore.swiftmodule'))
 out=run/'report.json';out.write_text(json.dumps(result,indent=2)+'\n');out.chmod(0o600)
 summary={'passed':True,'count':result['count'],'retainedReport':str(out),'retainedReportSHA256':sha(out),'sourceHashes':before,'previewRoot':str(run),'fixtureOnly':True,'continuousOnScreenAnimationVerified':False,'ownHiddenWindowCreated':True,'windowActivated':False,'externalNetworkUsed':False,'accountsKeychainGamesOrBenchmarkUsed':False}
 (ROOT/'Evidence/launch-splash-ui-tests.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
