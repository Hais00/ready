// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

@main struct ReadySteamGameAuthorizationProbe {
  @MainActor static func main() throws {
    let profile = UUID(), other = UUID(), identity = "76561198000000001"
    let original = try JSONSerialization.data(withJSONObject: ["username":"fixture_account", "refresh_token":"fixture_only_secret"])
    var vault: Data? = original, writes = 0, checks = [String: Bool](), clock: TimeInterval = 100
    let access = StoreClient.CredentialAccess(load: { id, _ in id == profile ? vault : nil },
      save: { _, _, _ in writes += 1 }, remove: { _, _ in vault = nil })
    let network = SteamClientSession(profile: profile, command: [CommandLine.arguments[1], CommandLine.arguments[2]], credentialAccess: access)
    let factory = SteamGameAuthorization(network: network, credentialAccess: access, uptime: { clock })
    func check(_ value: Bool, _ name: String) throws {
      checks[name] = value
      if !value { throw NSError(domain: "SteamGameAuthorizationFixture_" + name, code: 1) }
    }
    func spin(_ condition: () -> Bool) throws {
      let end = Date().addingTimeInterval(4)
      while !condition(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
      if !condition() { throw NSError(domain: "SteamGameAuthorizationFixtureTimeout", code: 1) }
    }
    func settle() { let end = Date().addingTimeInterval(0.2); while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) } }
    func command(_ operation: String, _ options: [String: Any] = [:]) throws {
      var done = false
      network.request(operation, options: options) { if ["result", "error"].contains($0["type"] as? String ?? "") { done = true } }
      try spin { done }
    }
    func mode(_ value: String) throws { try command("fixture_mode", ["mode": value]) }
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
        if expectedFailure { throw NSError(domain: "UnexpectedAuthorizationGrant", code: 1) }
        return grant
      case .failure:
        if !expectedFailure { throw NSError(domain: "UnexpectedAuthorizationFailure", code: 1) }
        return nil
      }
    }
    func consumeFails(_ grant: SteamGameAuthorizationGrant) -> Bool { do { _ = try grant.consume(); return false } catch { return true } }
    defer { factory.cancel(); network.stop() }
    network.start(); try spin { network.state.online && network.state.steamID == identity }

    try mode("valid")
    let grant = try prepare()!
    try check(grant.profile == profile && grant.gameID == 480 && grant.steamID == identity, "serverIdentityMetadata")
    var frame = try grant.consume()
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
    }
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
      try check(immediateFailure, name + "VaultRejectedBeforeRequest")
    }
    vault = original

    try mode("delay")
    var completionCount = 0, failed = false
    factory.prepare(profile: profile, gameID: "480") { completionCount += 1; if case .failure = $0 { failed = true } }
    vault = try JSONSerialization.data(withJSONObject: ["username":"fixture_account", "refresh_token":"different_fixture_secret"])
    try spin { completionCount == 1 }; try check(failed, "vaultChangeRejectsLateResult"); vault = original

    for terminal in ["revoked", "logged_out", "changed_identity"] {
      try mode(terminal); _ = try prepare(true); try check(true, terminal + "RejectsResult")
      network.stop(); vault = original; network.start(); try spin { network.state.online && network.state.steamID == identity }
    }
    try mode("delay"); completionCount = 0; var cancellation: SteamGameAuthorization.Failure?
    factory.prepare(profile: profile, gameID: "480") { result in completionCount += 1; if case .failure(let failure) = result { cancellation = failure } }
    factory.cancel(); factory.cancel(); settle()
    try check(completionCount == 1 && cancellation == .cancelled, "cancelCompletesOnceAndSuppressesLateCallback")
    try command("fixture_assert_cancelled")
    try check(true, "cancelReachesPersistentService")
    completionCount = 0
    factory.prepare(profile: profile, gameID: "480") { _ in completionCount += 1 }
    network.stop(); vault = original; network.start(); try spin { network.state.online && network.state.steamID == identity }
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
    try online(); try mode("valid")
    held = try prepare()!; network.stop(); network.start(); try spin { network.state.online && network.state.steamID == identity }
    try check(consumeFails(held), "consumeRechecksGeneration")
    held = try prepare()!; network.logout(); try check(consumeFails(held), "logoutInvalidatesGrant")
    try check(writes == 0, "noCredentialWrites")
    checks["allPassed"] = checks.values.allSatisfy { $0 }
    print(String(data: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), encoding: .utf8)!)
  }
}
