// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum Store: String, Codable, CaseIterable {
  case steam, epic, gog, amazon, local
  public var title: String {
    switch self {
    case .steam: return "Steam"
    case .epic: return "Epic Games"
    case .gog: return "GOG"
    case .amazon: return "Amazon Games"
    case .local: return "Locali"
    }
  }

}
public enum GamePlatform: String, Codable { case macOS, windows }
public enum BinaryArchitecture: String, Codable { case arm64, x86_64, universal, x86, unknown }
public enum GraphicsEngine: String, Codable, CaseIterable {
  case automatic, dxmtMetal, d3dMetal, dxvkKosmic, dxvkMolten, vkd3dKosmic, vulkanKosmic,
    vulkanMolten, wineD3D
  public var title: String {
    switch self {
    case .automatic: return "Automatico"
    case .dxmtMetal: return "DXMT · DX11 → Metal"
    case .d3dMetal: return "D3DMetal · DX11 / DX12 (Apple, valutazione)"
    case .dxvkKosmic: return "DXVK · DX11 → KosmicKrisp"
    case .dxvkMolten: return "DXVK · DX11 → MoltenVK"
    case .vkd3dKosmic: return "VKD3D · DX12 → KosmicKrisp"
    case .vulkanKosmic: return "Vulkan → KosmicKrisp"
    case .vulkanMolten: return "Vulkan → MoltenVK"
    case .wineD3D: return "WineD3D · OpenGL"
    }
  }
}
public struct GameVariant: Codable, Equatable, Identifiable {
  public var id: String
  public var platform: GamePlatform
  public var architecture: BinaryArchitecture
  public var executable: String?
  public var workingDirectory: String?
  public var installationRoot: String?
  public var arguments: [String]
  public var installed: Bool
  public var verification: String
  public init(
    id: String, platform: GamePlatform, architecture: BinaryArchitecture = .unknown,
    executable: String? = nil, workingDirectory: String? = nil, installationRoot: String? = nil,
    arguments: [String] = [],
    installed: Bool = false,
    verification: String = "Architettura da verificare dopo l’installazione"
  ) {
    self.id = id
    self.platform = platform
    self.architecture = architecture
    self.executable = executable
    self.workingDirectory = workingDirectory
    self.installationRoot = installationRoot
    self.arguments = arguments
    self.installed = installed
    self.verification = verification
  }
  public var title: String {
    platform == .windows
      ? "Windows"
      : (architecture == .arm64 || architecture == .universal
        ? "Apple Silicon nativo"
        : architecture == .x86_64 ? "Mac Intel · Rosetta" : "macOS · architettura da verificare")
  }
}
extension GameVariant {
  public func installationDirectory() throws -> URL {
    guard let executable, executable.hasPrefix("/") else {
      throw LauncherError.invalid("Eseguibile del gioco non valido.")
    }
    let target = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
    let raw = installationRoot ?? target.deletingLastPathComponent().path
    guard raw.hasPrefix("/") else {
      throw LauncherError.invalid("Installazione del gioco non valida.")
    }
    let root = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
    var directory: ObjCBool = false
    guard root.path != "/",
      FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
      directory.boolValue, target.path.hasPrefix(root.path + "/")
    else {
      throw LauncherError.invalid(
        "L’eseguibile non appartiene alla cartella d’installazione selezionata.")
    }
    return root
  }
}
public struct SaveRule: Codable, Equatable {
  public var relativePath: String
  public init(_ relativePath: String) { self.relativePath = relativePath }
}
public struct Game: Codable, Identifiable, Equatable {
  public var id: String
  public var store: Store
  public var storeID: String
  public var title: String
  public var artworkURL: String?
  public var variants: [GameVariant]
  public var selectedVariant: String?
  public var engine: GraphicsEngine
  public var controllerInputMode: ControllerInputMode?
  public var lastPlayed: Date?
  public var saveRules: [SaveRule]
  public var metadata: [String: JSONValue]?
  public var profileIDs: [UUID]?
  public init(
    id: String, store: Store, storeID: String, title: String, artworkURL: String? = nil,
    variants: [GameVariant] = [], selectedVariant: String? = nil,
    engine: GraphicsEngine = .automatic, lastPlayed: Date? = nil, saveRules: [SaveRule] = []
  ) {
    self.id = id
    self.store = store
    self.storeID = storeID
    self.title = title
    self.artworkURL = artworkURL
    self.variants = variants
    self.selectedVariant = selectedVariant
    self.engine = engine
    self.lastPlayed = lastPlayed
    self.saveRules = saveRules
  }
  public var currentVariant: GameVariant? {
    variants.first { $0.id == selectedVariant } ?? variants.first {
      $0.installed && ($0.architecture == .arm64 || $0.architecture == .universal)
    } ?? variants.first { $0.installed } ?? variants.first
  }
}
public indirect enum JSONValue: Codable, Equatable {
  case string(String)
  case integer(Int64)
  case unsigned(UInt64)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let n = try? c.decode(Int64.self) {
      self = .integer(n)
    } else if let n = try? c.decode(UInt64.self) {
      self = .unsigned(n)
    } else if let n = try? c.decode(Double.self) {
      self = .number(n)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let x): try c.encode(x)
    case .integer(let x): try c.encode(x)
    case .unsigned(let x): try c.encode(x)
    case .number(let x): try c.encode(x)
    case .bool(let x): try c.encode(x)
    case .array(let x): try c.encode(x)
    case .object(let x): try c.encode(x)
    case .null: try c.encodeNil()
    }
  }
  public var foundation: Any {
    switch self {
    case .string(let x): return x
    case .integer(let x): return NSNumber(value: x)
    case .unsigned(let x): return NSNumber(value: x)
    case .number(let x): return x
    case .bool(let x): return x
    case .array(let x): return x.map { $0.foundation }
    case .object(let x): return x.mapValues { $0.foundation }
    case .null: return NSNull()
    }
  }
}
public struct Profile: Codable, Identifiable, Equatable {
  public var id: UUID
  public var name: String
  public var createdAt: Date
  public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
  }
}
public struct LibraryState: Codable {
  public var schema = 1
  public var profiles: [Profile]
  public var activeProfile: UUID
  public var games: [Game]
  public var gamePreferences: [String: GamePreferences]?
  public init(profiles: [Profile], activeProfile: UUID, games: [Game] = []) {
    self.profiles = profiles
    self.activeProfile = activeProfile
    self.games = games
  }
  public static func initial() -> LibraryState {
    let p = Profile(name: "Giocatore 1")
    return .init(profiles: [p], activeProfile: p.id)
  }
  public func configured(_ game: Game, profile: UUID? = nil) -> Game {
    var value = game
    // Shared/store Game metadata cannot select another profile's input policy.
    value.controllerInputMode = nil
    if let preferences = gamePreferences?[
      GamePreferences.key(profile: profile ?? activeProfile, gameID: game.id)]
    {
      value.engine = preferences.engine
      value.controllerInputMode = preferences.controllerInputMode
      value.selectedVariant = preferences.selectedVariant
      if let scoped = preferences.variants {
        value.variants =
          game.variants.map { original in scoped.first { $0.id == original.id } ?? original }
          + scoped.filter { item in !game.variants.contains { $0.id == item.id } }
      }
    }
    return value
  }
  public mutating func clearVariantOverride(profile: UUID, gameID: String, variantID: String) {
    let key = GamePreferences.key(profile: profile, gameID: gameID)
    guard var preferences = gamePreferences?[key], let scoped = preferences.variants else { return }
    preferences.variants = scoped.filter { $0.id != variantID }
    gamePreferences?[key] = preferences
  }
}
public struct GamePreferences: Codable {
  public var engine: GraphicsEngine
  public var selectedVariant: String?
  public var variants: [GameVariant]?
  public var controllerInputMode: ControllerInputMode?
  public init(
    engine: GraphicsEngine = .automatic, selectedVariant: String? = nil,
    variants: [GameVariant]? = nil, controllerInputMode: ControllerInputMode? = nil
  ) {
    self.engine = engine
    self.selectedVariant = selectedVariant
    self.variants = variants
    self.controllerInputMode = controllerInputMode
  }
  public static func key(profile: UUID, gameID: String) -> String {
    profile.uuidString + ":" + gameID
  }
}
public enum LauncherError: Error, LocalizedError {
  case invalid(String)
  case unavailable(String)
  case busy
  case failed(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let s), .unavailable(let s), .failed(let s): return s
    case .busy: return "Questo gioco è già attivo per il profilo selezionato."
    }
  }
}
