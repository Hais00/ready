// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Additional per-game save directories, outside the standard redirected user
/// folders. Rules use prefix-relative paths, e.g. drive_c/ProgramData/Game/Saves.
/// Caller holds the game/profile prefix lease for every filesystem mutation.
public enum PersistentGameFolders {
  private static func manifest(_ prefix: URL) -> URL {
    prefix.appendingPathComponent(".ready/save-folders.json")
  }
  public static func storedRules(prefix: URL) throws -> [SaveRule] {
    let file = manifest(prefix)
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let data = try Data(contentsOf: file)
    guard data.count <= 65_536 else {
      throw LauncherError.invalid("Manifest dei salvataggi troppo grande.")
    }
    return try JSONDecoder().decode([SaveRule].self, from: data)
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
  public static func prepare(
    rules: [SaveRule], profile: UUID, gameID: String,
    paths: LauncherPaths, prefix: URL
  ) throws {
    let fm = FileManager.default
    var names = [String]()
    for rule in try storedRules(prefix: prefix) + rules {
      let name = try normalized(rule)
      if !names.contains(name) { names.append(name) }
    }
    guard !names.isEmpty else { return }
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
    // Persist intent before the first move, so retry/recreation knows every rule.
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
