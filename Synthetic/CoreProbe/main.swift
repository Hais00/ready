// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherChecks
import LauncherCore

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
