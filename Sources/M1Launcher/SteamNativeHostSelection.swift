// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// A centrally selected local binding; this does not download, copy or approve
/// redistribution of the externally installed Valve client or game SDK.
enum SteamNativeHostSelection {
  static func load(runtimeRoot: URL, gameID: String) throws -> SteamNativeHostProcess.Binding {
    guard let app = UInt32(gameID), app > 0 else { throw Failure.invalid }
    let environment = ProcessInfo.processInfo.environment
    if let raw = environment["READY_STEAM_NATIVE_BINDING"],
      let hash = environment["READY_STEAM_NATIVE_BINDING_SHA256"] {
      return try production(URL(fileURLWithPath: raw), hash: hash)
    }
    let tools = environment["READY_STORE_TOOLS_ROOT"].map { URL(fileURLWithPath: $0) }
      ?? runtimeRoot.appendingPathComponent("Tools/StoreBridge")
    let root = tools.resolvingSymlinksInPath().appendingPathComponent("NativeSteamHost/\(app)")
    let path = root.appendingPathComponent("selected.json")
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.missing }
    defer { close(fd) }
    var info = stat()
    guard path.standardizedFileURL == path, path.resolvingSymlinksInPath() == path,
      fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 8192 else { throw Failure.invalid }
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
    let count = Darwin.read(fd, &bytes, bytes.count)
    guard count == info.st_size,
      let value = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
      value["schema"] as? Int == 1, value["kind"] as? String == "ready-native-steam-host-selection-v1",
      let relative = value["manifestPath"] as? String, !relative.hasPrefix("/"),
      relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      let hash = value["manifestSHA256"] as? String else { throw Failure.invalid }
    return try production(root.appendingPathComponent(relative), hash: hash)
  }
  enum Failure: Error { case missing, invalid, fixture }
  private static func production(_ url: URL, hash: String) throws -> SteamNativeHostProcess.Binding {
    let binding = try SteamNativeHostProcess.Binding.load(manifestURL: url, expectedSHA256: hash)
    guard !binding.fixtureOnly else { throw Failure.fixture }
    return binding
  }
}
