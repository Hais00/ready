// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
@main struct ReadyNativeCacheRevisionProbe {
  static func main()throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),marker=root.appendingPathComponent(".ready-native-credential-revision.json")
    let a=Data("public synthetic credential A".utf8),b=Data("public synthetic credential B".utf8)
    var checks=[String:Bool]()
    func check(_ condition:Bool,_ name:String)throws{if !condition{throw NSError(domain:name,code:1)};checks[name]=true}
    func rejected(_ action:()throws->Void)->Bool{do{try action();return false}catch{return true}}
    let first=try SteamNativeCacheRevision.select(packet:a,root:root)
    try check(first.mode == .fresh && !FileManager.default.fileExists(atPath:marker.path),"unmarked-cache-requires-fresh-once-without-writing-before-ready")
    _=try SteamNativeCacheRevision.select(packet:b,root:root)
    try check(!FileManager.default.fileExists(atPath:marker.path),"failed-or-abandoned-preparation-does-not-mark-revision")
    try first.recordReady()
    let original=try Data(contentsOf:marker)
    try check(try SteamNativeCacheRevision.select(packet:a,root:root).mode == .reuse,"ready-matching-revision-selects-automatic-reuse")
    try check(try SteamNativeCacheRevision.select(packet:b,root:root).mode == .fresh,"new-credential-selects-fresh-despite-existing-native-cache")
    let value=try JSONSerialization.jsonObject(with:original)as![String:Any]
    let attributes=try FileManager.default.attributesOfItem(atPath:marker.path)
    try check(Set(value.keys)==Set(["schema","revision"])&&(attributes[.posixPermissions]as?NSNumber)?.intValue==0o600,"marker-is-private-and-contains-only-schema-and-revision")
    try check(!String(describing:first).contains(value["revision"]as!String)&&Mirror(reflecting:first).children.isEmpty,"revision-description-and-reflection-are-redacted")
    let second=try SteamNativeCacheRevision.select(packet:b,root:root);try second.recordReady()
    try check(try SteamNativeCacheRevision.select(packet:b,root:root).mode == .reuse,"new-successful-ready-replaces-revision-for-next-launch")
    try check(try SteamNativeCacheRevision.select(packet:a,root:root).mode == .fresh,"former-credential-does-not-match-new-ready-revision")
    let valid=try Data(contentsOf:marker)
    for payload in [Data("{}".utf8),try JSONSerialization.data(withJSONObject:["schema":true,"revision":String(repeating:"a",count:64)]),try JSONSerialization.data(withJSONObject:["schema":1,"revision":"invalid"])] {
      try payload.write(to:marker)
      try check(rejected{_=try SteamNativeCacheRevision.select(packet:b,root:root)},"malformed-marker-refused-"+String(checks.count))
    }
    try valid.write(to:marker)
    try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:marker.path)
    try check(rejected{_=try SteamNativeCacheRevision.select(packet:b,root:root)},"public-marker-mode-refused")
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:marker.path)
    let link=root.appendingPathComponent("hardlink")
    try FileManager.default.linkItem(at:marker,to:link)
    try check(rejected{_=try SteamNativeCacheRevision.select(packet:b,root:root)},"hardlinked-marker-refused")
    try FileManager.default.removeItem(at:link);try FileManager.default.removeItem(at:marker)
    try FileManager.default.createSymbolicLink(at:marker,withDestinationURL:link)
    try check(rejected{_=try SteamNativeCacheRevision.select(packet:b,root:root)},"aliased-marker-refused")
    try FileManager.default.removeItem(at:marker)
    try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
    try check(rejected{_=try SteamNativeCacheRevision.select(packet:b,root:root)},"nonprivate-state-root-refused")
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"count":checks.count,"checks":checks,"fixtureOnly":true,"accountOrSDKUsed":false]),as:UTF8.self))
  }
}
