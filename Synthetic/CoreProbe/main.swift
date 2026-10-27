// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherChecks
import LauncherCore

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
