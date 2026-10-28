// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// An owned pointer to an external installation, never an engine/config installer.
public enum RuntimeLocationStore {
  private struct Location: Codable { var schemaVersion = 1; var root: String }
  private struct Snapshot: Codable {
    var schemaVersion = 1
    var location: Location?
    var originalBytes: Data?
  }
  public struct Validation {
    public let root: URL
    public let windowsAvailable: Bool
    public let storeToolsAvailable: Bool
  }
  private static let filename = "external-runtime-location.json"
  private static let previous = "external-runtime-location.previous.json"

  private static func resolvedPath(_ path: String) -> String? {
    guard let result = realpath(path, nil) else { return nil }
    defer { free(result) }
    return String(cString: result)
  }
  private static func canonical(_ url: URL) throws -> URL {
    let path = url.path
    let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    guard url.isFileURL, path.hasPrefix("/"), path != "/",
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      resolvedPath(path).map({ $0 == path }) ?? true
    else { throw LauncherError.invalid("Scegli una cartella assoluta e canonica, senza collegamenti simbolici.") }
    return URL(fileURLWithPath: path)
  }
  public static func validate(_ root: URL) throws -> Validation {
    let root = try canonical(root)
    let config = root.appendingPathComponent("runtime.json")
    let fm = FileManager.default
    var directory: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
      fm.isReadableFile(atPath: config.path),
      (try? fm.attributesOfItem(atPath: config.path)[.type] as? FileAttributeType) == .typeRegular,
      resolvedPath(config.path) == config.path
    else { throw LauncherError.unavailable("La cartella deve contenere un runtime.json leggibile e regolare.") }
    guard let runtime = try? RuntimeConfiguration.read(config)
    else { throw LauncherError.invalid("runtime.json non è una configurazione ready valida.") }
    let wines = [runtime.wine].compactMap { $0 } + Array((runtime.engineWineBinaries ?? [:]).values)
    for wine in wines {
      guard wine.hasPrefix("/"), let executable = resolvedPath(wine),
        (try? fm.attributesOfItem(atPath: executable)[.type] as? FileAttributeType) == .typeRegular,
        fm.isExecutableFile(atPath: executable) else {
        throw LauncherError.unavailable("Il percorso Wine dichiarato non è un eseguibile disponibile: \(wine)")
      }
    }
    return Validation(root: root, windowsAvailable: !wines.isEmpty,
      storeToolsAvailable: fm.fileExists(atPath: root.appendingPathComponent("Tools/StoreBridge").path))
  }

