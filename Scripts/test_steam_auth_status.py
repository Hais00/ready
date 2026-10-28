#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Owned synthetic PNG/status tests, with a NEVER-visible in-window card.

No account/helper/Steam execution. The fixture compiles the actual reader/card
and dialog infrastructure with a tiny host, then runs main-loop updates hidden.
"""
import hashlib,json,os
from pathlib import Path
import struct,subprocess,tempfile,uuid,zlib
ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
SWIFT=r'''
import AppKit
import Foundation
final class MetalCanvas: NSView { var interactionEnabled=true }
final class AppDelegate: NSObject, NSApplicationDelegate {
 var window:NSWindow!
 lazy var dialogs=ReadyDialogPresenter(window:{[weak self] in self?.window})
}
@main struct DiagnosticFixture {
 static var checks=[String:Bool]()
 static func check(_ condition:Bool,_ name:String){precondition(condition,name);checks[name]=true}
 static func write(_ value:[String:Any],_ path:URL)throws{
  let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
  let temp=path.deletingLastPathComponent().appendingPathComponent(".fixture-"+UUID().uuidString)
  try data.write(to:temp);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temp.path)
  guard Darwin.rename(temp.path,path.path)==0 else{throw NSError(domain:"fixture",code:1)}
 }
 static func spin(){RunLoop.main.run(until:Date().addingTimeInterval(0.3))}
 static func images(_ view:NSView)->[NSImageView]{(view as? NSImageView).map{[$0]} ?? view.subviews.flatMap{images($0)}}
 static func main()throws{
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let path=root.appendingPathComponent("live-auth.json")
  let generation=CommandLine.arguments[2];let firstPNG=CommandLine.arguments[3],secondPNG=CommandLine.arguments[4]
  func state(_ n:Int,_ phase:String,_ image:String?=nil,_ gen:String?=nil)->[String:Any]{
   var v:[String:Any]=["schema":1,"generation":gen ?? generation,"sequence":n,"phase":phase]
   if let image{v["image"]=image};return v
  }
  let host=AppDelegate();host.window=NSWindow(contentRect:NSRect(x:0,y:0,width:1240,height:760),styleMask:[.titled],backing:.buffered,defer:false)
  host.window.title="MODALITÀ TEST — NON SCANSIONARE";host.window.isReleasedWhenClosed=false
  host.window.contentView=MetalCanvas(frame:NSRect(x:0,y:0,width:1240,height:760))
  let diagnostics=try SteamAuthDiagnostics(delegate:host,status:path);try diagnostics.start();spin()
  check(!host.window.isVisible,"fixture-never-shows-window")
  check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("live-ui-ready.json").path),"hidden-window-does-not-ack")
  check(app.windows.count==1&&host.dialogs.isPresenting,"card-in-same-window-no-panel")
  try write(state(1,"qr",firstPNG),path);spin();check(diagnostics.imageVisible,"timer-displays-qr")
  let imageView=images(host.window.contentView!).first{$0.image != nil}!
  check(imageView.imageScaling == .scaleProportionallyUpOrDown&&imageView.frame.width==320&&imageView.frame.height==320,"qr-aspect-fit-320")
  host.window.contentView!.layoutSubtreeIfNeeded()
  check(imageView.visibleRect.contains(imageView.bounds.insetBy(dx:0.5,dy:0.5)),"complete-qr-inside-dialog-viewport")
  let first=imageView.image!.tiffRepresentation!
  try write(state(2,"qr",secondPNG),path);spin();check(diagnostics.imageVisible&&imageView.image!.tiffRepresentation != first,"rotation-replaces-pixels")
  try write(state(3,"authentication_complete"),path);spin();check(!diagnostics.imageVisible&&imageView.image==nil,"authentication-complete-clears-qr")
  try write(state(4,"qr",firstPNG),path);spin();check(diagnostics.imageVisible,"later-valid-qr-can-show")
  try write(state(5,"qr",secondPNG,UUID().uuidString.lowercased()),path);spin();check(!diagnostics.imageVisible,"generation-mismatch-clears-qr")
  try write(state(5,"authorizing_game"),path);spin();check(diagnostics.phase == .authorizing_game && !diagnostics.imageVisible,"generation-stays-frozen-and-license-phase-hides")
  try write(state(6,"qr",firstPNG),path);spin();try write(state(5,"qr",secondPNG),path);spin();check(!diagnostics.imageVisible,"stale-sequence-clears-qr")
  try write(state(7,"qr",secondPNG),path);spin();check(diagnostics.imageVisible,"valid-new-sequence-recovers")
  diagnostics.cancel();check(!diagnostics.isWatching && !diagnostics.imageVisible && !host.dialogs.isPresenting,"cancel-stops-watcher-and-dismisses")
  let cancelPath=root.appendingPathComponent("cancel.request")
  let cancel=try JSONSerialization.jsonObject(with:Data(contentsOf:cancelPath)) as! [String:Any]
  let attrs=try FileManager.default.attributesOfItem(atPath:cancelPath.path)
  check(cancel["generation"] as? String==generation&&cancel["action"] as? String=="cancel"&&attrs[.posixPermissions] as? Int==0o600,"cancel-private-generation-bound")
  try write(state(8,"qr",firstPNG),path);spin();check(!diagnostics.imageVisible,"cancelled-watcher-does-not-reopen-qr")
  let initialCancel=try Data(contentsOf:cancelPath);diagnostics.cancel();check(try Data(contentsOf:cancelPath)==initialCancel,"cancel-does-not-overwrite-existing-request")
  let reader=try SteamAuthDiagnosticReader(status:path);_ = try reader.next();try reader.acknowledge()
  let ackPath=root.appendingPathComponent("live-ui-ready.json");let ack=try JSONSerialization.jsonObject(with:Data(contentsOf:ackPath)) as! [String:Any]
  let ackAttrs=try FileManager.default.attributesOfItem(atPath:ackPath.path)
  check(ack["generation"] as? String==generation&&ack["pid"] as? Int==Int(getpid())&&ackAttrs[.posixPermissions] as? Int==0o600,"ack-writer-private-generation-and-pid")
  do{try reader.acknowledge();check(false,"ack-exclusive")}catch{check(true,"ack-exclusive")}
  func rejected(_ name:String,_ document:[String:Any])throws{
   try write(document,path)
   do{let r=try SteamAuthDiagnosticReader(status:path);_ = try r.next();check(false,name)}catch{check(true,name)}
  }
  try rejected("reject-boolean-schema",["schema":true,"generation":generation,"sequence":0,"phase":"starting"])
  try rejected("reject-float-sequence",["schema":1,"generation":generation,"sequence":0.5,"phase":"starting"])
  try rejected("reject-extra-secret-field",["schema":1,"generation":generation,"sequence":0,"phase":"starting","token":"synthetic-only"])
  try rejected("reject-unknown-phase",state(0,"unknown"))
  try rejected("reject-traversal-image",state(0,"qr","../outside.png"))
  let alias="qr-"+UUID().uuidString.lowercased()+".png"
  try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent(alias).path,withDestinationPath:root.appendingPathComponent(firstPNG).path)
  try rejected("reject-symlink-image",state(0,"qr",alias))
  try write(state(0,"starting"),path);try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:path.path)
  do{let r=try SteamAuthDiagnosticReader(status:path);_ = try r.next();check(false,"reject-world-readable-state")}catch{check(true,"reject-world-readable-state")}
  try write(state(0,"starting"),path);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
  do{_ = try SteamAuthDiagnosticReader(status:path);check(false,"reject-nonprivate-parent")}catch{check(true,"reject-nonprivate-parent")}
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
  check(!host.window.isVisible,"fixture-window-remains-hidden");host.window.close()
  let report:[String:Any]=["fixtureOnly":true,"passed":true,"checks":checks,"checkCount":checks.count,"windowEverShown":false,"realAuthentication":false]
  let output=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]);FileHandle.standardOutput.write(output)
 }
}
'''
def png(color):
 def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',64,64,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes(color)*64)*64))+chunk(b'IEND',b'')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 assert(WORK/'.ready-external-workspace').read_text().strip()=='ready project work for thread01a17e79'
 run=Path(tempfile.mkdtemp(prefix='steam-auth-status-fixture-',dir=WORK/'tests'));run.chmod(0o700)
 status=run/'owned-status';status.mkdir(mode=0o700);generation=str(uuid.uuid4());names=[]
 for color in [(230,40,40),(30,70,230)]:
  name='qr-'+str(uuid.uuid4())+'.png';p=status/name;p.write_bytes(png(color));p.chmod(0o600);names.append(name)
 state=status/'live-auth.json';state.write_text(json.dumps({'schema':1,'generation':generation,'sequence':0,'phase':'starting'}));state.chmod(0o600)
 source=run/'Fixture.swift';source.write_text(SWIFT)
 files=[ROOT/'Sources/M1Launcher'/name for name in ['ReadyDialogs.swift','ControllerNavigation.swift','SteamAuthDiagnostics.swift']]
 for path in files:(run/path.name).write_bytes(path.read_bytes())
 cache=WORK/'cache/steam-auth-status-swift';cache.mkdir(mode=0o700,exist_ok=True)
 exe=run/'StatusFixture';command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(cache),*map(str,files),str(source),'-framework','AppKit','-framework','ImageIO','-o',str(exe)]
 env=dict(os.environ);env['TMPDIR']=str(WORK/'tmp')+'/';env['PYTHONDONTWRITEBYTECODE']='1'
 built=subprocess.run(command,env=env,capture_output=True,text=True)
 if built.returncode:raise RuntimeError(built.stderr)
 tested=subprocess.run([str(exe),str(status),generation,*names],env=env,capture_output=True,text=True,timeout=30)
 if tested.returncode:raise RuntimeError(tested.stderr[-4000:])
 report=json.loads(tested.stdout);assert report['passed'] and not report['windowEverShown']
 report.update({'sourceHashes':{str(p.relative_to(ROOT)):sha(p) for p in files},'testSHA256':sha(Path(__file__)),'fixtureRoot':str(run),'fixtureSHA256':sha(exe),'command':command})
 (ROOT/'Evidence/steam-auth-status-fixtures.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k] for k in ['passed','checkCount','windowEverShown','realAuthentication','fixtureRoot']},indent=2))
if __name__=='__main__':main()
