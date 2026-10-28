// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

public struct LauncherPaths {
  public let root: URL
  public init(root: URL? = nil) {
    self.root =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("M1Launcher", isDirectory: true)
  }
  public var library: URL { root.appendingPathComponent("library.json") }
  public var legacyPrefix: URL { root.appendingPathComponent("SharedPrefix", isDirectory: true) }
  public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
  public var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
  public func prefix(profile: UUID, gameID: String) -> URL {
    root.appendingPathComponent(
      "Prefixes/" + profile.uuidString + "/" + SafePath.key(gameID), isDirectory: true)
  }
  public func session(_ id: UUID) -> URL {
    root.appendingPathComponent("Sessions/" + id.uuidString, isDirectory: true)
  }
  public func lock(profile: UUID, gameID: String) -> URL {
    root.appendingPathComponent(
      "Locks/" + profile.uuidString + "-" + SafePath.key(gameID) + ".lock")
  }
  public func profile(_ id: UUID) -> URL {
    root.appendingPathComponent("Profiles/" + id.uuidString, isDirectory: true)
  }
  public func gameData(profile: UUID, gameID: String) -> URL {
    self.profile(profile).appendingPathComponent("Games/" + SafePath.key(gameID), isDirectory: true)
  }
  public func prepare() throws {
    for p in [
      root, logs, runtimes, root.appendingPathComponent("Locks"),
      root.appendingPathComponent("Sessions"),
    ] {
      try FileManager.default.createDirectory(
        at: p, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }
}
public enum AtomicFile {
  /// Set permissions at creation time, then atomically publish; watchers never see a permissive intermediate file.
  public static func writePrivate(_ data: Data, to destination: URL) throws {
    let temp = destination.deletingLastPathComponent().appendingPathComponent(
      ".ready-" + UUID().uuidString)
    let descriptor = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw LauncherError.failed("Impossibile creare il file privato.") }
    defer {
      Darwin.close(descriptor)
      try? FileManager.default.removeItem(at: temp)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let n = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw LauncherError.failed("Scrittura del file privato non riuscita.") }
        offset += n
      }
    }
    guard fsync(descriptor) == 0, Darwin.rename(temp.path, destination.path) == 0 else {
      throw LauncherError.failed("Aggiornamento atomico non riuscito.")
    }
  }
}
public final class LibraryRepository {
  public let paths: LauncherPaths
  public init(paths: LauncherPaths) { self.paths = paths }
  public func load() throws -> LibraryState {
    try paths.prepare()
    guard FileManager.default.fileExists(atPath: paths.library.path) else {
      let s = LibraryState.initial()
      try save(s)
      return s
    }
    return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: paths.library))
  }
  public func save(_ state: LibraryState) throws {
    try paths.prepare()
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try AtomicFile.writePrivate(enc.encode(state), to: paths.library)
  }
}
/// Serializes only a particular game/profile prefix; independent games/profiles remain independent.
public final class PrefixLease {
  private var fd: Int32 = -1
  private var transferred = false
  public init(paths: LauncherPaths, profile: UUID, gameID: String) throws {
    try paths.prepare()
    fd = Darwin.open(
      paths.lock(profile: profile, gameID: gameID).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LauncherError.failed("Impossibile aprire il lock del prefix.") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(fd)
      fd = -1
      throw LauncherError.busy
    }
  }
  public func handleForSessionHost() throws -> FileHandle {
    let inherited = Darwin.dup(fd)
    guard inherited >= 0 else {
      throw LauncherError.failed("Impossibile trasferire il lock alla sessione.")
    }
    return FileHandle(fileDescriptor: inherited, closeOnDealloc: true)
  }
  public func markTransferredToSessionHost() { transferred = true }
  deinit {
    if fd >= 0 {
      if !transferred { flock(fd, LOCK_UN) }
      Darwin.close(fd)
    }
  }
}
public enum SafePath {
  public static func resolve(_ relative: String, under root: URL) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"),
      !relative.split(separator: "/").contains("..")
    else { throw LauncherError.invalid("Percorso relativo non valido.") }
    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    var dest = base
    // Resolve each EXISTING component independently; Foundation may leave a non-existing leaf unresolved.
    for part in relative.split(separator: "/") {
      dest = dest.appendingPathComponent(String(part)).standardizedFileURL
      if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: dest.path) {
        dest = URL(fileURLWithPath: link, relativeTo: dest.deletingLastPathComponent())
          .standardizedFileURL.resolvingSymlinksInPath()
      } else if FileManager.default.fileExists(atPath: dest.path) {
        dest = dest.resolvingSymlinksInPath()
      }
      guard dest.path == base.path || dest.path.hasPrefix(base.path + "/") else {
        throw LauncherError.invalid("Percorso fuori dalla directory consentita.")
      }
    }
    return dest
  }
  public static func key(_ raw: String) -> String {
    component(String(raw.prefix(32))) + "-"
      + SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public static func component(_ raw: String) -> String {
    let value = raw.unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        ? String($0) : "_"
    }.joined()
    return value.isEmpty || value == "." || value == ".." ? "_" : value
  }
}
