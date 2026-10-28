// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
import CryptoKit
import LauncherCore

/// Private, short-lived handoff for a separately supervised game host. Creating
/// this grant says nothing about whether that host or its launch gate is ready.
@MainActor
final class SteamGameAuthorizationGrant: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  nonisolated var description: String { "[private Steam game authorization]" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
  let profile: UUID
  let gameID: UInt32
  let steamID: String
  private var packet: NSMutableData?
  private let valid: () -> Bool
  private let deadline: TimeInterval
  private let uptime: () -> TimeInterval

  fileprivate init(profile: UUID, gameID: UInt32, steamID: String, packet: NSMutableData, valid: @escaping () -> Bool,
                   uptime: @escaping () -> TimeInterval, lifetime: TimeInterval) {
    self.profile = profile; self.gameID = gameID; self.steamID = steamID
    self.packet = packet; self.valid = valid; self.uptime = uptime
    deadline = uptime() + lifetime
  }
  /// The caller must use only a private anonymous pipe and clear its returned
  /// Data after handing it off. Every attempt consumes and erases this grant.
  func consume() throws -> Data {
    guard let packet else { throw SteamGameAuthorization.Failure.consumed }
    defer { invalidate() }
    guard uptime() < deadline, valid() else { throw SteamGameAuthorization.Failure.stale }
    return Data(bytes: packet.bytes, count: packet.length)
  }
  fileprivate func invalidate() {
    if let packet { packet.resetBytes(in: NSRange(location: 0, length: packet.length)); packet.length = 0 }
    packet = nil
  }
  deinit {
    if let packet { packet.resetBytes(in: NSRange(location: 0, length: packet.length)); packet.length = 0 }
  }
}

/// Uses only an already-online persistent client. Never logs in, requests a QR,
/// starts a one-shot StoreClient, or puts credentials in an event dictionary.
@MainActor
final class SteamGameAuthorization {
  enum Failure: String, Error { case unavailable, invalidRequest, rejected, stale, consumed, cancelled }
  typealias Completion = (Result<SteamGameAuthorizationGrant, Failure>) -> Void
  private let network: SteamClientSession
  private let credentialAccess: StoreClient.CredentialAccess
  private let uptime: () -> TimeInterval
  private let grantLifetime: TimeInterval
  private var requestID: String?
  private var pendingCompletion: Completion?
  private var revision = UUID()
  private weak var grant: SteamGameAuthorizationGrant?

  init(network: SteamClientSession, credentialAccess: StoreClient.CredentialAccess,
       uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       grantLifetime: TimeInterval = 15) {
    self.network = network; self.credentialAccess = credentialAccess; self.uptime = uptime
    self.grantLifetime = grantLifetime.isFinite ? min(15, max(0, grantLifetime)) : 0
  }

  @discardableResult
  func prepare(profile: UUID, gameID: String, completion: @escaping Completion) -> String {
    let attempt = cancelPending()
    let fallback = UUID().uuidString
    // Cancellation completions can themselves start a newer preparation.
    guard revision == attempt else { completion(.failure(.cancelled)); return fallback }
    guard let app = Self.number(gameID), app > 0, app < UInt64(UInt32.max) else {
      completion(.failure(.invalidRequest)); return fallback
    }
    guard network.profile == profile, network.state.online,
      let identity = Self.individual(network.state.steamID),
      let source = credentialAccess.load(profile, .steam), CredentialVault.steamStatus(source) == .available,
      let credentials = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
      let account = credentials["username"] as? String,
      account.caseInsensitiveCompare(network.state.accountName) == .orderedSame else {
      completion(.failure(.unavailable)); return fallback
    }
    let epoch = network.generation, digest = Data(SHA256.hash(data: source))
    let access = credentialAccess
    let stillValid: () -> Bool = { [weak network] in
      guard let network, network.profile == profile, network.generation == epoch, network.state.online,
        Self.individual(network.state.steamID) == identity,
        account.caseInsensitiveCompare(network.state.accountName) == .orderedSame,
        let current = access.load(profile, .steam), CredentialVault.steamStatus(current) == .available else { return false }
      return Data(SHA256.hash(data: current)) == digest
    }
    // A synchronous transport failure may run completion before request returns.
    var finished = false
    pendingCompletion = completion
    let id = network.request("authorize_game", options: ["gameID": String(app)]) { [weak self] event in
      guard let self, self.revision == attempt else { return }
      let type = event["type"] as? String
      guard type == "result" || type == "error" else { return }
      finished = true; self.requestID = nil; self.pendingCompletion = nil
      guard stillValid() else { completion(.failure(.stale)); return }
      guard type == "result", Self.trueValue(event["authorized"]), Self.trueValue(event["ownershipTicketReceived"]),
        Self.number(event["appID"]) == app, Self.individual(event["steamID"]) == identity,
        let current = access.load(profile, .steam), Data(SHA256.hash(data: current)) == digest,
        let packet = Self.packet(current, identity: identity, app: UInt32(app)) else {
        completion(.failure(.rejected)); return
      }
      let grant = SteamGameAuthorizationGrant(profile: profile, gameID: UInt32(app), steamID: String(identity),
        packet: packet, valid: stillValid, uptime: self.uptime, lifetime: self.grantLifetime)
      self.grant = grant
      completion(.success(grant))
    }
    if !finished, revision == attempt { requestID = id }
    return id
  }
  func cancel() { _ = cancelPending() }
  private func cancelPending() -> UUID {
    let epoch = UUID(); revision = epoch; grant?.invalidate(); grant = nil
    let completion = pendingCompletion; pendingCompletion = nil
    if let id = requestID { requestID = nil; network.cancel(id) }
    completion?(.failure(.cancelled))
    return epoch
  }
  private static func trueValue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
    return number.boolValue
  }
  private static func number(_ value: Any?) -> UInt64? {
    let text: String
    if let string = value as? String { text = string }
    else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
    else { return nil }
    guard !text.isEmpty, text.utf8.count <= 20, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return UInt64(text)
  }
  private static func individual(_ value: Any?) -> UInt64? {
    guard let id = number(value), id >> 56 == 1, (id >> 52) & 15 == 1,
      (id >> 32) & 0xfffff == 1, id & 0xffffffff != 0 else { return nil }
    return id
  }
  private static func packet(_ source: Data, identity: UInt64, app: UInt32) -> NSMutableData? {
    guard CredentialVault.steamStatus(source) == .available,
      let value = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
      let account = value["username"] as? String, let token = value["refresh_token"] as? String else { return nil }
    let packet = NSMutableData(data: Data("RDYAUTH1".utf8))
    func append<T: FixedWidthInteger>(_ input: T) {
      var big = input.bigEndian
      withUnsafeBytes(of: &big) { packet.append($0.baseAddress!, length: $0.count) }
    }
    append(UInt32(account.utf8.count)); append(UInt32(token.utf8.count)); append(identity); append(app)
    for text in [account, token] { for byte in text.utf8 { var value = byte; packet.append(&value, length: 1) } }
    return packet
  }
}
