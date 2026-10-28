// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Additional per-game save directories, outside the standard redirected user
/// folders. Rules use prefix-relative paths, e.g. drive_c/ProgramData/Game/Saves.
/// Caller holds the game/profile prefix lease for every filesystem mutation.
public enum PersistentGameFolders {
  private static func manifest(_ prefix: URL) -> URL {
    prefix.appendingPathComponent(".ready/save-folders.json")
  }
  private static func durableManifest(profile: UUID, gameID: String, paths: LauncherPaths) throws -> URL {
    let file = paths.gameData(profile: profile, gameID: gameID).appendingPathComponent("save-folders.json")
    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else {
      throw LauncherError.invalid("Il registro persistente dei salvataggi non può essere un collegamento.")
    }
    return try SafePath.resolve(
      "Profiles/" + profile.uuidString + "/Games/" + SafePath.key(gameID) + "/save-folders.json",
      under: paths.root)
  }
  private static func readRules(_ file: URL) throws -> [SaveRule] {
    var info = stat()
    if lstat(file.path, &info) != 0 {
      if errno == ENOENT { return [] }
      throw LauncherError.invalid("Manifest dei salvataggi non disponibile.")
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
      info.st_size <= 65_536 else {
      throw LauncherError.invalid("Il manifest dei salvataggi deve essere un file regolare dell’utente, di dimensione limitata.")
    }
    let data = try Data(contentsOf: file)
    guard data.count <= 65_536 else { throw LauncherError.invalid("Manifest dei salvataggi troppo grande.") }
    return try JSONDecoder().decode([SaveRule].self, from: data)
  }
  public static func storedRules(prefix: URL) throws -> [SaveRule] {
    try readRules(manifest(prefix))
  }
  /// Authoritative game/profile bindings survive every disposable prefix.
  public static func storedRules(profile: UUID, gameID: String, paths: LauncherPaths) throws -> [SaveRule] {
    try readRules(durableManifest(profile: profile, gameID: gameID, paths: paths))
  }
  private static func normalized(_ rule: SaveRule) throws -> String {
    let path = rule.relativePath
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard path.utf8.count <= 1024, parts.count >= 3, parts[0] == "drive_c",
      !path.contains("\\"), !path.contains("\0"),
      !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      !["windows", "users"].contains(parts[1].lowercased())
    else {
      throw LauncherError.invalid(
        "Usa una cartella del gioco relativa a drive_c; Windows e le cartelle utente standard sono gestiti separatamente."
      )
    }
    return parts.joined(separator: "/")
  }
  private static func mergedNames(
    rules: [SaveRule], profile: UUID, gameID: String, paths: LauncherPaths, prefix: URL
  ) throws -> [String] {
    let all = try storedRules(profile: profile, gameID: gameID, paths: paths)
      + storedRules(prefix: prefix) + rules
    return try validatedNames(all)
  }
  private static func validatedNames(_ rules: [SaveRule]) throws -> [String] {
    var names = [String]()
    for rule in rules {
      let name = try normalized(rule)
      if !names.contains(name) { names.append(name) }
    }
    guard names.count <= 128 else { throw LauncherError.invalid("Troppe regole per i salvataggi.") }
    // Preflight every rule before importing or moving any data.
    let keys = names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    guard Set(keys).count == keys.count else {
      throw LauncherError.invalid(
        "Regole di salvataggio equivalenti per Windows: usa un solo percorso canonico.")
    }
    for name in keys {
      guard !keys.contains(where: { $0 != name && name.hasPrefix($0 + "/") }) else {
        throw LauncherError.invalid(
          "Le cartelle di salvataggio non possono essere annidate fra loro.")
      }
    }
    return names
  }
  private static func persist(_ names: [String], profile: UUID, gameID: String, paths: LauncherPaths) throws {
    guard !names.isEmpty else { return }
    let file = try durableManifest(profile: profile, gameID: gameID, paths: paths)
    let bytes = try JSONEncoder().encode(names.map(SaveRule.init))
    guard bytes.count <= 65_536 else { throw LauncherError.invalid("Manifest dei salvataggi troppo grande.") }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try AtomicFile.writePrivate(bytes, to: file)
  }
  /// Promote legacy prefix-only metadata BEFORE recreation can archive its only
  /// copy. Caller holds the game/profile lease; no prefix or save bytes move here.
  static func preserveRulesBeforeRecreation(
    profile: UUID, gameID: String, paths: LauncherPaths, prefix: URL
  ) throws -> [SaveRule] {
    let names = try mergedNames(rules: [], profile: profile, gameID: gameID, paths: paths, prefix: prefix)
    try persist(names, profile: profile, gameID: gameID, paths: paths)
    return names.map(SaveRule.init)
  }
  public static func prepare(
    rules: [SaveRule], profile: UUID, gameID: String,
    paths: LauncherPaths, prefix: URL
  ) throws {
    let fm = FileManager.default
    let names = try mergedNames(
      rules: rules, profile: profile, gameID: gameID, paths: paths, prefix: prefix)
    guard !names.isEmpty else { return }
    let dataRoot = paths.gameData(profile: profile, gameID: gameID)
    try fm.createDirectory(
      at: dataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var pairs = [(URL, URL)]()
    for name in names {
      let components = name.split(separator: "/").map(String.init)
      let parent = try SafePath.resolve(components.dropLast().joined(separator: "/"), under: prefix)
      let source = parent.appendingPathComponent(components.last!)
      let target = try SafePath.resolve("ExtraSaveFolders/" + SafePath.key(name), under: dataRoot)
      if let link = try? fm.destinationOfSymbolicLink(atPath: source.path) {
        let existing = URL(fileURLWithPath: link, relativeTo: parent).standardizedFileURL
          .resolvingSymlinksInPath()
        guard existing.path == target.standardizedFileURL.resolvingSymlinksInPath().path else {
          throw LauncherError.invalid(
            "La cartella di salvataggio rimanda a una destinazione diversa; dati conservati.")
        }
      } else if fm.fileExists(atPath: source.path) {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
          throw LauncherError.invalid(
            "La regola richiede una cartella di salvataggio, non un singolo file.")
        }
        let entries = fm.enumerator(
          at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
        while let item = entries?.nextObject() as? URL {
          if (try item.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
            throw LauncherError.invalid(
              "Importazione di salvataggi con collegamenti interni non verificati: originali conservati."
            )
          }
        }
      }
      pairs.append((source, target))
    }
    let metadata = manifest(prefix)
    try fm.createDirectory(
      at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Persist outside the disposable prefix first. A crash after a later prefix
    // archive cannot erase the only recipe even if the new metadata never exists.
    try persist(names, profile: profile, gameID: gameID, paths: paths)
    try AtomicFile.writePrivate(JSONEncoder().encode(names.map(SaveRule.init)), to: metadata)
    for (source, target) in pairs {
      try fm.createDirectory(
        at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      if (try? fm.destinationOfSymbolicLink(atPath: source.path)) != nil { continue }
      try fm.createDirectory(
        at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
      var backup: URL?
      if fm.fileExists(atPath: source.path) {
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
          var destination = target.appendingPathComponent(item.lastPathComponent)
          if fm.fileExists(atPath: destination.path) {
            let conflict = target.appendingPathComponent("Imported-" + UUID().uuidString)
            try fm.createDirectory(at: conflict, withIntermediateDirectories: true)
            destination = conflict.appendingPathComponent(item.lastPathComponent)
          }
          try fm.copyItem(at: item, to: destination)
        }
        let archive = paths.root.appendingPathComponent("Backups/save-import-" + UUID().uuidString)
        try fm.createDirectory(
          at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: archive)
        backup = archive
      }
      do { try fm.createSymbolicLink(at: source, withDestinationURL: target) } catch {
        if let backup, !fm.fileExists(atPath: source.path) {
          try? fm.moveItem(at: backup, to: source)
        }
        throw error
      }
    }
  }
}
