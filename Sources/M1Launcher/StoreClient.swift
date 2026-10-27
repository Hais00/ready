// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

/// JSONL bridge: account credentials travel on private stdin/stdout pipes, never shell arguments or logs.
final class StoreClient {
  let project: URL
  private var processes = [UUID: Process]()
  private let lock = NSLock()
  init(project: URL) { self.project = project }
  @discardableResult
  func request(
    operation: String, store: Store, profile: UUID, options: [String: Any] = [:],
    event: @escaping ([String: Any]) -> Void
  ) -> UUID {
    let id = UUID()
    let credentials =
      CredentialVault.load(profile: profile, store: store).flatMap {
        try? JSONSerialization.jsonObject(with: $0)
      } as? [String: Any] ?? [:]
    let request: [String: Any] = [
      "operation": operation, "store": store.rawValue, "profileID": profile.uuidString,
      "credentials": credentials, "options": options,
    ]
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      do {
        let input = Pipe()
        let output = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", project.appendingPathComponent("StoreBridge/bridge.py").path]
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = project
        lock.lock()
        processes[id] = task
        lock.unlock()
        try task.run()
        var bytes = try JSONSerialization.data(withJSONObject: request)
        bytes.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: bytes)
        try input.fileHandleForWriting.close()
        var pending = Data()
        var received = false
        while true {
          let chunk = output.fileHandleForReading.readData(ofLength: 4096)
          if chunk.isEmpty { break }
          pending.append(chunk)
          guard pending.count < 32_000_000 else {
            task.terminate()
            throw LauncherError.failed("Risposta dello store troppo grande.")
          }
          while let newline = pending.firstIndex(of: 0x0a) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }
            received = true
            if let c = value["credentials"] as? [String: Any], !c.isEmpty {
              try CredentialVault.save(
                JSONSerialization.data(withJSONObject: c), profile: profile, store: store)
            }
            // The UI only receives account-free events. Never expose tokens through alerts/diagnostics.
            var safe = value
            safe.removeValue(forKey: "credentials")
            DispatchQueue.main.async { event(safe) }
          }
        }
        task.waitUntilExit()
        lock.lock()
        processes.removeValue(forKey: id)
        lock.unlock()
        if !received {
          DispatchQueue.main.async {
            event([
              "type": "error", "message": "Il servizio dello store non ha restituito una risposta.",
            ])
          }
        }
      } catch {
        lock.lock()
        processes.removeValue(forKey: id)
        lock.unlock()
        DispatchQueue.main.async {
          event(["type": "error", "message": error.localizedDescription])
        }
      }
    }
    return id
  }
  func cancel(_ id: UUID) {
    lock.lock()
    let p = processes.removeValue(forKey: id)
    lock.unlock()
    if p?.isRunning == true { p?.terminate() }
  }
}
