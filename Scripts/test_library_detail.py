#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own hidden/prohibited UI fixture, controlled public artwork transport only.
Compiles a PRIVATE Core product; no SwiftPM/global build, accounts or games."""
import argparse,hashlib,json,os,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
STUB=r'''
import AppKit
protocol ReadyDialogContentSizing{var maximumViewportHeight:CGFloat{get}}
extension Notification.Name{static let readyDialogContentLayoutChanged=Notification.Name("ready.dialog.content-layout-changed")}
enum ReadyDialogRole{case normal,primary,cancel,destructive}
struct ReadyDialogAction{var title:String;var role:ReadyDialogRole;var enabled:Bool}
final class TestSession{var running=false}
@MainActor final class TestDownloads{var profile=UUID();var snapshot=[SteamDownloadJob]();func control(_ id:String,action:String){}}
final class AppDelegate:NSObject{
 var maintenanceInProgress=false;var session:TestSession?;var pendingLaunch:UUID?;var state=LibraryState.initial();var canvas:MetalCanvas!;var window:NSWindow!
 var gameDetailView:GameDetailView?;var gameDetailID:String?;var steamDownloads:TestDownloads?
 var plays=[String](),installs=[String]()
 lazy var pages=ReadyPagePresenter(window:{[weak self]in self?.window},host:{[weak self]in self?.canvas})
 func beginPage(_ section:CanvasSection){pages.cancelCurrent();canvas.section=section}
 func navigateToLibrary(store:Store?=nil,preservingSelection:Bool=false){pages.detachForSession();gameDetailView=nil;gameDetailID=nil;canvas.section = .library}
 func launchGame(_ game:Game,variant:GameVariant){plays.append(game.id+":"+variant.id)}
 func installGame(index:Int,variant:GameVariant,showDownloads:Bool=true){installs.append(state.games[index].id+":"+variant.id+":"+String(showDownloads))}
 func gameOptions(_ id:String,advanced:Bool=true){}
 func requestSteamGameDetails(gameID:String,refresh:Bool=false,completion:@escaping([String:Any])->Void){}
}
'''
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--core-root',type=pathlib.Path);args=parser.parse_args()
 run=pathlib.Path(tempfile.mkdtemp(prefix='library-detail-ui-',dir=WORK/'tests'));run.chmod(0o700)
 names=['CanvasDrawing.swift','ControllerNavigation.swift','LibraryEntryPresentation.swift','ArtworkIndexStore.swift','CanvasShellRenderer.swift','LibraryGridSurface.swift','GameArtwork.swift','ArtworkCache.swift','MetalCanvas.swift','ReadyPagePresenter.swift','GameDetailView.swift','GameDetailUI.swift']
 files=[*[ROOT/'Sources/M1Launcher'/n for n in names],ROOT/'Synthetic/ReadyLibraryDetailProbe.swift',pathlib.Path(__file__).resolve()]
 core=sorted((ROOT/'Sources/LauncherCore').glob('*.swift'));before={str(p.relative_to(ROOT)):sha(p)for p in files+core}
 jobs=(ROOT/'Sources/M1Launcher/SteamDownloads.swift').read_text().split('@MainActor\nfinal class SteamDownloads',1)[0]
 (run/'Stubs.swift').write_text(jobs+STUB)
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','MTL_HUD_','RHG_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/library-detail-swift'))
 logs=[]
 def call(command,timeout=120):
  p=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout);logs.append(p.stdout+p.stderr);(run/'build.log').write_text('\n'.join(logs))
  if p.returncode:raise RuntimeError('Own library/detail UI fixture failed: '+str(run/'build.log'))
  return p
 swift=['xcrun','swiftc','-swift-version','5','-module-cache-path',WORK/'cache/hosted-controller-typecheck']
 if args.core_root:
  product=args.core_root.resolve(strict=True);receipt=product/'core-build.json'
  if receipt.exists():
   bound=json.loads(receipt.read_text());assert all(sha(ROOT/name)==digest for name,digest in bound['sourceHashes'].items());assert sha(product/'libLauncherCore.dylib')==bound['librarySHA256']and sha(product/'LauncherCore.swiftmodule')==bound['moduleSHA256']
  for filename in ['LauncherCore.swiftmodule','libLauncherCore.dylib']:shutil.copyfile(product/filename,run/filename)
 else:call(swift+['-emit-library','-emit-module','-module-name','LauncherCore',*core,'-emit-module-path',run/'LauncherCore.swiftmodule','-o',run/'libLauncherCore.dylib'])
 call(swift+['-parse-as-library','-I',run,run/'Stubs.swift',*[ROOT/'Sources/M1Launcher'/n for n in names],ROOT/'Synthetic/ReadyLibraryDetailProbe.swift','-L',run,'-lLauncherCore','-Xlinker','-rpath','-Xlinker',run,'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',run/'probe'])
 p=call([run/'probe',run],timeout=90);report=json.loads(p.stdout);assert report['passed']
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files+core}
 report['sourceHashes']=before;report['downloadJobDefinitionSHA256']=hashlib.sha256(jobs.encode()).hexdigest()
 path=run/'report.json';path.write_text(json.dumps(report,indent=2)+'\n');path.chmod(0o600)
 pointer={'passed':True,'count':report['count'],'retainedReport':str(path),'retainedReportSHA256':sha(path),'previewRoot':str(run),'sourceHashes':{str(p.relative_to(ROOT)):sha(p)for p in files},'fixtureOnly':True,'actualAccountsKeychainOrGamesUsed':False,'externalNetworkUsed':False,'windowActivated':False}
 (ROOT/'Evidence/library-detail-ui-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