  /// Open each component without following symlinks; pin the final owned directory
  /// so later atomic writes cannot be redirected by a replaced ancestor.
  private static func dataDirectory(_ root: URL, create: Bool) throws -> Int32? {
    let root = try canonical(root)
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw LauncherError.failed("Directory dati non disponibile.") }
    do {
      for part in root.pathComponents.dropFirst() {
        var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0 && errno == ENOENT {
          if !create { Darwin.close(fd); return nil }
          guard mkdirat(fd, part, 0o700) == 0 else { throw LauncherError.failed("Impossibile creare la directory dati privata.") }
          next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard next >= 0 else { throw LauncherError.invalid("Il percorso dati non può contenere collegamenti simbolici.") }
        Darwin.close(fd)
        fd = next
      }
      try ownedDirectory(fd)
      return fd
    } catch { Darwin.close(fd); throw error }
  }
  private static func ownedDirectory(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(),
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o077 == 0
    else { throw LauncherError.invalid("La directory dati deve appartenere all’utente ed essere privata (0700).") }
  }
  private static func childDirectory(_ parent: Int32, _ name: String, create: Bool) throws -> Int32? {
    var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 && errno == ENOENT {
      if !create { return nil }
      guard mkdirat(parent, name, 0o700) == 0 else { throw LauncherError.failed("Impossibile creare la cartella della posizione runtime.") }
      fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard fd >= 0 else { throw LauncherError.invalid("La cartella della posizione runtime non può essere un collegamento.") }
    do { try ownedDirectory(fd); return fd } catch { Darwin.close(fd); throw error }
  }
  private static func runtimeDirectory(paths: LauncherPaths, create: Bool) throws -> Int32? {
    guard let data = try dataDirectory(paths.root, create: create) else { return nil }
    defer { Darwin.close(data) }
    return try childDirectory(data, "Runtimes", create: create)
  }
  private static func read(_ name: String, at directory: Int32) throws -> Data? {
    let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 && errno == ENOENT { return nil }
    guard fd >= 0 else { throw LauncherError.invalid("La posizione runtime salvata non può essere un collegamento.") }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(),
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0,
      info.st_size <= 65536
    else { throw LauncherError.invalid("La posizione runtime salvata deve essere un file privato dell’utente.") }
    var result = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(fd, &bytes, bytes.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0, result.count + max(0, count) <= 65536 else { throw LauncherError.invalid("Posizione runtime salvata non valida.") }
      if count == 0 { return result }
      result.append(contentsOf: bytes.prefix(count))
    }
  }
  private static func write(_ bytes: Data, name: String, at directory: Int32) throws {
    let temp = ".runtime-location-" + UUID().uuidString
    let fd = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LauncherError.failed("Impossibile salvare la posizione runtime privata.") }
    defer { Darwin.close(fd); unlinkat(directory, temp, 0) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw LauncherError.failed("Scrittura della posizione runtime non riuscita.") }
        offset += count
      }
    }
    guard fsync(fd) == 0, renameat(directory, temp, directory, name) == 0 else {
      throw LauncherError.failed("Pubblicazione della posizione runtime non riuscita.")
    }
    _ = fsync(directory)
  }
  private static func decode(_ bytes: Data) throws -> Location {
    let record = try JSONDecoder().decode(Location.self, from: bytes)
    guard record.schemaVersion == 1, record.root.hasPrefix("/") else { throw LauncherError.invalid("Versione della posizione runtime sconosciuta.") }
    _ = try canonical(URL(fileURLWithPath: record.root))
    return record
  }
  public static func savedRoot(paths: LauncherPaths) throws -> URL? {
    guard let directory = try runtimeDirectory(paths: paths, create: false) else { return nil }
    defer { Darwin.close(directory) }
    guard let bytes = try read(filename, at: directory) else { return nil }
    return URL(fileURLWithPath: try decode(bytes).root)
  }
  public static func hasPrevious(paths: LauncherPaths) -> Bool {
    guard let directory = try? runtimeDirectory(paths: paths, create: false) else { return false }
    defer { Darwin.close(directory) }
    return (try? read(previous, at: directory)) != nil
  }
  public static func set(_ root: URL, paths: LauncherPaths) throws {
    let validated = try validate(root)
    try change(Location(root: validated.root.path), restoring: false, paths: paths)
  }
  public static func reset(paths: LauncherPaths) throws {
    try change(nil, restoring: false, paths: paths)
  }
  public static func restorePrevious(paths: LauncherPaths) throws {
    try change(nil, restoring: true, paths: paths)
  }
  private static func change(_ requested: Location?, restoring: Bool, paths: LauncherPaths) throws {
    guard let directory = try runtimeDirectory(paths: paths, create: requested != nil) else {
      if restoring { throw LauncherError.unavailable("Nessuna posizione precedente da ripristinare.") }
      return
    }
    defer { Darwin.close(directory) }
    let lock = openat(directory, ".runtime-location.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw LauncherError.invalid("Lock della posizione runtime non disponibile.") }
    defer { Darwin.close(lock) }
    var lockInfo = stat()
    guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == getuid(),
      lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), lockInfo.st_mode & 0o077 == 0,
      flock(lock, LOCK_EX) == 0 else { throw LauncherError.invalid("Lock della posizione runtime non privato.") }
    defer { flock(lock, LOCK_UN) }
    let currentBytes = try read(filename, at: directory)
    let current = currentBytes.flatMap { try? decode($0) }
    var next = requested
    if restoring {
      guard let bytes = try read(previous, at: directory) else { throw LauncherError.unavailable("Nessuna posizione precedente da ripristinare.") }
      let snapshot = try JSONDecoder().decode(Snapshot.self, from: bytes)
      guard snapshot.schemaVersion == 1 else { throw LauncherError.invalid("Cronologia della posizione runtime non valida.") }
      next = snapshot.location
      if next == nil && snapshot.originalBytes != nil {
        throw LauncherError.invalid("La posizione precedente non era valida; scegli una cartella oppure usa quella predefinita.")
      }
      if let next {
        guard next.root.hasPrefix("/") else { throw LauncherError.invalid("Posizione precedente non valida.") }
        _ = try validate(URL(fileURLWithPath: next.root))
      }
    }
    if next?.root == current?.root && (current != nil || currentBytes == nil) { return }
    let snapshot = try JSONEncoder().encode(Snapshot(location: current, originalBytes: current == nil ? currentBytes : nil))
    guard let history = try childDirectory(directory, "RuntimeLocationHistory", create: true) else { return }
    defer { Darwin.close(history) }
    try write(snapshot, name: UUID().uuidString + ".json", at: history)
    try write(snapshot, name: previous, at: directory)
    if let next {
      try write(JSONEncoder().encode(next), name: filename, at: directory)
    } else if unlinkat(directory, filename, 0) != 0 && errno != ENOENT {
      throw LauncherError.failed("Impossibile ripristinare la posizione predefinita.")
    }
    _ = fsync(directory)
  }
}
