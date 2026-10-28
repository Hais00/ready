// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

@main struct ReadyWineSessionProbe {
  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw LauncherError.failed(message) }
  }
  static func spin(_ seconds: TimeInterval = 90, until condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    try require(condition(), "Timed out waiting for actual Wine session state")
  }
  static func heartbeat(_ file: URL) -> UInt32 {
    guard let bytes = try? Data(contentsOf: file), bytes.count == 8 else { return 0 }
    return bytes.prefix(4).enumerated().reduce(UInt32(0)) {
      $0 | UInt32($1.element) << ($1.offset * 8)
    }
  }
  static func locked(_ paths: LauncherPaths, _ profile: UUID, _ game: String) -> Bool {
    do {
      _ = try PrefixLease(paths: paths, profile: profile, gameID: game)
      return false
    } catch { return true }
  }
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let project = URL(fileURLWithPath: CommandLine.arguments[2])
    let executable = CommandLine.arguments[3]
    let paths = LauncherPaths(root: root.appendingPathComponent("data"))
    let profile = UUID()
    let runtime = RuntimeConfiguration.load(project.appendingPathComponent("Runtime/runtime.json"))
    let ids = ["real-wine-session-A", "real-wine-session-B"]
    let writerBlockedID = "real-wine-writer-blocked"
    let writerBlockedPrefix = paths.prefix(profile: profile, gameID: writerBlockedID)
    func coordinate(_ phase: String, sequence: Int) throws -> [String: Any] {
      try AtomicFile.writePrivate(
        JSONSerialization.data(withJSONObject: [
          "phase": phase, "sequence": sequence,
          "installation": URL(fileURLWithPath: executable).deletingLastPathComponent()
            .resolvingSymlinksInPath().path,
        ]),
        to: root.appendingPathComponent("writer-request.json"))
      let response = root.appendingPathComponent("writer-response-" + String(sequence) + ".json")
      try spin(15) { FileManager.default.fileExists(atPath: response.path) }
      return try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as! [String: Any]
    }
    let prefixes = ids.map { paths.prefix(profile: profile, gameID: $0) }
    try AtomicFile.writePrivate(
      JSONSerialization.data(withJSONObject: [
        "prefixes": (prefixes + [writerBlockedPrefix]).map(\.path),
        "server": runtime.wineServer ?? "",
      ]),
      to: root.appendingPathComponent("cleanup.json"))
    var managers = ids.map { _ in SessionManager(paths: paths, project: project) }
    var started = [false, false]
    var finished = [false, false]
    var failures = [String]()
    var callbacksMain = true
    let files = ids.map { root.appendingPathComponent($0 + ".heartbeat") }
    defer {
      for manager in managers { manager.quit() }
      try? spin(15) { managers.allSatisfy { !$0.running } }
    }
    for index in 0..<2 {
      let variant = GameVariant(
        id: "windows", platform: .windows, architecture: .x86_64,
        executable: executable, installed: true)
      let game = Game(
        id: ids[index], store: .local, storeID: ids[index], title: ids[index],
        variants: [variant], engine: .wineD3D)
      managers[index].onFinish = { _ in
        finished[index] = true
        callbacksMain = callbacksMain && Thread.isMainThread
      }
      managers[index].start(
        game: game, variant: variant, profile: profile,
        launchEnvironment: [
          "SESSION_PROBE_HEARTBEAT": "Z:"
            + files[index].path.replacingOccurrences(of: "/", with: "\\")
        ]
      ) { result in
        callbacksMain = callbacksMain && Thread.isMainThread
        switch result {
        case .success: started[index] = true
        case .failure(let error): failures.append(error.localizedDescription)
        }
      }
    }
    try spin {
      !failures.isEmpty || (started.allSatisfy { $0 } && files.allSatisfy { heartbeat($0) > 2 })
    }
    try require(failures.isEmpty, "Real Wine startup failed: " + failures.joined(separator: "; "))
    try require(prefixes[0] != prefixes[1], "Session prefixes collided")
    try require(
      ids.allSatisfy { locked(paths, profile, $0) }, "A running real Wine session lost its lease")
    let readerProtection = try coordinate("read-check", sequence: 1)
    try require(
      readerProtection["busy"] as? Bool == true,
      "A real StoreBridge writer was admitted while Wine sessions were reading the shared installation"
    )
    let hostPIDs = managers.map { Int($0.sessionProcessIdentifier ?? -1) }
    let before = files.map(heartbeat)
    managers[0].quit()
    try spin(20) { finished[0] && !managers[0].running && !locked(paths, profile, ids[0]) }
    let bAfterA = heartbeat(files[1])
    try spin(8) { heartbeat(files[1]) > bAfterA + 2 }
    try require(
      managers[1].running && !finished[1] && locked(paths, profile, ids[1]),
      "Stopping A changed live Wine session B")
    let bStillAlive = heartbeat(files[1])
    let aStopped = heartbeat(files[0])
    let until = Date().addingTimeInterval(0.4)
    while Date() < until {
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    try require(
      heartbeat(files[0]) == aStopped, "Session A Windows helper remained alive after completion")
    managers[1].quit()
    try spin(20) { finished[1] && !managers[1].running && !locked(paths, profile, ids[1]) }
    let bStopped = heartbeat(files[1])
    let deadline = Date().addingTimeInterval(0.4)
    while Date() < deadline {
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    try require(
      heartbeat(files[1]) == bStopped, "Session B Windows helper remained alive after completion")
    let markers = prefixes.map {
      (try? String(
        contentsOf: $0.appendingPathComponent(".ready/runtime-initialized"), encoding: .utf8))
        == runtime.initializationIdentity(engine: .wineD3D)
    }
    try require(
      markers.allSatisfy { $0 }, "Real Wine initialization markers did not record runtime identity")
    // Hold the actual StoreBridge writer in the Python coordinator process. Prefix
    // initialization may complete, but the keeper must never start the Windows game.
    let writer = try coordinate("hold-writer", sequence: 2)
    try require(writer["held"] as? Bool == true, "Actual StoreBridge writer was not acquired")
    let blocked = SessionManager(paths: paths, project: project)
    managers.append(blocked)
    let blockedFile = root.appendingPathComponent("writer-blocked.heartbeat")
    let blockedVariant = GameVariant(
      id: "windows", platform: .windows, architecture: .x86_64,
      executable: executable, installed: true)
    let blockedGame = Game(
      id: writerBlockedID, store: .local, storeID: writerBlockedID,
      title: writerBlockedID, variants: [blockedVariant], engine: .wineD3D)
    var blockedFinished = false
    var blockedError: String?
    var blockedMessage = ""
    blocked.onFinish = { message in
      callbacksMain = callbacksMain && Thread.isMainThread
      blockedFinished = true
      blockedMessage = message
    }
    func startBlocked() {
      blocked.start(
        game: blockedGame, variant: blockedVariant, profile: profile,
        launchEnvironment: [
          "SESSION_PROBE_HEARTBEAT": "Z:"
            + blockedFile.path.replacingOccurrences(of: "/", with: "\\")
        ]
      ) {
        callbacksMain = callbacksMain && Thread.isMainThread
        if case .failure(let error) = $0 { blockedError = error.localizedDescription }
      }
    }
    startBlocked()
    try spin { blockedFinished || blockedError != nil }
    try require(
      !blocked.running && !FileManager.default.fileExists(atPath: blockedFile.path)
        && !locked(paths, profile, writerBlockedID),
      "Active StoreBridge writer allowed Windows child spawn or leaked a prefix lease")
    let rejection = blockedError ?? blockedMessage
    try require(
      rejection.contains("Installazione in aggiornamento"),
      "Busy installation did not produce its specific readable launcher message")
    let blockedInitializationMarker = try String(
      contentsOf: writerBlockedPrefix.appendingPathComponent(".ready/runtime-initialized"),
      encoding: .utf8)
    try require(
      blockedInitializationMarker == runtime.initializationIdentity(engine: .wineD3D),
      "Installation writer incorrectly blocked prefix-only initialization")
    let released = try coordinate("release-writer", sequence: 3)
    try require(released["released"] as? Bool == true, "StoreBridge writer did not release")
    blockedFinished = false
    blockedError = nil
    startBlocked()
    try spin { blockedError != nil || heartbeat(blockedFile) > 2 }
    try require(
      blockedError == nil && blocked.running,
      "The same Wine session could not start after releasing the writer")
    blocked.quit()
    try spin(20) { blockedFinished && !blocked.running && !locked(paths, profile, writerBlockedID) }
    try require(callbacksMain, "Real Wine lifecycle callback escaped the main thread")
    let report: [String: Any] = [
      "passed": true,
      "testType":
        "actual SessionManager + native keeper + Wine + compiled Windows WinAPI helper; no protocol mocks, account, or game",
      "runtimeID": runtime.runtimeIdentity, "prefixes": prefixes.map(\.path), "hostPIDs": hostPIDs,
      "heartbeatBeforeStop": before, "heartbeatBAfterAExit": bStillAlive,
      "heartbeatAFinal": aStopped, "heartbeatBFinal": bStopped,
      "initializationIdentity": runtime.initializationIdentity(engine: .wineD3D),
      "writerRejectionMessage": rejection, "writerBlockedPrefix": writerBlockedPrefix.path,
      "checks": [
        "distinctPrefixes": true, "bothInitiallyLocked": true, "quitADoesNotStopB": true,
        "windowsAHeartbeatStops": true, "windowsBHeartbeatStops": true,
        "bothLeasesReleasedAfterExactServerWait": true, "realInitializationMarkers": true,
        "callbacksMainThread": true, "activeWineSessionsBlockRealStoreWriter": true,
        "realStoreWriterPreventsWindowsChild": true, "writerDoesNotBlockPrefixInitialization": true,
        "sameSessionStartsAfterWriterRelease": true,
      ],
    ]
    FileHandle.standardOutput.write(
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
