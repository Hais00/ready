#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Render an explicit private library COPY; never open the original user root.
No auth/Keychain/process launch callbacks. Screenshots and raw report stay Dati.
Public artwork network is opt-in and writes only to an owned cache COPY."""
import argparse,hashlib,json,os,pathlib,re,shutil,stat,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def private_file(path):
 if not path.is_absolute()or path.resolve(strict=True)!=path:raise ValueError('Canonical private copy required')
 s=path.lstat()
 if s.st_uid!=os.getuid()or not stat.S_ISREG(s.st_mode)or s.st_mode&0o077:raise ValueError('Owned private regular file required')
 for parent in path.parents:
  if parent==WORK:break
  if parent.lstat().st_uid!=os.getuid()or parent.lstat().st_mode&0o077:raise ValueError('Private copy ancestors required')
 return s

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--library-copy',type=pathlib.Path,required=True);parser.add_argument('--library-sha256',required=True);parser.add_argument('--artwork-cache',type=pathlib.Path,required=True);parser.add_argument('--detail-store-id',required=True);parser.add_argument('--expected-count',type=int,default=495);parser.add_argument('--allow-public-artwork',action='store_true');parser.add_argument('--detail-artwork-only',action='store_true');a=parser.parse_args()
 if not re.fullmatch('[0-9a-f]{64}',a.library_sha256)or not a.detail_store_id.isdecimal()or not 1<=a.expected_count<=30000:raise ValueError('Invalid bounded copy-render arguments')
 if not a.library_copy.is_relative_to(WORK/'tests'):raise ValueError('Only explicitly retained private test COPY accepted')
 original=private_file(a.library_copy);assert sha(a.library_copy)==a.library_sha256
 cache=a.artwork_cache
 if cache.resolve(strict=True)!=cache or cache.stat().st_uid!=os.getuid()or cache.stat().st_mode&0o077 or not cache.is_dir():raise ValueError('Owned canonical private artwork cache required')
 pointer=json.loads((ROOT/'Evidence/library-detail-ui-tests.json').read_text());receipt=pathlib.Path(pointer['retainedReport']);assert receipt.is_relative_to(WORK/'tests')and sha(receipt)==pointer['retainedReportSHA256']
 core=receipt.parent;provenance=json.loads(receipt.read_text())
 for name,digest in provenance['sourceHashes'].items():
  if name.startswith('Sources/LauncherCore/'):assert sha(ROOT/name)==digest
 assert (core/'LauncherCore.swiftmodule').is_file()and(core/'libLauncherCore.dylib').is_file()
 run=pathlib.Path(tempfile.mkdtemp(prefix='library-copy-render-',dir=WORK/'tests'));run.chmod(0o700)
 if a.allow_public_artwork:
  # Never hand a writable original artwork location to the network cache.
  overlay=run/'artwork-copy';overlay.mkdir(mode=0o700);total=0
  for file in sorted(cache.iterdir()):
   s=file.lstat()
   if not(file.suffix=='.png'and re.fullmatch('[0-9a-f]{64}',file.stem))or not stat.S_ISREG(s.st_mode)or s.st_uid!=os.getuid()or s.st_mode&0o077 or s.st_size>10_000_000:continue
   if total+s.st_size>256*1024*1024:break
   shutil.copyfile(file,overlay/file.name);(overlay/file.name).chmod(0o600);total+=s.st_size
  cache=overlay
  if a.detail_artwork_only:
   # Refresh only these two files in this invocation's OWN overlay. The source
   # cache stays read-only; stale low-resolution thumbnails cannot satisfy proof.
   for name in ['library_600x900.jpg','library_hero.jpg']:
    address='https://cdn.akamai.steamstatic.com/steam/apps/'+a.detail_store_id+'/'+name
    (overlay/(hashlib.sha256(('1024:'+address).encode()).hexdigest()+'.png')).unlink(missing_ok=True)
 config={'libraryCopy':str(a.library_copy),'librarySHA256':a.library_sha256,'output':str(run),'artworkCache':str(cache),'detailStoreID':a.detail_store_id,'expectedCount':a.expected_count,'allowPublicArtwork':a.allow_public_artwork,'detailArtworkOnly':a.detail_artwork_only}
 config_path=run/'private-config.json';config_path.write_text(json.dumps(config)+'\n');config_path.chmod(0o600)
 names=['CanvasDrawing.swift','ControllerNavigation.swift','LibraryEntryPresentation.swift','ArtworkIndexStore.swift','CanvasShellRenderer.swift','LibraryGridSurface.swift','GameArtwork.swift','ArtworkCache.swift','ReadyShellModel.swift','MetalCanvas.swift','GameDetailView.swift']
 files=[*[ROOT/'Sources/M1Launcher'/n for n in names],ROOT/'Synthetic/ReadyLibraryCopyPreview.swift',pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 jobs=(ROOT/'Sources/M1Launcher/SteamDownloads.swift').read_text().split('@MainActor\nfinal class SteamDownloads',1)[0]
 (run/'Definitions.swift').write_text(jobs+'\nimport AppKit\nprotocol ReadyDialogContentSizing {var maximumViewportHeight:CGFloat{get}}\nextension Notification.Name{static let readyDialogContentLayoutChanged=Notification.Name("ready.dialog.content-layout-changed")}\n')
 env={k:v for k,v in os.environ.items()if k in ['PATH','HOME','USER','LOGNAME','LANG','LC_ALL','DEVELOPER_DIR']};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/library-copy-render'))
 command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/hosted-controller-typecheck'),'-I',str(core),str(run/'Definitions.swift'),*[str(ROOT/'Sources/M1Launcher'/n)for n in names],str(ROOT/'Synthetic/ReadyLibraryCopyPreview.swift'),'-L',str(core),'-lLauncherCore','-Xlinker','-rpath','-Xlinker',str(core),'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',str(run/'probe')]
 p=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Owned copy renderer compile failed; private build log retained at '+str(run/'build.log'))
 p=subprocess.run([str(run/'probe'),str(config_path)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=50);(run/'private-stdout.log').write_text(p.stdout);(run/'private-stderr.log').write_text(p.stderr)
 for log in ['build.log','private-stdout.log','private-stderr.log']:(run/log).chmod(0o600)
 if p.returncode:raise RuntimeError('Owned copy renderer failed; private diagnostics retained at '+str(run))
 result=json.loads(p.stdout);assert result['passed']and before=={str(p.relative_to(ROOT)):sha(p)for p in files}
 after=private_file(a.library_copy);assert sha(a.library_copy)==a.library_sha256 and (original.st_dev,original.st_ino,original.st_mode)==(after.st_dev,after.st_ino,after.st_mode)
 result.update(sourceHashes=before,privateCoreReceiptSHA256=sha(receipt),privateCoreLibrarySHA256=sha(core/'libLauncherCore.dylib'),privateCoreModuleSHA256=sha(core/'LauncherCore.swiftmodule'),previewRoot=str(run),originalArtworkCacheWritten=False)
 report=run/'report.private.json';report.write_text(json.dumps(result,indent=2)+'\n');report.chmod(0o600)
 # Summary intentionally excludes every account/profile/game identity and title.
 summary={'passed':True,'count':result['count'],'actualModelCopy':True,'activeProfileVisibleCount':result['activeProfileVisibleCount'],'steamFilterVisibleCount':result['steamFilterVisibleCount'],'inputCopySHA256':a.library_sha256,'retainedReport':str(report),'retainedReportSHA256':sha(report),'previewRoot':str(run),'captures':result['captures'],'publicArtworkNetworkEnabled':a.allow_public_artwork,'publicNetworkRestrictedToTwoDetailAssets':a.detail_artwork_only,'portraitPosterDecoded':result['portraitPosterDecoded'],'posterDecodedPixels':result['posterDecodedPixels'],'bannerArtworkDecoded':result['bannerArtworkDecoded'],'bannerDecodedPixels':result['bannerDecodedPixels'],'accountLoginPerformed':False,'KeychainReadOrWrite':False,'gameOrSteamSDKExecuted':False,'windowActivated':False,'userDataBytesModified':False}
 (ROOT/'Evidence/library-copy-render.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
