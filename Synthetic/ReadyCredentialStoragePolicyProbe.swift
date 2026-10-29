// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
import Darwin
@_silgen_name("ready_credential_mock_count") private func mockCount(_ index:Int32)->UInt32
@_silgen_name("ready_credential_mock_reset") private func mockReset()
@_silgen_name("ready_credential_binding_is_mocked") private func bindingsMocked()->Int32
private enum PolicyCheck:Error{case failed(String)}
@main struct ReadyCredentialStoragePolicyProbe {
  static func main()throws {
    var outcome:Result<[String:Any],Error>?
    CredentialVault.perform({Result{try runChecks()}}){outcome=$0}
    let deadline=Date().addingTimeInterval(10)
    while outcome==nil && Date()<deadline{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    guard let outcome else{throw PolicyCheck.failed("workerDeadline")}
    print(String(decoding:try JSONSerialization.data(withJSONObject:outcome.get(),options:[.sortedKeys]),as:UTF8.self))
  }
  static func runChecks()throws->[String:Any] {
    // Do not call ANY credential API unless all four call-site bindings point
    // at this fixture's non-forwarding replacements.
    guard bindingsMocked()==1 else{throw PolicyCheck.failed("mockBindingsRequiredBeforeCredentialCalls")}
    let state=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("private-state")
    try FileManager.default.createDirectory(at:state,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let suite="app.ready.credential-policy-fixture."+UUID().uuidString
    guard let preferences=UserDefaults(suiteName:suite)else{throw PolicyCheck.failed("preferences")}
    defer{preferences.removeVolatileDomain(forName:UserDefaults.argumentDomain)}
    func policy(_ value:String?){preferences.setVolatileDomain(value.map{[CredentialVault.steamStoragePreference:$0]} ?? [:],forName:UserDefaults.argumentDomain)}
    var checks=[String:Bool]()
    func check(_ value:Bool,_ label:String)throws{checks[label]=value;if !value{throw PolicyCheck.failed(label)}}
    let profile=UUID(),other=UUID(),file=state.appendingPathComponent("Credentials/"+profile.uuidString.lowercased()+"-steam.json")
    let payload=Data(#"{"username":"fixture_account","refresh_token":"fixture_only_refresh","guard_data":"fixture_only_guard"}"#.utf8)
    try check(!Thread.isMainThread,"productionFacadeExecutedThroughCredentialSerialWorker")
    mockReset();policy(nil)
    try check(CredentialVault.storage(for:.steam,preferences:preferences) == .keychain,"defaultSteamPolicyRemainsKeychain")
    policy("unknown")
    try check(CredentialVault.storage(for:.steam,preferences:preferences) == .keychain,"unknownPolicyCannotSelectLocalStorage")
    policy("privateFile")
    try check(CredentialVault.storage(for:.steam,preferences:preferences) == .privateFile && Store.allCases.filter{$0 != .steam}.allSatisfy{CredentialVault.storage(for:$0,preferences:preferences) == .keychain},"privateFilePolicyIsSteamOnly")
    let access=StoreClient.CredentialAccess.persistent(stateRoot:state,preferences:preferences)
    try check(access.load(profile,.steam)==nil && mockCount(4)==0,"missingPrivateFileNeverReadsOrMigratesKeychain")
    try access.save(payload,profile,.steam)
    try check(access.load(profile,.steam)==payload && mockCount(4)==0,"privatePolicySaveAndLoadUseOnlyOwnedFile")
    try check(try Data(contentsOf:file)==payload,"policyWritesExpectedProfileSteamPath")
    let attrs=try FileManager.default.attributesOfItem(atPath:file.path),dir=try FileManager.default.attributesOfItem(atPath:file.deletingLastPathComponent().path)
    try check((attrs[.posixPermissions]as?NSNumber)?.intValue==0o600 && (dir[.posixPermissions]as?NSNumber)?.intValue==0o700,"policyPreservesPrivateFileAndDirectoryModes")
    try check(access.load(other,.steam)==nil && mockCount(4)==0,"privatePolicySeparatesProfilesWithoutKeychainFallback")
    _=chmod(file.path,0o644)
    try check(access.load(profile,.steam)==nil && mockCount(4)==0,"unsafePrivateFileNeverFallsBackToKeychain")
    _=chmod(file.path,0o600);access.remove(profile,.steam)
    try check(!FileManager.default.fileExists(atPath:file.path) && mockCount(3)==0,"privateRemoveDoesNotDeleteOldKeychainEntries")
    let alias=StoreClient.CredentialAccess.keychain(stateRoot:state,preferences:preferences)
    try alias.save(payload,profile,.steam)
    try check(alias.load(profile,.steam)==payload && mockCount(4)==0,"compatibilityFactoryUsesPersistentPolicyWithoutKeychainRead")
    let previous=try Data(contentsOf:file)
    let otherValue=access.load(profile,.gog)
    try check(otherValue != nil && mockCount(0)==1,"otherStoreLoadRetainsMockedKeychainBackend")
    try access.save(Data("other_store_fixture".utf8),profile,.gog);access.remove(profile,.gog)
    try check(mockCount(1)==1 && mockCount(3)==1 && (try Data(contentsOf:file))==previous,"otherStoreSaveRemoveRemainKeychainAndDoNotTouchSteamFile")
    mockReset();policy(nil)
    let defaultValue=access.load(profile,.steam)
    try check(defaultValue != nil && defaultValue != payload && mockCount(0)==1,"defaultSteamReadUsesMockedKeychainWithoutImportingPrivateFile")
    try access.save(payload,profile,.steam);access.remove(profile,.steam)
    try check(mockCount(1)==1 && mockCount(3)==1 && (try Data(contentsOf:file))==previous,"defaultSteamSaveRemovePreserveExistingPrivateFile")
    try check(mockCount(5)==0,"allMockedKeychainCallsExecuteOnSerialWorkerNotMain")
    policy("privateFile");access.remove(profile,.steam)
    try check(mockCount(3)==1 && !FileManager.default.fileExists(atPath:file.path),"reselectingPrivateFileDeletesOnlyPrivateEntry")
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"fixtureOnly":true,"preferencesVolatileAndIsolated":true,"realApplicationPreferencesChanged":false,"realCredentialKeychainOrAccountUsed":false,"keychainOperationsMockedInsideOwnProcess":true]
    return report
  }
}
