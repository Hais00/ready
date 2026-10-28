// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import LauncherCore

private enum Failure:Error {case check(String)}
@main private struct ReadySteamNativeStateDirectoryProbe {
  static func main()throws {
    let run=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
    let profile=UUID(uuidString:"abcdefab-cdef-4abc-8def-abcdefabcdef")!
    var checks=[String:Bool]()
    func check(_ value:Bool,_ name:String)throws{guard value else{throw Failure.check(name)};checks[name]=true}
    func directory(_ value:URL)throws {try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    func prepare(_ root:URL,_ app:UInt32=480)throws->URL {try SteamNativeStateDirectory.prepare(paths:LauncherPaths(root:root),profile:profile,gameID:app)}
    func reject(_ name:String,_ action:()throws->Void)throws {var refused=false;do{try action()}catch{refused=true};try check(refused,name)}
    func canonical(_ path:URL)->Bool {path.hasDirectoryPath && path.standardizedFileURL==path && path.resolvingSymlinksInPath()==path}
    func privatePath(_ path:URL)->Bool {var info=stat();return lstat(path.path,&info)==0 && info.st_mode&S_IFMT==S_IFDIR && info.st_uid==getuid() && info.st_mode&0o7777==0o700}
    func fdCount()->Int {(0..<256).filter{fcntl(Int32($0),F_GETFD)>=0}.count}
    let root=run.appendingPathComponent("new");try directory(root)
    let created=try prepare(root)
    try check(canonical(created),"new-directory-URL-passes-unchanged-canonical-guard")
    try check(created.path.hasSuffix("/Profiles/"+profile.uuidString+"/Steam/Native/480"),"new-directories-expected-hierarchy")
    var ancestor=created
    while ancestor.path != root.path {try check(privatePath(ancestor),"private-owned-"+ancestor.lastPathComponent);ancestor=ancestor.deletingLastPathComponent()}
    try check(try prepare(root).path==created.path,"existing-private-tree-idempotent")
    let legacy=run.appendingPathComponent("case-existing"),lower=legacy.appendingPathComponent("Profiles/"+profile.uuidString.lowercased())
    try directory(lower)
    let upper=legacy.appendingPathComponent("Profiles/"+profile.uuidString)
    let caseInsensitive=FileManager.default.fileExists(atPath:upper.path)
    guard caseInsensitive else{throw Failure.check("Fixture must run on actual case-insensitive volume")}
    let resolved=try prepare(legacy,1091500)
    try check(resolved.path.hasPrefix(lower.path+"/"),"existing-lowercase-UUID-returned-with-real-spelling")
    try check(canonical(resolved),"real-cased-UUID-is-canonical-not-lowercase-normalized")
    try check(!FileManager.default.contentsOfDirectory(atPath:legacy.appendingPathComponent("Profiles").path).contains(profile.uuidString),"no-second-profile-created-for-case-alias")
    try check(try prepare(legacy,1091500).path==resolved.path,"case-alias-repeat-reuses-same-directory")
    let accented=run.appendingPathComponent("dàti-fixture");try directory(accented)
    try check(canonical(try prepare(accented)),"unicode-base-does-not-confuse-byte-and-character-offsets")
    let rootAlias=run.appendingPathComponent("base-alias");try FileManager.default.createSymbolicLink(at:rootAlias,withDestinationURL:legacy)
    try check(try prepare(rootAlias,1091500).path==resolved.path,"caller-base-alias-resolved-once-before-private-traversal")
    let outside=run.appendingPathComponent("outside");try directory(outside)
    let sentinel=outside.appendingPathComponent("keep");try Data("owned fixture sentinel".utf8).write(to:sentinel)
    for (name,linkPath) in [("Profiles",[String]()),("profile",["Profiles"]),("Steam",["Profiles",profile.uuidString]),("Native",["Profiles",profile.uuidString,"Steam"]),("AppID",["Profiles",profile.uuidString,"Steam","Native"])] {
      let base=run.appendingPathComponent("symlink-"+name);try directory(base)
      let parent=linkPath.reduce(base){$0.appendingPathComponent($1)};try directory(parent)
      let component=name=="profile" ? profile.uuidString:name=="AppID" ? "480":name
      try FileManager.default.createSymbolicLink(at:parent.appendingPathComponent(component),withDestinationURL:outside)
      try reject("reject-inner-symlink-"+name){_=try prepare(base)}
    }
    try check(try FileManager.default.contentsOfDirectory(atPath:outside.path)==["keep"] && String(data:Data(contentsOf:sentinel),encoding:.utf8)=="owned fixture sentinel","symlink-target-completely-unchanged")
    for special in ["file","fifo"] {
      let base=run.appendingPathComponent("special-"+special);try directory(base);let entry=base.appendingPathComponent("Profiles")
      if special=="file"{try Data("not a directory".utf8).write(to:entry)}else{guard mkfifo(entry.path,0o600)==0 else{throw Failure.check("fifo fixture")}}
      try reject("reject-special-entry-"+special){_=try prepare(base)}
    }
    let permissions=run.appendingPathComponent("wrong-permission");try directory(permissions)
    let profiles=permissions.appendingPathComponent("Profiles");try directory(profiles);chmod(profiles.path,0o755)
    try reject("reject-existing-nonprivate-directory-without-chmod"){_=try prepare(permissions)}
    var perm=stat();lstat(profiles.path,&perm);try check(perm.st_mode&0o7777==0o755,"unsafe-permissions-not-silently-repaired")
    let basePermission=run.appendingPathComponent("public-base");try directory(basePermission);chmod(basePermission.path,0o755)
    try reject("reject-nonprivate-base-before-child-creation"){_=try prepare(basePermission)}
    try check(!FileManager.default.fileExists(atPath:basePermission.appendingPathComponent("Profiles").path),"invalid-base-no-children-created")
    let foreign=URL(fileURLWithPath:"/usr/share");var foreignInfo=stat()
    guard lstat(foreign.path,&foreignInfo)==0,foreignInfo.st_uid != getuid() else{throw Failure.check("foreign owner control unavailable")}
    var foreignRejected=false
    do{_=try prepare(foreign)}catch SteamNativeStateDirectory.Failure.unsafeDirectory{foreignRejected=true}catch{}
    try check(foreignRejected,"other-UID-base-rejected-read-only-before-writes")
    try reject("zero-AppID-rejected"){_=try prepare(root,0)}
    let count=fdCount();for _ in 0..<100{_=try prepare(legacy,1091500)}
    try check(fdCount()<=count,"directory-descriptors-closed-after-success")
    for _ in 0..<100{do{_=try prepare(permissions)}catch{}}
    try check(fdCount()<=count,"directory-descriptors-closed-after-failure")
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"count":checks.count,"actualCaseInsensitiveVolume":caseInsensitive,"fixtureOnly":true,"accountKeychainSDKGameUsed":false],options:[.sortedKeys]),as:UTF8.self))
  }
}
