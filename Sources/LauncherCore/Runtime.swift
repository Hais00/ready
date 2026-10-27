// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

public struct RuntimeConfiguration: Codable {
  public var wine: String?
  public var wineServer: String?
  public var wineBoot: String?
  public var kosmicICD: String?
  public var moltenICD: String?
  public var vulkanLibrary: String?
  public var engineDLLs: [String: String]
  public var wineVersion: String?
  public var runtimeID: String?
  public var verifiedEngines: [String]?
  public var engineAPIs: [String: [String]]?
  public var engineOverrides: [String: String]?
  public var engineSearchPaths: [String: String]?
  public var engineWineBinaries: [String: String]?
  public var engineWineServers: [String: String]?
  public var builtin32Directory: String?
  public var engineDLLs32: [String: String]?
  public var engineArchitectures: [String: [String]]?
  public var runtimeIdentity: String { runtimeID ?? wineVersion ?? wine ?? "unknown" }
  public init(
    wine: String? = nil, wineServer: String? = nil, wineBoot: String? = nil,
    kosmicICD: String? = nil, moltenICD: String? = nil, vulkanLibrary: String? = nil,
    engineDLLs: [String: String] = [:]
  ) {
    self.wine = wine
    self.wineServer = wineServer
    self.wineBoot = wineBoot
    self.kosmicICD = kosmicICD
    self.moltenICD = moltenICD
    self.vulkanLibrary = vulkanLibrary
    self.engineDLLs = engineDLLs
  }
  public static func load(_ url: URL) -> RuntimeConfiguration {
    (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? .init()
  }
}
public struct LaunchPlan: Codable {
  public var executable: String
  public var arguments: [String]
  public var environment: [String: String]
  public var currentDirectory: String
  public var usesWine: Bool
  public var engine: GraphicsEngine
  public static func build(
    game: Game, variant: GameVariant, runtime: RuntimeConfiguration, paths: LauncherPaths,
    profile: UUID, overlay: URL?, controlURL: URL, diagnostics: Bool = false
  ) throws -> LaunchPlan {
    guard variant.installed, let target = variant.executable,
      FileManager.default.fileExists(atPath: target)
    else { throw LauncherError.unavailable("Installa o importa prima questa versione del gioco.") }
    var env = [String: String]()
    env["M1L_CONTROL_FILE"] = controlURL.path
    env["M1L_OVERLAY_STATUS"] =
      controlURL.deletingLastPathComponent().appendingPathComponent("overlay-status.json").path
    env["MTL_HUD_ENABLED"] = diagnostics ? "1" : "0"
    if diagnostics { env["MTL_HUD_LOG_ENABLED"] = "1" }
    if let overlay, FileManager.default.fileExists(atPath: overlay.path) {
      env["DYLD_INSERT_LIBRARIES"] = overlay.path
      env["READY_OVERLAY_LIBRARY"] = overlay.path
    }
    if variant.platform == .macOS {
      return .init(
        executable: target, arguments: variant.arguments, environment: env,
        currentDirectory: variant.workingDirectory
          ?? URL(fileURLWithPath: target).deletingLastPathComponent().path, usesWine: false,
        engine: .automatic)
    }
    guard let baseWine = runtime.wine, FileManager.default.isExecutableFile(atPath: baseWine) else {
      throw LauncherError.unavailable("Wine non è ancora pronto. Apri Diagnostica runtime.")
    }
    env["WINEPREFIX"] = paths.prefix(profile: profile, gameID: game.id).path
    env["WINEDEBUG"] = "-all"
    env["ROSETTA_ADVERTISE_AVX"] = "1"
    // Engines are centralized; each game/profile prefix receives only its selected translation DLLs under its own lease.
    let rulesURL = paths.runtimes.appendingPathComponent("compatibility.json")
    let rules =
      (try? JSONDecoder().decode([CompatibilityRule].self, from: Data(contentsOf: rulesURL))) ?? []
    let failures = RendererFailureLedger(paths: paths).failed(
      profile: profile, gameID: game.id, wineVersion: runtime.runtimeIdentity)
    let engine = try RendererSelector.select(
      game: game, runtime: runtime, rules: rules, failed: failures,
      architecture: variant.architecture == .unknown
        ? ((try? ArchitectureProbe.inspect(URL(fileURLWithPath: target))) ?? .unknown)
        : variant.architecture)
    let wine = runtime.engineWineBinaries?[engine.rawValue] ?? baseWine
    guard FileManager.default.isExecutableFile(atPath: wine) else {
      throw LauncherError.unavailable("Wine non disponibile per il provider selezionato.")
    }
    switch engine {
    case .dxvkKosmic, .vkd3dKosmic, .vulkanKosmic:
      guard let icd = runtime.kosmicICD, FileManager.default.fileExists(atPath: icd) else {
        throw LauncherError.unavailable("ICD KosmicKrisp non disponibile per questo runtime Wine.")
      }
      env["VK_DRIVER_FILES"] = icd
      env["VK_ICD_FILENAMES"] = icd
    case .dxvkMolten, .vulkanMolten:
      guard let icd = runtime.moltenICD, FileManager.default.fileExists(atPath: icd) else {
        throw LauncherError.unavailable("ICD MoltenVK non disponibile.")
      }
      env["VK_DRIVER_FILES"] = icd
      env["VK_ICD_FILENAMES"] = icd
    default: break
    }
    // The Wine wrapper configures its Vulkan loader. Upstream Wine does not read WINE_VULKAN_DRIVER.
    switch engine {
    case .dxmtMetal: env["WINEDLLOVERRIDES"] = "d3d11,dxgi,winemetal=b"
    case .d3dMetal: env["WINEDLLOVERRIDES"] = "d3d11,d3d12,d3d12core,dxgi=n"
    case .dxvkKosmic, .dxvkMolten: env["WINEDLLOVERRIDES"] = "d3d11,dxgi=n"
    case .vkd3dKosmic: env["WINEDLLOVERRIDES"] = "d3d12,d3d12core,dxgi=n"
    case .wineD3D, .automatic: env["WINEDLLOVERRIDES"] = "d3d11,d3d12,dxgi=b"
    default: break
    }
    // Wine-built-in payloads (unlike native DXVK DLLs) need an explicitly verified
    // provider path and load policy. This is scoped to the selected engine only.
    if let overrides = runtime.engineOverrides?[engine.rawValue] {
      env["WINEDLLOVERRIDES"] = overrides
    }
    if let search = runtime.engineSearchPaths?[engine.rawValue] { env["WINEDLLPATH"] = search }
    if [.dxmtMetal, .d3dMetal, .dxvkKosmic, .dxvkMolten, .vkd3dKosmic].contains(engine),
      runtime.engineDLLs[engine.rawValue] == nil
    {
      throw LauncherError.unavailable(
        "Il motore selezionato richiede DLL non ancora installate/verificate.")
    }
    return .init(
      executable: wine, arguments: [target] + variant.arguments, environment: env,
      currentDirectory: variant.workingDirectory
        ?? URL(fileURLWithPath: target).deletingLastPathComponent().path, usesWine: true,
      engine: engine)
  }
}
public enum EngineInstaller {
  public static let managedDLLs = [
    "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3d11.dll", "d3d12.dll", "d3d12core.dll",
    "dxgi.dll", "winemetal.dll",
  ]
  /// Call BEFORE wineboot on runtime changes, while holding this prefix's lease.
  /// Backups from an older Wine must never overwrite newly initialized builtins.
  public static func prepareForRuntimeChange(_ version: String, prefix: URL) throws {
    let fm = FileManager.default
    let config = prefix.appendingPathComponent(".ready")
    let marker = config.appendingPathComponent("dll-runtime-version")
    if (try? String(contentsOf: marker)) == version { return }
    try fm.createDirectory(at: config, withIntermediateDirectories: true)
    let state = config.appendingPathComponent("managed-dlls.json")
    let previous = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: state))) ?? []
    let archive = config.appendingPathComponent("RuntimeBackups/" + UUID().uuidString)
    for name in previous {
      guard managedDLLs.contains(name) else {
        throw LauncherError.invalid("Manifest DLL non valido")
      }
      let file = prefix.appendingPathComponent("drive_c/windows/system32/" + name)
      if (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil {
        try fm.removeItem(at: file)
      } else if fm.fileExists(atPath: file.path) {
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try fm.moveItem(at: file, to: archive.appendingPathComponent(name))
      }
    }
    let originals = config.appendingPathComponent("OriginalDLLs")
    if fm.fileExists(atPath: originals.path) {
      try fm.createDirectory(at: archive, withIntermediateDirectories: true)
      try fm.moveItem(at: originals, to: archive.appendingPathComponent("OriginalDLLs"))
    }
    try AtomicFile.writePrivate(JSONEncoder().encode([String]()), to: state)
    try reset32ForRuntimeChange(prefix: prefix, archive: archive)
    try AtomicFile.writePrivate(Data(version.utf8), to: marker)
  }
  private static func reset32ForRuntimeChange(prefix: URL, archive: URL) throws {
    let fm = FileManager.default
    let state = prefix.appendingPathComponent(".ready/managed-dlls32.json")
    let previous = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: state))) ?? []
    for name in previous {
      guard managedDLLs.contains(name) else {
        throw LauncherError.invalid("Manifest DLL32 non valido")
      }
      let file = prefix.appendingPathComponent("drive_c/windows/syswow64/" + name)
      if (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil {
        try fm.removeItem(at: file)
      } else if fm.fileExists(atPath: file.path) {
        let destination = archive.appendingPathComponent("syswow64")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.moveItem(at: file, to: destination.appendingPathComponent(name))
      }
    }
    let originals = prefix.appendingPathComponent(".ready/OriginalDLLs32")
    if fm.fileExists(atPath: originals.path) {
      try fm.createDirectory(at: archive, withIntermediateDirectories: true)
      try fm.moveItem(at: originals, to: archive.appendingPathComponent("OriginalDLLs32"))
    }
    try AtomicFile.writePrivate(JSONEncoder().encode([String]()), to: state)
  }
  /// Must be protected by this game's/profile's prefix lease. Preserve originals before any swap.
  public static func configure(
    _ engine: GraphicsEngine, runtime: RuntimeConfiguration, paths: LauncherPaths, prefix: URL
  ) throws {
    try configureDirectory(
      source: runtime.engineDLLs[engine.rawValue],
      system: prefix.appendingPathComponent("drive_c/windows/system32"),
      backups: prefix.appendingPathComponent(".ready/OriginalDLLs"),
      state: prefix.appendingPathComponent(".ready/managed-dlls.json"))
    // A PE32 renderer is independent of its PE64 counterpart. Never place x64 DLLs in syswow64.
    try configureDirectory(
      source: runtime.engineDLLs32?[engine.rawValue],
      system: prefix.appendingPathComponent("drive_c/windows/syswow64"),
      backups: prefix.appendingPathComponent(".ready/OriginalDLLs32"),
      state: prefix.appendingPathComponent(".ready/managed-dlls32.json"))
  }
  private static func configureDirectory(source: String?, system: URL, backups: URL, state: URL)
    throws
  {
    let fm = FileManager.default
    try fm.createDirectory(at: system, withIntermediateDirectories: true)
    try fm.createDirectory(at: backups, withIntermediateDirectories: true)
    let previous = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: state))) ?? []
    var incoming = [(String, URL)]()
    if let source {
      for dll in managedDLLs {
        let url = URL(fileURLWithPath: source).appendingPathComponent(dll)
        if fm.fileExists(atPath: url.path) { incoming.append((dll, url)) }
      }
      guard !incoming.isEmpty else {
        throw LauncherError.unavailable("Nessuna DLL nel pacchetto del motore.")
      }
    }
    for name in previous {
      guard managedDLLs.contains(name) else {
        throw LauncherError.invalid("Manifest DLL non valido")
      }
      let dest = system.appendingPathComponent(name)
      let backup = backups.appendingPathComponent(name)
      if fm.fileExists(atPath: dest.path)
        || (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil
      {
        try fm.removeItem(at: dest)
      }
      if fm.fileExists(atPath: backup.path) { try fm.copyItem(at: backup, to: dest) }
    }
    for (name, source) in incoming {
      let dest = system.appendingPathComponent(name)
      let backup = backups.appendingPathComponent(name)
      if fm.fileExists(atPath: dest.path) {
        if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: dest, to: backup) }
        try fm.removeItem(at: dest)
      }
      // Per-prefix writable projections must NOT be symlinks: an installer writing through
      // one would otherwise mutate the central engine and every other game. APFS clones
      // share unmodified storage and isolate writes. Non-APFS falls back to selected DLLs only.
      let immutableSource = source.resolvingSymlinksInPath()
      if Darwin.clonefile(immutableSource.path, dest.path, UInt32(CLONE_NOFOLLOW)) != 0 {
        try fm.copyItem(at: immutableSource, to: dest)
      }
      try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
    }
    try AtomicFile.writePrivate(JSONEncoder().encode(incoming.map { $0.0 }), to: state)
  }
}
