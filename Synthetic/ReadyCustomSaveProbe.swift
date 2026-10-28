// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import LauncherCore

@main struct ReadyCustomSaveProbe {
  static var managers = [SessionManager]()
  static func require(_ value: Bool, _ text: String) throws {
    if !value { throw LauncherError.failed(text) }
  }
  static func spin(_ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(140)
    while !predicate(), Date() < deadline {
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    try require(predicate(), "Save probe timed out")
  }
  static func stage(
    project: URL, paths: LauncherPaths, executable: URL, profile: UUID, id: String,
    write: Bool, rules: [SaveRule]
  ) throws -> Bool {
    let before = Set(try FileManager.default.contentsOfDirectory(atPath: paths.logs.path))
    let manager = SessionManager(paths: paths, project: project)
    managers.append(manager)
    var started: Result<Void, Error>?
    var ended: String?
    manager.onFinish = { ended = $0 }
    let variant = GameVariant(
      id: "windows", platform: .windows, architecture: .x86_64,
      executable: executable.path, arguments: write ? ["--write"] : [], installed: true)
    let game = Game(
      id: id, store: .local, storeID: id, title: "Custom save fixture", variants: [variant],
      engine: .wineD3D, saveRules: rules)
    manager.start(game: game, variant: variant, profile: profile) { started = $0 }
    try spin { started != nil }
    try started!.get()
    try spin { ended != nil }
    try require(ended!.hasSuffix("codice 0"), "Windows save helper failed")
    let after = Set(try FileManager.default.contentsOfDirectory(atPath: paths.logs.path))
    let file = paths.logs.appendingPathComponent(after.subtracting(before).first!)
    let records = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap {
      line -> [String: Any]? in
      guard line.first == "{" else { return nil }
      return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
    guard let value = records.last?["customMarker"] as? Bool else {
      throw LauncherError.failed("Missing Windows save observation")
    }
    return value
  }
  static func main() throws {
    let project = URL(fileURLWithPath: CommandLine.arguments[1])
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    let executable = URL(fileURLWithPath: CommandLine.arguments[3])
    let paths = LauncherPaths(root: root.appendingPathComponent("data"))
    try paths.prepare()
    let first = UUID()
    let second = UUID()
    let rule = SaveRule("drive_c/ProgramData/ReadyGame/Saves")
    let sourceConfiguration = project.appendingPathComponent("Runtime/runtime.json")
    try AtomicFile.writePrivate(
      Data(contentsOf: sourceConfiguration),
      to: paths.runtimes.appendingPathComponent("runtime.json"))
    let runtime = RuntimeConfiguration.load(paths.runtimes.appendingPathComponent("runtime.json"))
    let prefixes = [(first, "A"), (first, "B"), (second, "A")].map {
      paths.prefix(profile: $0.0, gameID: $0.1).path
    }
    try AtomicFile.writePrivate(
      JSONSerialization.data(withJSONObject: ["prefixes": prefixes, "server": runtime.wineServer!]),
      to: root.appendingPathComponent("cleanup.json"))
    defer { managers.forEach { $0.quit() } }
    var checks = [String: Bool]()
    checks["writeThroughNormalWindowsPath"] = try stage(
      project: project, paths: paths, executable: executable, profile: first, id: "A", write: true,
      rules: [rule])
    checks["otherGameDoesNotSeeCustomSave"] = try !stage(
      project: project, paths: paths, executable: executable, profile: first, id: "B", write: false,
      rules: [rule])
    checks["otherProfileDoesNotSeeCustomSave"] = try !stage(
      project: project, paths: paths, executable: executable, profile: second, id: "A",
      write: false, rules: [rule])
    let old = try PrefixManager(paths: paths).recreate(profile: first, gameID: "A")
    checks["oldPrefixRetained"] = old != nil && FileManager.default.fileExists(atPath: old!.path)
    checks["recreationPreservesSaveWithoutRepeatingRecipe"] = try stage(
      project: project, paths: paths, executable: executable, profile: first, id: "A", write: false,
      rules: [])
    try require(checks.values.allSatisfy { $0 }, "Save persistence/isolation check failed")
    let report: [String: Any] = [
      "passed": true, "checks": checks, "runtimeID": runtime.runtimeIdentity,
      "scope":
        "real SessionManager/Wine CreateFileA/GetFileAttributesA at C:\\ProgramData\\ReadyGame\\Saves, independent game/profile prefixes and prefix recreation",
    ]
    print(
      String(
        decoding: try JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}
