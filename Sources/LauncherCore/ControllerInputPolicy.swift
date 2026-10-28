// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

public enum ControllerInputMode: String, Codable, CaseIterable {
  case automatic, gameInput, forceBuiltin
  public var title: String {
    switch self {
    case .automatic: return "Controller · Automatico con overlay"
    case .gameInput: return "Controller · Input del gioco"
    case .forceBuiltin: return "Controller · Forza XInput Wine (avanzate)"
    }
  }
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    // Unknown future settings must not unexpectedly force an input implementation.
    self = Self(rawValue: raw) ?? .gameInput
  }
}

/// Optional fields retain readable legacy E5 metadata without claiming protocol2.
public struct ControllerInputDescriptor: Codable, Equatable {
  public var protocolVersion: Int?
  public var providerID: String?
  public var manifestPath: String?
  public var manifestSHA256: String?
  public var engineProviders: [String: String]?
  public var providers: [String: ControllerInputProvider]?
  public init(protocolVersion: Int? = nil, providerID: String? = nil,
              manifestPath: String? = nil, manifestSHA256: String? = nil,
              engineProviders: [String: String]? = nil, providers: [String: ControllerInputProvider]? = nil) {
    self.protocolVersion = protocolVersion; self.providerID = providerID
    self.manifestPath = manifestPath; self.manifestSHA256 = manifestSHA256
    self.engineProviders = engineProviders; self.providers = providers
  }
}
public struct ControllerInputProvider: Codable, Equatable {
  public var wineRoot: String
  public var wineBinarySHA256: String
  public var wineLauncherSHA256: String
  public var payloadHashes: [String: String]
  public var unixAliases: [String: String]
  public var knownBuiltinHashes: [String: [String]]
  public init(wineRoot: String, wineBinarySHA256: String, wineLauncherSHA256: String, payloadHashes: [String: String],
              unixAliases: [String: String], knownBuiltinHashes: [String: [String]]) {
    self.wineRoot = wineRoot; self.wineBinarySHA256 = wineBinarySHA256; self.wineLauncherSHA256 = wineLauncherSHA256
    self.payloadHashes = payloadHashes; self.unixAliases = unixAliases
    self.knownBuiltinHashes = knownBuiltinHashes
  }
}

