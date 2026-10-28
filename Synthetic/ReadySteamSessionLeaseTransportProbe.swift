// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@_silgen_name("flock") private func fixtureFlock(_ fd: Int32, _ operation: Int32) -> Int32

@main struct ReadySteamSessionLeaseTransportProbe {
  static func main() throws {
    let keeper = CommandLine.arguments[1], game = CommandLine.arguments[2]
    let root = URL(fileURLWithPath: CommandLine.arguments[3]), adapters = CommandLine.arguments[4]
    var checks = [String: Bool]()
    func check(_ condition: Bool, _ name: String) throws {
      checks[name] = condition
      if !condition { throw NSError(domain: "SteamSessionLeaseTransportFixture_" + name, code: 1) }
    }
    func wait(_ condition: () -> Bool, timeout: TimeInterval = 5) throws {
      let end = ProcessInfo.processInfo.systemUptime + timeout
      while !condition(), ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
      if !condition() { throw NSError(domain: "SteamSessionLeaseTransportFixtureTimeout", code: 1) }
    }
    func makePipe() throws -> (Int32, Int32) {
      var fds = [Int32](repeating: -1, count: 2)
      guard pipe(&fds) == 0 else { throw NSError(domain: "FixturePipe", code: Int(errno)) }
      return (fds[0], fds[1])
    }
    func lease(_ directory: URL) throws -> FileHandle {
      let fd = open(directory.appendingPathComponent("prefix.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard fd >= 3, fixtureFlock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "FixturePrefixLease", code: Int(errno)) }
      return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func locked(_ directory: URL) -> Bool {
      let fd = open(directory.appendingPathComponent("prefix.lock").path, O_RDWR | O_CLOEXEC)
      guard fd >= 0 else { return false }
      defer { close(fd) }
      return fixtureFlock(fd, LOCK_EX | LOCK_NB) != 0 && (errno == EWOULDBLOCK || errno == EAGAIN)
    }
    func directory(_ name: String) throws -> URL {
      let result = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return result
    }
    func spawn(_ transport: SteamSessionLeaseTransport, executable: String, arguments: [String], adapterValue: String) throws -> Process {
      let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
      var environment = ProcessInfo.processInfo.environment
      for name in Array(environment.keys) where name.hasPrefix("DYLD_") || name.hasPrefix("STEAM") || name.hasPrefix("Steam") || name == "READY_OVERLAY_LIBRARY" { environment.removeValue(forKey: name) }
      environment["READY_STEAM_ADAPTER_LIBRARIES"] = adapterValue
      task.environment = environment; task.standardInput = transport.childInput
      task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
      try task.run(); transport.childDidSpawn(); return task
    }
    func stop(_ task: Process, healthWriter: Int32) {
      if healthWriter >= 0 { close(healthWriter) }
      let end = ProcessInfo.processInfo.systemUptime + 5
      while task.isRunning, ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
      if task.isRunning { task.terminate() }
      let final = ProcessInfo.processInfo.systemUptime + 1
      while task.isRunning, ProcessInfo.processInfo.systemUptime < final { Thread.sleep(forTimeInterval: 0.01) }
      if task.isRunning { kill(task.processIdentifier, SIGKILL) }
      task.waitUntilExit()
    }

    // Extra unrelated parent descriptors must not reach the injected game.
    let extra = open(root.appendingPathComponent("unrelated-private-marker").path, O_CREAT | O_RDWR, 0o600)
    guard extra >= 0 else { throw NSError(domain: "FixtureSentinel", code: Int(errno)) }
    defer { close(extra) }
    let live = try directory("live"), prefix = try lease(live), transport = try SteamSessionLeaseTransport()
    let (healthRead, healthWrite) = try makePipe()
    let task = try spawn(transport, executable: keeper, arguments: ["--steam-bootstrap", "--", game, live.path], adapterValue: adapters)
    var writer: Int32 = healthWrite
    defer { stop(task, healthWriter: writer); try? prefix.close() }
    try transport.transfer(prefixLease: prefix, healthReadFD: healthRead, timeout: 3)
    try check(fcntl(healthRead, F_GETFD) == -1 && errno == EBADF, "transferConsumesHealthReader")
    let stateURL = live.appendingPathComponent("state.json")
    try wait { FileManager.default.fileExists(atPath: stateURL.path) }
    let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    try check((state["extraFDs"] as? [Int]) == [], "gameHasNoCredentialHealthLifelineOrPrefixFDs")
    try check(state["adapters"] as? String == adapters, "gameReceivesExactlyThreeOwnAdapters")
    try check(state["ignoredTERM"] as? Bool == true && task.isRunning, "ownGameIgnoresTERMAndRemainsAlive")
    try prefix.close()
    try check(locked(live), "keeperRetainsPrefixLeaseAfterParentClosesCopy")
    let (repeatRead, repeatWrite) = try makePipe(); defer { close(repeatWrite) }
    var repeated = false
    do { try transport.transfer(prefixLease: prefix, healthReadFD: repeatRead) }
    catch SteamSessionLeaseTransport.Failure.alreadyUsed { repeated = true }
    try check(repeated && fcntl(repeatRead, F_GETFD) == -1 && errno == EBADF, "singleUseConsumesRepeatedHealthReader")
    let start = ProcessInfo.processInfo.systemUptime
    close(writer); writer = -1
    try wait({ !task.isRunning }, timeout: 4)
    task.waitUntilExit()
    try check(task.terminationReason == .exit && task.terminationStatus == 75 && ProcessInfo.processInfo.systemUptime - start < 3.5, "healthEOFStopsTERMResistantGameWith75WithinBudget")
    try check(!locked(live), "prefixLeaseReleasesOnlyAfterGameStops")
    let gamePID = state["pid"] as! Int32
    try check(kill(gamePID, 0) != 0 && errno == ESRCH, "ownedGameIsReapedAfterHealthEOF")

    // Structural descriptor failures must occur before ancillary admission.
    for kind in ["regularHealth", "writeHealth", "socketHealth", "pipePrefix", "directoryPrefix"] {
      let d = try directory(kind), validPrefix = try lease(d), candidate = try SteamSessionLeaseTransport()
      let (readFD, writeFD) = try makePipe(); var health = readFD; var chosenPrefix = validPrefix
      var sockets = [Int32](repeating: -1, count: 2), otherPrefix: FileHandle?
      if kind == "regularHealth" { health = dup(validPrefix.fileDescriptor); close(readFD) }
      if kind == "writeHealth" { health = dup(writeFD); close(readFD) }
      if kind == "socketHealth" { guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw NSError(domain: "FixtureSocket", code: 1) }; health = sockets[0]; close(readFD) }
      if kind == "pipePrefix" { otherPrefix = FileHandle(fileDescriptor: dup(writeFD), closeOnDealloc: true); chosenPrefix = otherPrefix! }
      if kind == "directoryPrefix" { otherPrefix = FileHandle(fileDescriptor: open(d.path, O_RDONLY), closeOnDealloc: true); chosenPrefix = otherPrefix! }
      var invalid = false
      do { try candidate.transfer(prefixLease: chosenPrefix, healthReadFD: health, timeout: 0.1) }
      catch SteamSessionLeaseTransport.Failure.invalidDescriptor { invalid = true }
      try check(invalid && fcntl(health, F_GETFD) == -1 && errno == EBADF, kind + "RejectedAndConsumed")
      close(writeFD); if sockets[1] >= 0 { close(sockets[1]) }; try? otherPrefix?.close(); try validPrefix.close()
    }

    let rejected = try directory("rejected"), rejectedPrefix = try lease(rejected), rejectedTransport = try SteamSessionLeaseTransport()
    let (rejectedRead, rejectedWrite) = try makePipe()
    let rejectedTask = try spawn(rejectedTransport, executable: keeper, arguments: ["--steam-bootstrap", "--", game, rejected.path], adapterValue: "")
    defer { stop(rejectedTask, healthWriter: -1); try? rejectedPrefix.close() }
    var admissionFailed = false
    do { try rejectedTransport.transfer(prefixLease: rejectedPrefix, healthReadFD: rejectedRead, timeout: 1) }
    catch { admissionFailed = true }
    close(rejectedWrite); try rejectedPrefix.close()
    try wait { !rejectedTask.isRunning }; rejectedTask.waitUntilExit()
    try check(admissionFailed && rejectedTask.terminationStatus == 75 && !FileManager.default.fileExists(atPath: rejected.appendingPathComponent("state.json").path), "emptyAdaptersRejectAdmissionWithoutSpawningGame")
    try check(!locked(rejected), "failedAdmissionReleasesTransferredPrefix")

    for mode in ["noACK", "ACKWithoutEOF", "badACK"] {
      let d = try directory(mode), handle = try lease(d), candidate = try SteamSessionLeaseTransport()
      let (readFD, writeFD) = try makePipe()
      let peer = try spawn(candidate, executable: game, arguments: ["--" + mode], adapterValue: "")
      let began = ProcessInfo.processInfo.systemUptime; var expectedFailure = false
      do { try candidate.transfer(prefixLease: handle, healthReadFD: readFD, timeout: 0.25) }
      catch SteamSessionLeaseTransport.Failure.deadline { expectedFailure = mode != "badACK" }
      catch SteamSessionLeaseTransport.Failure.rejected { expectedFailure = mode == "badACK" }
      let elapsed = ProcessInfo.processInfo.systemUptime - began
      try check(expectedFailure && elapsed < 1, mode + "FailsWithinSingleDeadline")
      try check(fcntl(readFD, F_GETFD) == -1 && errno == EBADF, mode + "ConsumesHealthReader")
      close(writeFD); peer.terminate(); try wait { !peer.isRunning }; peer.waitUntilExit(); try handle.close()
      try check(!locked(d), mode + "LeavesNoPrefixLease")
    }
    checks["allPassed"] = checks.values.allSatisfy { $0 }
    print(String(data: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), encoding: .utf8)!)
  }
}
