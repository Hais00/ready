// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Foundation
import LauncherCore

@main struct ReadyProviderSwitchProbe {
  static var managers = [SessionManager]()
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw LauncherError.failed(message) }
  }
  static func spin(_ seconds: TimeInterval = 140, until predicate: () -> Bool) throws {
    let end = Date().addingTimeInterval(seconds)
    while !predicate(), Date() < end {
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    try require(predicate(), "Provider-switch probe timed out")
  }
  static func hash(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
  }
  static func stage(
    project: URL, paths: LauncherPaths, profile: UUID, gameID: String,
    executable: URL, arguments: [String] = [], engine: GraphicsEngine,
    configuration: [String: Any]
  ) throws -> [String: Any] {
    try AtomicFile.writePrivate(
      JSONSerialization.data(withJSONObject: configuration),
      to: paths.runtimes.appendingPathComponent("runtime.json"))
    try AtomicFile.writePrivate(JSONSerialization.data(withJSONObject: ["game":gameID,"engine":engine.rawValue,"executable":executable.path,"state":"starting"]), to: paths.root.appendingPathComponent("last-stage.json"))
    let manager = SessionManager(paths: paths, project: project)
    managers.append(manager)
    let previous = Set(try FileManager.default.contentsOfDirectory(atPath: paths.logs.path))
    var result: Result<Void, Error>?
    var finished: String?
    manager.onFinish = { finished = $0 }
    let variant = GameVariant(
      id: "windows", platform: .windows, architecture: .x86_64,
      executable: executable.path, installationRoot: executable.deletingLastPathComponent().path,
      arguments: arguments, installed: true)
    let game = Game(
      id: gameID, store: .local, storeID: gameID, title: "Synthetic provider switch",
      variants: [variant], engine: engine)
    manager.start(game: game, variant: variant, profile: profile) { result = $0 }
    try spin { result != nil }
    try result!.get()
    try spin { finished != nil }
    try require(
      finished!.hasSuffix("codice 0"), "Windows probe did not exit successfully: " + finished!)
    try AtomicFile.writePrivate(JSONSerialization.data(withJSONObject: ["game":gameID,"engine":engine.rawValue,"state":"finished","message":finished!]), to: paths.root.appendingPathComponent("last-stage.json"))
    let current = Set(try FileManager.default.contentsOfDirectory(atPath: paths.logs.path))
    guard let name = current.subtracting(previous).first else {
      throw LauncherError.failed("Missing private session log")
    }
    let log = try String(contentsOf: paths.logs.appendingPathComponent(name), encoding: .utf8)
    let records = log.split(separator: "\n").compactMap { line -> [String: Any]? in
      guard line.first == "{" else { return nil }
      return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
    guard let observation = records.last else {
      throw LauncherError.failed("No Windows API observation")
    }
    let runtime = RuntimeConfiguration.load(paths.runtimes.appendingPathComponent("runtime.json"))
    let marker = try String(
      contentsOf: paths.prefix(profile: profile, gameID: gameID).appendingPathComponent(
        ".ready/runtime-initialized"), encoding: .utf8)
    try require(
      marker == runtime.initializationIdentity(engine: engine),
      "Wine initialization marker belongs to another provider")
    // Lease acquisition after keeper exit proves the previous server wait completed.
    _ = try PrefixLease(paths: paths, profile: profile, gameID: gameID)
    return observation
  }
  static func main() throws {
    let project = URL(fileURLWithPath: CommandLine.arguments[1])
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    let paths = LauncherPaths(root: root.appendingPathComponent("data"))
    try paths.prepare()
    let fm = FileManager.default
    let baseData = try Data(contentsOf: project.appendingPathComponent("Runtime/runtime.json"))
    let evalData = try Data(
      contentsOf: project.appendingPathComponent("Runtime/evaluation-runtime.json"))
    var base = try JSONSerialization.jsonObject(with: baseData) as! [String: Any]
    var evaluation = try JSONSerialization.jsonObject(with: evalData) as! [String: Any]
    let combined = evaluation["runtimeID"] as! String
    // The combined identity stays constant: only the selected provider changes.
    base["runtimeID"] = combined
    evaluation["evaluationModeEnabled"] = true
    let baseRuntime = RuntimeConfiguration.load(
      project.appendingPathComponent("Runtime/runtime.json"))
    let evalRuntime = RuntimeConfiguration.load(
      project.appendingPathComponent("Runtime/evaluation-runtime.json"))
    var checks = [String: Bool]()
    checks["evaluationUnavailableWithoutExplicitOptIn"] = !RendererSelector.available(
      .d3dMetal, runtime: evalRuntime)
    try require(
      checks["evaluationUnavailableWithoutExplicitOptIn"] == true,
      "Apple evaluation route was enabled by default")
    let profile = UUID()
    let win32 = project.appendingPathComponent("Runtime/Probes/prefix_windows_probe.exe")
    let dx12 = project.appendingPathComponent("Runtime/Probes/runtime_d3d12_probe.exe")
    let aID = "provider-switch-A"
    let bID = "provider-switch-B"
    // Exact cleanup descriptors, written before starting any Wine process.
    let servers = Array(
      Set(
        [baseRuntime.wineServer, evalRuntime.engineWineServers?[GraphicsEngine.d3dMetal.rawValue]]
          .compactMap { $0 }))
    try AtomicFile.writePrivate(
      JSONSerialization.data(withJSONObject: [
        "prefixes": [
          paths.prefix(profile: profile, gameID: aID).path,
          paths.prefix(profile: profile, gameID: bID).path,
        ], "servers": servers,
      ]), to: root.appendingPathComponent("cleanup.json"))
    defer {
      managers.forEach { $0.quit() }
      try? spin(10) { managers.allSatisfy { !$0.running } }
    }
    _ = try stage(
      project: project, paths: paths, profile: profile, gameID: bID, executable: win32,
      arguments: ["--write"], engine: .wineD3D, configuration: base)
    let b = paths.prefix(profile: profile, gameID: bID)
    let bFiles = [
      "user.reg", "drive_c/windows/system32/d3d11.dll", "drive_c/windows/syswow64/kernel32.dll",
    ]
    let bBefore = try bFiles.map { try hash(b.appendingPathComponent($0)) }
    let written = try stage(
      project: project, paths: paths, profile: profile, gameID: aID, executable: win32,
      arguments: ["--write"], engine: .wineD3D, configuration: base)
    try require(
      written["registryMarker"] as? Bool == true && written["appDataMarker"] as? Bool == true,
      "Base Wine did not write private markers")
    checks["baseWineWritesPrivateState"] = true
    let a = paths.prefix(profile: profile, gameID: aID)
    let initial32 = try hash(a.appendingPathComponent("drive_c/windows/syswow64/kernel32.dll"))
    let rendered = try stage(
      project: project, paths: paths, profile: profile, gameID: aID, executable: dx12,
      engine: .d3dMetal, configuration: evaluation)
    for name in [
      "deviceCreated", "gpuBufferReadbackVerified", "renderTargetClearReadbackVerified",
      "shaderRasterizationVerified",
    ] {
      try require(rendered[name] as? Bool == true, "Actual D3D12 GPU stage failed: " + name)
    }
    checks["samePrefixSwitchesToWineCXAndRendersDX12"] = true
    let pureCX = URL(fileURLWithPath: evalRuntime.bootstrap32Directory(engine: .d3dMetal)!)
    try require(
      try hash(a.appendingPathComponent("drive_c/windows/syswow64/kernel32.dll"))
        == hash(pureCX.appendingPathComponent("kernel32.dll")),
      "PE32 core from another Wine remained after provider change")
    checks["evaluationUsesItsOwnPurePE32Core"] = true
    let restored = try stage(
      project: project, paths: paths, profile: profile, gameID: aID, executable: win32,
      engine: .wineD3D, configuration: base)
    for name in ["registryMarker", "documentsMarker", "appDataMarker", "savedGamesMarker"] {
      try require(
        restored[name] as? Bool == true,
        "Personal state lost after Wine version round-trip: " + name)
    }
    checks["roundTripPreservesRegistryAndPersistentPersonalFolders"] = true
    try require(
      try hash(a.appendingPathComponent("drive_c/windows/syswow64/kernel32.dll")) == initial32,
      "Pure base PE32 kernel was not restored")
    checks["returnToBaseRestoresPurePE32Core"] = true
    try require(
      try bFiles.map { try hash(b.appendingPathComponent($0)) } == bBefore, "Switching A altered B")
    checks["otherGameRegistryAndDLLsRemainUnchanged"] = true
    try require(
      try Data(contentsOf: project.appendingPathComponent("Runtime/runtime.json")) == baseData,
      "Project default runtime was modified")
    try require(
      try Data(contentsOf: project.appendingPathComponent("Runtime/evaluation-runtime.json"))
        == evalData, "Local opt-in leaked into the evaluation fragment")
    checks["defaultAndEvaluationSourceConfigurationsRemainUnchanged"] = true
    try require(checks.values.allSatisfy { $0 }, "Provider switch checks failed")
    let report: [String: Any] = [
      "passed": true, "checks": checks, "evaluationOnly": true,
      "consumerPlayEnabled": false,
      "scope":
        "real SessionManager + keeper + Wine 11.20 → WineCX 11.19/Apple GPTK4b3 DX12 → Wine 11.20, same synthetic game/profile and combined runtime ID",
      "runtimeID": combined,
    ]
    print(
      String(
        decoding: try JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}
