// SPDX-License-Identifier: GPL-3.0-only
// Standalone: link the explicit LauncherCore static product and its matching module.
import Darwin
import Foundation
import LauncherCore

@main struct ReadyPrefixRecreationProbe {
  enum Failure: Error { case failed(String) }
  static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.failed(message) }
  }
  static func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure.failed("Expected operation to reject unsafe metadata")
  }
  static func inode(_ file: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    return (attributes[.systemFileNumber] as! NSNumber).uint64Value
  }
  static func binding(_ paths: LauncherPaths, _ profile: UUID, _ game: String) -> URL {
    paths.gameData(profile: profile, gameID: game).appendingPathComponent("save-folders.json")
  }
  static func main() throws {
    let args = CommandLine.arguments
    let fm = FileManager.default
    if args.count == 5, args[1] == "--recreate-child" {
      let paths = LauncherPaths(root: URL(fileURLWithPath: args[2]))
      guard let profile = UUID(uuidString: args[3]) else { throw Failure.failed("Invalid fixture profile") }
      let prefix = paths.prefix(profile: profile, gameID: args[4])
      _ = try PrefixManager(paths: paths).recreateFixture(profile: profile, gameID: args[4]) { backup in
        try require(!fm.fileExists(atPath: prefix.path), "Prefix already recreated before crash boundary")
        try require(!fm.fileExists(atPath: prefix.appendingPathComponent(".ready/save-folders.json").path), "New metadata exists too early")
        try require(!PersistentGameFolders.storedRules(profile: profile, gameID: args[4], paths: paths).isEmpty, "Durable binding missing after archive")
        try AtomicFile.writePrivate(
          JSONSerialization.data(withJSONObject: ["backup": backup.path, "prefix": prefix.path, "phase": "old-prefix-moved-new-metadata-absent"]),
          to: paths.root.appendingPathComponent(".recreation-paused.json"))
        raise(SIGSTOP)
        throw Failure.failed("Crash fixture unexpectedly resumed without SIGKILL")
      }
      throw Failure.failed("Crash fixture never reached its archive boundary")
    }
    let resolved = realpath(NSTemporaryDirectory(), nil)!
    let temporary = String(cString: resolved)
    free(resolved)
    let root = URL(fileURLWithPath: temporary).appendingPathComponent("ready-recreate-crash-" + UUID().uuidString)
    let paths = LauncherPaths(root: root)
    try paths.prepare()
    defer { try? fm.removeItem(at: root) }
    try AtomicFile.writePrivate(Data("Owned synthetic prefix/save fixture only\n".utf8), to: root.appendingPathComponent(".ready-synthetic-prefix-recreate"))
    let manager = PrefixManager(paths: paths), owner = UUID(), otherProfile = UUID()
    let game = "A"
    let rules = [SaveRule("drive_c/ProgramData/ReadyGame/Saves"), SaveRule("drive_c/GameData/ReadyGame/Settings")]
    let prefix = try manager.prepare(profile: owner, gameID: game)
    for (index, rule) in rules.enumerated() {
      let folder = prefix.appendingPathComponent(rule.relativePath)
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data(("original-extra-data-" + String(index)).utf8).write(to: folder.appendingPathComponent("marker.bin"))
    }
    _ = try manager.prepare(profile: owner, gameID: game, saveRules: rules)
    let targets = rules.map { prefix.appendingPathComponent($0.relativePath).resolvingSymlinksInPath() }
    let contents = try targets.map { try Data(contentsOf: $0.appendingPathComponent("marker.bin")) }
    let targetInodes = try targets.map(inode)
    let oldPrefixInode = try inode(prefix)
    let peerGame = try manager.prepare(profile: owner, gameID: "B", saveRules: [rules[0]])
    let peerProfile = try manager.prepare(profile: otherProfile, gameID: game, saveRules: [rules[0]])
    let peers = [peerGame, peerProfile]
    for (index, peer) in peers.enumerated() {
      try Data(("isolated-peer-" + String(index)).utf8).write(to: peer.appendingPathComponent(rules[0].relativePath + "/marker.bin"))
    }
    let peerRecipes = try [binding(paths, owner, "B"), binding(paths, otherProfile, game)].map { try Data(contentsOf: $0) }
    // A known folder may be physical after an interrupted earlier import.
    // Recreate must import this new, non-conflicting file before archiving it.
    let physicalKnownFolder = prefix.appendingPathComponent(rules[0].relativePath)
    try fm.removeItem(at: physicalKnownFolder) // Remove only this fixture's symlink.
    try fm.createDirectory(at: physicalKnownFolder, withIntermediateDirectories: true)
    let newKnownSave = Data("new-save-after-interrupted-import".utf8)
    try newKnownSave.write(to: physicalKnownFolder.appendingPathComponent("new-known-save.bin"))
    try require(!fm.fileExists(atPath: targets[0].appendingPathComponent("new-known-save.bin").path), "Physical fixture already imported")
    // Deliberately model the prior version: recipe exists ONLY in the prefix.
    // recreate must promote that legacy record before it can archive the prefix.
    try fm.removeItem(at: binding(paths, owner, game))
    try require(try PersistentGameFolders.storedRules(prefix: prefix) == rules, "Legacy recipe missing")
    var checks = [String: Bool]()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = ["--recreate-child", root.path, owner.uuidString, game]
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe(); process.standardError = errors
    try process.run()
    defer {
      if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }
    let paused = root.appendingPathComponent(".recreation-paused.json")
    let deadline = Date().addingTimeInterval(10)
    while !fm.fileExists(atPath: paused.path), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard fm.fileExists(atPath: paused.path) else {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw Failure.failed("Child never reached the exact post-rename boundary")
    }
    let record = try JSONSerialization.jsonObject(with: Data(contentsOf: paused)) as! [String: String]
    let backup = URL(fileURLWithPath: record["backup"]!)
    try require(record["phase"] == "old-prefix-moved-new-metadata-absent", "Wrong checkpoint")
    try require(!fm.fileExists(atPath: prefix.path), "New prefix exists at stopped boundary")
    try require(try inode(backup) == oldPrefixInode, "Old prefix was not actually renamed")
    try require(try PersistentGameFolders.storedRules(profile: owner, gameID: game, paths: paths) == rules, "Recipe not durable before rename")
    var metadataInfo = stat()
    try require(lstat(binding(paths, owner, game).path, &metadataInfo) == 0 && metadataInfo.st_uid == getuid() && metadataInfo.st_mode & 0o777 == 0o600, "External recipe is not private")
    checks["legacyRecipePromotedBeforeRealPrefixRename"] = true
    try require(try Data(contentsOf: targets[0].appendingPathComponent("new-known-save.bin")) == newKnownSave, "Known physical save was stranded in archived prefix")
    checks["knownPhysicalSaveImportedBeforePrefixArchive"] = true
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    try require(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL, "Fixture did not terminate by SIGKILL")
    try require(!fm.fileExists(atPath: prefix.appendingPathComponent(".ready/save-folders.json").path), "New prefix recipe appeared after SIGKILL")
    checks["SIGKILLAfterArchiveLeavesNoNewPrefixMetadata"] = true
    // A fresh manager receives NO Game.saveRules and no in-memory recipe.
    let fresh = PrefixManager(paths: paths)
    _ = try fresh.prepare(profile: owner, gameID: game)
    for (index, rule) in rules.enumerated() {
      let folder = prefix.appendingPathComponent(rule.relativePath)
      try require((try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil, "Rule not reattached")
      try require(folder.resolvingSymlinksInPath().path == targets[index].path, "Binding changed its target")
      try require(try inode(targets[index]) == targetInodes[index], "Persistent directory was replaced")
      try require(try Data(contentsOf: folder.appendingPathComponent("marker.bin")) == contents[index], "Extra save bytes changed")
    }
    try require(try PersistentGameFolders.storedRules(prefix: prefix) == rules, "Prefix recipe was not reconstructed")
    checks["freshPrepareWithoutGameRulesReattachesBothExistingTargets"] = true
    checks["extraSaveBytesAndDirectoryIdentitySurvive"] = true
    try require(try Data(contentsOf: prefix.appendingPathComponent(rules[0].relativePath + "/new-known-save.bin")) == newKnownSave, "Physical known save not attached after SIGKILL recovery")
    checks["knownPhysicalSaveVisibleThroughRecoveredNormalPath"] = true
    try require(try inode(backup) == oldPrefixInode && PersistentGameFolders.storedRules(prefix: backup) == rules, "Archived original was lost or changed")
    checks["originalPrefixBackupAndRecipeRetained"] = true
    for (index, peer) in peers.enumerated() {
      try require(try Data(contentsOf: peer.appendingPathComponent(rules[0].relativePath + "/marker.bin")) == Data(("isolated-peer-" + String(index)).utf8), "Other game/profile data changed")
    }
    try require(try Data(contentsOf: binding(paths, owner, "B")) == peerRecipes[0] && Data(contentsOf: binding(paths, otherProfile, game)) == peerRecipes[1], "Other game/profile bindings changed")
    checks["gameAndProfileIsolationPreserved"] = true
    _ = try fresh.prepare(profile: owner, gameID: game)
    let nextBackup = try fresh.recreate(profile: owner, gameID: game)
    try require(nextBackup != nil && fm.fileExists(atPath: nextBackup!.path) && fm.fileExists(atPath: backup.path), "Healthy retry discarded an earlier backup")
    for (index, rule) in rules.enumerated() {
      try require(try Data(contentsOf: prefix.appendingPathComponent(rule.relativePath + "/marker.bin")) == contents[index], "Healthy recreation lost recovered bytes")
    }
    checks["repeatPrepareAndHealthyRecreationKeepBindingsAndAllBackups"] = true
    let corruptGame = "corrupt-metadata"
    let intact = try fresh.prepare(profile: owner, gameID: corruptGame, saveRules: [rules[0]])
    let intactInode = try inode(intact)
    let previousBackups = Set(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path))
    try AtomicFile.writePrivate(Data("{invalid recipe".utf8), to: binding(paths, owner, corruptGame))
    try rejects { _ = try fresh.recreate(profile: owner, gameID: corruptGame) }
    try require(try inode(intact) == intactInode && Set(fm.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path)) == previousBackups, "Corrupt external recipe moved the original prefix")
    checks["corruptDurableRecipeRejectsBeforePrefixMove"] = true
    let unmarked = LauncherPaths(root: root.appendingPathComponent("unmarked"))
    try unmarked.prepare()
    try rejects { _ = try PrefixManager(paths: unmarked).recreateFixture(profile: owner, gameID: game) { _ in } }
    checks["checkpointRequiresExplicitOwnedSyntheticMarker"] = true
    try fm.removeItem(at: root)
    try require(!fm.fileExists(atPath: root.path), "Synthetic fixture cleanup incomplete")
    let report: [String: Any] = [
      "passed": checks.values.allSatisfy { $0 }, "checks": checks,
      "scope": "real PrefixManager rename, stopped child SIGKILL before replacement metadata, fresh empty-rule prepare; only synthetic data, no Wine/account/game",
      "crashBoundary": record["phase"]!, "realSIGKILLCount": 1,
      "fixtureCleanedAfterVerification": true,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if let index = args.firstIndex(of: "--output"), args.indices.contains(index + 1) {
      try AtomicFile.writePrivate(data, to: URL(fileURLWithPath: args[index + 1]))
    }
    print(String(decoding: data, as: UTF8.self))
  }
}
