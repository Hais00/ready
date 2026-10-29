// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

private final class AuthorizationMemoryVault {
  private let lock=NSLock();private var value:Data?;private var writesValue=0,mainCallsValue=0;var delay:TimeInterval=0
  init(_ value:Data){self.value=value}
  var data:Data?{get{lock.lock();defer{lock.unlock()};return value}set{lock.lock();value=newValue;lock.unlock()}}
  var writes:Int{lock.lock();defer{lock.unlock()};return writesValue}
  var mainCalls:Int{lock.lock();defer{lock.unlock()};return mainCallsValue}
  func load()->Data?{lock.lock();if Thread.isMainThread{mainCallsValue+=1};let v=value,d=delay;lock.unlock();if d>0{Thread.sleep(forTimeInterval:d)};return v}
  func save(){lock.lock();if Thread.isMainThread{mainCallsValue+=1};writesValue+=1;lock.unlock()}
  func remove(){lock.lock();if Thread.isMainThread{mainCallsValue+=1};value=nil;lock.unlock()}
}
@main struct ReadySteamGameAuthorizationProbe {
  @MainActor static func main() throws {
    let profile = UUID(), other = UUID(), identity = "76561198000000001"
    let original = try JSONSerialization.data(withJSONObject: ["username":"fixture_account", "refresh_token":"fixture_only_secret"])
    let memory=AuthorizationMemoryVault(original)
    var vault:Data?{get{memory.data}set{memory.data=newValue}}
    var writes:Int{memory.writes}
    var checks = [String: Bool](), clock: TimeInterval = 100
    let access = StoreClient.CredentialAccess(load: { id, _ in id == profile ? memory.load() : nil },
      save: { _, _, _ in memory.save() }, remove: { _, _ in memory.remove() })
    let network = SteamClientSession(profile: profile, command: [CommandLine.arguments[1], CommandLine.arguments[2]], credentialAccess: access)
    let factory = SteamGameAuthorization(network: network, credentialAccess: access, uptime: { clock })
    var lastFailure:SteamGameAuthorization.Failure?
    var stage="startup"
    func check(_ value: Bool, _ name: String) throws {
      checks[name] = value;stage=name
      if !value { throw NSError(domain: "SteamGameAuthorizationFixture_" + name, code: 1) }
    }
    func spin(_ condition: () -> Bool) throws {
      let end = Date().addingTimeInterval(4)
      while !condition(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
      if !condition() { throw NSError(domain: "SteamGameAuthorizationFixtureTimeout_"+stage, code: 1) }
    }
    func settle() { let end = Date().addingTimeInterval(0.2); while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) } }
    func command(_ operation: String, _ options: [String: Any] = [:]) throws {
      var done = false
      network.request(operation, options: options) { if ["result", "error"].contains($0["type"] as? String ?? "") { done = true } }
      try spin { done }
    }
    func mode(_ value: String) throws { try command("fixture_mode", ["mode": value]) }
    func startedCount()->Int{Int((try?String(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3]).appendingPathComponent("authorization-count"),encoding:.utf8)) ?? "0") ?? 0}

    func online() throws {
      vault = original
      if !network.state.online { network.reconnect() }
      try spin { network.state.online && network.state.steamID == identity }
      try command("fixture_identity", ["steamID": identity])
    }
    func prepare(_ expectedFailure: Bool = false) throws -> SteamGameAuthorizationGrant? {
      var outcome: Result<SteamGameAuthorizationGrant, SteamGameAuthorization.Failure>?
      factory.prepare(profile: profile, gameID: "480") { outcome = $0 }
      try spin { outcome != nil }
      switch outcome! {
      case .success(let grant):
        lastFailure=nil
        if expectedFailure { throw NSError(domain: "UnexpectedAuthorizationGrant", code: 1) }
        return grant
      case .failure(let failure):
        lastFailure=failure
        if !expectedFailure { throw NSError(domain: "UnexpectedAuthorizationFailure", code: 1) }
        return nil
      }
    }
    func consume(_ grant: SteamGameAuthorizationGrant) throws -> Data {
      var outcome:Result<Data,SteamGameAuthorization.Failure>?
      grant.consume { outcome=$0 };try spin{outcome != nil};return try outcome!.get()
    }
    func consumeFails(_ grant: SteamGameAuthorizationGrant) -> Bool { do { _ = try consume(grant); return false } catch { return true } }
    defer { factory.cancel(); network.stop() }
    network.start(); try spin { network.state.online && network.state.steamID == identity }

    try mode("valid")
    let grant = try prepare()!
    try check(grant.profile == profile && grant.gameID == 480 && grant.steamID == identity, "serverIdentityMetadata")
    var frame = try consume(grant)
    var expected = Data("RDYAUTH1".utf8)
    for (value, count) in [(UInt64(15), 4), (UInt64(19), 4), (UInt64(identity)!, 8), (UInt64(480), 4)] {
      for shift in stride(from: (count - 1) * 8, through: 0, by: -8) { expected.append(UInt8((value >> shift) & 255)) }
    }
    expected.append(Data("fixture_accountfixture_only_secret".utf8))
    try check(frame == expected, "exactPrivateRDYAUTH1Frame")
    frame.resetBytes(in: 0..<frame.count); expected.resetBytes(in: 0..<expected.count)
    try check(consumeFails(grant), "singleUse")
    try check(!String(describing: grant).contains("fixture_only_secret") && !String(reflecting: grant).contains("fixture_only_secret") && Mirror(reflecting: grant).children.isEmpty, "opaqueDescriptionsAndReflection")

    for invalid in ["wrong_app", "wrong_identity", "numeric_authorized", "numeric_ticket", "false_ticket", "boolean_app", "invalid_individual", "error", "missing_ticket"] {
      try mode(invalid); _ = try prepare(true); try check(true, "reject_" + invalid)
      try check(lastFailure == (invalid=="error" ? .serviceFailure:.rejected),"safeClassification_"+invalid)
      let detail=try JSONEncoder().encode(factory.lastFailureDetail!)
      let fields=try JSONSerialization.jsonObject(with:detail)as![String:Any]
      try check(Set(fields.keys).isSubset(of:["code","steamResult","epochMatches","stateOnline","vaultMatches","appMatched","identityMatched","ticketReported"]),"diagnosticFieldWhitelist_"+invalid)
      let text=String(decoding:detail,as:UTF8.self)
      try check(!text.contains(identity) && !text.contains(profile.uuidString) && !text.contains("fixture_only_secret"),"diagnosticNoIdentityOrCredential_"+invalid)
    }
    for (name,failure,result) in [("error_denied",SteamGameAuthorization.Failure.notAuthorized,"AccessDenied"),
      ("error_timeout",.timeout,nil),("error_network",.network,"NoConnection"),("error_auth",.authenticationRequired,"Expired"),
      ("error_busy",.serviceFailure,nil),("error_invalid_callback",.rejected,"OK"),("error_uncorroborated_denial",.serviceFailure,nil),
      ("error_throttle",.rateLimited,"RateLimitExceeded"),("error_job",.serviceFailure,nil),("error_unknown_result",.serviceFailure,"Unknown"),
      ("error_numeric_facts",.serviceFailure,"OK")] as [(String,SteamGameAuthorization.Failure,String?)] {
      try mode(name);_=try prepare(true)
      try check(lastFailure==failure&&factory.lastFailureDetail?.steamResult==result,"specificSafeFailure_"+name)
      try check(vault==original&&writes==0,"failurePreservesCredential_"+name)
      if name=="error_numeric_facts"{try check(factory.lastFailureDetail?.appMatched==nil&&factory.lastFailureDetail?.ticketReported==nil,"numericFactsNeverBecomeObservedTrue")}
      if name=="error_invalid_callback"{try check(factory.lastFailureDetail?.appMatched==false&&factory.lastFailureDetail?.ticketReported==true,"callbackFactsRetainedWithoutTicketBytes")}
    }
    try mode("error_then_result");var terminalCount=0
    factory.prepare(profile:profile,gameID:"480"){result in terminalCount+=1;if case .failure(let reason)=result{lastFailure=reason}}
    try spin{terminalCount==1};settle()
    try check(terminalCount==1&&lastFailure == .network,"errorThenLatePositiveCannotCreateGrant")
    try mode("valid");_=try prepare();try check(factory.lastFailureDetail==nil,"successClearsPriorSafeFailure")
    try mode("error_busy");_=try prepare(true);try mode("valid");_=try prepare();try check(factory.lastFailureDetail==nil,"repeatedFailureAndSuccessStaySeparate")
    let malicious=SteamGameAuthorization.FailureDetail(code:"fixture_only_secret",steamResult:identity,epochMatches:true,stateOnline:true,vaultMatches:true,appMatched:nil,identityMatched:nil,ticketReported:nil)
    let diagnosticEncoder=JSONEncoder();diagnosticEncoder.outputFormatting=[.sortedKeys]
    let encoded=try diagnosticEncoder.encode(malicious),encodedText=String(decoding:encoded,as:UTF8.self)
    try check(malicious.code=="unknown_error" && malicious.steamResult=="Unknown" && !encodedText.contains("fixture_only_secret") && !encodedText.contains(identity),"failureDetailCannotSerializeUnlistedStrings")
    let logs=URL(fileURLWithPath:CommandLine.arguments[3]).appendingPathComponent("private-diagnostic")
    try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    try malicious.writePrivate(logs:logs)
    let file=logs.appendingPathComponent("steam-last-authorization-failure.json")
    let stored=try Data(contentsOf:file),fileMode=(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions]as!NSNumber).intValue
    try check(stored==encoded&&fileMode==0o600,"diagnosticWrittenAtomicallyWithPrivatePermissions")
    let alias=logs.deletingLastPathComponent().appendingPathComponent("diagnostic-alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:logs)
    var refused=false;do{try malicious.writePrivate(logs:alias)}catch{refused=true}
    try check(refused,"diagnosticDirectorySymlinkRejected")
    var immediateFailure = false
    factory.prepare(profile: other, gameID: "480") { if case .failure = $0 { immediateFailure = true } }
    try check(immediateFailure, "wrongProfileRejectedBeforeRequest")
    for app in ["0", "-1", "480.0", "4294967295", "4294967296"] {
      immediateFailure = false
      factory.prepare(profile: profile, gameID: app) { if case .failure = $0 { immediateFailure = true } }
      try check(immediateFailure, "invalidApp_" + app)
    }
    for (name, source) in [
      ("missing", nil as Data?),
      ("expired", try JSONSerialization.data(withJSONObject: ["username":"fixture_account", "refresh_token":"fixture_only_secret", "refresh_token_expires_at_epoch":1])),
      ("differentAccount", try JSONSerialization.data(withJSONObject: ["username":"another_fixture_account", "refresh_token":"fixture_only_secret"]))
    ] {
      vault = source; immediateFailure = false
      factory.prepare(profile: profile, gameID: "480") { if case .failure = $0 { immediateFailure = true } }
      try spin{immediateFailure}
      try check(immediateFailure, name + "VaultRejectedBeforeRequest")
    }
    vault = original

    try mode("delay")
    var completionCount = 0, failed = false
    let beforeChanged=startedCount()
    factory.prepare(profile: profile, gameID: "480") { completionCount += 1; if case .failure = $0 { failed = true } }
    try spin{startedCount()>beforeChanged}
    vault = try JSONSerialization.data(withJSONObject: ["username":"fixture_account", "refresh_token":"different_fixture_secret"])
    try spin { completionCount == 1 }; try check(failed, "vaultChangeRejectsLateResult"); vault = original
    try check(factory.lastFailureDetail?.code=="local_credentials_changed"&&factory.lastFailureDetail?.vaultMatches==false,"localVaultChangeIdentifiedWithoutSteamBlame")

    for terminal in ["revoked", "logged_out", "changed_identity"] {
      try mode(terminal); _ = try prepare(true); try check(true, terminal + "RejectsResult")
      if terminal=="revoked"{try check(factory.lastFailureDetail?.steamResult=="Revoked"&&factory.lastFailureDetail?.stateOnline==false,"staleResultRetainsSafeConnectionResult")}
      stage="reconnectAfter_"+terminal
      network.stop(); vault = original; network.reconnect(); try spin { network.state.online && network.state.steamID == identity }
    }
    try mode("delay"); completionCount = 0; var cancellation: SteamGameAuthorization.Failure?
    stage="waitCancellationRequestStarted"
    let beforeCancelled=startedCount()
    factory.prepare(profile: profile, gameID: "480") { result in completionCount += 1; if case .failure(let failure) = result { cancellation = failure } }
    try spin{startedCount()>beforeCancelled}
    factory.cancel(); factory.cancel(); settle()
    try check(completionCount == 1 && cancellation == .cancelled, "cancelCompletesOnceAndSuppressesLateCallback")
    try command("fixture_assert_cancelled")
    try check(true, "cancelReachesPersistentService")
    completionCount = 0
    factory.prepare(profile: profile, gameID: "480") { _ in completionCount += 1 }
    network.stop(); vault = original; network.reconnect(); try spin { network.state.online && network.state.steamID == identity }
    settle(); try check(completionCount == 0, "generationRestartDropsOldCallback"); factory.cancel()
    try mode("wrong_envelope"); completionCount = 0
    factory.prepare(profile: profile, gameID: "480") { _ in completionCount += 1 }
    settle(); try check(completionCount == 0, "staleGenerationEnvelopeIgnored"); factory.cancel()

    try mode("valid")
    var held = try prepare()!; clock += 16
    try check(consumeFails(held), "deadlineExpiresGrant"); clock = 100
    held = try prepare()!; factory.cancel(); try check(consumeFails(held), "cancelInvalidatesDeliveredGrant")
    held = try prepare()!; vault = nil; try check(consumeFails(held), "consumeRechecksVault"); vault = original
    held = try prepare()!; try command("fixture_identity", ["steamID":"76561198000000002"])
    try check(consumeFails(held), "consumeRechecksIdentity"); try command("fixture_identity", ["steamID":identity])
    held = try prepare()!; network.goOffline(); try spin { !network.state.online }
    try check(consumeFails(held), "consumeRechecksOnline")
    immediateFailure = false
    factory.prepare(profile: profile, gameID: "480") { if case .failure = $0 { immediateFailure = true } }
    try check(immediateFailure, "offlineNeverStartsLogin")
    try check(factory.lastFailureDetail?.code=="local_offline"&&factory.lastFailureDetail?.stateOnline==false,"offlinePreflightHasSafeLocalCause")
    try command("fixture_connection_result",["steamResult":"Expired"])
    factory.prepare(profile:profile,gameID:"480"){_ in}
    try check(factory.lastFailureDetail?.steamResult=="Expired"&&factory.lastFailureDetail?.stateOnline==false,"offlinePreflightRetainsSafeConnectionResult")
    try online(); try mode("valid")
    held = try prepare()!; network.stop(); network.reconnect(); try spin { network.state.online && network.state.steamID == identity }
    try check(consumeFails(held), "consumeRechecksGeneration")
    held = try prepare()!;memory.delay=0.2
    var delayed:Result<Data,SteamGameAuthorization.Failure>?,heartbeat=false
    held.consume{delayed=$0}
    DispatchQueue.main.asyncAfter(deadline:.now()+0.02){heartbeat=true}
    try spin{heartbeat};try check(delayed==nil,"slowConsumeVaultNeverBlocksMainRunLoop")
    factory.cancel();try spin{delayed != nil}
    if case .failure=delayed!{try check(true,"cancelWhileConsumeReadPendingCannotDeliverCredentialFrame")}else{try check(false,"cancelWhileConsumeReadPendingCannotDeliverCredentialFrame")}
    memory.delay=0
    try check(memory.mainCalls==0,"allAuthorizationAndConsumeCredentialIOOffMain")
    held = try prepare()!; network.logout(); try check(consumeFails(held), "logoutInvalidatesGrant")
    try check(writes == 0, "noCredentialWrites")
    checks["allPassed"] = checks.values.allSatisfy { $0 }
    print(String(data: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), encoding: .utf8)!)
  }
}
