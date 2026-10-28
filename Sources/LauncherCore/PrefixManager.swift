// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Personal data is outside disposable Wine prefixes. AppData remains isolated by game AND profile.
public final class PrefixManager {
  public let paths: LauncherPaths
  public init(paths: LauncherPaths) { self.paths = paths }
  @discardableResult
  public func prepare(profile: UUID, gameID: String, userName: String = NSUserName()) throws -> URL
  {
    try paths.prepare()
    let fm = FileManager.default
    let prefix = paths.prefix(profile: profile, gameID: gameID)
    let user = prefix.appendingPathComponent("drive_c/users/" + SafePath.component(userName))
    let personal = paths.profile(profile)
    let privateData = paths.gameData(profile: profile, gameID: gameID)
    try fm.createDirectory(
      at: user, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let links: [(String, URL)] = [
      ("Documents", personal.appendingPathComponent("Documents")),
      ("My Documents", personal.appendingPathComponent("Documents")),
      ("Saved Games", personal.appendingPathComponent("Saved Games")),
      ("Desktop", personal.appendingPathComponent("Desktop")),
      ("Downloads", personal.appendingPathComponent("Downloads")),
      ("Music", personal.appendingPathComponent("Music")),
      ("Pictures", personal.appendingPathComponent("Pictures")),
      ("Videos", personal.appendingPathComponent("Videos")),
      ("AppData", privateData.appendingPathComponent("AppData")),
    ]
    for (name, target) in links {
      try fm.createDirectory(
        at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try redirect(user.appendingPathComponent(name), to: target, prefix: prefix)
    }
    for name in ["Local", "LocalLow", "Roaming"] {
      try fm.createDirectory(
        at: privateData.appendingPathComponent("AppData/" + name),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let reg = #"""
      Windows Registry Editor Version 5.00

      [HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders]
      "Personal"="C:\\users\\\#(SafePath.component(userName))\\Documents"
      "{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}"="C:\\users\\\#(SafePath.component(userName))\\Saved Games"
      "AppData"="C:\\users\\\#(SafePath.component(userName))\\AppData\\Roaming"
      "Local AppData"="C:\\users\\\#(SafePath.component(userName))\\AppData\\Local"
      "Desktop"="C:\\users\\\#(SafePath.component(userName))\\Desktop"
      "{374DE290-123F-4565-9164-39C4925E467B}"="C:\\users\\\#(SafePath.component(userName))\\Downloads"
      "My Music"="C:\\users\\\#(SafePath.component(userName))\\Music"
      "My Pictures"="C:\\users\\\#(SafePath.component(userName))\\Pictures"
      "My Video"="C:\\users\\\#(SafePath.component(userName))\\Videos"

      """#
    let config = prefix.appendingPathComponent(".ready")
    try fm.createDirectory(at: config, withIntermediateDirectories: true)
    var registryData = Data([0xff, 0xfe])
    registryData.append(reg.data(using: .utf16LittleEndian)!)
    try AtomicFile.writePrivate(registryData, to: config.appendingPathComponent("folders.reg"))
    return prefix
  }
  private func redirect(_ source: URL, to target: URL, prefix: URL) throws {
    let fm = FileManager.default
    if let link = try? fm.destinationOfSymbolicLink(atPath: source.path) {
      let existing = URL(fileURLWithPath: link, relativeTo: source.deletingLastPathComponent())
        .standardizedFileURL.resolvingSymlinksInPath()
      if existing == target.standardizedFileURL.resolvingSymlinksInPath() { return }
      // Remove only the link itself: NEVER walk Wine's default links into the host's Documents.
      try fm.removeItem(at: source)
    } else if fm.fileExists(atPath: source.path) {
      let backup = paths.root.appendingPathComponent("Backups/redirect-" + UUID().uuidString)
      try fm.createDirectory(
        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
      let originalContents =
        (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
      for item in originalContents {
        let dest = target.appendingPathComponent(item.lastPathComponent)
        if !fm.fileExists(atPath: dest.path) {
          try fm.copyItem(at: item, to: dest)
        } else {
          let conflicts = target.appendingPathComponent("Imported-" + UUID().uuidString)
          try fm.createDirectory(at: conflicts, withIntermediateDirectories: true)
          try fm.copyItem(at: item, to: conflicts.appendingPathComponent(item.lastPathComponent))
        }
      }
      try fm.moveItem(at: source, to: backup)
    }
    try fm.createSymbolicLink(at: source, withDestinationURL: target)
  }
  /// Never deletes the old prefix. Caller gets a rollback path, and personal directories are reused.
  @discardableResult
  public func recreate(profile: UUID, gameID: String) throws -> URL? {
    let lease = try PrefixLease(paths: paths, profile: profile, gameID: gameID)
    return try withExtendedLifetime(lease) {
      let prefix = paths.prefix(profile: profile, gameID: gameID)
      let fm = FileManager.default
      var backup: URL?
      if fm.fileExists(atPath: prefix.path) {
        let b = paths.root.appendingPathComponent("Backups/prefix-" + UUID().uuidString)
        try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: prefix, to: b)
        backup = b
      }
      do {
        try prepare(profile: profile, gameID: gameID)
        return backup
      } catch {
        if let backup {
          if fm.fileExists(atPath: prefix.path) { try fm.removeItem(at: prefix) }
          try fm.moveItem(at: backup, to: prefix)
        }
        throw error
      }
    }
  }
}

public struct LegacyMigrationPlan: Codable {
  public var id: UUID
  public var source: String
  public var ownerProfile: UUID
  public var destinations: [String: String]
  public var status: String
  public var warning: String
}
public enum LegacyMigration {
  /// Abort a copied migration without deleting either the legacy source or new data.
  /// Returns the archive root containing the independent prefix copies.
  public static func rollback(_ plan: LegacyMigrationPlan, paths: LauncherPaths) throws -> URL {
    try rollbackTransaction(plan, paths: paths, checkpoint: nil)
  }

  /// Preparation is deliberately non-destructive. Never guess ownership of old mixed-account data.
  public static func prepare(paths: LauncherPaths, profile: UUID, games: [Game]) throws
    -> LegacyMigrationPlan?
  {
    guard !requiresRecovery(paths: paths) else {
      throw LauncherError.invalid(
        "Recupera prima la migrazione interrotta: gli originali sono conservati.")
    }
    let oldJournal = paths.root.appendingPathComponent("Migration/journal.json")
    if FileManager.default.fileExists(atPath: oldJournal.path),
      let previous = loadPlan(paths: paths)
    {
      let destination = historyDirectory(previous, paths: paths).appendingPathComponent(
        "completed-journal-" + UUID().uuidString + ".json")
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: oldJournal, to: destination)
    }
    guard FileManager.default.fileExists(atPath: paths.legacyPrefix.path) else { return nil }
    guard
      (try? FileManager.default.destinationOfSymbolicLink(atPath: paths.legacyPrefix.path)) == nil
    else {
      throw LauncherError.invalid(
        "Il vecchio prefix è un collegamento: la migrazione automatica non lo modifica.")
    }
    let directory = paths.root.appendingPathComponent("Migration")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var destinations = [String: String]()
    for game in games where game.variants.contains(where: { $0.platform == .windows }) {
      destinations[game.id] = paths.prefix(profile: profile, gameID: game.id).path
    }
    let plan = LegacyMigrationPlan(
      id: UUID(), source: paths.legacyPrefix.path, ownerProfile: profile,
      destinations: destinations, status: "prepared-original-untouched",
      warning:
        "The legacy prefix may contain mixed accounts. Assign its data to the correct profile before executing migration. Keep the original until real games and saves have been verified."
    )
    try record(plan, paths: paths)
    return plan
  }
  /// Clone only on explicit execution after assigning legacy ownership. No hard links: registry writes must remain isolated.
  public static func execute(_ plan: LegacyMigrationPlan, paths: LauncherPaths) throws
    -> LegacyMigrationPlan
  {
    guard plan.source == paths.legacyPrefix.path, plan.status == "prepared-original-untouched"
    else { throw LauncherError.invalid("Piano di migrazione non valido") }
    let fm = FileManager.default
    guard (try? fm.destinationOfSymbolicLink(atPath: paths.legacyPrefix.path)) == nil else {
      throw LauncherError.invalid("Sorgente della migrazione sostituita da un collegamento")
    }
    var leases = [PrefixLease]()
    for id in plan.destinations.keys.sorted() {
      leases.append(try PrefixLease(paths: paths, profile: plan.ownerProfile, gameID: id))
    }
    return try withExtendedLifetime(leases) {
      // Validate ALL destinations before changing any of them.
      for (id, path) in plan.destinations {
        guard paths.prefix(profile: plan.ownerProfile, gameID: id).path == path,
          !fm.fileExists(atPath: path)
        else {
          throw LauncherError.invalid(
            "Destinazione già presente o non valida; originali conservati")
        }
      }
      let journal = paths.root.appendingPathComponent("Migration/journal.json")
      var created = [URL]()
      do {
        for (id, path) in plan.destinations.sorted(by: { $0.key < $1.key }) {
          let expected = URL(fileURLWithPath: path)
          try fm.createDirectory(
            at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
          created.append(expected)
          try AtomicFile.writePrivate(JSONEncoder().encode(created.map { $0.path }), to: journal)
          try fm.copyItem(at: paths.legacyPrefix, to: expected)
          try PrefixManager(paths: paths).prepare(profile: plan.ownerProfile, gameID: id)
        }
      } catch {
        // Retain partial copies and journal. Recovery archives them, never deletes
        // user-visible data or assumes a partly copied prefix is ready to launch.
        throw error
      }
      var result = plan
      result.status = "copied-awaiting-real-validation-original-retained"
      try record(result, paths: paths)
      let completed = historyDirectory(plan, paths: paths).appendingPathComponent(
        "copy-journal.json")
      try fm.moveItem(at: journal, to: completed)
      return result
    }
  }
}
