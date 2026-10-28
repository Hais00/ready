// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import LauncherChecks
import LauncherCore

for operation in ["--rollback-migration-fixture", "--recover-rollback-fixture", "--migration-status-fixture", "--reconcile-migration-fixture"] {
  if let index = CommandLine.arguments.firstIndex(of: operation), CommandLine.arguments.indices.contains(index + 1) {
    let paths = LauncherPaths(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    guard FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(".ready-synthetic-migration").path) else {
      throw LauncherError.invalid("Rollback probe accepts only marked synthetic migration fixtures.")
    }
    func argument(_ name: String) -> String? {
      guard let position = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(position + 1) else { return nil }
      return CommandLine.arguments[position + 1]
    }
    if operation == "--reconcile-migration-fixture" {
      let library = try LibraryRepository(paths: paths).load()
      let updated = try LegacyMigration.reconcileLibrary(library, paths: paths)
      try LibraryRepository(paths: paths).save(updated)
      print("{\"reconciled\":true}"); exit(0)
    }
    if operation == "--migration-status-fixture" {
      let plan = LegacyMigration.loadPlan(paths: paths)
      var blocked = [String: Bool]()
      if let plan { for id in plan.destinations.keys { blocked[id] = LegacyMigration.blocksSession(paths: paths, profile: plan.ownerProfile, gameID: id) } }
      let value: [String: Any] = ["recoveryRequired": LegacyMigration.requiresRecovery(paths: paths), "kind": LegacyMigration.recoveryKind(paths: paths) ?? "none", "blocked": blocked]
      print(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)); exit(0)
    }
    let phase = argument("--pause-phase"), count = Int(argument("--pause-count") ?? "-1") ?? -1
    let checkpoint: (String, Int) throws -> Void = { actual, moved in
      if phase == actual && moved == count {
        let report: [String: Any] = ["phase": actual, "count": moved, "pid": ProcessInfo.processInfo.processIdentifier]
        try AtomicFile.writePrivate(JSONSerialization.data(withJSONObject: report), to: paths.root.appendingPathComponent(".rollback-probe-pause.json"))
        // Probe-only deterministic fault point AFTER a real rename, before its progress commit.
        raise(SIGSTOP)
      }
    }
    let archive: URL
    if operation == "--rollback-migration-fixture" {
      guard let plan = LegacyMigration.loadPlan(paths: paths) else { throw LauncherError.invalid("Fixture migration plan missing.") }
      archive = try LegacyMigration.rollbackFixture(plan, paths: paths, checkpoint: checkpoint)
      try checkpoint("rollback.returned", plan.destinations.count)
      let library = try LibraryRepository(paths: paths).load()
      try LibraryRepository(paths: paths).save(LegacyMigration.libraryAfterRollback(library, plan: plan))
    } else {
      archive = try LegacyMigration.recoverInterruptedFixture(paths: paths, checkpoint: checkpoint)
    }
    let value: [String: Any] = ["archive": archive.path, "recoveryRequired": LegacyMigration.requiresRecovery(paths: paths), "kind": LegacyMigration.recoveryKind(paths: paths) ?? "none", "planStatus": LegacyMigration.loadPlan(paths: paths)?.status ?? "missing"]
    print(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)); exit(0)
  }
}

for operation in ["--execute-migration-fixture", "--recover-migration-fixture"] {
  if let index = CommandLine.arguments.firstIndex(of: operation),
    CommandLine.arguments.indices.contains(index + 1)
  {
    let paths = LauncherPaths(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    guard
      FileManager.default.fileExists(
        atPath: paths.root.appendingPathComponent(".ready-synthetic-migration").path)
    else {
      throw LauncherError.invalid("This probe accepts only marked synthetic migration fixtures.")
    }
    if operation == "--recover-migration-fixture" {
      let archive = try LegacyMigration.recoverInterrupted(paths: paths)
      print(
        String(
          decoding: try JSONSerialization.data(withJSONObject: [
            "archive": archive.path,
            "recoveryRequired": LegacyMigration.requiresRecovery(paths: paths),
          ]), as: UTF8.self))
    } else {
      let library = try LibraryRepository(paths: paths).load()
      guard
        let plan = try LegacyMigration.prepare(
          paths: paths, profile: library.activeProfile, games: library.games)
      else { throw LauncherError.invalid("Missing fixture source") }
      let copied = try LegacyMigration.execute(plan, paths: paths)
      try LibraryRepository(paths: paths).save(
        LegacyMigration.bindLibrary(library, plan: copied, paths: paths))
      print(String(decoding: try JSONEncoder().encode(copied), as: UTF8.self))
    }
    exit(0)
  }
}

if let i = CommandLine.arguments.firstIndex(of: "--recreate-wine-fixture"),
  CommandLine.arguments.indices.contains(i + 1)
{
  let paths = LauncherPaths(root: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
  let profile = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  let backup = try PrefixManager(paths: paths).recreate(profile: profile, gameID: "A")
  let report: [String: Any] = [
    "prefix": paths.prefix(profile: profile, gameID: "A").path, "backup": backup?.path ?? "",
    "originalRetained": backup != nil,
  ]
  print(
    String(
      decoding: try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--prepare-wine-fixture"),
  CommandLine.arguments.indices.contains(i + 1)
{
  let p = LauncherPaths(root: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
  let manager = PrefixManager(paths: p)
  let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
  var prefixes = [[String: String]]()
  for (profile, game) in [(a, "A"), (a, "B"), (b, "A")] {
    let prefix = try manager.prepare(profile: profile, gameID: game)
    prefixes.append([
      "profile": profile.uuidString, "game": game, "prefix": prefix.path,
      "documents": p.profile(profile).appendingPathComponent("Documents").path,
      "appData": p.gameData(profile: profile, gameID: game).appendingPathComponent("AppData").path,
    ])
  }
  print(
    String(
      decoding: try JSONSerialization.data(
        withJSONObject: ["prefixes": prefixes], options: [.prettyPrinted, .sortedKeys]),
      as: UTF8.self))
  exit(0)
}
let results = CoreChecks().run()
let passed = results.allSatisfy { $0["status"] == "pass" }
let report: [String: Any] = ["pass": passed, "checks": results]
print(
  String(
    decoding: try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
exit(passed ? 0 : 1)
