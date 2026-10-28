// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

enum PersistentGameFolderChecks {
  static func validate() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "ready-extra-saves-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let paths = LauncherPaths(root: root)
    let manager = PrefixManager(paths: paths)
    let first = UUID()
    let second = UUID()
    let rule = SaveRule("drive_c/ProgramData/ReadyGame/Saves")
    func require(_ value: Bool, _ message: String) throws {
      if !value { throw LauncherError.failed(message) }
    }
    func rejects(_ operation: () throws -> Void) throws {
      do { try operation() } catch { return }
      throw LauncherError.failed("Unsafe save rule was accepted")
    }
    let a = try manager.prepare(profile: first, gameID: "A")
    let folderA = a.appendingPathComponent(rule.relativePath)
    try fm.createDirectory(at: folderA, withIntermediateDirectories: true)
    try Data("A-private-save".utf8).write(to: folderA.appendingPathComponent("save.bin"))
    _ = try manager.prepare(profile: first, gameID: "A", saveRules: [rule])
    try require(
      (try? fm.destinationOfSymbolicLink(atPath: folderA.path)) != nil, "Save folder not redirected"
    )
    let target = folderA.resolvingSymlinksInPath()
    try require(
      target.path.hasPrefix(
        paths.gameData(profile: first, gameID: "A").resolvingSymlinksInPath().path + "/"),
      "Save target left game/profile data")
    try require(
      try String(contentsOf: folderA.appendingPathComponent("save.bin")) == "A-private-save",
      "Existing save lost during import")
    let b = try manager.prepare(profile: first, gameID: "B", saveRules: [rule])
    let a2 = try manager.prepare(profile: second, gameID: "A", saveRules: [rule])
    try require(
      !fm.fileExists(atPath: b.appendingPathComponent(rule.relativePath + "/save.bin").path),
      "Game B inherited A save")
    try require(
      !fm.fileExists(atPath: a2.appendingPathComponent(rule.relativePath + "/save.bin").path),
      "Other profile inherited A save")
    try Data("second-profile".utf8).write(
      to: a2.appendingPathComponent(rule.relativePath + "/save.bin"))
    let backup = try manager.recreate(profile: first, gameID: "A")
    try require(
      backup != nil && fm.fileExists(atPath: backup!.path), "Recreation lost rollback copy")
    try require(
      try String(contentsOf: folderA.appendingPathComponent("save.bin")) == "A-private-save",
      "Recreation lost nonstandard save")
    try require(
      try String(contentsOf: a2.appendingPathComponent(rule.relativePath + "/save.bin"))
        == "second-profile", "Recreation touched another profile")
    try require(
      try PersistentGameFolders.storedRules(prefix: a) == [rule], "Recreation lost save recipe")
    _ = try manager.prepare(profile: first, gameID: "A")
    try require(
      folderA.resolvingSymlinksInPath().path == target.path,
      "Empty incoming recipe dropped persisted rules")
    let other = try manager.prepare(profile: first, gameID: "preflight")
    let physical = other.appendingPathComponent("drive_c/Game/Saves")
    try fm.createDirectory(at: physical, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: physical.appendingPathComponent("keep.bin"))
    for invalid in [
      "../outside", "/absolute", "drive_c/windows/system32", "drive_c/users/test/AppData",
      "drive_c/Game/../escape", "drive_c//Game/Saves",
    ] {
      try rejects {
        try PersistentGameFolders.prepare(
          rules: [SaveRule("drive_c/Game/Saves"), SaveRule(invalid)], profile: first,
          gameID: "preflight", paths: paths, prefix: other)
      }
      try require(
        (try? fm.destinationOfSymbolicLink(atPath: physical.path)) == nil,
        "Preflight moved an earlier rule before rejecting later input")
    }
    try rejects {
      try PersistentGameFolders.prepare(
        rules: [SaveRule("drive_c/Game/Saves"), SaveRule("drive_c/game/saves")], profile: first,
        gameID: "preflight", paths: paths, prefix: other)
    }
    try rejects {
      try PersistentGameFolders.prepare(
        rules: [SaveRule("drive_c/Game/Saves"), SaveRule("drive_c/Game/Saves/Child")],
        profile: first, gameID: "preflight", paths: paths, prefix: other)
    }
    let foreign = root.appendingPathComponent("foreign")
    try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
    try Data("untouched".utf8).write(to: foreign.appendingPathComponent("marker"))
    try fm.createSymbolicLink(
      at: other.appendingPathComponent("drive_c/escape"), withDestinationURL: foreign)
    try rejects {
      try PersistentGameFolders.prepare(
        rules: [SaveRule("drive_c/escape/Saves")], profile: first, gameID: "preflight",
        paths: paths, prefix: other)
    }
    try fm.createSymbolicLink(
      at: physical.appendingPathComponent("external"), withDestinationURL: foreign)
    try rejects {
      try PersistentGameFolders.prepare(
        rules: [SaveRule("drive_c/Game/Saves")], profile: first, gameID: "preflight", paths: paths,
        prefix: other)
    }
    try require(
      try String(contentsOf: foreign.appendingPathComponent("marker")) == "untouched",
      "Rule followed an external link")
    try require(
      try String(contentsOf: physical.appendingPathComponent("keep.bin")) == "keep",
      "Rejected rules changed original content")
  }
}
