#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real installation view + current isolated Core, synthetic options, hidden ownwindow."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-root',type=pathlib.Path);args=ap.parse_args()
 run=pathlib.Path(tempfile.mkdtemp(prefix='game-installation-ui-',dir=WORK/'tests'));run.chmod(0o700);core=args.core_root.resolve() if args.core_root else run/'core'
 if not args.core_root:core.mkdir(mode=0o700)
 models=sorted((ROOT/'Sources/LauncherCore').glob('*.swift'));sources=[ROOT/'Sources/M1Launcher/GameInstallationView.swift',ROOT/'Sources/M1Launcher/ControllerNavigation.swift',ROOT/'Sources/M1Launcher/LibraryEntryPresentation.swift',ROOT/'Synthetic/ReadyGameInstallationProbe.swift',pathlib.Path(__file__)];before={str(p.relative_to(ROOT)):sha(p)for p in models+sources}
 stub=run/'Stub.swift';stub.write_text('import AppKit\nprotocol ReadyDialogContentSizing{var maximumViewportHeight:CGFloat{get}}\nextension Notification.Name{static let readyDialogContentLayoutChanged=Notification.Name("own.install.layout")}\n')
 env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','STEAM','Steam','RHG_','MTL_HUD_'))};env['TMPDIR']=str(WORK/'tmp')+'/'
 swift=['xcrun','swiftc','-swift-version','5','-module-cache-path',str(WORK/'cache/game-installation-ui-module-cache')]
 commands=[swift+['-emit-library','-emit-module','-module-name','LauncherCore',*map(str,models),'-emit-module-path',str(core/'LauncherCore.swiftmodule'),'-o',str(core/'libLauncherCore.dylib')],swift+['-parse-as-library','-I',str(core),str(stub),*map(str,sources[:4]),'-L',str(core),'-lLauncherCore','-Xlinker','-rpath','-Xlinker',str(core),'-framework','AppKit','-o',str(run/'probe')]]
 if args.core_root:
  original=core.parent/'report.json';record=json.loads(original.read_text())
  assert record['coreModuleSHA256']==sha(core/'LauncherCore.swiftmodule')
  assert record['coreLibrarySHA256']==sha(core/'libLauncherCore.dylib')
  assert {str(p.relative_to(ROOT)):sha(p) for p in models}=={k:v for k,v in record['sourceHashes'].items() if k.startswith('Sources/LauncherCore/')}
  commands=commands[1:]
 for index,command in enumerate(commands):
  p=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=120);(run/f'build-{index}.log').write_text(p.stdout+p.stderr)
  if p.returncode:raise RuntimeError('Own installation UI compile failed '+p.stderr[-2600:])
 p=subprocess.run([str(run/'probe')],env=env,capture_output=True,text=True,timeout=20);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError('Installation UI fixture failed '+str(run))
 d=json.loads(p.stdout);assert d['passed'];assert before=={str(p.relative_to(ROOT)):sha(p)for p in models+sources};d['sourceHashes']=before;d['coreRoot']=str(core);d['coreReused']=bool(args.core_root);d['coreSourceReceiptSHA256']=sha(core.parent/'report.json') if args.core_root else None;d['coreModuleSHA256']=sha(core/'LauncherCore.swiftmodule');d['coreLibrarySHA256']=sha(core/'libLauncherCore.dylib');raw=run/'report.json';raw.write_text(json.dumps(d,indent=2)+'\n');raw.chmod(0o600);out={**d,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/game-installation-ui-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
