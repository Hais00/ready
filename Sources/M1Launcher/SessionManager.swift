// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import LauncherCore

final class SessionManager {
    let paths:LauncherPaths
    let project:URL
    private var process:Process?
    private var lease:PrefixLease?
    private var monitor:Timer?
    private var sequence=0
    private var visible=false
    private var selection=0
    private var logHandle:FileHandle?
    private var activeGame:Game?
    private var activeProfile:UUID?
    private var lastActionSequence:Int = -1
    private var lastActionPID:Int = -1
    private var activePrefix:URL?
    private var activeRuntime:RuntimeConfiguration?
    private var sessionID=UUID()
    private var sessionDirectory:URL {paths.session(sessionID)}
    private(set) var overlayStatus:[String:Any]=[:]
    var onFinish:((String)->Void)?
    var running:Bool { lease != nil }
    var controlFile:URL {sessionDirectory.appendingPathComponent("control.json")}
    init(paths:LauncherPaths,project:URL){self.paths=paths;self.project=project}
    func start(game:Game,variant:GameVariant,profile:UUID)throws {
        guard !running else{throw LauncherError.busy}
        sessionID=UUID()
        lastActionSequence = -1;lastActionPID = -1;visible=false;selection=0;sequence=0;overlayStatus=[:]
        try paths.prepare()
        try FileManager.default.createDirectory(at:sessionDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let held=try PrefixLease(paths:paths,profile:profile,gameID:game.id)
        let userRuntime=paths.runtimes.appendingPathComponent("runtime.json")
        let runtime=RuntimeConfiguration.load(FileManager.default.fileExists(atPath:userRuntime.path) ? userRuntime:project.appendingPathComponent("Runtime/runtime.json"))
        let overlay=project.appendingPathComponent("Build/libReadyOverlay.dylib")
        let plan=try LaunchPlan.build(game:game,variant:variant,runtime:runtime,paths:paths,profile:profile,overlay:overlay,controlURL:controlFile)
        if plan.usesWine {
            let prefix=try PrefixManager(paths:paths).prepare(profile:profile,gameID:game.id)
            // Wine boot/registry setup is per-prefix; shared engine files remain central.
            let marker=prefix.appendingPathComponent(".ready/runtime-initialized")
            let version=runtime.wineVersion ?? runtime.wine ?? "unknown"
            if (try? String(contentsOf:marker)) != version {
                try EngineInstaller.prepareForRuntimeChange(version,prefix:prefix)
                let boot=Process();boot.executableURL=URL(fileURLWithPath:runtime.wine!);boot.arguments=["wineboot","-u"];boot.environment=ProcessInfo.processInfo.environment.merging(["WINEPREFIX":prefix.path,"WINEDEBUG":"-all"]){_,v in v};boot.standardOutput=FileHandle.nullDevice;boot.standardError=FileHandle.nullDevice
                try boot.run();boot.waitUntilExit();guard boot.terminationStatus==0 else{throw LauncherError.failed("Inizializzazione Wine del gioco non riuscita.")}
                try PrefixManager(paths:paths).prepare(profile:profile,gameID:game.id)
                let reg=Process();reg.executableURL=URL(fileURLWithPath:runtime.wine!);reg.arguments=["regedit","/S",prefix.appendingPathComponent(".ready/folders.reg").path];reg.environment=boot.environment;reg.standardOutput=FileHandle.nullDevice;reg.standardError=FileHandle.nullDevice;try reg.run();reg.waitUntilExit()
                guard reg.terminationStatus==0 else{throw LauncherError.failed("Reindirizzamento cartelle Windows non riuscito.")}
                try AtomicFile.writePrivate(Data(version.utf8),to:marker)
            }
            try EngineInstaller.configure(plan.engine,runtime:runtime,paths:paths,prefix:prefix)
            activePrefix=prefix
        }
        try writeControl(visible:false)
        let status=sessionDirectory.appendingPathComponent("overlay-status.json")
        if FileManager.default.fileExists(atPath:status.path){try FileManager.default.removeItem(at:status)}
        let task=Process();task.executableURL=URL(fileURLWithPath:plan.executable);task.arguments=plan.arguments;task.currentDirectoryURL=URL(fileURLWithPath:plan.currentDirectory)
        task.environment=ProcessInfo.processInfo.environment.merging(plan.environment){_,new in new}
        let log=paths.logs.appendingPathComponent("session-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]);let handle=try FileHandle(forWritingTo:log)
        task.standardOutput=handle;task.standardError=handle
        task.terminationHandler={[weak self] p in DispatchQueue.main.async{self?.finish("Sessione terminata · codice \(p.terminationStatus)")}}
        try task.run();process=task;lease=held;activeGame=game;activeProfile=profile;activeRuntime=runtime;logHandle=handle
        monitor=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.pollOverlay()}
    }
    func overlayToggle(){guard running else{return};try? writeControl(visible:!visible)}
    func overlayMove(_ delta:Int){guard running,visible else{return};selection=(selection+delta+2)%2;try? writeControl(visible:true)}
    func overlayConfirm(){guard running,visible else{return};if selection==1{quit()}else{try? writeControl(visible:false)}}
    func resume(){try? writeControl(visible:false)}
    func quit(){
        guard let process else{return}
        try? writeControl(visible:false)
        if process.isRunning {process.terminate()}
        // No global killall: only this exact game/profile wineserver may be shut down.
        let cfg=activeRuntime ?? RuntimeConfiguration()
        if let prefix=activePrefix,let server=cfg.wineServer,FileManager.default.isExecutableFile(atPath:server){
            let stop=Process();stop.executableURL=URL(fileURLWithPath:server);stop.arguments=["-k"];stop.environment=ProcessInfo.processInfo.environment.merging(["WINEPREFIX":prefix.path]){_,v in v};try? stop.run()
        }
    }
    private func writeControl(visible:Bool)throws {
        self.visible=visible;sequence+=1
        let value:[String:Any]=["visible":visible,"selection":selection,"sequence":sequence]
        try AtomicFile.writePrivate(JSONSerialization.data(withJSONObject:value),to:controlFile)
    }
    private func pollOverlay(){
        guard let bytes=try? Data(contentsOf:sessionDirectory.appendingPathComponent("overlay-status.json")),let status=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] else{return}
        overlayStatus=status
        guard (status["frameCount"] as? Int ?? 0)>0 else{return}
        if (status["controlSequence"] as? Int ?? -1)>=sequence {
            if let shown=status["visible"] as? Bool{visible=shown}
            if let current=status["selection"] as? Int{selection=current}
        }
        let actionSequence=status["actionSequence"] as? Int ?? -1
        let actionPID=status["pid"] as? Int ?? -1
        if (actionPID != lastActionPID || actionSequence != lastActionSequence),let action=status["requestedAction"] as? String {
            lastActionSequence=actionSequence
            lastActionPID=actionPID
            if action=="quit"{quit()}else if action=="resume"{resume()}
        }
    }
    private func finish(_ message:String){
        guard running else{return};monitor?.invalidate();monitor=nil
        // Personal folders persist outside the prefix; no global save swapping occurs on profile changes.
        try? logHandle?.close();logHandle=nil;process=nil;activeGame=nil;activeProfile=nil;activePrefix=nil;activeRuntime=nil;lease=nil;onFinish?(message)
    }
}
