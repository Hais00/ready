// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import CryptoKit
import Foundation
import LauncherCore

/// Private JSONL IPC. A request remains active through process cleanup and callback delivery.
final class StoreClient {
  struct CredentialAccess {
    var load: (UUID, Store) -> Data?
    var save: (Data, UUID, Store) throws -> Void
    var remove: (UUID, Store) -> Void = { _, _ in }
    static func keychain(stateRoot: URL? = nil) -> Self {
      Self(
        load: { CredentialVault.load(profile: $0, store: $1, stateRoot: stateRoot) },
        save: { try CredentialVault.save($0, profile: $1, store: $2, stateRoot: stateRoot) },
        remove: { CredentialVault.remove(profile: $0, store: $1, stateRoot: stateRoot) })
    }
  }
  private final class RequestState {
    let id: UUID
    let callback: ([String: Any]) -> Void
    let store: Store
    let profile: UUID
    let accountEpoch: UUID
    var credentialFingerprint: Data?
    var cancelled = false
    var terminationRequested = false
    var process: Process?
    init(id: UUID, store: Store, profile: UUID, accountEpoch: UUID, callback: @escaping ([String: Any]) -> Void) {
      self.id = id
      self.callback = callback
      self.store = store
      self.profile = profile
      self.accountEpoch = accountEpoch
    }
  }
  private enum Failure: Error {
    case request, launch, pipe, response, incomplete, exited
    var message: String {
      switch self {
      case .request: return "Richiesta dello store non valida."
      case .launch: return "Impossibile avviare il servizio dello store."
      case .pipe: return "Comunicazione con lo store interrotta."
      case .response: return "Risposta dello store non valida o troppo grande."
      case .incomplete: return "Il servizio dello store è terminato senza una risposta conclusiva."
      case .exited: return "Il servizio dello store è terminato con un errore."
      }
    }
  }

  let project: URL
  let runtimeRoot: URL
  private let stateRoot: URL?
  private let credentials: CredentialAccess
  private let workerQueue: DispatchQueue
  private var requests = [UUID: RequestState]()
  private var pendingRequests = Set<UUID>()
  private var steamEpochs = [UUID: UUID]()
  private var steamFingerprints = [UUID: Data]()
  private var steamRevisions = [UUID: UUID]()
  private var steamRejectedFingerprints = [UUID: Data]()
  // A callback may synchronously call cancel/hasActiveRequests. Keeping this
  // recursive lock through delivery makes cancel a barrier against late events.
  private let lock = NSRecursiveLock()
  var hasActiveRequests: Bool { withLock { !pendingRequests.isEmpty } }

  func steamCredentialStatus(profile: UUID) -> CredentialVault.SteamStatus {
    withLock { steamStatus(credentials.load(profile, .steam), profile: profile) }
  }
  private func steamStatus(_ data: Data?, profile: UUID) -> CredentialVault.SteamStatus {
    if let data, steamRejectedFingerprints[profile] == Data(SHA256.hash(data: data)) { return .expired }
    return CredentialVault.steamStatus(data)
  }
  static func isSteamAuthenticationRejection(_ value: [String: Any]) -> Bool {
    let code = value["code"] as? String ?? ""
    return ["authentication_required", "auth_required"].contains(code)
      || (code == "steam_login_failed" && ["Expired", "Revoked", "InvalidPassword", "AccessDenied",
        "AccountDisabled", "AccountLogonDenied", "AccountLockedDown", "AccountLoginDeniedNeedTwoFactor"]
        .contains(value["steamResult"] as? String ?? ""))
  }
  /// Opaque local revision only; the credential digest never leaves this client.
  func steamCredentialRevision(profile: UUID) -> UUID? {
    withLock {
      guard let data = credentials.load(profile, .steam),
        steamStatus(data, profile: profile) == .available else { return nil }
      let fingerprint = Data(SHA256.hash(data: data))
      if steamFingerprints[profile] != fingerprint {
        steamFingerprints[profile] = fingerprint
        steamRevisions[profile] = UUID()
      }
      return steamRevisions[profile]
    }
  }

