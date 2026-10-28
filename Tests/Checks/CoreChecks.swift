// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

public final class CoreChecks {
  public init() {}

  public func run() -> [[String: String]] {
    let cases: [(String, () throws -> Void)] = [
      ("Valve manifests and malformed input", testValveManifestWithEscapesAndComments),
      (
        "Mach-O architecture and unknown native availability",
        testDistinguishesARM64IntelAndFatBinaries
      ),
      ("Per-prefix locks allow independent sessions", testPrefixLeasePreventsConcurrentMutations),
      (
        "Isolated game/profile prefix paths and persistent profiles",
        testProfilesPersistWithGamePrefixes
      ),
      (
        "Personal folders persist across prefix recreation",
        testSaveSnapshotsDoNotLeakBetweenProfiles
      ),
      ("Path traversal and symlink escape rejection", testSavePathsRejectTraversalAndSymlinkEscape),
      (
        "Literal process arguments and verified engine selection",
        testLaunchPlanUsesLiteralArgumentsAndIsolatedPrefix
      ),
      ("Dependencies and registry remain isolated between games", testDependencyIsolation),
      ("Non-destructive legacy migration and rollback source", testLegacyMigration),
      ("Migration preflight does not leave partial prefixes", testMigrationPreflight),
      ("Migrated executable bindings belong only to the assigned profile", testMigrationBindings),
      ("Interrupted copies are archived and block only affected sessions", testMigrationRecovery),
      (
        "Installation roots contain the executable after resolving aliases",
        testInstallationDirectory
      ),
      ("Runtime upgrade never restores old Wine DLLs", testRuntimeUpgrade),
      ("Legacy symlink cannot redirect migration into original data", testLegacySymlink),
      ("Store manifest identifiers preserve 64-bit integer precision", testMetadataPrecision),
      ("Low feature-level fallback is not advertised as modern DX11", testGraphicsCapabilityScope),
      ("Renderer failures are scoped by profile, game and runtime", testRendererFailureLedger),
      ("Windows registry redirection uses canonical escaping and Unicode", testRegistryEncoding),
      ("PE import detection distinguishes APIs and malformed input", testPEImports),
      ("Built-in provider policy is explicit and scoped", testBuiltinProviderPolicy),
      (
        "PE32 builtin and renderer projections isolate writes and restore pure Wine",
        testBuiltin32Projection
      ),
    ]
    return cases.map { name, body in
      assertions.removeAll()
      do {
        try setUpWithError()
        defer { try? tearDownWithError() }
        try body()
        return [
          "name": name, "status": assertions.isEmpty ? "pass" : "fail",
          "detail": assertions.joined(separator: "; "),
        ]
      } catch { return ["name": name, "status": "fail", "detail": error.localizedDescription] }
    }
  }
  private var assertions = [String]()
  private func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: T) rethrows {
    let actual = try a()
    if actual != b { assertions.append("Values differ: \(actual) != \(b)") }
  }
  private func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T) {
    if a == b { assertions.append("Values unexpectedly equal") }
  }
  private func XCTAssertFalse(_ b: Bool) { if b { assertions.append("Expected false") } }
  private func XCTAssertNotNil<T>(_ x: T?) { if x == nil { assertions.append("Expected non-nil") } }
  private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do {
      _ = try expression()
      assertions.append("Expected operation to throw")
    } catch {}
  }

  var temporary: URL!
  func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ready-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  }
  func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
  func testValveManifestWithEscapesAndComments() throws {
    let kv = try KeyValues.parse(
      "// Steam manifest\n\"AppState\" { \"appid\" \"42\" \"name\" \"A \\\"game\\\"\" \"nested\" { \"path\" \"C:\\\\Games\" } }"
    )
    XCTAssertEqual(kv["AppState"]?["appid"]?.string, "42")
    XCTAssertEqual(kv["AppState"]?["name"]?.string, "A \"game\"")
    XCTAssertEqual(kv["AppState"]?["nested"]?["path"]?.string, "C:\\Games")
    XCTAssertThrowsError(try KeyValues.parse("\"broken\" { \"a\" \"b\""))
  }
  func testDistinguishesARM64IntelAndFatBinaries() throws {
    try XCTAssertEqual(
      try ArchitectureProbe.inspect(Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1])), .arm64)
    try XCTAssertEqual(
      try ArchitectureProbe.inspect(Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1])), .x86_64)
    var fat = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2])
    fat.append(contentsOf: [1, 0, 0, 0x0c])
    fat.append(Data(repeating: 0, count: 16))
    fat.append(contentsOf: [1, 0, 0, 7])
    fat.append(Data(repeating: 0, count: 16))
    try XCTAssertEqual(try ArchitectureProbe.inspect(fat), .universal)
    try XCTAssertEqual(try ArchitectureProbe.inspect(Data([0, 1, 2])), .unknown)
    XCTAssertEqual(GameVariant(id: "m", platform: .macOS).architecture, .unknown)
    XCTAssertFalse(GameVariant(id: "m", platform: .macOS).title.contains("Silicon"))
  }
  func testPrefixLeasePreventsConcurrentMutations() throws {
    let p = LauncherPaths(root: temporary)
    let profile = UUID()
    let other = UUID()
    var first: PrefixLease? = try PrefixLease(paths: p, profile: profile, gameID: "gameA")
    XCTAssertNotNil(first)
    XCTAssertThrowsError(try PrefixLease(paths: p, profile: profile, gameID: "gameA"))
    let independent = try PrefixLease(paths: p, profile: profile, gameID: "gameB")
    let isolated = try PrefixLease(paths: p, profile: other, gameID: "gameA")
    XCTAssertNotNil(independent)
    XCTAssertNotNil(isolated)
    first = nil
    let second = try PrefixLease(paths: p, profile: profile, gameID: "gameA")
    XCTAssertNotNil(second)
  }
  func testProfilesPersistWithGamePrefixes() throws {
    let paths = LauncherPaths(root: temporary)
    let repo = LibraryRepository(paths: paths)
    var state = try repo.load()
    let first = state.activeProfile
    let second = Profile(name: "Secondo")
    state.profiles.append(second)
    state.activeProfile = second.id
    try repo.save(state)
    let loaded = try repo.load()
    XCTAssertEqual(loaded.profiles.count, 2)
    XCTAssertEqual(loaded.activeProfile, second.id)
    XCTAssertNotEqual(
      paths.prefix(profile: first, gameID: "a:b"), paths.prefix(profile: first, gameID: "a_b"))
    XCTAssertNotEqual(
      paths.prefix(profile: first, gameID: "gameA"),
      paths.prefix(profile: second.id, gameID: "gameA"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyPrefix.path))
  }
  func testSaveSnapshotsDoNotLeakBetweenProfiles() throws {
    let paths = LauncherPaths(root: temporary)
    let manager = PrefixManager(paths: paths)
    let a = UUID()
    let b = UUID()
    let pa = try manager.prepare(profile: a, gameID: "gameA", userName: "test")
    let pb = try manager.prepare(profile: b, gameID: "gameA", userName: "test")
    let docA = pa.appendingPathComponent("drive_c/users/test/Documents/save.dat")
    let docB = pb.appendingPathComponent("drive_c/users/test/Documents/save.dat")
    try Data("A saves".utf8).write(to: docA)
    XCTAssertFalse(FileManager.default.fileExists(atPath: docB.path))
    let ga = try manager.prepare(profile: a, gameID: "gameB", userName: "test")
    try XCTAssertEqual(
      try String(contentsOf: ga.appendingPathComponent("drive_c/users/test/Documents/save.dat")),
      "A saves")
    let privateA = pa.appendingPathComponent("drive_c/users/test/AppData/Local/account.json")
    try Data("A account".utf8).write(to: privateA)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: ga.appendingPathComponent("drive_c/users/test/AppData/Local/account.json").path))
    let backup = try manager.recreate(profile: a, gameID: "gameA")
    XCTAssertNotNil(backup)
    try XCTAssertEqual(
      try String(contentsOf: paths.profile(a).appendingPathComponent("Documents/save.dat")),
      "A saves")
    try XCTAssertEqual(
      try String(
        contentsOf: paths.gameData(profile: a, gameID: "gameA").appendingPathComponent(
          "AppData/Local/account.json")), "A account")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: paths.profile(b).appendingPathComponent("Documents/save.dat").path))
  }
  func testDependencyIsolation() throws {
    let paths = LauncherPaths(root: temporary)
    let manager = PrefixManager(paths: paths)
    let profile = UUID()
    let a = try manager.prepare(profile: profile, gameID: "A")
    let b = try manager.prepare(profile: profile, gameID: "B")
    let dlls = temporary.appendingPathComponent("Engines/dxvk-verified")
    try FileManager.default.createDirectory(at: dlls, withIntermediateDirectories: true)
    try Data("renderer-v1".utf8).write(to: dlls.appendingPathComponent("d3d11.dll"))
    var cfg = RuntimeConfiguration(
      wine: "/usr/bin/true", engineDLLs: [GraphicsEngine.dxvkKosmic.rawValue: dlls.path])
    try EngineInstaller.configure(.dxvkKosmic, runtime: cfg, paths: paths, prefix: a)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: b.appendingPathComponent("drive_c/windows/system32/d3d11.dll").path))
    try EngineInstaller.configure(.dxvkKosmic, runtime: cfg, paths: paths, prefix: b)
    let aDLL = a.appendingPathComponent("drive_c/windows/system32/d3d11.dll")
    let bDLL = b.appendingPathComponent("drive_c/windows/system32/d3d11.dll")
    try Data("game-A-installer-modified".utf8).write(to: aDLL)
    try XCTAssertEqual(try String(contentsOf: bDLL), "renderer-v1")
    try XCTAssertEqual(
      try String(contentsOf: dlls.appendingPathComponent("d3d11.dll")), "renderer-v1")
    try Data("registry A".utf8).write(to: a.appendingPathComponent("user.reg"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: b.appendingPathComponent("user.reg").path))
    cfg.wineVersion = "11.test"
    cfg.verifiedEngines = [GraphicsEngine.wineD3D.rawValue]
    let game = Game(id: "A", store: .local, storeID: "A", title: "A")
    let rule = CompatibilityRule(
      gameID: "A", wineVersion: "11.test", engines: [.d3dMetal, .wineD3D], verified: true,
      evidence: "Synthetic fixture: WineD3D only")
    try XCTAssertEqual(
      try RendererSelector.select(game: game, runtime: cfg, rules: [rule]), .wineD3D)
    XCTAssertThrowsError(
      try RendererSelector.select(game: game, runtime: cfg, rules: [rule], failed: [.wineD3D]))
  }
  func testLegacyMigration() throws {
    let paths = LauncherPaths(root: temporary)
    try paths.prepare()
    try FileManager.default.createDirectory(
      at: paths.legacyPrefix, withIntermediateDirectories: true)
    let registry = paths.legacyPrefix.appendingPathComponent("user.reg")
    try Data("original registry".utf8).write(to: registry)
    let profile = UUID()
    let games = [
      Game(
        id: "A", store: .local, storeID: "A", title: "A",
        variants: [.init(id: "windows", platform: .windows)])
    ]
    let plan = try LegacyMigration.prepare(paths: paths, profile: profile, games: games)
    XCTAssertNotNil(plan)
    let migrated = try LegacyMigration.execute(plan!, paths: paths)
    XCTAssertEqual(migrated.status, "copied-awaiting-real-validation-original-retained")
    try Data("new registry".utf8).write(
      to: paths.prefix(profile: profile, gameID: "A").appendingPathComponent("user.reg"))
    try XCTAssertEqual(try String(contentsOf: registry), "original registry")
    do {
      let live = try PrefixLease(paths: paths, profile: profile, gameID: "A")
      try withExtendedLifetime(live) {
        XCTAssertThrowsError(try LegacyMigration.rollback(migrated, paths: paths))
      }
    }
    let archive = try LegacyMigration.rollback(migrated, paths: paths)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: paths.prefix(profile: profile, gameID: "A").path))
    try XCTAssertEqual(
      try String(contentsOf: archive.appendingPathComponent(SafePath.key("A") + "/user.reg")),
      "new registry")
    try XCTAssertEqual(try String(contentsOf: registry), "original registry")
  }
  func testMigrationPreflight() throws {
    let p = LauncherPaths(root: temporary)
    try p.prepare()
    try FileManager.default.createDirectory(at: p.legacyPrefix, withIntermediateDirectories: true)
    let profile = UUID()
    let games = ["A", "B"].map {
      Game(
        id: $0, store: .local, storeID: $0, title: $0,
        variants: [.init(id: "windows", platform: .windows)])
    }
    let plan = try LegacyMigration.prepare(paths: p, profile: profile, games: games)!
    try FileManager.default.createDirectory(
      at: p.prefix(profile: profile, gameID: "B"), withIntermediateDirectories: true)
    XCTAssertThrowsError(try LegacyMigration.execute(plan, paths: p))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: p.prefix(profile: profile, gameID: "A").path))
  }
  func testInstallationDirectory() throws {
    let game = temporary.appendingPathComponent("game")
    try FileManager.default.createDirectory(
      at: game.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let executable = game.appendingPathComponent("bin/game.exe")
    try Data([0x4d, 0x5a]).write(to: executable)
    let alias = temporary.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: game)
    var variant = GameVariant(
      id: "w", platform: .windows, executable: alias.appendingPathComponent("bin/game.exe").path,
      installationRoot: alias.path, installed: true)
    try XCTAssertEqual(try variant.installationDirectory(), game)
    variant.installationRoot = "/"
    XCTAssertThrowsError(try variant.installationDirectory())
    variant.installationRoot = temporary.appendingPathComponent("missing").path
    XCTAssertThrowsError(try variant.installationDirectory())
    variant.installationRoot = game.path
    variant.executable = temporary.appendingPathComponent("outside.exe").path
    XCTAssertThrowsError(try variant.installationDirectory())
  }
  func testMigrationBindings() throws {
    let paths = LauncherPaths(root: temporary)
    let fm = FileManager.default
    let source = paths.legacyPrefix.appendingPathComponent("drive_c/LegacyGame")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    let executable = source.appendingPathComponent("game.exe")
    try Data("game bytes".utf8).write(to: executable)
    let a = Profile(name: "A")
    let b = Profile(name: "B")
    let game = Game(
      id: "legacy", store: .local, storeID: "legacy", title: "legacy",
      variants: [
        .init(
          id: "w", platform: .windows, executable: executable.path, workingDirectory: source.path,
          installationRoot: source.path, installed: true)
      ], engine: .wineD3D)
    let state = LibraryState(profiles: [a, b], activeProfile: a.id, games: [game])
    let plan = try LegacyMigration.prepare(paths: paths, profile: a.id, games: [game])!
    let copied = try LegacyMigration.execute(plan, paths: paths)
    let bound = try LegacyMigration.bindLibrary(state, plan: copied, paths: paths)
    let first = bound.configured(game, profile: a.id)
    let second = bound.configured(game, profile: b.id)
    XCTAssertEqual(first.engine, .wineD3D)
    XCTAssertEqual(
      first.variants[0].executable,
      paths.prefix(profile: a.id, gameID: game.id).appendingPathComponent(
        "drive_c/LegacyGame/game.exe"
      ).path)
    XCTAssertEqual(second.variants[0].executable, executable.path)
    XCTAssertEqual(bound.games[0].variants[0].executable, executable.path)
    let twice = try LegacyMigration.bindLibrary(bound, plan: copied, paths: paths)
    XCTAssertEqual(twice.configured(game, profile: a.id).variants, first.variants)
    var updated = bound
    var refreshed = game
    refreshed.variants.append(.init(id: "native-new", platform: .macOS, architecture: .arm64))
    updated.games = [refreshed]
    XCTAssertEqual(updated.configured(refreshed, profile: a.id).variants.count, 2)
    XCTAssertEqual(updated.configured(refreshed, profile: a.id).variants[1].id, "native-new")
    refreshed.variants[0].executable = temporary.appendingPathComponent("shared-new/game.exe").path
    updated.games = [refreshed]
    updated.clearVariantOverride(profile: a.id, gameID: game.id, variantID: "w")
    XCTAssertEqual(
      updated.configured(refreshed, profile: a.id).variants[0].executable,
      refreshed.variants[0].executable)
    var forged = copied
    forged.destinations[game.id] = temporary.appendingPathComponent("outside").path
    XCTAssertThrowsError(try LegacyMigration.bindLibrary(bound, plan: forged, paths: paths))
    _ = try LegacyMigration.rollback(copied, paths: paths)
    let restored = LegacyMigration.libraryAfterRollback(bound, plan: copied)
    XCTAssertFalse(restored.configured(game, profile: a.id).variants[0].installed)
    XCTAssertEqual(restored.configured(game, profile: b.id).variants[0].executable, executable.path)
    try XCTAssertEqual(try String(contentsOf: executable), "game bytes")
  }
  func testMigrationRecovery() throws {
    let paths = LauncherPaths(root: temporary)
    let fm = FileManager.default
    try fm.createDirectory(at: paths.legacyPrefix, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: paths.legacyPrefix.appendingPathComponent("original.txt"))
    let profile = UUID()
    let games = ["A", "B"].map {
      Game(
        id: $0, store: .local, storeID: $0, title: $0,
        variants: [.init(id: "w", platform: .windows)])
    }
    let plan = try LegacyMigration.prepare(paths: paths, profile: profile, games: games)!
    let partial = paths.prefix(profile: profile, gameID: "A")
    try fm.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("partial bytes".utf8).write(to: partial.appendingPathComponent("partial.txt"))
    let journal = paths.root.appendingPathComponent("Migration/journal.json")
    try AtomicFile.writePrivate(JSONEncoder().encode([partial.path]), to: journal)
    XCTAssertEqual(LegacyMigration.blocksSession(paths: paths, profile: profile, gameID: "A"), true)
    XCTAssertFalse(LegacyMigration.blocksSession(paths: paths, profile: UUID(), gameID: "A"))
    XCTAssertFalse(
      LegacyMigration.blocksSession(paths: paths, profile: profile, gameID: "unrelated"))
    XCTAssertThrowsError(try LegacyMigration.prepare(paths: paths, profile: profile, games: games))
    try AtomicFile.writePrivate(
      JSONEncoder().encode([temporary.appendingPathComponent("not-a-destination").path]),
      to: journal)
    XCTAssertThrowsError(try LegacyMigration.recoverInterrupted(paths: paths))
    XCTAssertEqual(fm.fileExists(atPath: partial.path), true)
    try AtomicFile.writePrivate(JSONEncoder().encode([partial.path]), to: journal)
    do {
      let lease = try PrefixLease(paths: paths, profile: profile, gameID: "A")
      try withExtendedLifetime(lease) {
        XCTAssertThrowsError(try LegacyMigration.recoverInterrupted(paths: paths))
      }
    }
    let archive = try LegacyMigration.recoverInterrupted(paths: paths)
    try XCTAssertEqual(
      try String(
        contentsOf: archive.appendingPathComponent(partial.lastPathComponent + "/partial.txt")),
      "partial bytes")
    try XCTAssertEqual(
      try String(contentsOf: paths.legacyPrefix.appendingPathComponent("original.txt")), "original")
    XCTAssertFalse(fm.fileExists(atPath: partial.path))
    XCTAssertFalse(LegacyMigration.requiresRecovery(paths: paths))
    XCTAssertEqual(
      LegacyMigration.loadPlan(paths: paths)?.status,
      "interrupted-copies-archived-original-retained")
    XCTAssertNotNil(try LegacyMigration.prepare(paths: paths, profile: profile, games: games))
    XCTAssertEqual(plan.ownerProfile, profile)
  }
  func testRuntimeUpgrade() throws {
    let p = LauncherPaths(root: temporary)
    let profile = UUID()
    let prefix = try PrefixManager(paths: p).prepare(profile: profile, gameID: "A")
    let system = prefix.appendingPathComponent("drive_c/windows/system32")
    try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    let d = system.appendingPathComponent("d3d11.dll")
    try Data("wine-old".utf8).write(to: d)
    let engine = temporary.appendingPathComponent("engine")
    try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
    try Data("dxvk".utf8).write(to: engine.appendingPathComponent("d3d11.dll"))
    let config = RuntimeConfiguration(
      wine: "/usr/bin/true", engineDLLs: [GraphicsEngine.dxvkKosmic.rawValue: engine.path])
    try EngineInstaller.prepareForRuntimeChange("old", prefix: prefix)
    try EngineInstaller.configure(.dxvkKosmic, runtime: config, paths: p, prefix: prefix)
    try EngineInstaller.prepareForRuntimeChange("new", prefix: prefix)
    try Data("wine-new".utf8).write(to: d)
    try EngineInstaller.configure(.wineD3D, runtime: config, paths: p, prefix: prefix)
    try XCTAssertEqual(try String(contentsOf: d), "wine-new")
  }
  func testLegacySymlink() throws {
    let p = LauncherPaths(root: temporary)
    try p.prepare()
    let actual = temporary.appendingPathComponent("outside-original")
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: p.legacyPrefix, withDestinationURL: actual)
    XCTAssertThrowsError(try LegacyMigration.prepare(paths: p, profile: UUID(), games: []))
  }
  func testMetadataPrecision() throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data("18446744073709551614".utf8))
    try XCTAssertEqual(
      try String(decoding: JSONEncoder().encode(value), as: UTF8.self), "18446744073709551614")
  }
  func testGraphicsCapabilityScope() throws {
    var runtime = RuntimeConfiguration(wine: "/usr/bin/true")
    runtime.wineVersion = "fixture"
    runtime.verifiedEngines = ["wineD3D"]
    runtime.engineAPIs = ["wineD3D": ["d3d9"]]
    var game = Game(id: "modern", store: .local, storeID: "modern", title: "Modern")
    game.metadata = ["graphicsAPI": .string("d3d11")]
    XCTAssertThrowsError(try RendererSelector.select(game: game, runtime: runtime, rules: []))
  }
  func testRendererFailureLedger() throws {
    let paths = LauncherPaths(root: temporary)
    let ledger = RendererFailureLedger(paths: paths)
    let profile = UUID()
    XCTAssertFalse(
      RendererFailureLedger.graphicsInitializationFailed(
        exitCode: 1, userRequestedStop: false, diagnostic: "Steam license missing"))
    XCTAssertFalse(
      RendererFailureLedger.graphicsInitializationFailed(
        exitCode: 130, userRequestedStop: true, diagnostic: "Failed to initialize DXVK"))
    XCTAssertEqual(
      RendererFailureLedger.graphicsInitializationFailed(
        exitCode: 3, userRequestedStop: false, diagnostic: "Failed to initialize DXVK"), true)
    try ledger.record(profile: profile, gameID: "A", wineVersion: "wine-11.20", engine: .dxvkKosmic)
    XCTAssertEqual(
      ledger.failed(profile: profile, gameID: "A", wineVersion: "wine-11.20"), [.dxvkKosmic])
    XCTAssertEqual(ledger.failed(profile: profile, gameID: "B", wineVersion: "wine-11.20"), [])
    XCTAssertEqual(ledger.failed(profile: UUID(), gameID: "A", wineVersion: "wine-11.20"), [])
    XCTAssertEqual(ledger.failed(profile: profile, gameID: "A", wineVersion: "wine-11.21"), [])
  }
  func testRegistryEncoding() throws {
    let paths = LauncherPaths(root: temporary)
    let prefix = try PrefixManager(paths: paths).prepare(
      profile: UUID(), gameID: "A", userName: "test")
    let data = try Data(contentsOf: prefix.appendingPathComponent(".ready/folders.reg"))
    XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xfe])
    let text = String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian)!
    XCTAssertEqual(
      text.contains(
        #"[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders]"#
      ), true)
    XCTAssertEqual(text.contains(#"C:\\users\\test\\Documents"#), true)
    XCTAssertFalse(text.contains(#"C:\\\\users"#))
  }
  func testPEImports() throws {
    var data = Data(repeating: 0, count: 1024)
    func set16(_ at: Int, _ value: Int) {
      data[at] = UInt8(value & 255)
      data[at + 1] = UInt8((value >> 8) & 255)
    }
    func set32(_ at: Int, _ value: Int) {
      for i in 0..<4 { data[at + i] = UInt8((value >> (i * 8)) & 255) }
    }
    data[0] = 0x4d
    data[1] = 0x5a
    set32(0x3c, 64)
    set32(64, 0x4550)
    set16(70, 1)
    set16(84, 240)
    set16(88, 0x20b)
    set32(208, 0x1000)
    set32(336, 0x200)
    set32(340, 0x1000)
    set32(344, 512)
    set32(348, 512)
    set32(524, 0x1080)
    for (i, byte) in "d3d12.dll\0".utf8.enumerated() { data[640 + i] = byte }
    XCTAssertEqual(PEImports.graphicsAPIs(in: data), ["d3d12"])
    set32(544, 0x1180)
    for (i, byte) in "vulkan-1.dll\0".utf8.enumerated() { data[896 + i] = byte }
    XCTAssertEqual(PEImports.graphicsAPIs(in: data), ["d3d12", "vulkan"])
    set32(524, 0xffff_ffff)
    XCTAssertEqual(PEImports.graphicsAPIs(in: data), [])
    XCTAssertEqual(PEImports.graphicsAPIs(in: Data([0, 1, 2])), [])
  }
  func testBuiltinProviderPolicy() throws {
    let paths = LauncherPaths(root: temporary)
    let profile = UUID()
    let executable = temporary.appendingPathComponent("game.exe")
    try Data([0x4d, 0x5a]).write(to: executable)
    let variant = GameVariant(
      id: "windows", platform: .windows, executable: executable.path, installed: true)
    let game = Game(
      id: "A", store: .local, storeID: "A", title: "A", variants: [variant], engine: .d3dMetal)
    var runtime = RuntimeConfiguration(
      wine: "/usr/bin/true", engineDLLs: ["d3dMetal": temporary.path])
    for name in RendererSelector.requiredDLLs(.d3dMetal) {
      try Data("Apple fixture".utf8).write(to: temporary.appendingPathComponent(name))
    }
    runtime.engineOverrides = ["d3dMetal": "d3d11,dxgi=b"]
    runtime.engineSearchPaths = ["d3dMetal": temporary.path]
    XCTAssertThrowsError(
      try LaunchPlan.build(
        game: game, variant: variant, runtime: runtime, paths: paths, profile: profile,
        overlay: nil, controlURL: temporary.appendingPathComponent("control.json")))
    runtime.evaluationModeEnabled = true
    let plan = try LaunchPlan.build(
      game: game, variant: variant, runtime: runtime, paths: paths, profile: profile, overlay: nil,
      controlURL: temporary.appendingPathComponent("control.json"))
    XCTAssertEqual(plan.environment["WINEDLLOVERRIDES"], "d3d11,dxgi=b")
    XCTAssertEqual(plan.environment["WINEDLLPATH"], temporary.path)
    XCTAssertEqual(plan.environment["WINEPREFIX"], paths.prefix(profile: profile, gameID: "A").path)
  }
  func testBuiltin32Projection() throws {
    let paths = LauncherPaths(root: temporary.appendingPathComponent("data"))
    let base = temporary.appendingPathComponent("base32")
    let renderer = temporary.appendingPathComponent("dxmt32")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
    for name in ["kernel32.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] {
      try Data(("pure:" + name).utf8).write(to: base.appendingPathComponent(name))
    }
    for name in RendererSelector.requiredDLLs(.dxmtMetal) {
      try Data(("renderer:" + name).utf8).write(to: renderer.appendingPathComponent(name))
    }
    var runtime = RuntimeConfiguration(wine: "/usr/bin/true")
    runtime.runtimeID = "v1"
    runtime.builtin32Directory = base.path
    XCTAssertFalse(RendererSelector.available(.dxmtMetal, runtime: runtime, architecture: .x86))
    runtime.engineDLLs = ["dxmtMetal": renderer.path]
    runtime.engineDLLs32 = ["dxmtMetal": renderer.path]
    XCTAssertEqual(
      RendererSelector.available(.dxmtMetal, runtime: runtime, architecture: .x86), true)
    try FileManager.default.removeItem(at: renderer.appendingPathComponent("dxgi.dll"))
    XCTAssertFalse(RendererSelector.available(.dxmtMetal, runtime: runtime, architecture: .x86))
    try Data("renderer:dxgi.dll".utf8).write(to: renderer.appendingPathComponent("dxgi.dll"))
    var automatic = Game(id: "32", store: .local, storeID: "32", title: "32")
    automatic.metadata = ["graphicsAPI": .string("d3d11")]
    runtime.verifiedEngines = ["dxmtMetal"]
    runtime.engineAPIs = ["dxmtMetal": ["d3d11"]]
    XCTAssertThrowsError(
      try RendererSelector.select(game: automatic, runtime: runtime, rules: [], architecture: .x86))
    runtime.engineArchitectures = ["dxmtMetal": ["i386"]]
    try XCTAssertEqual(
      try RendererSelector.select(game: automatic, runtime: runtime, rules: [], architecture: .x86),
      .dxmtMetal)
    let profile = UUID()
    let a = try PrefixManager(paths: paths).prepare(profile: profile, gameID: "A")
    let b = try PrefixManager(paths: paths).prepare(profile: profile, gameID: "B")
    for prefix in [a, b] {
      try WindowsBuiltinBootstrap.prepare(runtime: runtime, prefix: prefix)
      try EngineInstaller.configure(.dxmtMetal, runtime: runtime, paths: paths, prefix: prefix)
    }
    let relative = "drive_c/windows/syswow64/"
    try Data("private write".utf8).write(to: a.appendingPathComponent(relative + "d3d11.dll"))
    try XCTAssertEqual(
      try String(contentsOf: b.appendingPathComponent(relative + "d3d11.dll")), "renderer:d3d11.dll"
    )
    try XCTAssertEqual(
      try String(contentsOf: renderer.appendingPathComponent("d3d11.dll")), "renderer:d3d11.dll")
    try EngineInstaller.configure(.wineD3D, runtime: runtime, paths: paths, prefix: a)
    try XCTAssertEqual(
      try String(contentsOf: a.appendingPathComponent(relative + "d3d11.dll")), "pure:d3d11.dll")
    // A runtime update must preserve an installer's custom dependency while updating pure core files.
    try Data("custom kernel".utf8).write(to: a.appendingPathComponent(relative + "kernel32.dll"))
    try Data("new pure kernel".utf8).write(to: base.appendingPathComponent("kernel32.dll"))
    runtime.runtimeID = "v2"
    try WindowsBuiltinBootstrap.prepare(runtime: runtime, prefix: a)
    try WindowsBuiltinBootstrap.prepare(runtime: runtime, prefix: b)
    try XCTAssertEqual(
      try String(contentsOf: a.appendingPathComponent(relative + "kernel32.dll")), "custom kernel")
    try XCTAssertEqual(
      try String(contentsOf: b.appendingPathComponent(relative + "kernel32.dll")), "new pure kernel"
    )
  }
  func testSavePathsRejectTraversalAndSymlinkEscape() throws {
    let prefix = temporary.appendingPathComponent("prefix")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    XCTAssertThrowsError(try SafePath.resolve("../outside", under: prefix))
    XCTAssertThrowsError(try SafePath.resolve("/tmp/file", under: prefix))
    try FileManager.default.createSymbolicLink(
      at: prefix.appendingPathComponent("escape"), withDestinationURL: temporary)
    XCTAssertThrowsError(try SafePath.resolve("escape/outside", under: prefix))
  }
  func testLaunchPlanUsesLiteralArgumentsAndIsolatedPrefix() throws {
    let p = LauncherPaths(root: temporary)
    try p.prepare()
    let profile = UUID()
    let exe = temporary.appendingPathComponent("game with spaces;echo.exe")
    try Data([0x4d, 0x5a]).write(to: exe)
    let variant = GameVariant(
      id: "w", platform: .windows, executable: exe.path,
      arguments: ["--name", "a;$(touch /tmp/no)"], installed: true)
    let g = Game(
      id: "1", store: .local, storeID: "1", title: "Game", variants: [variant], engine: .wineD3D)
    let cfg = RuntimeConfiguration(wine: "/usr/bin/true")
    let plan = try LaunchPlan.build(
      game: g, variant: variant, runtime: cfg, paths: p, profile: profile, overlay: nil,
      controlURL: p.session(UUID()).appendingPathComponent("control.json"))
    XCTAssertEqual(plan.environment["WINEPREFIX"], p.prefix(profile: profile, gameID: g.id).path)
    XCTAssertEqual(plan.arguments, [exe.path, "--name", "a;$(touch /tmp/no)"])
    var unavailable = g
    unavailable.engine = .d3dMetal
    XCTAssertThrowsError(
      try LaunchPlan.build(
        game: unavailable, variant: variant, runtime: cfg, paths: p, profile: profile, overlay: nil,
        controlURL: p.session(UUID()).appendingPathComponent("control.json")))
  }
}
