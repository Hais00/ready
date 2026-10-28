// SPDX-License-Identifier: GPL-3.0-only
import Darwin
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
  public static func recoveryKind(paths: LauncherPaths) -> String? {
    if rollbackJournalExists(paths) { return "rollback" }
    let file = paths.root.appendingPathComponent("Migration/journal.json")
    if FileManager.default.fileExists(atPath: file.path),
      loadPlan(paths: paths)?.status == "prepared-original-untouched" || loadPlan(paths: paths) == nil
    { return "copy" }
    return nil
  }
  public static func requiresRecovery(paths: LauncherPaths) -> Bool {
    recoveryKind(paths: paths) != nil
  }
  public static func blocksSession(paths: LauncherPaths, profile: UUID, gameID: String) -> Bool {
    guard requiresRecovery(paths: paths) else { return false }
    let plan: LegacyMigrationPlan?
    if rollbackJournalExists(paths) { plan = try? readRollbackJournal(paths).plan }
    else { plan = loadPlan(paths: paths) }
    guard let plan else { return true } // Unknown pending scope must fail closed.
    return plan.ownerProfile == profile && plan.destinations[gameID] != nil
  }
  @discardableResult
  public static func recoverInterrupted(paths: LauncherPaths) throws -> URL {
    if rollbackJournalExists(paths) { return try restoreRollback(paths: paths, checkpoint: nil) }
    return try recoverCopyInterrupted(paths: paths)
  }
  /// Preserve partial files from an interrupted copy; don't attempt to execute them.
  @discardableResult
  private static func recoverCopyInterrupted(paths: LauncherPaths) throws -> URL {
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
  /// Pure startup reconciliation. Never binds missing prefixes while a transaction is pending.
  public static func reconcileLibrary(_ library: LibraryState, paths: LauncherPaths) throws -> LibraryState {
    guard !requiresRecovery(paths: paths), let plan = loadPlan(paths: paths) else { return library }
    if plan.status == "copied-awaiting-real-validation-original-retained" {
      return try bindLibrary(library, plan: plan, paths: paths)
    }
    if plan.status == "rolled-back-copies-archived-original-retained" {
      return libraryAfterRollback(library, plan: plan)
    }
    return library
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

private struct MigrationEntryIdentity: Codable, Equatable {
  var device: UInt64
  var inode: UInt64
  var directory: Bool
}
private struct RollbackCopyEntry: Codable {
  var gameID: String
  var identity: MigrationEntryIdentity
  var archiveIntent = false
  var archived = false
  var restoreIntent = false
  var restored = false
}
private struct RollbackConflictEntry: Codable {
  var id: UUID
  var gameID: String
  var identity: MigrationEntryIdentity
}
private struct RollbackJournal: Codable {
  var schema = 1
  var kind = "rollback"
  var transaction: UUID
  var plan: LegacyMigrationPlan
  var legacyIdentity: MigrationEntryIdentity
  var archiveIdentity: MigrationEntryIdentity
  var phase = "archiving"
  var copies: [RollbackCopyEntry]
  var conflicts: [RollbackConflictEntry] = []
}
private final class RollbackOperationLease {
  let descriptor: Int32
  init(_ path: URL) throws {
    descriptor = Darwin.open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw LauncherError.failed("Registro del ripristino non disponibile.") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
      UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
      flock(descriptor, LOCK_EX | LOCK_NB) == 0
    else { Darwin.close(descriptor); throw LauncherError.unavailable("Un recupero è già in corso o il registro non è sicuro.") }
    fchmod(descriptor, 0o600)
  }
  deinit { Darwin.close(descriptor) }
}

extension LegacyMigration {
  private static func rollbackJournalExists(_ paths: LauncherPaths) -> Bool {
    let file = paths.root.appendingPathComponent("Migration/rollback-journal.json")
    var info = stat()
    return lstat(file.path, &info) == 0
  }
  /// Parent aliases are resolved once; aliases beneath the data root are never followed.
  private static func rollbackPath(_ relative: String, paths: LauncherPaths) throws -> URL {
    let root = paths.root.standardizedFileURL.resolvingSymlinksInPath()
    let expected = root.appendingPathComponent(relative).standardizedFileURL
    let resolved = try SafePath.resolve(relative, under: root)
    guard resolved.path == expected.path else { throw LauncherError.invalid("Percorso del ripristino sostituito da un collegamento.") }
    return resolved
  }
  private static func entryIdentity(_ url: URL) throws -> MigrationEntryIdentity? {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if errno == ENOENT { return nil }
      throw LauncherError.failed("Impossibile verificare i dati del ripristino.")
    }
    let kind = UInt32(info.st_mode) & UInt32(S_IFMT)
    guard kind == UInt32(S_IFDIR) || kind == UInt32(S_IFREG) else {
      throw LauncherError.invalid("Collegamento o tipo di file non sicuro nel ripristino.")
    }
    return .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), directory: kind == UInt32(S_IFDIR))
  }
  private static func privateRollbackDirectory(_ relative: String, paths: LauncherPaths) throws -> URL {
    let path = try rollbackPath(relative, paths: paths)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(path.path, &info) == 0, info.st_uid == geteuid(),
      UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR)
    else { throw LauncherError.invalid("La directory del recupero non è privata.") }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    return path
  }
  private static func archivePath(_ journal: RollbackJournal, paths: LauncherPaths) throws -> URL {
    try rollbackPath("Backups/migration-rollback-" + journal.transaction.uuidString, paths: paths)
  }
  private static func prefixPath(_ game: String, plan: LegacyMigrationPlan, paths: LauncherPaths) throws -> URL {
    guard plan.destinations[game] == paths.prefix(profile: plan.ownerProfile, gameID: game).path else {
      throw LauncherError.invalid("Destinazione del ripristino non valida.")
    }
    return try rollbackPath("Prefixes/" + plan.ownerProfile.uuidString + "/" + SafePath.key(game), paths: paths)
  }
  private static func copyArchivePath(_ game: String, journal: RollbackJournal, paths: LauncherPaths) throws -> URL {
    try rollbackPath("Backups/migration-rollback-" + journal.transaction.uuidString + "/" + SafePath.key(game), paths: paths)
  }
  private static func conflictPath(_ entry: RollbackConflictEntry, journal: RollbackJournal, paths: LauncherPaths) throws -> URL {
    try rollbackPath("Backups/migration-rollback-" + journal.transaction.uuidString + "/Conflicts/" + SafePath.key(entry.gameID) + "-" + entry.id.uuidString, paths: paths)
  }
  private static func writeRollbackJournal(_ journal: RollbackJournal, paths: LauncherPaths) throws {
    let file = try rollbackPath("Migration/rollback-journal.json", paths: paths)
    try AtomicFile.writePrivate(JSONEncoder().encode(journal), to: file)
    let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw LauncherError.failed("Impossibile confermare il journal del ripristino.") }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw LauncherError.failed("Impossibile sincronizzare il journal del ripristino.") }
  }
  private static func readRollbackJournal(_ paths: LauncherPaths) throws -> RollbackJournal {
    let file = try rollbackPath("Migration/rollback-journal.json", paths: paths)
    var info = stat()
    guard lstat(file.path, &info) == 0, info.st_uid == geteuid(), info.st_size > 0,
      info.st_size <= 16 * 1024 * 1024, UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG)
    else { throw LauncherError.invalid("Journal del ripristino non sicuro; dati conservati.") }
    let journal = try JSONDecoder().decode(RollbackJournal.self, from: Data(contentsOf: file))
    guard journal.schema == 1, journal.kind == "rollback",
      journal.plan.source == paths.legacyPrefix.path,
      journal.plan.status == "copied-awaiting-real-validation-original-retained",
      ["archiving", "committing", "restoring", "restored"].contains(journal.phase),
      journal.legacyIdentity.directory, journal.archiveIdentity.directory,
      journal.copies.allSatisfy({ $0.identity.directory && $0.identity.device == journal.archiveIdentity.device }),
      Set(journal.copies.map { $0.gameID }) == Set(journal.plan.destinations.keys),
      Set(journal.copies.map { $0.gameID }).count == journal.copies.count,
      Set(journal.conflicts.map { $0.id }).count == journal.conflicts.count,
      journal.conflicts.allSatisfy({ journal.plan.destinations[$0.gameID] != nil })
    else { throw LauncherError.invalid("Journal del ripristino non valido; dati conservati.") }
    return journal
  }
  /// Exclusive rename never replaces a destination and never falls back to copy/delete.
  private static func renameRollback(_ source: URL, _ destination: URL) throws {
    guard Darwin.renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw LauncherError.failed("Spostamento del ripristino non completato: journal e dati conservati.")
    }
  }
  private static func validateRollbackState(_ journal: RollbackJournal, paths: LauncherPaths) throws {
    let original = try rollbackPath("SharedPrefix", paths: paths)
    guard try entryIdentity(original) == journal.legacyIdentity,
      try entryIdentity(archivePath(journal, paths: paths)) == journal.archiveIdentity
    else { throw LauncherError.invalid("Sorgente o archivio del ripristino cambiati: nessun dato modificato.") }
    // Validate every affected prefix before making any recovery move.
    for entry in journal.copies {
      let current = try entryIdentity(prefixPath(entry.gameID, plan: journal.plan, paths: paths))
      let archived = try entryIdentity(copyArchivePath(entry.gameID, journal: journal, paths: paths))
      guard current == entry.identity || archived == entry.identity else {
        throw LauncherError.invalid("Una copia del ripristino non è identificabile: tutti i dati restano conservati.")
      }
    }
    for conflict in journal.conflicts {
      let current = try entryIdentity(prefixPath(conflict.gameID, plan: journal.plan, paths: paths))
      let saved = try entryIdentity(conflictPath(conflict, journal: journal, paths: paths))
      guard saved == conflict.identity || (saved == nil && current == conflict.identity) else {
        throw LauncherError.invalid("Una copia conflittuale del recupero è cambiata: dati conservati.")
      }
    }
  }
  private static func recordRollbackPlan(_ plan: LegacyMigrationPlan, paths: LauncherPaths) throws {
    _ = try privateRollbackDirectory("Migration/Plans/" + plan.id.uuidString, paths: paths)
    _ = try rollbackPath("Migration/plan.json", paths: paths)
    _ = try rollbackPath("Migration/Plans/" + plan.id.uuidString + "/plan.json", paths: paths)
    try record(plan, paths: paths)
  }
  static func rollbackTransaction(
    _ plan: LegacyMigrationPlan, paths: LauncherPaths,
    checkpoint: ((String, Int) throws -> Void)?
  ) throws -> URL {
    guard !requiresRecovery(paths: paths), plan.source == paths.legacyPrefix.path,
      plan.status == "copied-awaiting-real-validation-original-retained"
    else { throw LauncherError.invalid("Piano del ripristino non valido o recupero già necessario.") }
    _ = try privateRollbackDirectory("Migration", paths: paths)
    let operation = try RollbackOperationLease(rollbackPath("Migration/rollback-operation.lock", paths: paths))
    var leases = [PrefixLease]()
    for id in plan.destinations.keys.sorted() { leases.append(try PrefixLease(paths: paths, profile: plan.ownerProfile, gameID: id)) }
    return try withExtendedLifetime((operation, leases)) {
      guard !rollbackJournalExists(paths) else { throw LauncherError.unavailable("Ripristino già in corso.") }
      let original = try rollbackPath("SharedPrefix", paths: paths)
      guard let legacy = try entryIdentity(original), legacy.directory else { throw LauncherError.invalid("Sorgente originale del ripristino non disponibile.") }
      var copies = [RollbackCopyEntry]()
      for id in plan.destinations.keys.sorted() {
        guard let identity = try entryIdentity(prefixPath(id, plan: plan, paths: paths)), identity.directory else { throw LauncherError.invalid("Copia della migrazione non valida: dati conservati.") }
        copies.append(.init(gameID: id, identity: identity))
      }
      let transaction = UUID()
      let archive = try privateRollbackDirectory("Backups/migration-rollback-" + transaction.uuidString, paths: paths)
      guard let archiveIdentity = try entryIdentity(archive), copies.allSatisfy({ $0.identity.device == archiveIdentity.device }) else { throw LauncherError.invalid("Il ripristino richiede spostamenti atomici sullo stesso filesystem.") }
      var journal = RollbackJournal(transaction: transaction, plan: plan, legacyIdentity: legacy, archiveIdentity: archiveIdentity, copies: copies)
      try writeRollbackJournal(journal, paths: paths) // Complete transaction before any move.
      for index in journal.copies.indices {
        journal.copies[index].archiveIntent = true
        try writeRollbackJournal(journal, paths: paths)
        let entry = journal.copies[index]
        try renameRollback(prefixPath(entry.gameID, plan: plan, paths: paths), copyArchivePath(entry.gameID, journal: journal, paths: paths))
        try checkpoint?("rollback.moved", index + 1) // Probe only: before progress is recorded.
        journal.copies[index].archived = true
        try writeRollbackJournal(journal, paths: paths)
      }
      try validateRollbackState(journal, paths: paths)
      for entry in journal.copies {
        guard try entryIdentity(prefixPath(entry.gameID, plan: plan, paths: paths)) == nil,
          try entryIdentity(copyArchivePath(entry.gameID, journal: journal, paths: paths)) == entry.identity
        else { throw LauncherError.invalid("Una destinazione del ripristino è cambiata: recupero necessario, dati conservati.") }
      }
      var result = plan
      result.status = "rolled-back-copies-archived-original-retained"
      journal.phase = "committing"
      try writeRollbackJournal(journal, paths: paths)
      try AtomicFile.writePrivate(JSONEncoder().encode(result), to: archive.appendingPathComponent("plan.json"))
      try recordRollbackPlan(result, paths: paths)
      try checkpoint?("rollback.commit-pending", journal.copies.count)
      try renameRollback(rollbackPath("Migration/rollback-journal.json", paths: paths), archive.appendingPathComponent("rollback-journal.json"))
      return archive
    }
  }
  private static func restoreRollback(paths: LauncherPaths, checkpoint: ((String, Int) throws -> Void)?) throws -> URL {
    let operation = try RollbackOperationLease(rollbackPath("Migration/rollback-operation.lock", paths: paths))
    var journal = try readRollbackJournal(paths)
    var leases = [PrefixLease]()
    for id in journal.plan.destinations.keys.sorted() { leases.append(try PrefixLease(paths: paths, profile: journal.plan.ownerProfile, gameID: id)) }
    return try withExtendedLifetime((operation, leases)) {
      try validateRollbackState(journal, paths: paths)
      journal.phase = "restoring"
      try writeRollbackJournal(journal, paths: paths)
      let archive = try archivePath(journal, paths: paths)
      let parent = try rollbackPath("Prefixes/" + journal.plan.ownerProfile.uuidString, paths: paths)
      if try entryIdentity(parent) == nil {
        _ = try privateRollbackDirectory("Prefixes/" + journal.plan.ownerProfile.uuidString, paths: paths)
      }
      // Resume an already-journaled conflict move before discovering new conflicts.
      for conflict in journal.conflicts {
        let target = try conflictPath(conflict, journal: journal, paths: paths)
        if try entryIdentity(target) == nil {
          try renameRollback(prefixPath(conflict.gameID, plan: journal.plan, paths: paths), target)
          try checkpoint?("recovery.conflict-moved", 0)
        }
      }
      var restored = 0
      for index in journal.copies.indices {
        let entry = journal.copies[index]
        let original = try prefixPath(entry.gameID, plan: journal.plan, paths: paths)
        if try entryIdentity(original) != entry.identity {
          if let conflictIdentity = try entryIdentity(original) {
            _ = try privateRollbackDirectory("Backups/migration-rollback-" + journal.transaction.uuidString + "/Conflicts", paths: paths)
            let conflict = RollbackConflictEntry(id: UUID(), gameID: entry.gameID, identity: conflictIdentity)
            journal.conflicts.append(conflict)
            try writeRollbackJournal(journal, paths: paths)
            try renameRollback(original, conflictPath(conflict, journal: journal, paths: paths))
            try checkpoint?("recovery.conflict-moved", restored)
          }
          journal.copies[index].restoreIntent = true
          try writeRollbackJournal(journal, paths: paths)
          try renameRollback(copyArchivePath(entry.gameID, journal: journal, paths: paths), original)
          restored += 1
          try checkpoint?("recovery.restored", restored) // Before progress commit; safe to repeat after crash.
        }
        journal.copies[index].restored = true
        try writeRollbackJournal(journal, paths: paths)
      }
      try validateRollbackState(journal, paths: paths)
      // Aborted rollback restores the previous copied state, so library bindings stay valid.
      try recordRollbackPlan(journal.plan, paths: paths)
      journal.phase = "restored"
      try writeRollbackJournal(journal, paths: paths)
      let outcome: [String: Any] = ["outcome": "rollback-interrupted-copies-restored-original-retained", "planID": journal.plan.id.uuidString, "restoredCountThisRun": restored, "conflictsPreserved": journal.conflicts.map { $0.id.uuidString }, "legacyOriginalRetained": true]
      try AtomicFile.writePrivate(JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys]), to: archive.appendingPathComponent("recovery-result.json"))
      try checkpoint?("recovery.commit-pending", restored)
      try renameRollback(rollbackPath("Migration/rollback-journal.json", paths: paths), archive.appendingPathComponent("restored-rollback-journal.json"))
      return archive
    }
  }
  private static func requireMigrationFixture(_ paths: LauncherPaths) throws {
    let marker = paths.root.appendingPathComponent(".ready-synthetic-migration")
    var info = stat()
    guard lstat(marker.path, &info) == 0, info.st_uid == geteuid(), UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { throw LauncherError.invalid("Il punto di controllo è disponibile solo per fixture sintetiche marcate.") }
  }
  /// Fault checkpoints are opt-in probe callbacks, never sleeps/environment hooks in production.
  public static func rollbackFixture(_ plan: LegacyMigrationPlan, paths: LauncherPaths, checkpoint: @escaping (String, Int) throws -> Void) throws -> URL {
    try requireMigrationFixture(paths)
    return try rollbackTransaction(plan, paths: paths, checkpoint: checkpoint)
  }
  public static func recoverInterruptedFixture(paths: LauncherPaths, checkpoint: @escaping (String, Int) throws -> Void) throws -> URL {
    try requireMigrationFixture(paths)
    if rollbackJournalExists(paths) { return try restoreRollback(paths: paths, checkpoint: checkpoint) }
    return try recoverCopyInterrupted(paths: paths)
  }
}
