// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
import Darwin

private enum CleanupFixtureError:Error { case expectedFailure,check(String),deadline }
private class FixtureLease:SteamGameSessionLease {
  let sessionID=UUID(),profile:UUID,gameID:UInt32=480
  let platform:GamePlatform = .macOS
  var isReady=true,keeperArguments=[String](),onInvalidated:(()->Void)?
  var stopCalls=0
  init(_ profile:UUID){self.profile=profile}
  func validatedEnvironment(game:Game,variant:GameVariant,profile:UUID)throws->[String:String]{throw CleanupFixtureError.expectedFailure}
  func keeperInput(prefixLease:FileHandle)throws->SteamKeeperHandoff{throw CleanupFixtureError.expectedFailure}
  func takeGameHealthReadFD()throws->Int32{throw CleanupFixtureError.expectedFailure}
  func stop(){stopCalls+=1}
}
private final class DelayedLease:SteamGameSessionLease {
  let sessionID=UUID(),profile:UUID,gameID:UInt32=480
  let platform:GamePlatform = .macOS
  var isReady=true,keeperArguments=[String](),onInvalidated:(()->Void)?
  var stopCalls=0,barriers=[()->Void](),lastBarrier:(()->Void)?
  init(_ profile:UUID){self.profile=profile}
  func validatedEnvironment(game:Game,variant:GameVariant,profile:UUID)throws->[String:String]{throw CleanupFixtureError.expectedFailure}
  func keeperInput(prefixLease:FileHandle)throws->SteamKeeperHandoff{throw CleanupFixtureError.expectedFailure}
  func takeGameHealthReadFD()throws->Int32{throw CleanupFixtureError.expectedFailure}
  func stop(){stopCalls+=1}
  func stop(completion:@escaping()->Void){stopCalls+=1;barriers.append(completion);lastBarrier=completion}
  func releaseFromWorker(){
    let callbacks=barriers;barriers.removeAll()
    DispatchQueue.global().async{callbacks.forEach{$0();$0()}}
  }
}

// The runner appends this extension to the unchanged production source file.
// It installs an already-ended context to exercise real cleanup/finish paths,
// without executing a game, Wine, Steam host, keeper or account operation.
extension SessionManager {
  fileprivate func fixtureCleanup(_ lease:SteamGameSessionLease,game:Game,variant:GameVariant,
      profile:UUID,startupFailure:Bool,completion:@escaping(Result<Void,Error>)->Void)throws {
    guard !running else{throw LauncherError.busy}
    let ctx=Context(game:game,variant:variant,profile:profile,runtime:RuntimeConfiguration(),paths:paths,
      host:project.appendingPathComponent("Build/ReadySessionHost"),arguments:[],environment:[:],steamSession:lease,completion:completion)
    ctx.lease=try PrefixLease(paths:paths,profile:profile,gameID:game.id)
    stateLock.lock();context=ctx;phase=startupFailure ? .initializing:.playing;lastSessionID=ctx.id;stateLock.unlock()
    if startupFailure{startupFailed(ctx,error:CleanupFixtureError.expectedFailure)}
    else{ctx.reportedStart=true;ctx.completion=nil;finish(ctx,"Controlled fixture finish")}
  }
  fileprivate var fixtureHasStoppingContext:Bool {
    guard let ctx=currentContext()else{return false};return ctx.cleaning && !ctx.cleanupCompleted && running && !initializing
  }
  fileprivate func fixtureRepeatedFinish(){
    guard let ctx=currentContext()else{return};finish(ctx,"Ignored duplicate");startupFailed(ctx,error:CleanupFixtureError.expectedFailure)
  }
}