  init(
    project: URL, stateRoot: URL? = nil, runtimeRoot: URL? = nil, credentialAccess: CredentialAccess? = nil,
    workerQueue: DispatchQueue = .global(qos: .userInitiated)
  ) {
    self.project = project
    self.runtimeRoot = runtimeRoot ?? project.appendingPathComponent("Runtime")
    self.stateRoot = stateRoot
    self.credentials = credentialAccess ?? .keychain(stateRoot: stateRoot)
    self.workerQueue = workerQueue
  }
  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
  @discardableResult
  func request(
    operation: String, store: Store, profile: UUID, options: [String: Any] = [:],
    event: @escaping ([String: Any]) -> Void
  ) -> UUID {
    let id = UUID()
    let epoch = withLock { () -> UUID in
      if steamEpochs[profile] == nil { steamEpochs[profile] = UUID() }
      return steamEpochs[profile]!
    }
    let state = RequestState(id: id, store: store, profile: profile, accountEpoch: epoch, callback: event)
    withLock {
      requests[id] = state
      pendingRequests.insert(id)
    }
    workerQueue.async { [self] in
      perform(state, operation: operation, store: store, profile: profile, options: options)
    }
    return id
  }

  private func deliver(_ value: [String: Any], state: RequestState) {
    var safe = value
    safe.removeValue(forKey: "credentials")
    DispatchQueue.main.async { [self] in
      withLock {
        guard !state.cancelled else { return }
        guard state.store != .steam || steamEpochs[state.profile] == state.accountEpoch else { return }
        state.callback(safe)
      }
    }
  }
  private func finish(
    _ state: RequestState, store: Store, profile: UUID,
    terminal: [String: Any]? = nil, failure: Failure? = nil
  ) {
    // FIFO with the request's earlier progress callbacks; pending stays true
    // until the final callback has returned, even if the process already exited.
    DispatchQueue.main.async { [self] in
      withLock {
        defer {
          requests.removeValue(forKey: state.id)
          pendingRequests.remove(state.id)
        }
        guard !state.cancelled else { return }
        guard store != .steam || steamEpochs[profile] == state.accountEpoch else { return }
        var value = terminal ?? ["type": "error", "message": (failure ?? .incomplete).message]
        if store == .steam, let fingerprint = state.credentialFingerprint {
          let current = credentials.load(profile, .steam).map { Data(SHA256.hash(data: $0)) }
          if current != fingerprint {
            value = ["type": "error", "code": "credentials_changed", "message": "L’account Steam è cambiato durante la richiesta."]
          }
        }
        if value["type"] as? String == "result",
          let refreshed = value["credentials"] as? [String: Any], !refreshed.isEmpty
        {
          do {
            try credentials.save(JSONSerialization.data(withJSONObject: refreshed), profile, store)
            if store == .steam { steamRejectedFingerprints.removeValue(forKey: profile) }
          } catch {
            value = ["type": "error", "message": "Impossibile salvare l’account nel Portachiavi."]
          }
        }
        if store == .steam, let fingerprint = state.credentialFingerprint, value["type"] as? String == "error" {
          if Self.isSteamAuthenticationRejection(value) { steamRejectedFingerprints[profile] = fingerprint }
        }
        value.removeValue(forKey: "credentials")
        state.callback(value)
      }
    }
  }
  private func terminate(_ state: RequestState) {
    withLock {
      guard !state.terminationRequested, let process = state.process, process.isRunning else {
        return
      }
      state.terminationRequested = true
      // Signal only this still-running supervisor. It reserves the child PGID,
      // terminates descendants, and exits only after their descriptors close.
      process.terminate()
    }
  }
  private func perform(
    _ state: RequestState, operation: String, store: Store, profile: UUID, options: [String: Any]
  ) {
    let input = Pipe()
    let output = Pipe()
    let task = Process()
    var launched = false
    var terminal: [String: Any]?
    var failure: Failure?
    defer {
      if launched {
        if task.isRunning { terminate(state) }
        task.waitUntilExit()
      }
      for handle in [input.fileHandleForReading, input.fileHandleForWriting,
        output.fileHandleForReading, output.fileHandleForWriting]
      { try? handle.close() }
      withLock { state.process = nil }
      finish(state, store: store, profile: profile, terminal: terminal, failure: failure)
    }
    guard !withLock({ state.cancelled }) else { return }
    do {
      let credentialData = credentials.load(profile, store)
      if store == .steam && operation != "auth_begin" && operation != "auth_start" {
        withLock { state.credentialFingerprint = credentialData.map { Data(SHA256.hash(data: $0)) } }
      }
      let account = credentialData.flatMap {
        try? JSONSerialization.jsonObject(with: $0)
      } as? [String: Any] ?? [:]
      let request: [String: Any] = [
        "operation": operation, "store": store.rawValue, "profileID": profile.uuidString,
        "credentials": account, "options": options,
      ]
      guard JSONSerialization.isValidJSONObject(request) else { throw Failure.request }
      var bytes: Data
      do { bytes = try JSONSerialization.data(withJSONObject: request) }
      catch { throw Failure.request }
      bytes.append(0x0a)
      task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      task.arguments = [
        "python3", project.appendingPathComponent("StoreBridge/supervisor.py").path,
        project.appendingPathComponent("StoreBridge/bridge.py").path,
      ]
      task.standardInput = input
      task.standardOutput = output
      task.standardError = FileHandle.nullDevice
      task.currentDirectoryURL = project
      var environment = ProcessInfo.processInfo.environment
      environment["READY_RUNTIME_ROOT"] = runtimeRoot.path
      environment["PYTHONDONTWRITEBYTECODE"] = "1"
      if let stateRoot { environment["READY_DATA_ROOT"] = stateRoot.path }
      task.environment = environment
      // Prevent a closed request pipe from delivering process-wide SIGPIPE.
      guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
        throw Failure.pipe
      }
      let started = try withLock { () throws -> Bool in
        guard !state.cancelled else { return false }
        state.process = task
        do { try task.run() } catch { throw Failure.launch }
        return true
      }
      guard started else { return }
      launched = true
      try? input.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
      do {
        try input.fileHandleForWriting.write(contentsOf: bytes)
        try input.fileHandleForWriting.close()
      } catch { throw Failure.pipe }
      var pending = Data()
      func consume(_ line: Data) throws {
        guard !withLock({ state.cancelled }) else { return }
        guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          let type = value["type"] as? String
        else { return }
        guard terminal == nil else { throw Failure.response }
        if ["result", "auth_url", "error"].contains(type) { terminal = value }
        else if ["progress", "qr"].contains(type) { deliver(value, state: state) }
      }
      var storage=[UInt8](repeating:0,count:4096)
      while true {
        let count=Darwin.read(output.fileHandleForReading.fileDescriptor,&storage,storage.count)
        if count<0&&errno==EINTR{continue}
        if count<0{throw Failure.pipe}
        if count==0{break}
        pending.append(contentsOf:storage.prefix(count))
        guard pending.count < 32_000_000 else { throw Failure.response }
        while let newline = pending.firstIndex(of: 0x0a) {
          try consume(Data(pending[..<newline]))
          pending.removeSubrange(...newline)
        }
      }
      if !pending.isEmpty { try consume(pending) }
      task.waitUntilExit()
      if terminal?["type"] as? String != "error",
        task.terminationReason != .exit || task.terminationStatus != 0
      { terminal = nil; throw Failure.exited }
      if terminal == nil { throw Failure.incomplete }
    } catch {
      terminal = nil
      failure = error as? Failure ?? .pipe
    }
  }

  func cancel(_ id: UUID) {
    withLock {
      guard let state = requests[id] else { return }
      state.cancelled = true
      terminate(state)
    }
  }
  func cancelAll() {
    withLock {
      for state in requests.values {
        state.cancelled = true
        terminate(state)
      }
    }
  }
  /// Account switches/logout invalidate queued callbacks and credential saves,
  /// including auth results which have already left the worker process.
  func invalidateSteamAccount(profile: UUID, removeStored: Bool = false) {
    withLock {
      steamEpochs[profile] = UUID()
      steamFingerprints.removeValue(forKey: profile)
      steamRevisions.removeValue(forKey: profile)
      for state in requests.values where state.store == .steam && state.profile == profile {
        state.cancelled = true
        terminate(state)
      }
      if removeStored {
        credentials.remove(profile, .steam)
        steamRejectedFingerprints.removeValue(forKey: profile)
      }
    }
  }
}
