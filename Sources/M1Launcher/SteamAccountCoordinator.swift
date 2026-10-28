// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import Foundation
import LauncherCore

/// One credential-backed Steam account per profile, shared by every target.
/// SteamKit requests remain short-lived connections; this is not a game host.
/// Every callback is credential-free. Backend worker handoff/readiness is pending.
@MainActor
final class SteamAccountCoordinator {
  enum Target { case nativeMac, wineWindows }
  typealias Event = ([String: Any]) -> Void
  private struct Key: Hashable { let profile: UUID; let app: UInt32 }
  private final class AuthFlight {
    let generation: UUID
    var request: UUID?
    var subscribers = [UUID: Event]()
    var qr: [String: Any]?
    init(_ generation: UUID) { self.generation = generation }
  }
  private final class GameFlight {
    let generation: UUID
    var revision: UUID?
    var request: UUID?
    var expected: UInt64?
    var subscribers = [UUID: Event]()
    init(_ generation: UUID, expected: UInt64?) { self.generation = generation; self.expected = expected }
  }
  private let client: StoreClient
  private var generations = [UUID: UUID]()
  private var auth = [UUID: AuthFlight]()
  private var games = [Key: GameFlight]()
  private var active = Set<UUID>()
  private var prompted = [UUID: UUID]()
  private var rejected = Set<UUID>()
  private var identities = [UUID: (UUID, UInt64)]()
  var hasActiveRequests: Bool { !auth.isEmpty || !games.isEmpty || client.hasActiveRequests }

  init(client: StoreClient) { self.client = client }
  private func generation(_ profile: UUID) -> UUID {
    if generations[profile] == nil { generations[profile] = UUID() }
    return generations[profile]!
  }
  private func terminal(_ subscribers: [UUID: Event], profile: UUID, generation: UUID, value: [String: Any]) {
    for (id, callback) in subscribers {
      guard generations[profile] == generation, active.remove(id) != nil else { continue }
      callback(value)
    }
  }
  private func progress(_ subscribers: [UUID: Event], profile: UUID, generation: UUID, value: [String: Any]) {
    for (id, callback) in subscribers where active.contains(id) {
      guard generations[profile] == generation, active.contains(id) else { continue }
      callback(value)
    }
  }
  private func failure(_ code: String) -> [String: Any] {
    ["type": "error", "code": code, "message": "Operazione Steam non riuscita."]
  }
  private func requireAuthentication(_ profile: UUID, flight: GameFlight) {
    guard prompted[profile] == nil,
      let (id, callback) = flight.subscribers.first(where: { active.contains($0.key) }) else { return }
    prompted[profile] = id
    callback(["type": "authentication_required", "code": "authentication_required",
              "message": "Accedi a Steam per questo profilo."])
  }

  /// Explicit user login only. Existing valid credentials never start another QR.
  @discardableResult
  func authenticate(profile: UUID, force: Bool = false, event: @escaping Event) -> UUID {
    let id = UUID()
    if let flight = auth[profile] {
      active.insert(id); flight.subscribers[id] = event
      if let qr = flight.qr { event(qr) }
      return id
    }
    if !force && !rejected.contains(profile) && client.steamCredentialStatus(profile: profile) == .available {
      active.insert(id)
      let current = generation(profile)
      DispatchQueue.main.async { [weak self] in
        self?.terminal([id: event], profile: profile, generation: current,
                       value: ["type": "result", "accountConnected": true, "reusedStoredAccount": true])
      }
      return id
    }
    if force { cancel(profile: profile) }
    active.insert(id)
    let flight = AuthFlight(generation(profile)); flight.subscribers[id] = event; auth[profile] = flight
    flight.request = client.request(operation: "auth_begin", store: .steam, profile: profile) { [weak self, weak flight] value in
      DispatchQueue.main.async { [weak self, weak flight] in
        guard let self, let flight, self.auth[profile] === flight,
          self.generations[profile] == flight.generation else { return }
        switch value["type"] as? String {
        case "qr":
          guard let url = value["url"] as? String, let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else {
            if let request = flight.request { self.client.cancel(request) }
            self.endAuthentication(profile, flight: flight, value: self.failure("invalid_qr")); return
          }
          let qr: [String: Any] = ["type": "qr", "url": url]
          flight.qr = qr
          self.progress(flight.subscribers, profile: profile, generation: flight.generation, value: qr)
        case "result":
          guard self.client.steamCredentialStatus(profile: profile) == .available else {
            self.endAuthentication(profile, flight: flight, value: self.failure("authentication_required")); return
          }
          self.rejected.remove(profile); self.prompted.removeValue(forKey: profile); self.identities.removeValue(forKey: profile)
          self.endAuthentication(profile, flight: flight, value: ["type": "result", "accountConnected": true, "reusedStoredAccount": false])
          for (key, game) in self.games where key.profile == profile && game.request == nil {
            self.start(key, flight: game)
          }
        case "error": self.endAuthentication(profile, flight: flight, value: self.failure(self.safeCode(value)))
        default: break
        }
      }
    }
    return id
  }
  private func endAuthentication(_ profile: UUID, flight: AuthFlight, value: [String: Any]) {
    guard auth[profile] === flight else { return }
    auth.removeValue(forKey: profile)
    terminal(flight.subscribers, profile: profile, generation: flight.generation, value: value)
  }

