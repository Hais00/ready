// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

/// Workaround for a Wine bootstrap that leaves syswow64 empty. Only Windows PE
/// files are projected; the executable engine and Unix libraries stay central.
public enum WindowsBuiltinBootstrap {
  private struct Manifest: Codable {
    var identity: String
    var files: [String: String]
  }
  private static func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
  /// Caller must hold this prefix's lease. Existing custom DLLs are preserved.
  public static func prepare(runtime: RuntimeConfiguration, prefix: URL) throws {
    guard let directory = runtime.builtin32Directory else { return }
    let fm = FileManager.default
    let source = URL(fileURLWithPath: directory)
    guard fm.fileExists(atPath: source.appendingPathComponent("kernel32.dll").path) else {
      throw LauncherError.unavailable("Il runtime Wine a 32 bit non è disponibile.")
    }
    let manifestURL = prefix.appendingPathComponent(".ready/builtin32.json")
    let previous = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    let identity = runtime.runtimeIdentity + ":" + source.path
    let target = prefix.appendingPathComponent("drive_c/windows/syswow64")
    guard (try? fm.destinationOfSymbolicLink(atPath: target.path)) == nil else {
      throw LauncherError.invalid("syswow64 non può reindirizzare i file del runtime.")
    }
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    if previous?.identity == identity,
      fm.fileExists(atPath: target.appendingPathComponent("kernel32.dll").path)
    {
      return
    }
    var owned = [String: String]()
    for item in try fm.contentsOfDirectory(
      at: source, includingPropertiesForKeys: [.isRegularFileKey])
    {
      guard ["dll", "exe"].contains(item.pathExtension.lowercased()),
        (try item.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
      else { continue }
      let name = item.lastPathComponent
      let destination = target.appendingPathComponent(name)
      // Follow no prefix link and preserve private installer changes. Update only
      // files that still match a previously projected, unmodified Wine builtin.
      guard (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil else { continue }
      if fm.fileExists(atPath: destination.path) {
        guard let oldHash = previous?.files[name], try digest(destination) == oldHash else {
          continue
        }
      }
      let temporary = target.appendingPathComponent(".ready-" + UUID().uuidString)
      defer { try? fm.removeItem(at: temporary) }
      if Darwin.clonefile(item.path, temporary.path, UInt32(CLONE_NOFOLLOW)) != 0 {
        try fm.copyItem(at: item, to: temporary)
      }
      try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
      guard Darwin.rename(temporary.path, destination.path) == 0 else {
        throw LauncherError.failed("Impossibile proiettare il runtime Windows a 32 bit.")
      }
      owned[name] = try digest(item)
    }
    try fm.createDirectory(
      at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try AtomicFile.writePrivate(
      JSONEncoder().encode(Manifest(identity: identity, files: owned)), to: manifestURL)
  }
}
