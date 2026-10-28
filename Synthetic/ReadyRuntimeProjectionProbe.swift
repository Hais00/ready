// SPDX-License-Identifier: GPL-3.0-only
// Standalone adapter for the production throwing resolver; no AppDelegate/UI.
import Darwin
import Foundation
import LauncherCore

@main struct ReadyRuntimeProjectionProbe {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count >= 2 else { throw LauncherError.invalid("Runtime configuration required") }
    let file = URL(fileURLWithPath: args[1])
    let document = try RuntimeConfigurationPaths.readDocument(file)
    let runtime = try RuntimeConfiguration.read(file)
    guard let wine = runtime.wine, wine.hasPrefix("/"),
      FileManager.default.isExecutableFile(atPath: wine) else {
      throw LauncherError.invalid("Resolved Wine executable unavailable")
    }
    var report: [String: Any] = ["configuration": document, "wine": wine]
    if let index = args.firstIndex(of: "--data-root"), args.indices.contains(index + 1) {
      let root = URL(fileURLWithPath: args[index + 1])
      let marker = root.appendingPathComponent(".ready-runtime-projection-test")
      var info = stat()
      guard lstat(marker.path, &info) == 0, info.st_uid == getuid(),
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw LauncherError.invalid("Only an explicitly marked owned test data root is accepted")
      }
      let paths = LauncherPaths(root: root)
      let profile = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
      let gameIndex = args.firstIndex(of: "--game")
      let game = gameIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "base"
      let lease = try PrefixLease(paths: paths, profile: profile, gameID: game)
      let prefix = try withExtendedLifetime(lease) {
        try PrefixManager(paths: paths).prepare(
          profile: profile, gameID: game, userName: "projection",
          saveRules: args.contains("--initial") ? [SaveRule("drive_c/ProgramData/ReadyProjection/Saves")] : [])
      }
      report["prefix"] = prefix.path
      report["saveFolder"] = prefix.appendingPathComponent("drive_c/ProgramData/ReadyProjection/Saves").path
      report["persistentSaveFolder"] = prefix.appendingPathComponent("drive_c/ProgramData/ReadyProjection/Saves").resolvingSymlinksInPath().path
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}
