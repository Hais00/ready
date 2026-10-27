// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct RendererFailureLedger {
  let paths: LauncherPaths
  public init(paths: LauncherPaths) { self.paths = paths }
  private struct Record: Codable {
    var wineVersion: String
    var failed: [GraphicsEngine]
    var reason: String
  }
  private func file(profile: UUID, gameID: String) -> URL {
    paths.gameData(profile: profile, gameID: gameID).appendingPathComponent(
      "renderer-attempts.json")
  }
  public func failed(profile: UUID, gameID: String, wineVersion: String) -> Set<GraphicsEngine> {
    guard
      let r = try? JSONDecoder().decode(
        Record.self, from: Data(contentsOf: file(profile: profile, gameID: gameID))),
      r.wineVersion == wineVersion
    else { return [] }
    return Set(r.failed)
  }
  /// Only classify an actual failed graphics initialization. A DRM/login failure is not a renderer failure.
  public static func graphicsInitializationFailed(
    exitCode: Int32, userRequestedStop: Bool, diagnostic: String
  ) -> Bool {
    guard exitCode != 0, !userRequestedStop else { return false }
    let message = diagnostic.lowercased()
    return [
      "failed to initialize dxvk", "vk_error_incompatible_driver",
      "failed to create a dxgi factory", "device does not support required feature",
      "vkd3d-proton: failed to create device",
    ].contains { message.contains($0) }
  }
  public func record(profile: UUID, gameID: String, wineVersion: String, engine: GraphicsEngine)
    throws
  {
    var engines = failed(profile: profile, gameID: gameID, wineVersion: wineVersion)
    engines.insert(engine)
    let target = file(profile: profile, gameID: gameID)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let record = Record(
      wineVersion: wineVersion, failed: engines.sorted { $0.rawValue < $1.rawValue },
      reason:
        "Verified graphics initialization failed; next launch may use the next available verified path."
    )
    try AtomicFile.writePrivate(JSONEncoder().encode(record), to: target)
  }
  public func reset(profile: UUID, gameID: String) throws {
    let p = file(profile: profile, gameID: gameID)
    if FileManager.default.fileExists(atPath: p.path) { try FileManager.default.removeItem(at: p) }
  }
}
