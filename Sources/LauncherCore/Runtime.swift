import Foundation

public struct RuntimeConfiguration: Codable {
    public var wine: String?
    public var wineServer: String?
    public var wineBoot: String?
    public var kosmicICD: String?
    public var moltenICD: String?
    public var vulkanLibrary: String?
    public var engineDLLs: [String:String]
    public var wineVersion: String?
    public var verifiedEngines: [String]?
    public init(wine:String?=nil,wineServer:String?=nil,wineBoot:String?=nil,kosmicICD:String?=nil,moltenICD:String?=nil,vulkanLibrary:String?=nil,engineDLLs:[String:String]=[:]) {
        self.wine=wine;self.wineServer=wineServer;self.wineBoot=wineBoot;self.kosmicICD=kosmicICD;self.moltenICD=moltenICD;self.vulkanLibrary=vulkanLibrary;self.engineDLLs=engineDLLs
    }
    public static func load(_ url:URL)->RuntimeConfiguration { (try? JSONDecoder().decode(Self.self,from:Data(contentsOf:url))) ?? .init() }
}
public struct LaunchPlan: Codable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String:String]
    public var currentDirectory: String
    public var usesWine: Bool
    public var engine: GraphicsEngine
    public static func build(game:Game, variant:GameVariant, runtime:RuntimeConfiguration, paths:LauncherPaths, profile:UUID, overlay:URL?, controlURL:URL, diagnostics:Bool=false)throws->LaunchPlan {
        guard variant.installed,let target=variant.executable,FileManager.default.fileExists(atPath:target) else{throw LauncherError.unavailable("Installa o importa prima questa versione del gioco.")}
        var env=[String:String]()
        env["M1L_CONTROL_FILE"]=controlURL.path
        env["M1L_OVERLAY_STATUS"]=controlURL.deletingLastPathComponent().appendingPathComponent("overlay-status.json").path
        env["MTL_HUD_ENABLED"]=diagnostics ? "1":"0"
        if diagnostics { env["MTL_HUD_LOG_ENABLED"]="1" }
        if let overlay,FileManager.default.fileExists(atPath:overlay.path){env["DYLD_INSERT_LIBRARIES"]=overlay.path;env["READY_OVERLAY_LIBRARY"]=overlay.path}
        if variant.platform == .macOS {
            return .init(executable:target,arguments:variant.arguments,environment:env,currentDirectory:URL(fileURLWithPath:target).deletingLastPathComponent().path,usesWine:false,engine:.automatic)
        }
        guard let wine=runtime.wine,FileManager.default.isExecutableFile(atPath:wine) else{throw LauncherError.unavailable("Wine non è ancora pronto. Apri Diagnostica runtime.")}
        env["WINEPREFIX"]=paths.prefix(profile:profile,gameID:game.id).path
        env["WINEDEBUG"]="-all"
        env["ROSETTA_ADVERTISE_AVX"]="1"
        // Engines are centralized; each game/profile prefix receives only its selected translation DLLs under its own lease.
        let rulesURL=paths.runtimes.appendingPathComponent("compatibility.json")
        let rules=(try? JSONDecoder().decode([CompatibilityRule].self,from:Data(contentsOf:rulesURL))) ?? []
        let engine=try RendererSelector.select(game:game,runtime:runtime,rules:rules)
        switch engine {
        case .dxvkKosmic,.vkd3dKosmic,.vulkanKosmic:
            guard let icd=runtime.kosmicICD,FileManager.default.fileExists(atPath:icd) else{throw LauncherError.unavailable("ICD KosmicKrisp non disponibile per questo runtime Wine.")}
            env["VK_DRIVER_FILES"]=icd;env["VK_ICD_FILENAMES"]=icd
        case .dxvkMolten,.vulkanMolten:
            guard let icd=runtime.moltenICD,FileManager.default.fileExists(atPath:icd) else{throw LauncherError.unavailable("ICD MoltenVK non disponibile.")}
            env["VK_DRIVER_FILES"]=icd;env["VK_ICD_FILENAMES"]=icd
        default:break
        }
        // The Wine wrapper configures its Vulkan loader. Upstream Wine does not read WINE_VULKAN_DRIVER.
        switch engine {
        case .d3dMetal:env["WINEDLLOVERRIDES"]="d3d11,d3d12,d3d12core,dxgi=n,b"
        case .dxvkKosmic,.dxvkMolten:env["WINEDLLOVERRIDES"]="d3d11,dxgi=n,b"
        case .vkd3dKosmic:env["WINEDLLOVERRIDES"]="d3d12,d3d12core,dxgi=n,b"
        case .wineD3D,.automatic:env["WINEDLLOVERRIDES"]="d3d11,d3d12,dxgi=b"
        default:break
        }
        if [.d3dMetal,.dxvkKosmic,.dxvkMolten,.vkd3dKosmic].contains(engine),runtime.engineDLLs[engine.rawValue]==nil {
            throw LauncherError.unavailable("Il motore selezionato richiede DLL non ancora installate/verificate.")
        }
        return .init(executable:wine,arguments:[target]+variant.arguments,environment:env,currentDirectory:URL(fileURLWithPath:target).deletingLastPathComponent().path,usesWine:true,engine:engine)
    }
}
public enum EngineInstaller {
    public static let managedDLLs=["d3d10.dll","d3d10_1.dll","d3d10core.dll","d3d11.dll","d3d12.dll","d3d12core.dll","dxgi.dll"]
    /// Call BEFORE wineboot on runtime changes, while holding this prefix's lease.
    /// Backups from an older Wine must never overwrite newly initialized builtins.
    public static func prepareForRuntimeChange(_ version:String,prefix:URL)throws {
        let fm=FileManager.default,config=prefix.appendingPathComponent(".ready"),marker=config.appendingPathComponent("dll-runtime-version")
        if (try? String(contentsOf:marker))==version{return}
        try fm.createDirectory(at:config,withIntermediateDirectories:true)
        let state=config.appendingPathComponent("managed-dlls.json")
        let previous=(try? JSONDecoder().decode([String].self,from:Data(contentsOf:state))) ?? []
        let archive=config.appendingPathComponent("RuntimeBackups/"+UUID().uuidString)
        for name in previous {
            guard managedDLLs.contains(name) else{throw LauncherError.invalid("Manifest DLL non valido")}
            let file=prefix.appendingPathComponent("drive_c/windows/system32/"+name)
            if (try? fm.destinationOfSymbolicLink(atPath:file.path)) != nil {try fm.removeItem(at:file)}
            else if fm.fileExists(atPath:file.path){try fm.createDirectory(at:archive,withIntermediateDirectories:true);try fm.moveItem(at:file,to:archive.appendingPathComponent(name))}
        }
        let originals=config.appendingPathComponent("OriginalDLLs")
        if fm.fileExists(atPath:originals.path){try fm.createDirectory(at:archive,withIntermediateDirectories:true);try fm.moveItem(at:originals,to:archive.appendingPathComponent("OriginalDLLs"))}
        try AtomicFile.writePrivate(JSONEncoder().encode([String]()),to:state)
        try AtomicFile.writePrivate(Data(version.utf8),to:marker)
    }
    /// Must be protected by the global prefix lease. Preserve original DLLs before any swap.
    public static func configure(_ engine:GraphicsEngine,runtime:RuntimeConfiguration,paths:LauncherPaths,prefix:URL)throws {
        let fm=FileManager.default,system=prefix.appendingPathComponent("drive_c/windows/system32"),backups=prefix.appendingPathComponent(".ready/OriginalDLLs")
        try fm.createDirectory(at:system,withIntermediateDirectories:true);try fm.createDirectory(at:backups,withIntermediateDirectories:true)
        let state=prefix.appendingPathComponent(".ready/managed-dlls.json")
        let previous=(try? JSONDecoder().decode([String].self,from:Data(contentsOf:state))) ?? []
        var incoming=[(String,URL)]()
        if let source=runtime.engineDLLs[engine.rawValue] {
            for dll in managedDLLs {
                let url=URL(fileURLWithPath:source).appendingPathComponent(dll)
                if fm.fileExists(atPath:url.path){incoming.append((dll,url))}
            }
            guard !incoming.isEmpty else{throw LauncherError.unavailable("Nessuna DLL nel pacchetto del motore.")}
        }
        for name in previous {
            guard managedDLLs.contains(name) else{throw LauncherError.invalid("Manifest DLL non valido")}
            let dest=system.appendingPathComponent(name),backup=backups.appendingPathComponent(name)
            if fm.fileExists(atPath:dest.path){try fm.removeItem(at:dest)}
            if fm.fileExists(atPath:backup.path){try fm.copyItem(at:backup,to:dest)}
        }
        for (name,source) in incoming {
            let dest=system.appendingPathComponent(name),backup=backups.appendingPathComponent(name)
            if fm.fileExists(atPath:dest.path) {
                if !fm.fileExists(atPath:backup.path){try fm.copyItem(at:dest,to:backup)}
                try fm.removeItem(at:dest)
            }
            // Translator binaries stay versioned centrally; only links belong to a prefix.
            try fm.createSymbolicLink(at:dest,withDestinationURL:source)
        }
        try JSONEncoder().encode(incoming.map{$0.0}).write(to:state,options:.atomic)
    }
}
