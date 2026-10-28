// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import LauncherCore

enum ControllerInputPolicyChecks {
  static func validate() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ready-controller-policy-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let paths = LauncherPaths(root: root.appendingPathComponent("data")), profile = UUID()
    func require(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
      if try !value() { throw LauncherError.failed(text) }
    }
    func rejects(_ body: () throws -> Void) throws {
      do { try body() } catch { return }
      throw LauncherError.failed("Unsafe controller request was accepted")
    }
    func hash(_ file: URL) throws -> String {
      SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }
    func write(_ path: URL, _ value: String, executable: Bool = false) throws {
      try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(value.utf8).write(to: path)
      if executable { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) }
    }
    var providers = [String: ControllerInputProvider]()
    for role in ["base", "dxmt"] {
      let wine = root.appendingPathComponent(role + "/wine")
      try write(wine.appendingPathComponent("bin/wine"), "synthetic-Wine-ABI-" + role, executable: true)
      try write(wine.appendingPathComponent("bin/ready-wine"), "#!/bin/sh\nexit 0\n", executable: true)
      var hashes = [String: String](), known = [String: [String]]()
      for arch in ["i386", "x86_64"] {
        for name in ControllerInputPolicy.dllNames {
          let relative = arch + "-windows/" + name
          let file = wine.appendingPathComponent("lib/wine/" + relative)
          try write(file, "synthetic-production-" + relative)
          hashes[relative] = try hash(file)
          known[relative] = [hashes[relative]!]
        }
      }
      let module = wine.appendingPathComponent("lib/wine/x86_64-unix/xinput-capture.so")
      try write(module, "synthetic-protocol2-reader")
      hashes["x86_64-unix/xinput-capture.so"] = try hash(module)
      for (relative, target) in ControllerInputPolicy.unixAliases {
        try fm.createSymbolicLink(atPath: wine.appendingPathComponent("lib/wine/" + relative).path, withDestinationPath: target)
      }
      for name in ["d3d11.dll", "dxgi.dll", "winemetal.dll"] { try write(wine.appendingPathComponent("lib/wine/x86_64-windows/" + name), "renderer-fixture") }
      providers[role] = ControllerInputProvider(
        wineRoot: wine.path, wineBinarySHA256: try hash(wine.appendingPathComponent("bin/wine")),
        wineLauncherSHA256: try hash(wine.appendingPathComponent("bin/ready-wine")),
        payloadHashes: hashes, unixAliases: ControllerInputPolicy.unixAliases, knownBuiltinHashes: known)
    }
    let manifest = root.appendingPathComponent("controller-capability.json")
    var descriptor = ControllerInputDescriptor(protocolVersion: 2, providerID: "owned-policy-fixture",
      engineProviders: ["wineD3D": "base", "dxmtMetal": "dxmt"], providers: providers)
    try JSONEncoder().encode(descriptor).write(to: manifest)
    descriptor.manifestPath = manifest.path; descriptor.manifestSHA256 = try hash(manifest)
    let base = URL(fileURLWithPath: providers["base"]!.wineRoot)
    let dxmt = URL(fileURLWithPath: providers["dxmt"]!.wineRoot)
    var runtime = RuntimeConfiguration(wine: base.appendingPathComponent("bin/ready-wine").path,
      engineDLLs: ["dxmtMetal": dxmt.appendingPathComponent("lib/wine/x86_64-windows").path])
    runtime.overlayInputCapture = descriptor
    runtime.engineWineBinaries = ["dxmtMetal": dxmt.appendingPathComponent("bin/ready-wine").path]
    runtime.engineSearchPaths = ["dxmtMetal": dxmt.appendingPathComponent("lib/wine").path]
    runtime.engineOverrides = ["dxmtMetal": "d3d11,dxgi,winemetal=b"]
    runtime.builtin32Directory = base.appendingPathComponent("lib/wine/i386-windows").path
    let executable = root.appendingPathComponent("Install/Game.exe"), overlay = root.appendingPathComponent("Overlay.dylib")
    try write(executable, "synthetic exe"); try write(overlay, "owned overlay fixture")
    var variant = GameVariant(id: "win", platform: .windows, architecture: .x86_64, executable: executable.path, installed: true)
    var game = Game(id: "fixture", store: .local, storeID: "fixture", title: "Controller policy fixture", variants: [variant], engine: .wineD3D)
    let control = paths.session(UUID()).appendingPathComponent("control.json")
    func plan(_ game: Game, _ runtime: RuntimeConfiguration, _ overlay: URL? = overlay, _ variant: GameVariant = variant) throws -> LaunchPlan {
      try LaunchPlan.build(game: game, variant: variant, runtime: runtime, paths: paths, profile: profile, overlay: overlay, controlURL: control)
    }
    let automatic = try plan(game, runtime)
    try require(automatic.environment[ControllerInputPolicy.enableVariable] == "1", "Matching E6 should opt in")
    try require(automatic.environment["WINEDLLOVERRIDES"]!.hasSuffix(ControllerInputPolicy.builtinOverride), "Builtin policy appended after renderer overrides")
    try require(try plan(game, runtime, nil).environment[ControllerInputPolicy.enableVariable] == "0", "Missing overlay cannot enable capture")
    var dxmtGame = game; dxmtGame.engine = .dxmtMetal
    try require(try plan(dxmtGame, runtime).environment["WINEDLLOVERRIDES"] == "d3d11,dxgi,winemetal=b;" + ControllerInputPolicy.builtinOverride, "DXMT renderer policy was overwritten")
    let reader = base.appendingPathComponent("lib/wine/x86_64-unix/xinput-capture.so")
    let readerBytes = try Data(contentsOf: reader)
    try fm.removeItem(at: reader)
    try rejects { _ = try plan(game, runtime) }
    var unmarkedMissing = runtime; unmarkedMissing.overlayInputCapture = nil
    try require(try plan(game, unmarkedMissing).environment[ControllerInputPolicy.enableVariable] == nil, "Missing reader was incorrectly treated as a declaredV2 provider in legacy config")
    try readerBytes.write(to: reader)
    var invalidVariant = variant; invalidVariant.executable = nil
    var invalidEnvironment = [String: String]()
    try rejects {
      try ControllerInputPolicy.apply(game: game, variant: invalidVariant, runtime: runtime, engine: .wineD3D, wine: runtime.wine,
        prefix: root, overlayAvailable: true, environment: &invalidEnvironment)
    }
    var explicitInput = runtime
    explicitInput.engineOverrides = ["wineD3D": "Z:\\custom\\xinput1_3=n;d3d11=b"]
    try require(try plan(game, explicitInput).environment[ControllerInputPolicy.enableVariable] == "0", "Explicit path input override was ignored")
    let shadow = root.appendingPathComponent("shadow/lib/wine")
    try fm.createDirectory(at: shadow, withIntermediateDirectories: true)
    var shadowRuntime = runtime; shadowRuntime.engineSearchPaths = ["wineD3D": shadow.path]
    try rejects { _ = try plan(game, shadowRuntime) }
    let privateDLL = executable.deletingLastPathComponent().appendingPathComponent("XINPUT1_3.DLL")
    try write(privateDLL, "private app implementation")
    let privateBytes = try Data(contentsOf: privateDLL)
    let passthrough = try plan(game, runtime)
    try require(passthrough.environment[ControllerInputPolicy.enableVariable] == "0" && !passthrough.environment["WINEDLLOVERRIDES"]!.contains("xinput"), "Private app DLL must prevent Auto force")
    game.controllerInputMode = .forceBuiltin
    try require(try plan(game, runtime).environment[ControllerInputPolicy.enableVariable] == "1", "Advanced force did not choose verified builtin")
    try require(try Data(contentsOf: privateDLL) == privateBytes, "Policy touched private DLL")
    game.controllerInputMode = .gameInput
    try require(try plan(game, runtime).environment[ControllerInputPolicy.enableVariable] == "0", "Real protocol2 opt-out absent")
    try fm.removeItem(at: privateDLL)
    game.controllerInputMode = nil
    let known = base.appendingPathComponent("lib/wine/x86_64-windows/xinput1_3.dll")
    try fm.copyItem(at: known, to: privateDLL)
    try require(try plan(game, runtime).environment[ControllerInputPolicy.enableVariable] == "1", "Known builtin hash misclassified as private DLL")
    try fm.removeItem(at: privateDLL)
    let cwd = root.appendingPathComponent("Working")
    try write(cwd.appendingPathComponent("xinput1_4.dll"), "private working directory DLL")
    variant.workingDirectory = cwd.path
    try require(try plan(game, runtime, overlay, variant).environment[ControllerInputPolicy.enableVariable] == "0", "Working directory DLL ignored")
    let privatePrefix = paths.prefix(profile: profile, gameID: game.id).appendingPathComponent("drive_c/windows/syswow64/xinput9_1_0.dll")
    try write(privatePrefix, "private prefix DLL")
    try require(try plan(game, runtime).environment[ControllerInputPolicy.enableVariable] == "0", "Private prefix DLL ignored")
    try fm.removeItem(at: privatePrefix)
    var legacy = runtime; legacy.overlayInputCapture = ControllerInputDescriptor(providerID: "legacy-E5")
    try require(try plan(game, legacy).environment[ControllerInputPolicy.enableVariable] == nil, "Auto changed legacy behavior")
    game.controllerInputMode = .gameInput
    try rejects { _ = try plan(game, legacy) }
    game.controllerInputMode = .forceBuiltin
    try rejects { _ = try plan(game, legacy) }
    game.controllerInputMode = nil
    var corrupt = runtime; corrupt.overlayInputCapture?.manifestSHA256 = String(repeating: "0", count: 64)
    try rejects { _ = try plan(game, corrupt) }
    let launcher = base.appendingPathComponent("bin/ready-wine")
    let launcherBytes = try Data(contentsOf: launcher)
    try write(launcher, "changed launcher", executable: true)
    try rejects { _ = try plan(game, runtime) }
    try launcherBytes.write(to: launcher)
    let alias = base.appendingPathComponent("lib/wine/x86_64-unix/xinput1_4.so")
    try fm.removeItem(at: alias); try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "../xinput-capture.so")
    try rejects { _ = try plan(game, runtime) }
    try fm.removeItem(at: alias); try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "xinput-capture.so")
    var environment = [String: String]()
    var native = variant; native.platform = .macOS
    try ControllerInputPolicy.apply(game: game, variant: native, runtime: runtime, engine: .automatic, wine: nil, prefix: root, overlayAvailable: true, environment: &environment)
    try require(environment[ControllerInputPolicy.enableVariable] == nil, "Native Auto behavior changed")
    game.controllerInputMode = .gameInput
    try ControllerInputPolicy.apply(game: game, variant: native, runtime: runtime, engine: .automatic, wine: nil, prefix: root, overlayAvailable: true, environment: &environment)
    try require(environment[ControllerInputPolicy.enableVariable] == "0", "Explicit native gamepad opt-out missing")
    let unpatched = root.appendingPathComponent("legacy-winecx/bin/ready-wine")
    try write(unpatched, "legacy WineCX", executable: true)
    environment = [:]; game.controllerInputMode = nil
    try ControllerInputPolicy.apply(game: game, variant: variant, runtime: runtime, engine: .d3dMetal, wine: unpatched.path, prefix: root, overlayAvailable: true, environment: &environment)
    try require(environment.isEmpty, "WineCX Auto acquired Wine11.20 policy")
    var library = LibraryState.initial(); let first = library.activeProfile, second = UUID()
    library.gamePreferences = [GamePreferences.key(profile: first, gameID: game.id): GamePreferences(controllerInputMode: .gameInput), GamePreferences.key(profile: second, gameID: game.id): GamePreferences(controllerInputMode: .forceBuiltin)]
    library.games = [game]
    let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(library))
    try require(decoded.configured(game, profile: first).controllerInputMode == .gameInput && decoded.configured(game, profile: second).controllerInputMode == .forceBuiltin, "Profile preferences leaked")
    // A store refresh replaces Game metadata, not this per-profile preference map.
    let refreshed = Game(id: game.id, store: .local, storeID: game.id, title: "Refreshed metadata", variants: [variant])
    try require(decoded.configured(refreshed, profile: first).controllerInputMode == .gameInput, "Refresh dropped profile opt-out")
    let legacyExe = paths.legacyPrefix.appendingPathComponent("drive_c/Game/Game.exe")
    try write(legacyExe, "owned migration exe")
    var legacyVariant = variant; legacyVariant.executable = legacyExe.path; legacyVariant.workingDirectory = nil
    var migratedGame = refreshed; migratedGame.variants = [legacyVariant]
    var migrating = library; migrating.games = [migratedGame]
    guard let migration = try LegacyMigration.prepare(paths: paths, profile: first, games: [migratedGame]) else {
      throw LauncherError.failed("Owned migration fixture missing")
    }
    let copied = try LegacyMigration.execute(migration, paths: paths)
    let rebound = try LegacyMigration.bindLibrary(migrating, plan: copied, paths: paths)
    try require(rebound.configured(migratedGame, profile: first).controllerInputMode == .gameInput
      && rebound.configured(migratedGame, profile: second).controllerInputMode == .forceBuiltin, "Migration dropped controller scope")
    var relative = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runtime)) as! [String: Any]
    // Only declare the controller paths relative; remove the other absolute
    // fields so this tests their codec independently of renderer fixtures.
    relative = ["pathFormat": "runtime-relative-v1", "engineDLLs": [String: String](),
      "overlayInputCapture": ["protocolVersion": 2, "manifestPath": "controller-capability.json",
        "providers": ["base": ["wineRoot": "base/wine"]], "historicalPath": "/old/source/unchanged"]]
    let absolute = try RuntimeConfigurationPaths.absoluteDocument(relative, root: root)
    let capture = absolute["overlayInputCapture"] as! [String: Any]
    try require(capture["manifestPath"] as? String == manifest.path
      && capture["historicalPath"] as? String == "/old/source/unchanged", "Controller codec rewrote provenance")
    var unsafe = relative
    unsafe["overlayInputCapture"] = ["manifestPath": "../escape"]
    try rejects { _ = try RuntimeConfigurationPaths.absoluteDocument(unsafe, root: root) }
    unsafe["overlayInputCapture"] = ["providers": ["base": ["wineRoot": "/absolute"]]]
    try rejects { _ = try RuntimeConfigurationPaths.absoluteDocument(unsafe, root: root) }
    var sharedMetadata = game; sharedMetadata.controllerInputMode = .forceBuiltin
    try require(decoded.configured(sharedMetadata, profile: UUID()).controllerInputMode == nil, "Shared metadata selected unowned profile policy")
    let oldPrefs = try JSONDecoder().decode(GamePreferences.self, from: Data("{\"engine\":\"automatic\"}".utf8))
    try require(oldPrefs.controllerInputMode == nil, "Old preference schema lost Auto default")
    let unknown = try JSONDecoder().decode(ControllerInputMode.self, from: Data("\"future-policy\"".utf8))
    try require(unknown == .gameInput, "Unknown preference unexpectedly forced input")
  }
}