@main struct ReadySessionCleanupBarrierProbe {
  static func main()throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),paths=LauncherPaths(root:root.appendingPathComponent("data")),profile=UUID()
    let project=root.appendingPathComponent("project"),build=project.appendingPathComponent("Build")
    try FileManager.default.createDirectory(at:build,withIntermediateDirectories:true)
    // Public start's executable admission check is allowed to pass, but the
    // missing selected game makes LaunchPlan fail BEFORE any Process.run.
    let keeper=build.appendingPathComponent("ReadySessionHost")
    try Data("fixture keeper must never execute\n".utf8).write(to:keeper)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:keeper.path)
    let variant=GameVariant(id:"native",platform:.macOS,architecture:.arm64,executable:root.appendingPathComponent("missing-game-never-created").path,installed:true)
    let game=Game(id:"steam:480",store:.steam,storeID:"480",title:"Controlled cleanup fixture",variants:[variant])
    let manager=SessionManager(paths:paths,project:project),lease=DelayedLease(profile)
    var checks=[String:Bool](),finishes=0,failed=0,willLaunch=0,callbackMain=true
    func check(_ value:Bool,_ name:String)throws{if !value{throw CleanupFixtureError.check(name)};checks[name]=true}
    func pump(_ condition:()->Bool)throws {
      let deadline=Date().addingTimeInterval(4)
      while !condition(),Date()<deadline{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
      if !condition(){throw CleanupFixtureError.deadline}
    }
    func locked()->Bool{do{_=try PrefixLease(paths:paths,profile:profile,gameID:game.id);return false}catch{return true}}
    manager.onWillLaunch={willLaunch+=1}
    manager.onFinish={_ in finishes+=1;callbackMain=callbackMain && Thread.isMainThread}
    try manager.fixtureCleanup(lease,game:game,variant:variant,profile:profile,startupFailure:false){_ in failed+=100}
    try check(manager.fixtureHasStoppingContext&&locked()&&finishes==0&&lease.stopCalls==1,"finish-retains-context-and-prefix-lease-while-native-barrier-pending")
    manager.fixtureRepeatedFinish()
    try check(lease.stopCalls==1&&finishes==0,"duplicate-finish-and-startup-failure-do-not-repeat-stop-or-callback")
    var busy=false
    manager.start(game:game,variant:variant,profile:profile){result in if case .failure(LauncherError.busy)=result{busy=true}}
    try check(busy&&manager.fixtureHasStoppingContext&&locked(),"next-public-start-remains-busy-before-native-host-reap")
    lease.releaseFromWorker();try pump{finishes==1}
    try check(!manager.running && !locked()&&callbackMain,"barrier-completes-on-main-before-finish-and-releases-prefix")
    // The next public launch is admitted synchronously after release. Its
    // controlled missing executable must then fail without executing anything.
    let local=Game(id:"local-after-cleanup",store:.local,storeID:"controlled",title:"Not executed",variants:[variant])
    var admissionError:Error?
    manager.start(game:local,variant:variant,profile:profile){if case .failure(let error)=$0{admissionError=error}}
    try check(manager.running&&manager.initializing,"next-public-start-is-admitted-after-native-barrier-release")
    try pump{admissionError != nil && !manager.running}
    if let error=admissionError,case LauncherError.busy=error{throw CleanupFixtureError.check("admitted-start-must-not-fail-busy")}
    try check(willLaunch==0&&manager.sessionProcessIdentifier==nil,"admission-probe-does-not-execute-any-game-or-keeper")

    let startup=DelayedLease(profile)
    try manager.fixtureCleanup(startup,game:game,variant:variant,profile:profile,startupFailure:true){result in
      if case .failure = result{failed+=1;callbackMain=callbackMain && Thread.isMainThread}
    }
    try check(manager.fixtureHasStoppingContext&&locked()&&failed==0,"startup-error-callback-is-deferred-through-native-cleanup-barrier")
    lease.lastBarrier?();manager.fixtureRepeatedFinish()
    try check(manager.fixtureHasStoppingContext&&locked()&&startup.stopCalls==1&&finishes==1,"old-barrier-callback-cannot-clear-next-session-context-or-prefix")
    startup.releaseFromWorker();try pump{failed==1}
    try check(!manager.running && !locked()&&callbackMain&&finishes==1,"startup-error-publishes-once-after-native-host-cleanup")
    let immediate=FixtureLease(profile)
    try manager.fixtureCleanup(immediate,game:game,variant:variant,profile:profile,startupFailure:false){_ in failed+=100}
    try check(immediate.stopCalls==1&&finishes==2 && !manager.running && !locked(),"legacy-fixture-default-stop-barrier-remains-synchronous")
    lease.lastBarrier=nil;startup.lastBarrier=nil
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,
      "fixtureOnly":true,"accountOrKeychainUsed":false,"gameWineOrKeeperExecuted":false,"networkUsed":false]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("report.json"))
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"count":checks.count]),as:UTF8.self))
  }
}
