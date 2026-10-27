// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct CompatibilityRule: Codable, Equatable {
  public var gameID: String
  public var wineVersion: String
  public var engines: [GraphicsEngine]
  public var verified: Bool
  public var evidence: String
  public init(
    gameID: String, wineVersion: String, engines: [GraphicsEngine], verified: Bool, evidence: String
  ) {
    self.gameID = gameID
    self.wineVersion = wineVersion
    self.engines = engines
    self.verified = verified
    self.evidence = evidence
  }
}
public enum RendererSelector {
  public static func available(_ engine: GraphicsEngine, runtime: RuntimeConfiguration) -> Bool {
    let fm = FileManager.default
    guard let wine = runtime.engineWineBinaries?[engine.rawValue] ?? runtime.wine,
      fm.isExecutableFile(atPath: wine)
    else { return false }
    switch engine {
    case .automatic: return false
    case .wineD3D: return true
    case .dxvkKosmic, .vkd3dKosmic, .vulkanKosmic:
      guard let icd = runtime.kosmicICD, fm.fileExists(atPath: icd) else { return false }
    case .dxvkMolten, .vulkanMolten:
      guard let icd = runtime.moltenICD, fm.fileExists(atPath: icd) else { return false }
    case .dxmtMetal, .d3dMetal: break
    }
    if [.dxmtMetal, .d3dMetal, .dxvkKosmic, .dxvkMolten, .vkd3dKosmic].contains(engine) {
      guard let directory = runtime.engineDLLs[engine.rawValue], fm.fileExists(atPath: directory)
      else { return false }
    }
    return true
  }
  /// Fallback is evaluated between launches. Never hot-swap DLLs in a running prefix.
  public static func select(
    game: Game, runtime: RuntimeConfiguration, rules: [CompatibilityRule],
    failed: Set<GraphicsEngine> = []
  ) throws -> GraphicsEngine {
    if game.engine != .automatic {
      guard available(game.engine, runtime: runtime) else {
        throw LauncherError.unavailable("Il motore scelto non è installato per questo runtime.")
      }
      return game.engine
    }
    let verified = Set(runtime.verifiedEngines ?? [])
    let requiredAPI: String? = {
      if case .string(let api) = game.metadata?["graphicsAPI"] { return api }
      return nil
    }()
    func supportsRequiredAPI(_ engine: GraphicsEngine) -> Bool {
      guard let api = requiredAPI else { return true }
      return runtime.engineAPIs?[engine.rawValue]?.contains(api) == true
    }
    let candidates = rules.filter {
      $0.gameID == game.id && $0.wineVersion == runtime.runtimeIdentity && $0.verified
        && !$0.evidence.isEmpty
    }.flatMap { $0.engines }
    if let selected = candidates.first(where: {
      !failed.contains($0) && verified.contains($0.rawValue) && supportsRequiredAPI($0)
        && available($0, runtime: runtime)
    }) {
      return selected
    }
    // A detected/imported API can use a verified generic path, but is not mislabelled as game-specific validation.
    let api = game.metadata?["graphicsAPI"]
    let generic: [GraphicsEngine]
    switch api {
    case .string("d3d12"): generic = [.d3dMetal, .vkd3dKosmic]
    case .string("d3d11"): generic = [.dxmtMetal, .d3dMetal, .dxvkKosmic, .dxvkMolten, .wineD3D]
    case .string("vulkan"): generic = [.vulkanKosmic, .vulkanMolten]
    default: generic = [.dxmtMetal, .d3dMetal, .wineD3D]
    }
    if let engine = generic.first(where: {
      verified.contains($0.rawValue) && supportsRequiredAPI($0) && !failed.contains($0)
        && available($0, runtime: runtime)
    }) {
      return engine
    }
    throw LauncherError.unavailable(
      "Nessun percorso grafico disponibile e verificato per questa API/versione. Il launcher non combina automaticamente DLL incompatibili."
    )
  }
}
