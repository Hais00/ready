#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Cached actual-data viewport→artwork timing under blocked background writer;
actual cache and renderer, .default vs eventTracking, no app/game/auth/network."""
import argparse,hashlib,json,os,pathlib,shutil,stat,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
COPY=WORK/'tests/ready-owned-model-4pvpjaj4/library-copy.private.json'
COPY_SHA='3c6d0e39a30b2cca2b58cbc6986718cd52c0ef09d93366c4241e29231875c87b'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--baseline-ref",choices=["a8b6340"]);args=parser.parse_args()
 assert COPY.resolve(strict=True)==COPY and sha(COPY)==COPY_SHA
 run=pathlib.Path(tempfile.mkdtemp(prefix='viewport-artwork-ui-',dir=WORK/'tests'));run.chmod(0o700)
 caches=[];original=pathlib.Path('/Volumes/Dati APFS/Ready Cache/Artwork')
 referenced=set()
 for filename in ['index.json','index-recovery.json']:
  try:
   index=json.loads((original/filename).read_text())
   referenced.update(r['hash']for r in index.get('roles',{}).values()if r.get('role')=='card'and r.get('hash'))
  except (OSError,ValueError):pass
 priority={'index.json','index-recovery.json','index-dirty'}
 for h in referenced:priority.update([h+'.asset',h+'-512.png',h+'-1024.png'])
 candidates=[]
 for base,dirs,files in os.walk(original,followlinks=False):
  base=pathlib.Path(base);dirs[:]=[d for d in dirs if not(base/d).is_symlink()]
  for name in files:
   path=base/name;info=path.lstat()
   if (name in priority or name.startswith('url-')and name.endswith('.json'))and stat.S_ISREG(info.st_mode)and info.st_uid==os.getuid()and info.st_size<=16*1024*1024:candidates.append((path,info.st_size))
 candidates.sort(key=lambda p:(p[0].name not in priority,str(p[0])))
 copyIntegrity=[]
 for number in range(2):
  target=run/('cache-copy-'+str(number));target.mkdir(mode=0o700);total=0
  for path,size in candidates:
   if total+size>768*1024*1024:continue
   destination=target/path.relative_to(original);destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
   shutil.copyfile(path,destination);destination.chmod(0o600);total+=size
  good=0
  for h in referenced:
   readable=False
   for suffix in ['-512.png','-1024.png','.asset']:
    path=target/(h+suffix)
    if not path.exists():continue
    data=path.read_bytes()
    if suffix=='.asset':readable=hashlib.sha256(data).hexdigest()==h
    else:readable=data.startswith(bytes([137,80,78,71,13,10,26,10]))and len(data)>32
    if readable:break
   good+=int(readable)
  copyIntegrity.append({'referencedCardHashes':len(referenced),'readableCopiedCardHashes':good,'bytesCopied':total})
  assert good==len(referenced)
  caches.append(str(target))
 pointer=json.loads((ROOT/'Evidence/library-detail-ui-tests.json').read_text());core_receipt=pathlib.Path(pointer['retainedReport']);assert sha(core_receipt)==pointer['retainedReportSHA256'];core=core_receipt.parent
 for name,digest in json.loads(core_receipt.read_text())['sourceHashes'].items():
  if name.startswith('Sources/LauncherCore/'):assert sha(ROOT/name)==digest
 config={'output':str(run),'libraryCopy':str(COPY),'librarySHA256':COPY_SHA,'cacheCopies':caches,'baseline':bool(args.baseline_ref),'copyIntegrity':copyIntegrity};(run/'config.json').write_text(json.dumps(config)+'\n');(run/'config.json').chmod(0o600)
 names=['CanvasDrawing.swift','ControllerNavigation.swift','LibraryEntryPresentation.swift','GameArtwork.swift','ArtworkIndexStore.swift','ArtworkCache.swift','CanvasShellRenderer.swift','LibraryGridSurface.swift','ReadyShellModel.swift','MetalCanvas.swift']
 files=[*[ROOT/'Sources/M1Launcher'/n for n in names],ROOT/'Synthetic/ReadyViewportArtworkProbe.swift',pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 env={k:v for k,v in os.environ.items()if k in ['PATH','HOME','USER','LOGNAME','LANG','LC_ALL','DEVELOPER_DIR']};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/viewport-artwork-swift'))
 selected=[ROOT/'Sources/M1Launcher'/n for n in names];probe=ROOT/'Synthetic/ReadyViewportArtworkProbe.swift';baselineHashes={}
 if args.baseline_ref:
  for name in ['ArtworkCache.swift','ArtworkIndexStore.swift']:
   content=subprocess.run(['git','show',args.baseline_ref+':Sources/M1Launcher/'+name],cwd=ROOT,capture_output=True,check=True).stdout
   path=run/name;path.write_bytes(content);baselineHashes[name]=sha(path);selected=[path if p.name==name else p for p in selected]
  adapter=run/'BaselineAPIAdapter.swift';adapter.write_text('import Foundation\nimport LauncherCore\nextension ArtworkCache{func prepareViewport(games:[Game],visibleGameIDs:[String],lookAheadGameIDs:[String]){prepare(games:games,visibleGameIDs:visibleGameIDs)}}\n');selected.append(adapter)
  probe=run/'BaselineProbe.swift';probe.write_text((ROOT/'Synthetic/ReadyViewportArtworkProbe.swift').read_text().replace(',backgroundWriteGate:{gate.wait()}',''))
 command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/hosted-controller-typecheck'),'-I',str(core),*map(str,selected),str(probe),'-L',str(core),'-lLauncherCore','-Xlinker','-rpath','-Xlinker',str(core),'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',str(run/'probe')]
 p=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Owned viewport fixture compile failed: '+str(run/'build.log'))
 p=subprocess.run([str(run/'probe'),str(run/'config.json')],cwd=ROOT,env=env,capture_output=True,text=True,timeout=35);(run/'private-output.log').write_text(p.stdout+p.stderr)
 result=json.loads(p.stdout);assert before=={str(p.relative_to(ROOT)):sha(p)for p in files}and sha(COPY)==COPY_SHA
 result.update(functionalPassed=all(v for k,v in result["checks"].items()if not k.startswith("predictive-cached-row-artwork-p95-under100ms-")),softLatencyGoalUnder100msMet=all(v for k,v in result["checks"].items()if k.startswith("predictive-cached-row-artwork-p95-under100ms-")),copyIntegrity=copyIntegrity,sourceHashes=before,baselineRef=args.baseline_ref,baselineSourceHashes=baselineHashes,libraryCopySHA256=COPY_SHA,originalCacheWritten=False)
 path=run/'report.private.json';path.write_text(json.dumps(result,indent=2)+'\n');path.chmod(0o600)
 summary={'passed':result['passed'],'functionalPassed':result['functionalPassed'],'softLatencyGoalUnder100msMet':result['softLatencyGoalUnder100msMet'],'count':result['count'],'retainedReport':str(path),'retainedReportSHA256':sha(path),'results':result['results'],'originalCacheWritten':False,'onScreenImageLatencyVerified':False,'accountKeychainGameOrGameBenchmarkUsed':False}
 (ROOT/('Evidence/viewport-artwork-baseline-tests.json'if args.baseline_ref else'Evidence/viewport-artwork-ui-tests.json')).write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
 if not result['passed']:raise SystemExit(1)
if __name__=='__main__':main()
