// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import LauncherCore

@main struct ReadySessionScratchProbe {
  static func spin(_ condition:()->Bool)throws{let end=Date().addingTimeInterval(8);while !condition(),Date()<end{RunLoop.main.run(until:Date().addingTimeInterval(0.005))};if !condition(){throw NSError(domain:"ownScratchDeadline",code:1)}}
  static func main()throws{
    if CommandLine.arguments.count>1,CommandLine.arguments[1]=="--child"{
      let env=ProcessInfo.processInfo.environment,expected=CommandLine.arguments[2],temporary=NSTemporaryDirectory(),effective=ProcessInfo.processInfo.environment["TMP"] ?? ""
      let expectedURL=URL(fileURLWithPath:expected).standardizedFileURL.resolvingSymlinksInPath()
      let effectiveURL=URL(fileURLWithPath:effective).standardizedFileURL.resolvingSymlinksInPath()
      let foundationURL=URL(fileURLWithPath:temporary).standardizedFileURL.resolvingSymlinksInPath()
      let correct=effectiveURL.path.hasPrefix(expectedURL.path+"/") && foundationURL.pathComponents==effectiveURL.pathComponents
      let file=URL(fileURLWithPath:effective).appendingPathComponent("own-scratch-file")
      if effectiveURL.path.hasPrefix(expectedURL.path+"/"){try Data("Own benign scratch fixture.\n".utf8).write(to:file)}
      let payload:[String:Bool]=["foundationUsesExternalScratch":correct,"actualScratchWriteSucceeded":fmFileExists(file.path),
        "allNativeTemporaryVariablesAgree":env["TMPDIR"]==effective+"/" && env["TEMP"]==effective && env["READY_NATIVE_SESSION_TMPDIR"]==effective+"/",
        "workingDirectoryPreserved":FileManager.default.currentDirectoryPath==CommandLine.arguments[3],
        "homePreserved":env["HOME"]==CommandLine.arguments[4]]
      try JSONSerialization.data(withJSONObject:payload).write(to:URL(fileURLWithPath:CommandLine.arguments[5]))
      usleep(100000);return
    }
    let fm=FileManager.default,run=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
    var checks=[String:Bool]()
    func check(_ name:String,_ value:Bool)throws{checks[name]=value;if !value{throw NSError(domain:name,code:1)}}
    func rejects(_ body:()throws->Void)->Bool{do{try body();return false}catch{return true}}
    let preferences=UserDefaults(suiteName:"ready-own-scratch-"+UUID().uuidString)!
    try check("missingPreferenceKeepsLegacyEnvironment",try SessionScratchDirectory.nativeEnvironment(sessionID:UUID(),preferences:preferences).isEmpty)
    let scratch=run.appendingPathComponent("Session Scratch"),first=UUID(),second=UUID()
    let a=try SessionScratchDirectory.prepare(root:scratch,sessionID:first),b=try SessionScratchDirectory.prepare(root:scratch,sessionID:second)
    try check("freshPrivateDirectoriesHaveCanonicalFDSelectedNames",a.path != b.path && a.path.hasPrefix(scratch.path+"/") && a.path==a.resolvingSymlinksInPath().path)
    try check("repeatedSessionPreservesExistingScratch",try SessionScratchDirectory.prepare(root:scratch,sessionID:first)==a)
    let mode=(try fm.attributesOfItem(atPath:a.path)[.posixPermissions]as!NSNumber).intValue
    try check("sessionScratchIsOwnerPrivate",mode==0o700)
    let outside=run.appendingPathComponent("outside");try fm.createDirectory(at:outside,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let alias=run.appendingPathComponent("alias");try fm.createSymbolicLink(at:alias,withDestinationURL:outside)
    try check("rootSymlinkCannotCreateOutsideSession",rejects{_=try SessionScratchDirectory.prepare(root:alias,sessionID:UUID())} && (try fm.contentsOfDirectory(atPath:outside.path)).isEmpty)
    try check("parentSymlinkCannotCreateScratchRoot",rejects{_=try SessionScratchDirectory.prepare(root:alias.appendingPathComponent("scratch"),sessionID:UUID())} && (try fm.contentsOfDirectory(atPath:outside.path)).isEmpty)
    let linkedID=UUID();try fm.createSymbolicLink(at:scratch.appendingPathComponent(linkedID.uuidString.lowercased()),withDestinationURL:outside)
    try check("sessionSymlinkCannotCreateExternalTmp",rejects{_=try SessionScratchDirectory.prepare(root:scratch,sessionID:linkedID)} && (try fm.contentsOfDirectory(atPath:outside.path)).isEmpty)
    let loose=run.appendingPathComponent("loose");try fm.createDirectory(at:loose,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])
    try check("existingPermissionsAreRejectedWithoutChmodOrChildren",rejects{_=try SessionScratchDirectory.prepare(root:loose,sessionID:UUID())} && (try fm.contentsOfDirectory(atPath:loose.path)).isEmpty)
    try check("foreignOwnedSystemRootIsNeverAdopted",rejects{_=try SessionScratchDirectory.prepare(root:URL(fileURLWithPath:"/private/tmp"),sessionID:UUID())})
    let regular=run.appendingPathComponent("regular");try Data("keep".utf8).write(to:regular)
    try check("regularFileIsNotAScratchDirectory",rejects{_=try SessionScratchDirectory.prepare(root:regular,sessionID:UUID())} && (try Data(contentsOf:regular))==Data("keep".utf8))
    let fifo=run.appendingPathComponent("fifo");guard mkfifo(fifo.path,0o600)==0 else{throw NSError(domain:"ownFIFO",code:1)}
    try check("specialEntryRejectedWithoutOpeningForIO",rejects{_=try SessionScratchDirectory.prepare(root:fifo,sessionID:UUID())})
    try check("filesystemRootIsRejected",rejects{_=try SessionScratchDirectory.prepare(root:URL(fileURLWithPath:"/"),sessionID:UUID())})
    preferences.setVolatileDomain(["readySessionScratchDirectory":"relative"],forName:UserDefaults.argumentDomain)
    try check("nonAbsolutePreferenceFailsClosed",rejects{_=try SessionScratchDirectory.nativeEnvironment(sessionID:UUID(),preferences:preferences)})
    let standard=UserDefaults.standard,old=standard.volatileDomain(forName:UserDefaults.argumentDomain)
    standard.setVolatileDomain(["readySessionScratchDirectory":scratch.path],forName:UserDefaults.argumentDomain)
    defer{standard.setVolatileDomain(old,forName:UserDefaults.argumentDomain)}
    let project=run.appendingPathComponent("project"),build=project.appendingPathComponent("Build")
    try fm.createDirectory(at:build,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    try fm.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[2]),to:build.appendingPathComponent("ReadySessionHost"))
    let manager=SessionManager(paths:LauncherPaths(root:run.appendingPathComponent("data")),project:project)
    let executable=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),report=run.appendingPathComponent("child-report.json")
    // SessionManager chooses its UUID, so the child compares the effective
    // trusted TMP variable with Foundation rather than predicting that UUID.
    let variant=GameVariant(id:"native",platform:.macOS,architecture:.arm64,executable:executable.path,workingDirectory:run.path,installationRoot:run.path,
      arguments:["--child",scratch.path,run.path,ProcessInfo.processInfo.environment["HOME"] ?? "",report.path],installed:true)
    let game=Game(id:"own-scratch",store:.local,storeID:"own-scratch",title:"Own benign scratch fixture",variants:[variant])
    var complete=false,started=false;manager.onFinish={_ in complete=true}
    manager.start(game:game,variant:variant,profile:UUID(),launchEnvironment:["TMPDIR":"/not-trusted/","TMP":"/not-trusted","TEMP":"/not-trusted"]){if case .success=$0{started=true}}
    try spin{complete}
    let child=try JSONSerialization.jsonObject(with:Data(contentsOf:report))as![String:Bool]
    try check("actualKeeperChildUsesTrustedExternalTemporaryEnvironmentAfterStoreMerge",started && child["actualScratchWriteSucceeded"]==true && child["allNativeTemporaryVariablesAgree"]==true)
    try check("actualKeeperChildKeepsHomeAndWorkingDirectory",child["workingDirectoryPreserved"]==true && child["homePreserved"]==true)
    try check("scratchFilesRemainForInspectionWithoutAutomaticDeletion",(try fm.contentsOfDirectory(atPath:scratch.path)).count>=4)
    let result:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"actualBenignKeeperChild":true,"accountGameOrKeychainUsed":false,"ANECompilerBehaviorVerified":false,"foundationTemporaryDirectoryRedirected":child["foundationUsesExternalScratch"]==true]
    print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
  }
  private static func fmFileExists(_ path:String)->Bool{FileManager.default.fileExists(atPath:path)}
}
