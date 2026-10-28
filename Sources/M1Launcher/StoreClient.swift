// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import LauncherCore

/// Private JSONL IPC. A request remains active through process cleanup and callback delivery.
final class StoreClient {
  struct CredentialAccess {
    var load: (UUID, Store) -> Data?
    var save: (Data, UUID, Store) throws -> Void
    static func keychain(stateRoot: URL? = nil) -> Self {
      Self(
        load: { CredentialVault.load(profile: $0, store: $1, stateRoot: stateRoot) },
        save: { try CredentialVault.save($0, profile: $1, store: $2, stateRoot: stateRoot) })
    }
  }
  private final class RequestState {
    let id: UUID
    let callback: ([String: Any]) -> Void
    var cancelled = false
    var terminationRequested = false
    var process: Process?
    init(id: UUID, callback: @escaping ([String: Any]) -> Void) {
      self.id = id
      self.callback = callback
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
  // A callback may synchronously call cancel/hasActiveRequests. Keeping this
  // recursive lock through delivery makes cancel a barrier against late events.
  private let lock = NSRecursiveLock()
  var hasActiveRequests: Bool { withLock { !pendingRequests.isEmpty } }

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
    let state = RequestState(id: id, callback: event)
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
        var value = terminal ?? ["type": "error", "message": (failure ?? .incomplete).message]
        if value["type"] as? String == "result",
          let refreshed = value["credentials"] as? [String: Any], !refreshed.isEmpty
        {
          do {
            try credentials.save(JSONSerialization.data(withJSONObject: refreshed), profile, store)
          } catch {
            value = ["type": "error", "message": "Impossibile salvare l’account nel Portachiavi."]
          }
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
      let account = credentials.load(profile, store).flatMap {
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
      while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
        pending.append(chunk)
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
}