  /// Both native and Wine callers use the same profile/app flight and vault key.
  @discardableResult
  func authorize(profile: UUID, gameID: String, target: Target, expectedSteamID: String? = nil,
                 event: @escaping Event) -> UUID {
    let id = UUID(); active.insert(id)
    guard let appValue = Self.number(gameID), appValue > 0, appValue <= UInt64(UInt32.max),
      expectedSteamID == nil || Self.individual(expectedSteamID!) != nil else {
      terminal([id:event], profile: profile, generation: generation(profile), value: failure("invalid_game_id")); return id
    }
    let key = Key(profile: profile, app: UInt32(appValue))
    let expected = expectedSteamID.flatMap(Self.individual)
    if let flight = games[key] {
      if let expected, let original = flight.expected, expected != original {
        terminal([id:event], profile: profile, generation: generation(profile), value: failure("identity_mismatch")); return id
      }
      if flight.expected == nil { flight.expected = expected }
      flight.subscribers[id] = event
      return id
    }
    let flight = GameFlight(generation(profile), expected: expected); flight.subscribers[id] = event; games[key] = flight
    start(key, flight: flight)
    return id
  }
  private func start(_ key: Key, flight: GameFlight) {
    guard games[key] === flight, flight.request == nil, auth[key.profile] == nil else { return }
    guard !rejected.contains(key.profile), client.steamCredentialStatus(profile: key.profile) == .available,
      let revision = client.steamCredentialRevision(profile: key.profile) else {
      requireAuthentication(key.profile, flight: flight); return
    }
    flight.revision = revision
    if let binding = identities[key.profile], binding.0 == revision {
      if let expected = flight.expected, expected != binding.1 {
        endGame(key, flight: flight, value: failure("identity_mismatch")); return
      }
      flight.expected = binding.1
    }
    flight.request = client.request(operation: "authorize_game", store: .steam, profile: key.profile,
                                     options: ["gameID": String(key.app)]) { [weak self, weak flight] value in
      DispatchQueue.main.async { [weak self, weak flight] in
        guard let self, let flight, self.games[key] === flight,
          self.generations[key.profile] == flight.generation else { return }
        if value["type"] as? String == "result" {
          guard self.client.steamCredentialRevision(profile: key.profile) == flight.revision,
            Self.trueValue(value["authorized"]), Self.trueValue(value["ownershipTicketReceived"]),
            let app = Self.number(value["appID"]), app == UInt64(key.app),
            let identity = Self.individual(value["steamID"]), flight.expected == nil || flight.expected == identity else {
            self.endGame(key, flight: flight, value: self.failure("invalid_authorization")); return
          }
          self.identities[key.profile] = (revision, identity)
          self.endGame(key, flight: flight, value: ["type":"result", "authorized":true,
            "ownershipTicketReceived":true, "appID":key.app, "steamID":String(identity),
            "credentialRevision":revision.uuidString, "backendSessionReady":false])
        } else if value["type"] as? String == "error" {
          let code = self.safeCode(value)
          let exactRejection = StoreClient.isSteamAuthenticationRejection(value)
          if exactRejection {
            self.rejected.insert(key.profile); flight.request = nil
            self.requireAuthentication(key.profile, flight: flight)
          } else { self.endGame(key, flight: flight, value: self.failure(code)) }
        }
      }
    }
  }
  private func endGame(_ key: Key, flight: GameFlight, value: [String: Any]) {
    guard games[key] === flight else { return }
    games.removeValue(forKey: key)
    terminal(flight.subscribers, profile: key.profile, generation: flight.generation, value: value)
  }
  private func safeCode(_ value: [String: Any]) -> String {
    let code = value["code"] as? String ?? "steam_error"
    return ["authentication_required","auth_required","steam_login_failed","not_authorized","steam_error",
      "timeout","disconnected","backend_missing","unsupported_operation","credentials_changed"].contains(code) ? code : "steam_error"
  }
  private static func trueValue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
    return number.boolValue
  }
  private static func number(_ value: Any?) -> UInt64? {
    let text: String
    if let string = value as? String { text = string }
    else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { text = n.stringValue }
    else { return nil }
    guard !text.isEmpty, text.utf8.count <= 20, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return UInt64(text)
  }
  private static func individual(_ value: Any?) -> UInt64? {
    guard let n = number(value), n >> 56 == 1, (n >> 52) & 15 == 1,
      (n >> 32) & 0xfffff == 1, n & 0xffffffff != 0 else { return nil }
    return n
  }
  func cancel(_ id: UUID) {
    active.remove(id)
    let relinquishedProfiles = prompted.filter { $0.value == id }.map { $0.key }
    for (profile, flight) in Array(auth) where flight.subscribers.removeValue(forKey: id) != nil {
      if flight.subscribers.isEmpty {
        cancel(profile: profile)
      }
    }
    for (key, flight) in Array(games) where flight.subscribers.removeValue(forKey: id) != nil {
      if flight.subscribers.isEmpty {
        if let request = flight.request { client.cancel(request) }
        games.removeValue(forKey: key)
      }
    }
    for profile in relinquishedProfiles {
      prompted.removeValue(forKey: profile)
      if auth[profile] == nil,
        let waiting = games.first(where: { $0.key.profile == profile && $0.value.request == nil })?.value {
        requireAuthentication(profile, flight: waiting)
      }
    }
  }
  func cancel(profile: UUID) {
    generations[profile] = UUID()
    if let flight = auth.removeValue(forKey: profile) {
      active.subtract(flight.subscribers.keys)
    }
    for key in games.keys.filter({ $0.profile == profile }) {
      if let flight = games.removeValue(forKey: key) { active.subtract(flight.subscribers.keys) }
    }
    prompted.removeValue(forKey: profile); identities.removeValue(forKey: profile)
    client.invalidateSteamAccount(profile: profile)
  }
  func signOut(profile: UUID) {
    cancel(profile: profile)
    rejected.remove(profile)
    client.invalidateSteamAccount(profile: profile, removeStored: true)
  }
}
