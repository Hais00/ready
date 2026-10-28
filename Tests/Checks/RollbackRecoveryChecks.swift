// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

enum RollbackRecoveryChecks {
  private enum FixtureError: Error { case interrupted, failed(String) }
  private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw FixtureError.failed(message) }
  }
  private static func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw FixtureError.failed(message)
  }
  static func validate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ready-rollback-unit-" + UUID().uuidString).resolvingSymlinksInPath()
    let paths = LauncherPaths(root: root), fm = FileManager.default
    try paths.prepare()
    defer { try? fm.removeItem(at: root) }
    try AtomicFile.writePrivate(Data("Synthetic fixture only".utf8), to: root.appendingPathComponent(".ready-synthetic-migration"))
    try fm.createDirectory(at: paths.legacyPrefix, withIntermediateDirectories: true)
    try Data("legacy original".utf8).write(to: paths.legacyPrefix.appendingPathComponent("user.reg"))
    let owner = UUID()
    let executable = paths.legacyPrefix.appendingPathComponent("game.exe")
    try Data("MZ synthetic, never executed".utf8).write(to: executable)
    let games = ["A", "B", "C"].map { Game(id: $0, store: .local, storeID: $0, title: $0, variants: [.init(id: "windows", platform: .windows, executable: executable.path, installed: true)]) }
    let initialLibrary = LibraryState(profiles: [Profile(id: owner, name: "Fixture")], activeProfile: owner, games: games)
    let prepared = try LegacyMigration.prepare(paths: paths, profile: owner, games: games)!
    let copied = try LegacyMigration.execute(prepared, paths: paths)
    let boundLibrary = try LegacyMigration.reconcileLibrary(initialLibrary, paths: paths)
    try require(boundLibrary.configured(games[0]).variants[0].executable?.hasPrefix(paths.prefix(profile: owner, gameID: "A").path) == true, "Copied startup reconciliation binds private copy")
    for id in copied.destinations.keys {
      try Data(("modified " + id).utf8).write(to: paths.prefix(profile: owner, gameID: id).appendingPathComponent("user.reg"))
    }
    do {
      let active = try PrefixLease(paths: paths, profile: owner, gameID: "B")
      try withExtendedLifetime(active) {
        try rejects("Active prefix prevents rollback before any move") { _ = try LegacyMigration.rollback(copied, paths: paths) }
      }
    }
    try require(!LegacyMigration.requiresRecovery(paths: paths), "Busy preflight creates no pending journal")
    try rejects("Injected interruption must leave pending rollback") {
      _ = try LegacyMigration.rollbackFixture(copied, paths: paths) { phase, count in
        if phase == "rollback.moved" && count == 2 { throw FixtureError.interrupted }
      }
    }
    let pendingLibrary = try LegacyMigration.reconcileLibrary(boundLibrary, paths: paths)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    try require(try encoder.encode(pendingLibrary) == encoder.encode(boundLibrary), "Pending rollback leaves all library bindings unchanged")
    try require(LegacyMigration.recoveryKind(paths: paths) == "rollback", "Pending rollback kind")
    try require(LegacyMigration.blocksSession(paths: paths, profile: owner, gameID: "A"), "Affected sessions blocked")
    try require(!LegacyMigration.blocksSession(paths: paths, profile: UUID(), gameID: "A"), "Other profile not blocked")
    try require(!LegacyMigration.blocksSession(paths: paths, profile: owner, gameID: "unrelated"), "Unrelated game not blocked")
    do {
      let active = try PrefixLease(paths: paths, profile: owner, gameID: "C")
      try withExtendedLifetime(active) {
        try rejects("Active prefix prevents recovery") { _ = try LegacyMigration.recoverInterrupted(paths: paths) }
      }
    }
    // A replacement after a crash is preserved separately; it never overwrites the actual copied prefix.
    let conflict = paths.prefix(profile: owner, gameID: "A")
    try fm.createDirectory(at: conflict, withIntermediateDirectories: true)
    try Data("new conflicting data".utf8).write(to: conflict.appendingPathComponent("conflict.dat"))
    let archive = try LegacyMigration.recoverInterrupted(paths: paths)
    try require(!LegacyMigration.requiresRecovery(paths: paths), "Recovery closes pending journal")
    try require(LegacyMigration.loadPlan(paths: paths)?.status == copied.status, "Rollback abort restores copied plan status")
    for id in copied.destinations.keys {
      try require(try String(contentsOf: paths.prefix(profile: owner, gameID: id).appendingPathComponent("user.reg")) == "modified " + id, "Modified copied registry preserved")
    }
    let conflicts = try fm.contentsOfDirectory(at: archive.appendingPathComponent("Conflicts"), includingPropertiesForKeys: nil)
    try require(conflicts.count == 1, "Conflicting replacement archived")
    try require(try String(contentsOf: conflicts[0].appendingPathComponent("conflict.dat")) == "new conflicting data", "Conflicting replacement bytes retained")
    try require(try String(contentsOf: paths.legacyPrefix.appendingPathComponent("user.reg")) == "legacy original", "Legacy original remains unchanged")
    // All copies moved and the plan written is still uncommitted until the journal leaves Migration.
    try rejects("Commit-boundary interruption") {
      _ = try LegacyMigration.rollbackFixture(copied, paths: paths) { phase, _ in
        if phase == "rollback.commit-pending" { throw FixtureError.interrupted }
      }
    }
    try require(LegacyMigration.loadPlan(paths: paths)?.status == "rolled-back-copies-archived-original-retained", "Plan may reach commit status before journal closes")
    try require(LegacyMigration.requiresRecovery(paths: paths), "Journal dominates plan at commit boundary")
    _ = try LegacyMigration.recoverInterrupted(paths: paths)
    try require(LegacyMigration.loadPlan(paths: paths)?.status == copied.status, "Commit-boundary abort restores plan")
    _ = try LegacyMigration.rollback(copied, paths: paths)
    try require(!LegacyMigration.requiresRecovery(paths: paths), "Successful rollback commits")
    try require(!fm.fileExists(atPath: paths.prefix(profile: owner, gameID: "A").path), "Committed rollback archives prefix")
    let reconciled = try LegacyMigration.reconcileLibrary(boundLibrary, paths: paths)
    for game in games {
      let variant = reconciled.configured(game).variants[0]
      try require(!variant.installed && variant.executable == nil, "Committed rollback repairs stale library without a pending journal")
    }
  }
}
