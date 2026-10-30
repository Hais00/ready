#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual native grid UI profiling/parity, explicit data COPY and owned cache COPY.
No global SwiftPM build, app activation, credentials, games or external network."""
import argparse,hashlib,json,os,pathlib,shutil,stat,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
COPY=WORK/'tests/ready-owned-model-4pvpjaj4/library-copy.private.json'
COPY_SHA='3c6d0e39a30b2cca2b58cbc6986718cd52c0ef09d93366c4241e29231875c87b'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--core-root",type=pathlib.Path);args=parser.parse_args()
 assert COPY.resolve(strict=True)==COPY and COPY.stat().st_uid==os.getuid()and sha(COPY)==COPY_SHA
 run=pathlib.Path(tempfile.mkdtemp(prefix='library-scroll-ui-',dir=WORK/'tests'));run.chmod(0o700)
 source_cache=pathlib.Path('/Volumes/Dati APFS/Ready Cache/Artwork');cache=run/'artwork-copy';cache.mkdir(mode=0o700);copied=0
 for directory,dirs,files in os.walk(source_cache,followlinks=False):
  base=pathlib.Path(directory);dirs[:]=[d for d in dirs if not(base/d).is_symlink()]
  target=cache/base.relative_to(source_cache);target.mkdir(mode=0o700,exist_ok=True)
  for name in files:
   p=base/name;s=p.lstat()
   if not stat.S_ISREG(s.st_mode)or s.st_uid!=os.getuid()or s.st_size>16*1024*1024 or copied+s.st_size>768*1024*1024:continue
   shutil.copyfile(p,target/name);(target/name).chmod(0o600);copied+=s.st_size
 config={'libraryCopy':str(COPY),'librarySHA256':COPY_SHA,'artworkCache':str(cache),'output':str(run),'expectedCount':495}
 (run/'config.json').write_text(json.dumps(config)+'\n');(run/'config.json').chmod(0o600)
 names=['CanvasDrawing.swift','ControllerNavigation.swift','LibraryEntryPresentation.swift','GameArtwork.swift','ArtworkIndexStore.swift','ArtworkCache.swift','CanvasShellRenderer.swift','LibraryGridSurface.swift','ReadyShellModel.swift','MetalCanvas.swift']
 core=sorted((ROOT/'Sources/LauncherCore').glob('*.swift'));files=[*[ROOT/'Sources/M1Launcher'/n for n in names],ROOT/'Synthetic/ReadyLibraryScrollProbe.swift',pathlib.Path(__file__).resolve()]
 before={str(p.relative_to(ROOT)):sha(p)for p in core+files}
 env={k:v for k,v in os.environ.items()if k in ['PATH','HOME','USER','LOGNAME','LANG','LC_ALL','DEVELOPER_DIR']};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/library-scroll-swift'))
 logs=[]
 def call(command,timeout=120):
  p=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout);logs.append(p.stdout+p.stderr);(run/'build.log').write_text('\n'.join(logs))
  if p.returncode:raise RuntimeError('Owned UI scroll fixture failed; '+str(run/'build.log'))
  return p
 swift=['xcrun','swiftc','-swift-version','5','-module-cache-path',WORK/'cache/hosted-controller-typecheck']
 if args.core_root:
  product=args.core_root.resolve(strict=True);bound=json.loads((product/'core-build.json').read_text());assert all(sha(ROOT/name)==digest for name,digest in bound['sourceHashes'].items());assert sha(product/'libLauncherCore.dylib')==bound['librarySHA256']and sha(product/'LauncherCore.swiftmodule')==bound['moduleSHA256']
  for filename in ['LauncherCore.swiftmodule','libLauncherCore.dylib']:shutil.copyfile(product/filename,run/filename)
 else:call(swift+['-emit-library','-emit-module','-module-name','LauncherCore',*core,'-emit-module-path',run/'LauncherCore.swiftmodule','-o',run/'libLauncherCore.dylib'])
 core_receipt={'sourceHashes':{str(p.relative_to(ROOT)):sha(p)for p in core},'products':str(run),'librarySHA256':sha(run/'libLauncherCore.dylib'),'moduleSHA256':sha(run/'LauncherCore.swiftmodule')}
 (run/'core-build.json').write_text(json.dumps(core_receipt,indent=2)+'\n');print(json.dumps({'privateCoreProducts':str(run),'receipt':str(run/'core-build.json'),'receiptSHA256':sha(run/'core-build.json')}),flush=True)
 call(swift+['-parse-as-library','-I',run,*[ROOT/'Sources/M1Launcher'/n for n in names],ROOT/'Synthetic/ReadyLibraryScrollProbe.swift','-L',run,'-lLauncherCore','-Xlinker','-rpath','-Xlinker',run,'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',run/'probe'])
 p=call([run/'probe',run/'config.json'],timeout=100);report=json.loads(p.stdout);assert report['passed']
 assert sha(COPY)==COPY_SHA and before=={str(p.relative_to(ROOT)):sha(p)for p in core+files}
 report.update(sourceHashes=before,libraryCopySHA256=COPY_SHA,cacheBytesCopied=copied,privateCoreReceiptSHA256=sha(run/'core-build.json'),originalCacheWritten=False)
 out=run/'report.private.json';out.write_text(json.dumps(report,indent=2)+'\n');out.chmod(0o600)
 summary={'passed':True,'count':report['count'],'retainedReport':str(out),'retainedReportSHA256':sha(out),'previewRoot':str(run),'ownedCount':report['ownedCount'],'gamesCount':report['gamesCount'],'otherCount':report['otherCount'],'referenceCPUms':report['referenceCPUms'],'cachedScrollCPUms':report['cachedScrollCPUms'],'tileBytes':report['tileBytes'],'tileCount':report['tileCount'],'chromeRastersDuringScroll':report['chromeRastersDuringScroll'],'onScreenSmoothnessVerified':False,'accountKeychainOrGameUsed':False,'originalCacheWritten':False}
 (ROOT/'Evidence/library-scroll-ui-tests.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
