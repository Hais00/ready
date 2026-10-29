#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build an owned, bounded foreground probe using the production Space driver.

The default only builds. --run creates the probe's own fullscreen Space for a
short CUA inspection, exits fullscreen, then terminates. It never sends input,
captures another app, disables locking, starts a game or accesses an account.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
WORK = Path('/Volumes/Dati APFS/Codex-ready-01a17e79')

DRIVER = r'''
@MainActor final class SpaceProbe:NSObject,NSApplicationDelegate,NSWindowDelegate {
  var window:NSWindow!;var placement:HostedWindowPlacement!
  var facts=[String:Any]();var tokens=[NSObjectProtocol]()
  let output:URL;let hold:Double
  init(output:URL,hold:Double){self.output=output;self.hold=hold}
  func save(_ phase:String){facts["phase"]=phase
    if let bytes=try?JSONSerialization.data(withJSONObject:facts,options:[.sortedKeys,.prettyPrinted]){try?bytes.write(to:output,options:.atomic)}
  }
  func applicationDidFinishLaunching(_ notification:Notification){
    window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
    window.title="Ready Space Probe";window.delegate=self;window.isOpaque=true;window.backgroundColor = .black
    let label=NSTextField(labelWithString:"Ready · native fullscreen Space probe")
    label.textColor = .white;label.font=NSFont.systemFont(ofSize:28);label.frame=NSRect(x:50,y:100,width:850,height:70)
    window.contentView?.addSubview(label);window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    let before=window.windowNumber
    placement=HostedWindowPlacement(window:window)
    facts=["schema":1,"fixtureOnly":true,"gameOrAccountExecuted":false,"hostPID":getpid(),"windowBefore":before,"visualVerified":false]
    save("entering")
    placement.enter{[weak self] result in
      guard let self else{return}
      switch result {
      case .success:
        self.facts["nativeFullscreen"]=self.window.styleMask.contains(.fullScreen)
        self.facts["driverFullscreen"]=self.placement.isFullscreen
        self.facts["onActiveSpace"]=self.window.isOnActiveSpace
        self.facts["windowAfter"]=self.window.windowNumber
        self.facts["windowResourcePreserved"]=before==self.window.windowNumber
        self.facts["primary"]=self.window.collectionBehavior.contains(.fullScreenPrimary)
        self.facts["disallowsTiling"]=self.window.collectionBehavior.contains(.fullScreenDisallowsTiling)
        self.facts["windowLevel"]=self.window.level.rawValue
        self.save("entered")
        DispatchQueue.main.asyncAfter(deadline:.now()+self.hold){[weak self]in self?.placement.restore()}
      case .failure:self.facts["passed"]=false;self.save("failed");NSApp.terminate(nil)
      }
    }
    tokens.append(NotificationCenter.default.addObserver(forName:NSWindow.didExitFullScreenNotification,object:window,queue:.main){[weak self] _ in MainActor.assumeIsolated{
      guard let self else{return};self.facts["nativeExitObserved"]=true
      self.facts["passed"]=(self.facts["nativeFullscreen"] as?Bool)==true && (self.facts["driverFullscreen"] as?Bool)==true && !self.window.styleMask.contains(.fullScreen)
      self.save("exited");NSApp.terminate(nil)
    }})
    DispatchQueue.main.asyncAfter(deadline:.now()+hold+15){[weak self]in self?.facts["passed"]=false;self?.save("deadline");NSApp.terminate(nil)}
  }
  func windowDidFailToEnterFullScreen(_ window:NSWindow){placement?.failedToEnter()}
}
let app=NSApplication.shared
app.setActivationPolicy(.regular)
let probe=MainActor.assumeIsolated{SpaceProbe(output:URL(fileURLWithPath:CommandLine.arguments[1]),hold:Double(CommandLine.arguments[2])!)}
app.delegate=probe
app.run()
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--hold', type=int, default=30)
    args = parser.parse_args()
    assert 5 <= args.hold <= 45
    assert WORK.stat().st_uid == os.getuid()
    assert (WORK / '.ready-external-workspace').read_text() == 'ready project work for thread01a17e79\n'
    source = ROOT / 'Sources/M1Launcher/HostedGamePresentation.swift'
    raw = source.read_text()
    production = raw[raw.index('@MainActor final class HostedWindowPlacement'):raw.index('/// Experimental direct-drawable')]
    run = Path(tempfile.mkdtemp(prefix='ready-native-space-', dir=WORK / 'tests'))
    run.chmod(0o700)
    app = run / 'ReadySpaceProbe.app'
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True, mode=0o700)
    identifier = 'app.ready.spaceprobe.' + uuid.uuid4().hex
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleName': 'Ready Space Probe', 'CFBundleExecutable': 'probe', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True}))
    swift = run / 'main.swift'
    swift.write_text('import AppKit\n' + production + DRIVER)
    env = dict(os.environ, TMPDIR=str(WORK / 'tmp') + '/')
    # Match the package's Swift 5 language mode (swift-tools-version 5.10).
    built = subprocess.run(['swiftc', '-O', '-swift-version', '5', str(swift), '-o', str(macos / 'probe')], capture_output=True, text=True, env=env)
    (run / 'build.log').write_text(built.stdout + built.stderr)
    if built.returncode:
        raise RuntimeError('Probe compile failed: ' + str(run / 'build.log'))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    assert source.read_text() == raw, 'Production source changed during probe capture'
    receipt = {'fixtureOnly': True, 'sourceSHA256': hashlib.sha256(raw.encode()).hexdigest(), 'extractedDriverSHA256': hashlib.sha256(production.encode()).hexdigest(), 'app': str(app), 'bundleIdentifier': identifier, 'report': str(run / 'report.json'), 'started': args.run}
    if args.run:
        with (run / 'process.log').open('wb') as log:
            child = subprocess.Popen([str(macos / 'probe'), str(run / 'report.json'), str(args.hold)], stdout=log, stderr=log, env=env, start_new_session=True)
        receipt['pid'] = child.pid
        # Read only our own diagnostic state; a window screenshot taken before
        # didEnterFullScreen can capture the system transition animation.
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            try:
                phase = json.loads((run / 'report.json').read_text()).get('phase')
            except (OSError, ValueError):
                phase = None
            if phase in ('entered', 'failed', 'deadline', 'exited'):
                receipt['phaseObserved'] = phase
                break
            time.sleep(0.1)
    (run / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
