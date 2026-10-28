// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
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
  public var engineBootstrap32Dirs: [String: String]?
  public var evaluationOnlyEngines: [String]?
  public var evaluationModeEnabled: Bool?
  public var runtimeIdentity: String { runtimeID ?? wineVersion ?? wine ?? "unknown" }
  public func bootstrap32Directory(engine: GraphicsEngine?) -> String? {
    engine.flatMap { engineBootstrap32Dirs?[$0.rawValue] } ?? builtin32Directory
  }
  public func initializationIdentity(engine: GraphicsEngine) -> String {
    runtimeIdentity + ":wine:" + (engineWineBinaries?[engine.rawValue] ?? wine ?? "unavailable")
      + ":pe32:" + (bootstrap32Directory(engine: engine) ?? "none")
  }
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
    (try? read(url)) ?? .init()
  }
}
/// Wine must resolve to a regular executable; searchable directories also pass
/// FileManager.isExecutableFile on macOS. Final executable symlinks are allowed.
enum RuntimeExecutable {
  static func isAvailable(atPath path: String) -> Bool {
    guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return false }
    defer { free(resolved) }
    let target = String(cString: resolved)
    let fm = FileManager.default
    return (try? fm.attributesOfItem(atPath: target)[.type] as? FileAttributeType) == .typeRegular
      && fm.isExecutableFile(atPath: target)
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
    guard let baseWine = runtime.wine, RuntimeExecutable.isAvailable(atPath: baseWine) else {
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
    guard RuntimeExecutable.isAvailable(atPath: wine) else {
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
    try recoverInterrupted(prefix: prefix)
    // Recovery and strict manifest validation precede even an unchanged-version return.
    _ = try managedNames(stateFile("system32", prefix: prefix))
    _ = try managedNames(stateFile("syswow64", prefix: prefix))
    for relative in ["drive_c/windows/system32", "drive_c/windows/syswow64", ".ready/OriginalDLLs", ".ready/OriginalDLLs32"] { _ = try secure(relative, prefix: prefix) }
    let fm = FileManager.default
    let config = prefix.appendingPathComponent(".ready")
    let marker = config.appendingPathComponent("dll-runtime-version")
    if (try? String(contentsOf: marker)) == version { return }
    try fm.createDirectory(at: config, withIntermediateDirectories: true)
    let state = try stateFile("system32", prefix: prefix)
    let previous = try managedNames(state)
    let archive = config.appendingPathComponent("RuntimeBackups/" + UUID().uuidString)
    for name in previous {
      guard managedDLLs.contains(name) else {
        throw LauncherError.invalid("Manifest DLL non valido")
      }
      let file = try secure("drive_c/windows/system32", prefix: prefix).appendingPathComponent(name)
      if try fingerprint(file).kind != "absent" {
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try fm.moveItem(at: file, to: archive.appendingPathComponent(name))
      }
    }
    let originals = try backupDirectory("system32", prefix: prefix)
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
    let state = try stateFile("syswow64", prefix: prefix)
    let previous = try managedNames(state)
    for name in previous {
      guard managedDLLs.contains(name) else {
        throw LauncherError.invalid("Manifest DLL32 non valido")
      }
      let file = try secure("drive_c/windows/syswow64", prefix: prefix).appendingPathComponent(name)
      if try fingerprint(file).kind != "absent" {
        let destination = archive.appendingPathComponent("syswow64")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.moveItem(at: file, to: destination.appendingPathComponent(name))
      }
    }
    let originals = try backupDirectory("syswow64", prefix: prefix)
    if fm.fileExists(atPath: originals.path) {
      try fm.createDirectory(at: archive, withIntermediateDirectories: true)
      try fm.moveItem(at: originals, to: archive.appendingPathComponent("OriginalDLLs32"))
    }
    try AtomicFile.writePrivate(JSONEncoder().encode([String]()), to: state)
  }
  private struct FileSnapshot: Codable {
    var kind: String
    var sha256: String?
    var link: String?
  }
  private struct DLLIntent: Codable {
    var schema = 1
    var id: UUID
    var system: String
    var names: [String]
    var previous: [String]
    var previousManifest: Data?
    var systemBefore: [String: FileSnapshot]
    var backupsBefore: [String: FileSnapshot]
  }
  private static func managedNames(_ state: URL) throws -> [String] {
    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: state.path)) == nil else {
      throw LauncherError.invalid("Manifest DLL sostituito da un collegamento; dati conservati.")
    }
    guard FileManager.default.fileExists(atPath: state.path) else { return [] }
    let data = try Data(contentsOf: state)
    guard data.count <= 65_536 else { throw LauncherError.invalid("Manifest DLL troppo grande; dati conservati.") }
    let names = try JSONDecoder().decode([String].self, from: data)
    guard Set(names).count == names.count, names.allSatisfy(managedDLLs.contains) else {
      throw LauncherError.invalid("Manifest DLL non valido; dati conservati.")
    }
    return names
  }
  private static func secure(_ relative: String, prefix: URL) throws -> URL {
    let root = prefix.standardizedFileURL.resolvingSymlinksInPath()
    let expected = root.appendingPathComponent(relative).standardizedFileURL
    var component = root
    for part in relative.split(separator: "/") {
      component.appendPathComponent(String(part))
      guard (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) == nil else {
        throw LauncherError.invalid("Percorso DLL sostituito da un collegamento.")
      }
    }
    let value = try SafePath.resolve(relative, under: root)
    guard value.path == expected.path else { throw LauncherError.invalid("Directory DLL sostituita da un collegamento.") }
    return value
  }
  private static func stateFile(_ system: String, prefix: URL) throws -> URL {
    try secure(system == "system32" ? ".ready/managed-dlls.json" : ".ready/managed-dlls32.json", prefix: prefix)
  }
  private static func backupDirectory(_ system: String, prefix: URL) throws -> URL {
    try secure(system == "system32" ? ".ready/OriginalDLLs" : ".ready/OriginalDLLs32", prefix: prefix)
  }
  private static func intentFile(_ system: String, prefix: URL) throws -> URL {
    try secure(system == "system32" ? ".ready/managed-dlls.intent.json" : ".ready/managed-dlls32.intent.json", prefix: prefix)
  }
  private static func history(_ intent: DLLIntent, prefix: URL) throws -> URL {
    try secure(".ready/EngineTransactions/" + intent.id.uuidString, prefix: prefix)
  }
  private static func fingerprint(_ file: URL) throws -> FileSnapshot {
    let fm = FileManager.default
    if let link = try? fm.destinationOfSymbolicLink(atPath: file.path) {
      return .init(kind: "link", link: link)
    }
    guard fm.fileExists(atPath: file.path) else { return .init(kind: "absent") }
    guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
      throw LauncherError.invalid("Un percorso DLL non è un file regolare; dati conservati.")
    }
    return .init(kind: "file", sha256: SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined())
  }
  private static func matches(_ file: URL, _ expected: FileSnapshot) throws -> Bool {
    let actual = try fingerprint(file)
    return actual.kind == expected.kind && actual.sha256 == expected.sha256 && actual.link == expected.link
  }
  /// Clone regular files; preserve links as links without walking their targets.
  private static func copyPreserving(_ source: URL, _ destination: URL) throws {
    let fm = FileManager.default
    if let link = try? fm.destinationOfSymbolicLink(atPath: source.path) {
      try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: link)
    } else if Darwin.clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) != 0 {
      try fm.copyItem(at: source, to: destination)
    }
  }
  private static func archiveCurrent(_ file: URL, in directory: URL) throws {
    guard try fingerprint(file).kind != "absent" else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent + "-" + UUID().uuidString))
  }
  private static func atomicCopy(_ source: URL, _ destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ready-engine-" + UUID().uuidString)
    // A failed copy is retained at a private temporary name for inspection.
    try copyPreserving(source, temporary)
    guard Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw LauncherError.failed("Proiezione DLL non completata; dati conservati.")
    }
  }
  /// Caller holds this prefix's lease. Restore exact pre-swap state before another engine/runtime mutation.
  public static func recoverInterrupted(prefix: URL) throws {
    for system in ["system32", "syswow64"] {
      let pending = try intentFile(system, prefix: prefix)
      guard FileManager.default.fileExists(atPath: pending.path) else { continue }
      let bytes = try Data(contentsOf: pending)
      guard bytes.count <= 262_144 else { throw LauncherError.invalid("Journal DLL troppo grande; dati conservati.") }
      let intent = try JSONDecoder().decode(DLLIntent.self, from: bytes)
      guard intent.schema == 1, intent.system == system, Set(intent.names).count == intent.names.count,
        intent.names.allSatisfy(managedDLLs.contains), Set(intent.previous).count == intent.previous.count,
        Set(intent.previous).isSubset(of: Set(intent.names)),
        Set(intent.systemBefore.keys) == Set(intent.names), Set(intent.backupsBefore.keys) == Set(intent.names)
      else { throw LauncherError.invalid("Journal DLL non valido; nessun ripristino eseguito.") }
      let state = try stateFile(system, prefix: prefix)
      _ = try managedNames(state) // A corrupt manifest is never silently treated as empty.
      if let data = intent.previousManifest {
        guard try JSONDecoder().decode([String].self, from: data) == intent.previous else { throw LauncherError.invalid("Snapshot manifest DLL incoerente.") }
      } else if !intent.previous.isEmpty { throw LauncherError.invalid("Snapshot manifest DLL mancante.") }
      let archive = try history(intent, prefix: prefix)
      let targets = [try secure("drive_c/windows/" + system, prefix: prefix), try backupDirectory(system, prefix: prefix)]
      let snapshots = [intent.systemBefore, intent.backupsBefore]
      let labels = ["system", "backups"]
      // Validate every retained snapshot before touching any current file.
      for index in 0..<2 {
        _ = try secure(".ready/EngineTransactions/" + intent.id.uuidString + "/before/" + labels[index], prefix: prefix)
        for name in intent.names {
          let expected = snapshots[index][name]!
          let validShape = (expected.kind == "absent" && expected.sha256 == nil && expected.link == nil)
            || (expected.kind == "file" && expected.sha256?.count == 64 && expected.link == nil)
            || (expected.kind == "link" && expected.link != nil && expected.sha256 == nil)
          guard validShape else { throw LauncherError.invalid("Tipo snapshot DLL non valido.") }
          if expected.kind != "absent" {
            let saved = archive.appendingPathComponent("before/" + labels[index] + "/" + name)
            guard try matches(saved, expected) else { throw LauncherError.invalid("Snapshot DLL mancante o cambiato; dati conservati.") }
          }
        }
      }
      for index in 0..<2 {
        try FileManager.default.createDirectory(at: targets[index], withIntermediateDirectories: true)
        for name in intent.names {
          let expected = snapshots[index][name]!, target = targets[index].appendingPathComponent(name)
          if try matches(target, expected) { continue }
          try archiveCurrent(target, in: archive.appendingPathComponent("recovery/" + labels[index]))
          if expected.kind != "absent" {
            try atomicCopy(archive.appendingPathComponent("before/" + labels[index] + "/" + name), target)
          }
        }
      }
      try archiveCurrent(state, in: archive.appendingPathComponent("recovery/metadata"))
      if let previous = intent.previousManifest { try AtomicFile.writePrivate(previous, to: state) }
      else { try AtomicFile.writePrivate(JSONEncoder().encode([String]()), to: state) }
      try FileManager.default.moveItem(at: pending, to: archive.appendingPathComponent("recovered-intent.json"))
    }
  }
  /// Must be protected by this game's/profile's prefix lease. Preserve originals before any swap.
  public static func configure(_ engine: GraphicsEngine, runtime: RuntimeConfiguration, paths: LauncherPaths, prefix: URL) throws {
    try configureTransaction(engine, runtime: runtime, prefix: prefix, checkpoint: nil)
  }
  /// Deterministic injected interruption is available only for explicitly marked synthetic prefixes.
  public static func configureFixture(_ engine: GraphicsEngine, runtime: RuntimeConfiguration, paths: LauncherPaths, prefix: URL, checkpoint: @escaping (String, String) throws -> Void) throws {
    let marker = prefix.appendingPathComponent(".ready-synthetic-engine")
    guard (try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
      (try marker.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
    else { throw LauncherError.invalid("Checkpoint riservato a fixture sintetiche.") }
    try configureTransaction(engine, runtime: runtime, prefix: prefix, checkpoint: checkpoint)
  }
  private static func configureTransaction(_ engine: GraphicsEngine, runtime: RuntimeConfiguration, prefix: URL, checkpoint: ((String, String) throws -> Void)?) throws {
    try recoverInterrupted(prefix: prefix)
    // Both manifests are preflighted before either architecture changes.
    _ = try managedNames(stateFile("system32", prefix: prefix)); _ = try managedNames(stateFile("syswow64", prefix: prefix))
    try configureDirectory(source: runtime.engineDLLs[engine.rawValue], system: "system32", prefix: prefix, checkpoint: checkpoint)
    try configureDirectory(source: runtime.engineDLLs32?[engine.rawValue], system: "syswow64", prefix: prefix, checkpoint: checkpoint)
  }
  private static func configureDirectory(source: String?, system: String, prefix: URL, checkpoint: ((String, String) throws -> Void)?) throws {
    let fm = FileManager.default, directory = try secure("drive_c/windows/" + system, prefix: prefix)
    let backups = try backupDirectory(system, prefix: prefix), state = try stateFile(system, prefix: prefix)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true); try fm.createDirectory(at: backups, withIntermediateDirectories: true)
    let previous = try managedNames(state)
    var incoming = [(String, URL)]()
    if let source {
      for name in managedDLLs {
        let file = URL(fileURLWithPath: source).appendingPathComponent(name).resolvingSymlinksInPath()
        if fm.fileExists(atPath: file.path) {
          guard try fingerprint(file).kind == "file" else { throw LauncherError.invalid("Pacchetto DLL non regolare.") }
          incoming.append((name, file))
        }
      }
      guard !incoming.isEmpty else { throw LauncherError.unavailable("Nessuna DLL nel pacchetto del motore.") }
    }
    let names = Array(Set(previous + incoming.map { $0.0 })).sorted()
    let id = UUID(), archive = try secure(".ready/EngineTransactions/" + id.uuidString, prefix: prefix)
    let labels = ["system", "backups"], targets = [directory, backups]
    var records = [[String: FileSnapshot]]()
    for index in 0..<2 {
      let saved = archive.appendingPathComponent("before/" + labels[index]); try fm.createDirectory(at: saved, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var snapshot = [String: FileSnapshot]()
      for name in names {
        let file = targets[index].appendingPathComponent(name), value = try fingerprint(file); snapshot[name] = value
        if value.kind != "absent" { try copyPreserving(file, saved.appendingPathComponent(name)) }
      }
      records.append(snapshot)
    }
    let manifest = fm.fileExists(atPath: state.path) ? try Data(contentsOf: state) : nil
    let intent = DLLIntent(id: id, system: system, names: names, previous: previous, previousManifest: manifest, systemBefore: records[0], backupsBefore: records[1])
    try AtomicFile.writePrivate(JSONEncoder().encode(intent), to: intentFile(system, prefix: prefix))
    // Persist the complete union before any DLL mutation, including newly introduced names.
    try AtomicFile.writePrivate(JSONEncoder().encode(names), to: state)
    for name in previous {
      let target = directory.appendingPathComponent(name), backup = backups.appendingPathComponent(name)
      try archiveCurrent(target, in: archive.appendingPathComponent("replaced"))
      if try fingerprint(backup).kind != "absent" { try atomicCopy(backup, target) }
    }
    for (name, file) in incoming {
      let target = directory.appendingPathComponent(name), backup = backups.appendingPathComponent(name)
      if try fingerprint(target).kind != "absent" {
        if try fingerprint(backup).kind == "absent" { try atomicCopy(target, backup) }
        try archiveCurrent(target, in: archive.appendingPathComponent("replaced"))
      }
      try atomicCopy(file, target); try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
      try checkpoint?(system, name) // No production environment hook or sleep.
    }
    try AtomicFile.writePrivate(JSONEncoder().encode(incoming.map { $0.0 }), to: state)
    try fm.moveItem(at: intentFile(system, prefix: prefix), to: archive.appendingPathComponent("committed-intent.json"))
  }
}
