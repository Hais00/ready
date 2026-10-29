// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

private enum CheckFailure:Error{case check(String)}
@main struct ReadyPrivateCredentialFileProbe {
  static func main()throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("state")
    let fm=FileManager.default
    try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let profile=UUID(),other=UUID(),name=profile.uuidString.lowercased()+"-steam.json"
    let folder=root.appendingPathComponent("Credentials"),file=folder.appendingPathComponent(name)
    let backend=PrivateCredentialFile(stateRoot:root)
    let first=Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","guard_data":{"device":"fixture_guard"},"access_token":"fixture_only_access"}"#.utf8)
    let second=Data(#"{"username":"fixture_other","refresh_token":"another_fixture_only_refresh","steam_guard_data":"opaque_guard_fixture"}"#.utf8)
    var checks=[String:Bool]()
    func check(_ value:Bool,_ label:String)throws{checks[label]=value;if !value{throw CheckFailure.check(label)}}
    func rejects(_ label:String,_ action:()throws->Void)throws{var refused=false;do{try action()}catch{refused=true};try check(refused,label)}
    func mode(_ path:URL)->Int{((try?fm.attributesOfItem(atPath:path.path)[.posixPermissions])as?NSNumber)?.intValue ?? -1}
    try check(!fm.fileExists(atPath:folder.path),"constructionHasNoFilesystemSideEffect")
    try check(try backend.load(profile:profile)==nil && !fm.fileExists(atPath:folder.path),"missingReadDoesNotCreateDirectory")
    try backend.remove(profile:profile)
    try check(!fm.fileExists(atPath:folder.path),"missingRemoveDoesNotCreateDirectory")
    let password=Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","password":"never_store"}"#.utf8)
    try rejects("passwordRejectedBeforeDirectoryCreation"){try backend.save(password,profile:profile)}
    try check(!fm.fileExists(atPath:folder.path),"invalidSaveLeavesRootUntouched")
    try backend.save(first,profile:profile)
    try check(mode(folder)==0o700 && mode(file)==0o600,"privateDirectoryAndFilePermissions")
    try check(try backend.load(profile:profile)==first,"legitimateGuardAndAccessPayloadRoundTripsByteExactly")
    try backend.save(second,profile:other)
    try check(try backend.load(profile:profile)==first && backend.load(profile:other)==second,"profilesHaveDistinctFilesAndPayloads")
    var before=stat(),after=stat();guard lstat(file.path,&before)==0 else{throw CheckFailure.check("stat")}
    try backend.save(second,profile:profile);guard lstat(file.path,&after)==0 else{throw CheckFailure.check("stat")}
    try check(before.st_ino != after.st_ino && after.st_nlink==1 && mode(file)==0o600,"replacementPublishesNewPrivateInode")
    try check(try backend.load(profile:profile)==second,"replacementIsCompleteAndReadable")
    try backend.save(first,profile:profile)
    let forbidden:[Data]=[
      password,Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","guard_data":{"PaSsWoRd":"never_store"}}"#.utf8),
      Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","guard_data":{"pass\u0077ord":"never_store"}}"#.utf8),
      Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","guard_data":{"password":"never_store"},"guard_data":"opaque"}"#.utf8),
      Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","passphrase":"never_store"}"#.utf8),
      Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","guard_data":[{"password":"never_store"}]}"#.utf8),
      Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","guard_data":"opaque","PASSWORD":null}"#.utf8)]
    for(index,data)in forbidden.enumerated(){try rejects("passwordKeyCase\(index)"){try backend.save(data,profile:profile)}}
    try check(try backend.load(profile:profile)==first,"rejectedSecretFieldsPreserveOldCredential")
    for(index,data)in [Data(),Data("not-json".utf8),Data("[]".utf8),Data(#"{"username":"fixture_account","refresh_token":""}"#.utf8),Data(#"{"username":"invalid account","refresh_token":"fixture"}"#.utf8),Data(repeating:32,count:PrivateCredentialFile.maximumBytes+1)].enumerated(){
      try rejects("invalidPayload\(index)"){try backend.save(data,profile:profile)}
    }
    try check(try backend.load(profile:profile)==first,"invalidPayloadsDoNotReplaceExistingBytes")
    let expired=Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","refresh_token_expires_at_epoch":1}"#.utf8)
    try backend.save(expired,profile:profile)
    try check(CredentialVault.steamStatus(try backend.load(profile:profile)) == .expired,"explicitExpiryIsPreservedForCredentialPolicy")
    try backend.save(first,profile:profile)
    let external=root.deletingLastPathComponent().appendingPathComponent("outside-fixture.json");try second.write(to:external);_ = chmod(external.path,0o600)
    try fm.removeItem(at:file);try fm.createSymbolicLink(at:file,withDestinationURL:external)
    try rejects("symlinkReadRejected"){_=try backend.load(profile:profile)}
    try rejects("symlinkSaveRejected"){try backend.save(first,profile:profile)}
    try rejects("symlinkRemoveRejected"){try backend.remove(profile:profile)}
    try check(try Data(contentsOf:external)==second,"symlinkTargetBytesUntouched")
    try fm.removeItem(at:file);guard link(external.path,file.path)==0 else{throw CheckFailure.check("link")}
    try rejects("hardlinkReadRejected"){_=try backend.load(profile:profile)}
    try rejects("hardlinkSaveRejected"){try backend.save(first,profile:profile)}
    try rejects("hardlinkRemoveRejected"){try backend.remove(profile:profile)}
    try check(try Data(contentsOf:external)==second,"hardlinkTargetBytesUntouched")
    try fm.removeItem(at:file);try backend.save(first,profile:profile)
    _=chmod(file.path,0o644)
    try rejects("unsafeFilePermissionsRejected"){_=try backend.load(profile:profile)}
    try rejects("unsafeExistingPermissionsNotSilentlyRepaired"){try backend.save(second,profile:profile)}
    try check(mode(file)==0o644 && (try Data(contentsOf:file))==first,"unsafeFilePreservedOnFailure")
    _=chmod(file.path,0o600);try fm.removeItem(at:file);guard mkfifo(file.path,0o600)==0 else{throw CheckFailure.check("fifo")}
    let start=Date();try rejects("fifoRejected"){_=try backend.load(profile:profile)}
    try check(Date().timeIntervalSince(start)<0.3,"fifoReadIsNonblocking")
    try fm.removeItem(at:file);try fm.createDirectory(at:file,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    try rejects("directoryFileRejected"){_=try backend.load(profile:profile)}
    try fm.removeItem(at:file);try Data(repeating:65,count:PrivateCredentialFile.maximumBytes+1).write(to:file);_=chmod(file.path,0o600)
    try rejects("oversizedExistingFileRejectedBeforeRead"){_=try backend.load(profile:profile)}
    try fm.removeItem(at:file);try Data("{incomplete".utf8).write(to:file);_=chmod(file.path,0o600)
    try rejects("malformedExistingJSONRejected"){_=try backend.load(profile:profile)}
    try backend.remove(profile:profile);try password.write(to:file);_=chmod(file.path,0o600)
    try rejects("existingPasswordPayloadRejected"){_=try backend.load(profile:profile)}
    try backend.remove(profile:profile);try backend.save(first,profile:profile)
    var info=stat();guard lstat(file.path,&info)==0 else{throw CheckFailure.check("stat")};info.st_uid=getuid()+1
    try rejects("productionMetadataValidatorRejectsOtherUID"){try PrivateCredentialFile.validateFileMetadata(info)}
    let rootAlias=root.deletingLastPathComponent().appendingPathComponent("state-alias");try fm.createSymbolicLink(at:rootAlias,withDestinationURL:root)
    try rejects("rootAliasRejected"){_=try PrivateCredentialFile(stateRoot:rootAlias).load(profile:profile)}
    _=chmod(root.path,0o755)
    try rejects("unsafeRootPermissionsRejected"){_=try backend.load(profile:profile)};_=chmod(root.path,0o700)
    _=chmod(folder.path,0o755)
    try rejects("unsafeCredentialDirectoryRejected"){_=try backend.load(profile:profile)};_=chmod(folder.path,0o700)
    let moved=root.appendingPathComponent("Credentials-owned-fixture");try fm.moveItem(at:folder,to:moved);try fm.createSymbolicLink(at:folder,withDestinationURL:moved)
    try rejects("credentialDirectoryAliasRejected"){_=try backend.load(profile:profile)}
    try fm.removeItem(at:folder);try fm.moveItem(at:moved,to:folder)
    let orphan=folder.appendingPathComponent(".ready-steam-credential-unrelated-fixture");try Data("unrelated owned fixture".utf8).write(to:orphan)
    try backend.save(second,profile:profile)
    try check(try String(contentsOf:orphan,encoding:.utf8)=="unrelated owned fixture","noWildcardTemporaryCleanup")
    let group=DispatchGroup(),resultLock=NSLock();var concurrentFailure=false
    for _ in 0..<12 {group.enter();DispatchQueue.global().async{defer{group.leave()};do{try backend.save(first,profile:profile);let value=try backend.load(profile:profile);if value != first && value != second{resultLock.lock();concurrentFailure=true;resultLock.unlock()}}catch{resultLock.lock();concurrentFailure=true;resultLock.unlock()}}}
    group.wait();try check(!concurrentFailure,"concurrentAccessSerializesWithoutPartialJSON")
    try backend.remove(profile:profile)
    try check(try backend.load(profile:profile)==nil && backend.load(profile:other)==second,"removeAOnlyPreservesProfileB")
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"fixtureOnly":true,"backendActivated":false,"realCredentialOrKeychainOrAccountUsed":false]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
  }
}
