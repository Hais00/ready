// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Foundation
import LauncherCore

@main struct ReadyControllerPolicyProbe {
  static var active: SessionManager?
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw LauncherError.failed(message) }
  }
  static func hash(_ path: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
  }
  static func spin(_ timeout: TimeInterval = 40, until predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.025))
    }
    try require(predicate(), "Controller policy session timed out")
  }
  static func status(_ manager: SessionManager) -> [String: Any] {
    let file = manager.controlFile.deletingLastPathComponent().appendingPathComponent("overlay-status.json")
    return ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
  }
  static func records(_ url: URL) -> [[String: Any]] {
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
      guard line.first == "{" else { return nil }
      return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
  }
  static func mapped(_ pid: Int) throws -> [String] {
    let task = Process(), out = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    task.arguments = ["-p", String(pid), "-Fn"]
    task.standardOutput = out; task.standardError = FileHandle.nullDevice
    try task.run()
    let bytes = out.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    return String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap {
      $0.first == "n" ? String($0.dropFirst()) : nil
    }
  }
  static func main() throws {
    let project = URL(fileURLWithPath: CommandLine.arguments[1])
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    let candidate = URL(fileURLWithPath: CommandLine.arguments[3])
    let executable = URL(fileURLWithPath: CommandLine.arguments[4])
    let privateSource = URL(fileURLWithPath: CommandLine.arguments[5])
    let dxmtExecutable = URL(fileURLWithPath: CommandLine.arguments[6])
    let fm = FileManager.default, paths = LauncherPaths(root: root.appendingPathComponent("data"))
    try require(fm.fileExists(atPath: root.appendingPathComponent(".ready-controller-policy-test").path), "Missing owned test root marker")
    try paths.prepare()
    try AtomicFile.writePrivate(Data(contentsOf: candidate), to: paths.runtimes.appendingPathComponent("runtime.json"))
    let runtime = RuntimeConfiguration.load(candidate)
    guard let server = runtime.wineServer, let descriptor = runtime.overlayInputCapture,
      let provider = descriptor.providers?["base"] else { throw LauncherError.failed("Missing protocol2 base provider") }
    let profile = UUID(), gameID = "controller-policy-production"
    let prefix = paths.prefix(profile: profile, gameID: gameID)
    try AtomicFile.writePrivate(JSONSerialization.data(withJSONObject: ["prefixes":[prefix.path],"servers":Array(Set([server] + Array((runtime.engineWineServers ?? [:]).values)))]), to: root.appendingPathComponent("cleanup.json"))
    let template = project.appendingPathComponent("Runtime/TestPrefixes/wine-11.20")
    try fm.createDirectory(at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
    let copy = Process(); copy.executableURL = URL(fileURLWithPath: "/bin/cp"); copy.arguments = ["-cR", template.path, prefix.path]
    try copy.run(); copy.waitUntilExit(); try require(copy.terminationStatus == 0, "Owned COW prefix initialization failed")
    // This is an owned, stopped fixture: seed only the production controller
    // builtins so the policy sees known hashes before its first Wineboot plan.
    for (relative, expected) in provider.payloadHashes where relative.hasSuffix(".dll") {
      let folder = relative.hasPrefix("i386-") ? "syswow64" : "system32"
      let target = prefix.appendingPathComponent("drive_c/windows/" + folder + "/" + URL(fileURLWithPath: relative).lastPathComponent)
      let source = URL(fileURLWithPath: provider.wineRoot).appendingPathComponent("lib/wine/" + relative)
      let pending = target.appendingPathExtension("ready-controller-fixture")
      let copy = Process(); copy.executableURL = URL(fileURLWithPath: "/bin/cp"); copy.arguments = ["-c", source.path, pending.path]
      try copy.run(); copy.waitUntilExit(); try require(copy.terminationStatus == 0, "Production builtin COW copy failed")
      if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
      try fm.moveItem(at: pending, to: target)
      try require(try hash(target) == expected, "Fixture production builtin hash differs")
    }
    let privateDLL = executable.deletingLastPathComponent().appendingPathComponent("xinput1_4.dll")
    var cases = [[String: Any]]()
    defer {
      active?.quit()
      try? spin(20) { active?.running != true }
    }
    let modes: [(String, ControllerInputMode, Bool, Bool, GraphicsEngine, URL)] = [
      ("automatic-no-private", .automatic, false, true, .vulkanKosmic, executable),
      ("game-input", .gameInput, false, false, .vulkanKosmic, executable),
      ("automatic-private", .automatic, true, false, .vulkanKosmic, executable),
      ("force-private", .forceBuiltin, true, true, .vulkanKosmic, executable),
      ("automatic-dxmt", .automatic, false, true, .dxmtMetal, dxmtExecutable),
    ]
    for (label, mode, ownsPrivate, enabled, engine, selectedExecutable) in modes {
      guard let selectedProvider = descriptor.providers?[engine == .dxmtMetal ? "dxmt" : "base"] else { throw LauncherError.failed("Missing selected production controller provider") }
      if ownsPrivate && !fm.fileExists(atPath: privateDLL.path) { try fm.copyItem(at: privateSource, to: privateDLL) }
      let privateBefore = ownsPrivate ? try hash(privateDLL) : "absent"
      let variant = GameVariant(id: "windows", platform: .windows, architecture: .x86_64,
        executable: selectedExecutable.path, workingDirectory: selectedExecutable.deletingLastPathComponent().path,
        installationRoot: selectedExecutable.deletingLastPathComponent().path, installed: true)
      var game = Game(id: gameID, store: .local, storeID: gameID, title: "Production controller policy probe", variants: [variant], engine: engine)
      game.controllerInputMode = mode
      let manager = SessionManager(paths: paths, project: project, initializationTimeout: 180)
      active = manager
      let previousLogs = Set(try fm.contentsOfDirectory(atPath: paths.logs.path))
      var started: Result<Void, Error>?, finished: String?
      manager.onFinish = { finished = $0 }
      manager.start(game: game, variant: variant, profile: profile) { started = $0 }
      try spin(240) { started != nil }; try started!.get()
      try spin { (status(manager)["frameCount"] as? Int ?? 0) > 0 }
      let logs = Set(try fm.contentsOfDirectory(atPath: paths.logs.path)).subtracting(previousLogs)
      guard let name = logs.first else { throw LauncherError.failed("Missing session output log") }
      let log = paths.logs.appendingPathComponent(name)
      try spin { records(log).contains { $0["controllerPolicyProbe"] as? Bool == true } }
      let observation = records(log).first { $0["controllerPolicyProbe"] as? Bool == true }!
      try require(observation["captureFlag"] as? String == (enabled ? "1" : "0"), "Windows did not receive the expected opt-in")
      let override = observation["dllOverrides"] as? String ?? ""
      try require(override.contains("xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0=b") == enabled, "Unexpected real Windows input override")
      let privateLoaded = ownsPrivate && !enabled
      try require(observation["privateDLLLoaded"] as? Bool == privateLoaded, "Windows loaded the wrong XInput implementation")
      try require(observation["testBackendExportPresent"] as? Bool == false && observation["testDeviceBackendLoaded"] as? Bool == false, "Test backend appeared in production session")
      let idle = status(manager)
      try require(idle["gamepadMenuEnabled"] as? Bool == enabled, "Native overlay controller policy differs")
      guard let pid = idle["pid"] as? Int else { throw LauncherError.failed("Missing actual Wine Darwin PID") }
      let mappings = try mapped(pid)
      let nativeReader = selectedProvider.wineRoot + "/lib/wine/x86_64-unix/xinput-capture.so"
      let readerMapped = mappings.filter { $0.hasPrefix("/") }.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == URL(fileURLWithPath: nativeReader).resolvingSymlinksInPath().path }
      try require(readerMapped == !privateLoaded, "Production native input reader mapping differs")
      if engine == .dxmtMetal {
        try require(override.contains("d3d11,dxgi,d3d10core,winemetal=b"), "Controller policy lost the graphics override")
        let bridge = selectedProvider.wineRoot + "/lib/wine/x86_64-unix/winemetal.so"
        try require(mappings.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == bridge }, "DXMT native rendering bridge was not mapped")
      }
      manager.overlayToggle()
      try spin { let s = status(manager); return s["visible"] as? Bool == true && (s["overlayFrameCount"] as? Int ?? 0) > 0 && (s["trackedTextureBytes"] as? Int ?? 0) > 0 }
      let shown = status(manager)
      try require(shown["gamepadMenuEnabled"] as? Bool == enabled, "Visible native overlay changed controller policy")
      manager.resume()
      try spin { let s = status(manager); return s["visible"] as? Bool == false && s["trackedTextureBytes"] as? Int == 0 }
      let hidden = status(manager)
      manager.quit(); try spin(30) { !manager.running && finished != nil }
      _ = try PrefixLease(paths: paths, profile: profile, gameID: gameID)
      let privateAfter = ownsPrivate ? try hash(privateDLL) : "absent"
      try require(privateBefore == privateAfter, "Controller policy modified the app-local DLL")
      let result: [String: Any] = ["case":label,"mode":mode.rawValue,"engine":engine.rawValue,"selectedWineRoot":selectedProvider.wineRoot,"expectedCapture":enabled,
        "windowsObservation":observation,"idle":idle,"shown":shown,"hidden":hidden,
        "nativeReaderMapped":readerMapped,"mappedProductionPaths":mappings.filter { $0.hasPrefix(selectedProvider.wineRoot) },
        "privateDLLBefore":privateBefore,"privateDLLAfter":privateAfter,"log":log.path,"logSHA256":try hash(log),
        "sameOwnedPrefix":prefix.path,"keeperReleasedLease":true,"passed":true]
      cases.append(result)
      try AtomicFile.writePrivate(JSONSerialization.data(withJSONObject: ["cases":cases,"passed":cases.count == modes.count],options:[.prettyPrinted,.sortedKeys]), to: root.appendingPathComponent("progress.json"))
      active = nil
    }
    if fm.fileExists(atPath: privateDLL.path) { try require(try hash(privateDLL) == hash(privateSource), "Final provider transition modified the bystander app DLL") }
    print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed":true,"cases":cases,
      "scope":"production controller DLLs, Core policy and SessionManager; private DLL is app-local disconnected fixture only",
      "testControllerBackendUsed":false,"physicalControllerVerified":false,"defaultModified":false],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
  }
}