/// Launch-only policy. It never copies, replaces, removes or loads any game DLL.
public enum ControllerInputPolicy {
  public static let enableVariable = "M1L_XINPUT_CAPTURE"
  public static let dllNames = ["xinput1_1.dll", "xinput1_2.dll", "xinput1_3.dll", "xinput1_4.dll", "xinput9_1_0.dll"]
  public static let builtinOverride = "xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0=b"
  public static let unixAliases = Dictionary(uniqueKeysWithValues: ["xinput1_1", "xinput1_2", "xinput1_3", "xinput1_4"].map {
    ("x86_64-unix/" + $0 + ".so", "xinput-capture.so")
  })
  private static var pePaths: Set<String> {
    Set(["i386", "x86_64"].flatMap { arch in dllNames.map { arch + "-windows/" + $0 } })
  }
  private static func canonical(_ path: String) -> URL? {
    guard path.hasPrefix("/"), let value = realpath(path, nil) else { return nil }
    defer { free(value) }
    return URL(fileURLWithPath: String(cString: value))
  }
  private static func fileHash(_ file: URL) throws -> String {
    let fd = Darwin.open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw LauncherError.invalid("File controller non leggibile.") }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= 64 * 1024 * 1024 else {
      throw LauncherError.invalid("File controller non regolare o troppo grande.")
    }
    var hasher = SHA256(), bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = Darwin.read(fd, &bytes, bytes.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw LauncherError.invalid("File controller non leggibile.") }
      if count == 0 { break }
      hasher.update(data: Data(bytes.prefix(count)))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private static func validHash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  private static func selectedRoot(_ wine: String) -> URL? {
    guard let executable = canonical(wine), executable.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
    return executable.deletingLastPathComponent().deletingLastPathComponent()
  }
  private struct VerifiedProvider {
    var provider: ControllerInputProvider
    var supportsEngine: Bool
  }
  private static func verifiedProvider(
    descriptor: ControllerInputDescriptor?, engine: GraphicsEngine, wine: String
  ) throws -> VerifiedProvider? {
    guard let descriptor, descriptor.protocolVersion == 2,
      let id = descriptor.providerID, !id.isEmpty,
      let providers = descriptor.providers,
      let role = descriptor.engineProviders?[engine.rawValue]
        ?? providers.first(where: { canonical($0.value.wineRoot)?.path == selectedRoot(wine)?.path })?.key,
      let provider = providers[role],
      let declaredRoot = canonical(provider.wineRoot), declaredRoot.path != "/",
      declaredRoot.path == selectedRoot(wine)?.path,
      let manifestPath = descriptor.manifestPath, manifestPath.hasPrefix("/"), let expectedManifest = descriptor.manifestSHA256,
      validHash(expectedManifest), try fileHash(URL(fileURLWithPath: manifestPath)) == expectedManifest
    else { return nil }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    guard let document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      return nil
    }
    let resolved = try RuntimeConfigurationPaths.absoluteControllerManifest(
      document, root: URL(fileURLWithPath: manifestPath).resolvingSymlinksInPath().deletingLastPathComponent())
    let manifest = try JSONDecoder().decode(
      ControllerInputDescriptor.self, from: JSONSerialization.data(withJSONObject: resolved))
    guard manifest.protocolVersion == descriptor.protocolVersion, manifest.providerID == descriptor.providerID,
      manifest.engineProviders == descriptor.engineProviders, manifest.providers == descriptor.providers,
      validHash(provider.wineBinarySHA256), validHash(provider.wineLauncherSHA256),
      try fileHash(URL(fileURLWithPath: wine)) == provider.wineLauncherSHA256,
      try fileHash(declaredRoot.appendingPathComponent("bin/wine")) == provider.wineBinarySHA256,
      Set(provider.payloadHashes.keys) == pePaths.union(["x86_64-unix/xinput-capture.so"]),
      provider.unixAliases == unixAliases, Set(provider.knownBuiltinHashes.keys) == pePaths
    else { return nil }
    for (relative, expected) in provider.payloadHashes {
      guard validHash(expected), try fileHash(declaredRoot.appendingPathComponent("lib/wine/" + relative)) == expected else { return nil }
    }
    for (relative, hashes) in provider.knownBuiltinHashes {
      guard !hashes.isEmpty, hashes.allSatisfy(validHash),
        let current = provider.payloadHashes[relative], hashes.contains(current) else { return nil }
    }
    for (relative, target) in provider.unixAliases {
      let file = declaredRoot.appendingPathComponent("lib/wine/" + relative)
      guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == target,
        canonical(file.path)?.path == declaredRoot.appendingPathComponent("lib/wine/x86_64-unix/xinput-capture.so").path else { return nil }
    }
    return VerifiedProvider(provider: provider, supportsEngine: descriptor.engineProviders?[engine.rawValue] == role)
  }
  private static func hasReader(_ wine: String) -> Bool {
    guard let root = selectedRoot(wine) else { return false }
    return FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/wine/x86_64-unix/xinput-capture.so").path)
  }
  private static func hasPrivateDLL(game: Game, variant: GameVariant, prefix: URL, provider: ControllerInputProvider) -> Bool {
    let fm = FileManager.default
    guard let executable = variant.executable, executable.hasPrefix("/") else { return true }
    var folders = [URL(fileURLWithPath: executable).deletingLastPathComponent(),
                   prefix.appendingPathComponent("drive_c/windows/system32"), prefix.appendingPathComponent("drive_c/windows/syswow64")]
    if let working = variant.workingDirectory {
      guard working.hasPrefix("/") else { return true }
      folders.append(URL(fileURLWithPath: working))
    }
    for folder in Set(folders) {
      var isDirectory: ObjCBool = false
      guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { continue }
      guard isDirectory.boolValue,
        let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return true }
      for file in files where dllNames.contains(file.lastPathComponent.lowercased()) {
        let known = provider.knownBuiltinHashes.filter { $0.key.hasSuffix("/" + file.lastPathComponent.lowercased()) }.flatMap(\.value)
        guard let hash = try? fileHash(file), known.contains(hash) else { return true }
      }
    }
    return false
  }
  private static func hasInputOverride(_ value: String?) -> Bool {
    guard let value else { return false }
    let names = Set(dllNames.map { String($0.dropLast(4)) })
    return value.split(separator: ";").contains { entry in
      let modules = entry.split(separator: "=", maxSplits: 1).first ?? ""
      return modules.split(separator: ",").contains { raw in
        var name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        name = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? name
        if name.hasPrefix("*") { name.removeFirst() }
        if name.hasSuffix(".dll") { name.removeLast(4) }
        return names.contains(name)
      }
    }
  }
  private static func foreignSearchPath(_ value: String?, provider: ControllerInputProvider) -> Bool {
    guard let value, !value.isEmpty else { return false }
    guard let root = canonical(provider.wineRoot) else { return true }
    let expected = root.appendingPathComponent("lib/wine").path
    return value.split(separator: ":", omittingEmptySubsequences: false).contains {
      canonical(String($0))?.path != expected
    }
  }
  public static func apply(
    game: Game, variant: GameVariant, runtime: RuntimeConfiguration, engine: GraphicsEngine,
    wine: String?, prefix: URL, overlayAvailable: Bool, environment: inout [String: String]
  ) throws {
    let mode = game.controllerInputMode ?? .automatic
    guard let executable = variant.executable, !executable.isEmpty else {
      throw LauncherError.invalid("Variante senza eseguibile per la policy controller.")
    }
    if variant.platform == .macOS {
      if mode == .gameInput { environment[enableVariable] = "0" }
      if mode == .forceBuiltin { throw LauncherError.invalid("XInput Wine non si applica alla versione macOS.") }
      return
    }
    guard let wine else { return }
    let excluded = engine == .d3dMetal || runtime.evaluationOnlyEngines?.contains(engine.rawValue) == true
    let candidateProvider = excluded ? nil : (try? verifiedProvider(descriptor: runtime.overlayInputCapture, engine: engine, wine: wine))
    if let verified = candidateProvider,
      foreignSearchPath(environment["WINEDLLPATH"], provider: verified.provider) {
      // A different search path could load even a legacy reader which ignores
      // the opt-out flag. Do not claim capture OR passthrough for that mixture.
      throw LauncherError.unavailable("Il percorso DLL Wine non corrisponde al provider controller verificato.")
    }
    if mode == .gameInput {
      if hasReader(wine) && candidateProvider == nil {
        throw LauncherError.unavailable("Questo provider controller non supporta un opt-out verificato. Usa un runtime con protocollo2 oppure disabilita l’overlay.")
      }
      environment[enableVariable] = "0"
      return
    }
    guard let verified = candidateProvider else {
      if mode == .forceBuiltin { throw LauncherError.unavailable("Forzare XInput richiede un provider verificato con protocollo2.") }
      if !excluded && runtime.overlayInputCapture?.protocolVersion == 2
        && (runtime.overlayInputCapture?.engineProviders?[engine.rawValue] != nil || hasReader(wine)) {
        throw LauncherError.unavailable("Il provider controller dichiarato non corrisponde ai file Wine verificati.")
      }
      return // Unmarked legacy/native Wine behavior remains unchanged.
    }
    environment[enableVariable] = "0"
    guard verified.supportsEngine else {
      if mode == .forceBuiltin { throw LauncherError.unavailable("Questo motore non supporta la gestione XInput verificata.") }
      return
    }
    let provider = verified.provider
    guard overlayAvailable else {
      if mode == .forceBuiltin { throw LauncherError.unavailable("L’overlay non è disponibile per questo controller.") }
      return
    }
    if mode == .automatic && (hasPrivateDLL(game: game, variant: variant, prefix: prefix, provider: provider)
                              || hasInputOverride(environment["WINEDLLOVERRIDES"])) { return }
    environment[enableVariable] = "1"
    let overrides = environment["WINEDLLOVERRIDES"] ?? ""
    environment["WINEDLLOVERRIDES"] = overrides.isEmpty ? builtinOverride : overrides + ";" + builtinOverride
  }
}
