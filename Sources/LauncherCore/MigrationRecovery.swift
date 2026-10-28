// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension LegacyMigration {
  public static func loadPlan(paths: LauncherPaths) -> LegacyMigrationPlan? {
    try? JSONDecoder().decode(
      LegacyMigrationPlan.self,
      from: Data(contentsOf: paths.root.appendingPathComponent("Migration/plan.json")))
  }
  static func historyDirectory(_ plan: LegacyMigrationPlan, paths: LauncherPaths) -> URL {
    paths.root.appendingPathComponent("Migration/Plans/" + plan.id.uuidString)
  }
  static func record(_ plan: LegacyMigrationPlan, paths: LauncherPaths) throws {
    let directory = historyDirectory(plan, paths: paths)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let bytes = try JSONEncoder().encode(plan)
    try AtomicFile.writePrivate(bytes, to: directory.appendingPathComponent("plan.json"))
    try AtomicFile.writePrivate(bytes, to: paths.root.appendingPathComponent("Migration/plan.json"))
  }
  public static func requiresRecovery(paths: LauncherPaths) -> Bool {
    guard
      FileManager.default.fileExists(
        atPath: paths.root.appendingPathComponent("Migration/journal.json").path)
    else { return false }
    return loadPlan(paths: paths)?.status == "prepared-original-untouched"
      || loadPlan(paths: paths) == nil
  }
  public static func blocksSession(paths: LauncherPaths, profile: UUID, gameID: String) -> Bool {
    guard requiresRecovery(paths: paths), let plan = loadPlan(paths: paths) else { return false }
    return plan.ownerProfile == profile && plan.destinations[gameID] != nil
  }
  /// Preserve partial files from an interrupted copy; don't attempt to execute them.
  @discardableResult
  public static func recoverInterrupted(paths: LauncherPaths) throws -> URL {
    let fm = FileManager.default
    let journal = paths.root.appendingPathComponent("Migration/journal.json")
    guard requiresRecovery(paths: paths), let plan = loadPlan(paths: paths),
      plan.source == paths.legacyPrefix.path,
      (try? fm.destinationOfSymbolicLink(atPath: paths.legacyPrefix.path)) == nil,
      fm.fileExists(atPath: paths.legacyPrefix.path)
    else {
      throw LauncherError.invalid(
        "Il recupero richiede il piano e la sorgente originali: tutti i dati restano conservati.")
    }
    let created = try JSONDecoder().decode([String].self, from: Data(contentsOf: journal))
    let expected = Set(plan.destinations.values)
    guard Set(created).isSubset(of: expected), Set(created).count == created.count else {
      throw LauncherError.invalid("Journal della migrazione non valido: nessun dato modificato.")
    }
    var leases = [PrefixLease]()
    for id in plan.destinations.keys.sorted() {
      guard plan.destinations[id] == paths.prefix(profile: plan.ownerProfile, gameID: id).path
      else {
        throw LauncherError.invalid("Destinazione del recupero non valida.")
      }
      leases.append(try PrefixLease(paths: paths, profile: plan.ownerProfile, gameID: id))
    }
    return try withExtendedLifetime(leases) {
      let archive = paths.root.appendingPathComponent(
        "Backups/migration-interrupted-" + UUID().uuidString)
      try fm.createDirectory(
        at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var moved = [(URL, URL)]()
      do {
        for path in created where fm.fileExists(atPath: path) {
          guard (try? fm.destinationOfSymbolicLink(atPath: path)) == nil else {
            throw LauncherError.invalid("Copia interrotta sostituita da un collegamento.")
          }
          let source = URL(fileURLWithPath: path)
          let destination = archive.appendingPathComponent(source.lastPathComponent)
          try fm.moveItem(at: source, to: destination)
          moved.append((source, destination))
        }
        try fm.moveItem(at: journal, to: archive.appendingPathComponent("copy-journal.json"))
        var result = plan
        result.status = "interrupted-copies-archived-original-retained"
        try record(result, paths: paths)
        return archive
      } catch {
        for (source, destination) in moved.reversed() where !fm.fileExists(atPath: source.path) {
          try? fm.moveItem(at: destination, to: source)
        }
        // If journal was archived, restore it too so the next launch stays blocked.
        let saved = archive.appendingPathComponent("copy-journal.json")
        if !fm.fileExists(atPath: journal.path), fm.fileExists(atPath: saved.path) {
          try? fm.moveItem(at: saved, to: journal)
        }
        throw error
      }
    }
  }
  /// Per-profile bindings prevent a migrated executable in A's prefix from becoming
  /// the launch target of another profile. Shared external installations stay shared.
  public static func bindLibrary(
    _ library: LibraryState, plan: LegacyMigrationPlan, paths: LauncherPaths
  ) throws -> LibraryState {
    guard plan.status == "copied-awaiting-real-validation-original-retained",
      plan.source == paths.legacyPrefix.path,
      library.profiles.contains(where: { $0.id == plan.ownerProfile })
    else {
      throw LauncherError.invalid("Proprietario o piano della migrazione non valido.")
    }
    var result = library
    for game in library.games where plan.destinations[game.id] != nil {
      let expected = paths.prefix(profile: plan.ownerProfile, gameID: game.id)
      guard plan.destinations[game.id] == expected.path else {
        throw LauncherError.invalid("Destinazione della libreria non valida.")
      }
      let key = GamePreferences.key(profile: plan.ownerProfile, gameID: game.id)
      var preferences =
        result.gamePreferences?[key]
        ?? GamePreferences(engine: game.engine, selectedVariant: game.selectedVariant)
      var variants = game.variants
      var scoped = preferences.variants ?? []
      var changed = false
      for i in variants.indices where variants[i].platform == .windows {
        guard let executable = variants[i].executable, executable.hasPrefix(plan.source + "/")
        else { continue }
        func rebound(_ path: String) throws -> String {
          if path == plan.source { return expected.path }
          return try SafePath.resolve(
            String(path.dropFirst(plan.source.count + 1)), under: expected
          ).path
        }
        let destination = try rebound(executable)
        guard FileManager.default.fileExists(atPath: destination) else {
          throw LauncherError.unavailable(
            "La copia del gioco non è completa; la sorgente originale resta intatta.")
        }
        variants[i].executable = destination
        for field in [0, 1] {
          let path = field == 0 ? variants[i].workingDirectory : variants[i].installationRoot
          if let path, path == plan.source || path.hasPrefix(plan.source + "/") {
            if field == 0 {
              variants[i].workingDirectory = try rebound(path)
            } else {
              variants[i].installationRoot = try rebound(path)
            }
          }
        }
        scoped.removeAll { $0.id == variants[i].id }
        scoped.append(variants[i])
        changed = true
      }
      if changed {
        preferences.variants = scoped
        if result.gamePreferences == nil { result.gamePreferences = [:] }
        result.gamePreferences?[key] = preferences
      }
    }
    return result
  }
  public static func libraryAfterRollback(_ library: LibraryState, plan: LegacyMigrationPlan)
    -> LibraryState
  {
    var result = library
    for (id, prefix) in plan.destinations {
      let key = GamePreferences.key(profile: plan.ownerProfile, gameID: id)
      guard var preferences = result.gamePreferences?[key], var variants = preferences.variants
      else { continue }
      for i in variants.indices where variants[i].platform == .windows {
        if variants[i].executable?.hasPrefix(prefix + "/") == true {
          variants[i].installed = false
          variants[i].executable = nil
          variants[i].workingDirectory = nil
          variants[i].installationRoot = nil
          variants[i].verification =
            "Installazione archiviata dal ripristino; reimporta la copia conservata per giocare."
        }
      }
      preferences.variants = variants
      result.gamePreferences?[key] = preferences
    }
    return result
  }
}
