// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

// Controlled collaborators around the actual SteamGameLaunch.swift extension.
// They do not represent authentication, ownership, a native host or a game.
@MainActor private enum Fixture {
  static var authFailure:SteamGameAuthorization.Failure?
  static var nativeFailure:SteamNativeGameSession.Failure?
  static var nativeThrow:SteamNativeGameSession.Failure?
  static var nativeDelay:TimeInterval=0.01
  static var holdNativeReady=false
  static var requiredCleanup:SteamNativeGameSession?
  static var nativeStartedBeforeCleanup=false
  static var stopDelay:TimeInterval=0.08
  static var stopOrigin:String?
  static var authorizationCalls=0,nativeCalls=0,authDiagnosticWrites=0,nativeDiagnosticWrites=0
  static func reset(){authFailure=nil;nativeFailure=nil;nativeThrow=nil;nativeDelay=0.01;holdNativeReady=false;requiredCleanup=nil;nativeStartedBeforeCleanup=false;stopDelay=0.08;stopOrigin=nil;authorizationCalls=0;nativeCalls=0;authDiagnosticWrites=0;nativeDiagnosticWrites=0}
}
final class SteamNativeHostProcess {struct Binding{}}
enum SteamNativeHostSelection {
  static var fail=false
  static var delay:TimeInterval=0
  static func load(runtimeRoot:URL,gameID:String,stateRoot:URL?)throws->SteamNativeHostProcess.Binding{
    if delay>0{Thread.sleep(forTimeInterval:delay)}
    if fail{throw NSError(domain:"FixtureSelection",code:1)};return .init()
  }
}
@MainActor final class SteamClientSession {var ready=true;func accountReadyForGame()->Bool{ready}}
enum StoreClient {struct CredentialAccess {static func keychain(stateRoot:URL)->Self{.init()}}}
@MainActor final class SteamGameAuthorization {
  enum Failure:Error,Equatable{case cancelled,timeout;var userMessage:String{self == .cancelled ? "Preparazione Steam annullata.":"Tempo della verifica superato."}}
  struct Detail{@MainActor func writePrivate(logs:URL)throws{Fixture.authDiagnosticWrites+=1}}
  struct Grant{let gameID:UInt32=480}
  var completion:((Result<Grant,Failure>)->Void)?
  var lastFailureDetail:Detail?=Detail()
  init(network:SteamClientSession,credentialAccess:StoreClient.CredentialAccess){}
  func prepare(profile:UUID,gameID:String,completion:@escaping(Result<Grant,Failure>)->Void){
    Fixture.authorizationCalls+=1;self.completion=completion
    DispatchQueue.main.async{[weak self]in guard let self,let callback=self.completion else{return};self.completion=nil;if let failure=Fixture.authFailure{callback(.failure(failure))}else{callback(.success(.init()))}}
  }
  func cancel(){let callback=completion;completion=nil;callback?(.failure(.cancelled))}
}
enum SteamNativeStateDirectory {static func prepare(paths:LauncherPaths,profile:UUID,gameID:UInt32)throws->URL{paths.root}}
@MainActor final class SteamNativeGameSession {
  enum Failure:Error {case invalidGame,invalidVariant,invalidExecutable,unsupportedArchitecture,invalidSDK,invalidStateRoot,incompatibleSignature,grantUnavailable,hostSetupFailed,startupFailed,invalidated,stopped,healthUnavailable,alreadyHandedOff}
  struct Detail{let stopOrigin:String?;@MainActor func writePrivate(logs:URL)throws{Fixture.nativeDiagnosticWrites+=1}}
  var lastFailureDetail:Detail?=Detail(stopOrigin:nil)
  var stopCalls=0
  var cleanupDone=false,cleanupScheduled=false
  var cleanupCallbacks=[()->Void](),deliveredCleanupCallbacks=[()->Void]()
  var completion:((Result<SteamNativeGameSession,Failure>)->Void)?
  static func start(binding:SteamNativeHostProcess.Binding,grant:SteamGameAuthorization.Grant,game:Game,variant:GameVariant,profileStateRoot:URL,
    completion:@escaping(Result<SteamNativeGameSession,Failure>)->Void)throws->SteamNativeGameSession {
    Fixture.nativeCalls+=1;if let error=Fixture.nativeThrow{throw error}
    if let required=Fixture.requiredCleanup,!required.cleanupDone{Fixture.nativeStartedBeforeCleanup=true}
    let host=SteamNativeGameSession();host.completion=completion;host.lastFailureDetail=Detail(stopOrigin:Fixture.stopOrigin)
    if !Fixture.holdNativeReady{DispatchQueue.main.asyncAfter(deadline:.now()+Fixture.nativeDelay){[weak host]in
      guard let host,let callback=host.completion else{return};host.completion=nil
      if let failure=Fixture.nativeFailure{callback(.failure(failure))}else{callback(.success(host))}
    }};return host
  }
  func stop(){
    stopCalls+=1;let callback=completion;completion=nil
    if lastFailureDetail?.stopOrigin==nil{lastFailureDetail=Detail(stopOrigin:"owner_stop")}
    DispatchQueue.main.async{callback?(.failure(.stopped))}
    if !cleanupScheduled{cleanupScheduled=true;DispatchQueue.main.asyncAfter(deadline:.now()+Fixture.stopDelay){[self]in
      cleanupDone=true;let callbacks=cleanupCallbacks;cleanupCallbacks=[];deliveredCleanupCallbacks=callbacks;callbacks.forEach{$0()}
    }}
  }
  func stop(completion:@escaping()->Void){stop();if cleanupDone{DispatchQueue.main.async(execute:completion)}else{cleanupCallbacks.append(completion)}}
  func repeatOldCleanupCallbacks(){deliveredCleanupCallbacks.forEach{$0()}}
}
@MainActor final class FlowCanvas {
  var messages=[String](),refreshes=0
  var message=""{didSet{messages.append(message)}}
  func refresh(){refreshes+=1}
}
@MainActor final class FlowSession{var running=false}
struct FlowState{var activeProfile=UUID()}
@MainActor final class AppDelegate {
  var canvas:FlowCanvas!=FlowCanvas(),session:FlowSession!=FlowSession(),state=FlowState()
  var pendingLaunch:UUID?,steamPreparationID:UUID?,steamLaunchContinuation:(()->Void)?,steamLaunchCancellation:(()->Void)?
  var steamGameAuthorization:SteamGameAuthorization?,steamNativeGame:SteamNativeGameSession?,steamNetwork:SteamClientSession?=SteamClientSession()
  var errors=[String](),accountPages=0,canConfigure=true
  let runtimeRoot:URL,paths:LauncherPaths
  init(_ root:URL){runtimeRoot=root;paths=LauncherPaths(root)}
  func configureSteamNetwork(){if canConfigure{steamNetwork=SteamClientSession()}}
  func showError(_ error:Error){errors.append(error.localizedDescription)} // Deliberately does not clear canvas.message.
  func showSteamAccount(){accountPages+=1}
}
private enum ProbeFailure:Error{case check(String)}
@main private struct ReadySteamGameLaunchFlowProbe {
  @MainActor static func main()throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),game=Game("Fixture game"),variant=GameVariant(.macOS)
    var checks=[String:Bool]()
    func check(_ value:Bool,_ name:String)throws{guard value else{throw ProbeFailure.check(name)};checks[name]=true}
    func spin(_ condition:()->Bool)throws{let end=Date().addingTimeInterval(3);while !condition()&&Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))};if !condition(){throw ProbeFailure.check("deadline")}}
    func settle(){RunLoop.current.run(until:Date().addingTimeInterval(0.15))}
    func app()->AppDelegate{Fixture.reset();SteamNativeHostSelection.fail=false;SteamNativeHostSelection.delay=0;return AppDelegate(root)}
    func start(_ app:AppDelegate,ready:@escaping(SteamNativeGameSession)->Void={_ in}){let id=UUID();app.pendingLaunch=id;app.prepareSteamGame(game,variant:variant,profile:app.state.activeProfile,launchID:id,ready:ready)}
    do {
      let a=app();var ready=0;start(a){_ in ready+=1}
      try spin{ready==1}
      try check(a.canvas.messages==["Verifica del componente Steam…","Verifica della licenza Steam…","Avvio del backend Steam…","Avvio di Fixture game…"],"distinct-component-license-native-ready-phases")
      try check(a.canvas.message=="Avvio di Fixture game…"&&a.steamPreparationID==nil,"ready-does-not-leave-preparation-message")
    }
    do {
      let a=app();SteamNativeHostSelection.delay=0.05;start(a);a.cancelSteamGamePreparation();settle()
      try check(a.pendingLaunch==nil&&a.steamPreparationID==nil&&a.canvas.message=="Preparazione Steam annullata."&&Fixture.authorizationCalls==0,"cancel-during-selection-suppresses-late-progress")
    }
    do {
      let a=app();a.steamNetwork!.ready=false;start(a);try spin{a.accountPages==1}
      try check(a.canvas.message=="Attesa dell’accesso Steam…"&&Fixture.authorizationCalls==0,"account-wait-has-own-phase")
      a.steamLaunchCancellation?()
      try check(a.pendingLaunch==nil&&a.canvas.message=="Preparazione Steam annullata.","account-page-cancellation-clears-progress")
    }
    do {
      let a=app();a.steamNetwork!.ready=false;var ready=0;start(a){_ in ready+=1};try spin{a.accountPages==1}
      let continuation=a.steamLaunchContinuation;a.steamLaunchContinuation=nil;a.steamLaunchCancellation=nil;a.steamNetwork!.ready=true;continuation?()
      try spin{ready==1};try check(Fixture.authorizationCalls==1&&a.canvas.message=="Avvio di Fixture game…","account-resume-progresses-once-to-game-start")
    }
    do {
      let a=app();SteamNativeHostSelection.fail=true;start(a);try spin{!a.errors.isEmpty}
      try check(a.pendingLaunch==nil&&a.canvas.message=="Componente Steam nativo non disponibile."&&Fixture.authorizationCalls==0,"selection-failure-clears-progress-even-with-inline-error")
    }
    do {
      let a=app();a.steamNetwork=nil;a.canConfigure=false;start(a);try spin{!a.errors.isEmpty}
      try check(a.pendingLaunch==nil&&a.canvas.message=="Servizio Steam non disponibile.","network-component-unavailable-clears-progress")
    }
    for reason in [SteamGameAuthorization.Failure.timeout,.cancelled] {
      let a=app();Fixture.authFailure=reason;start(a);try spin{a.pendingLaunch==nil}
      try check(a.canvas.message==reason.userMessage&&Fixture.nativeCalls==0,"authorization-terminal-progress-"+(reason == .cancelled ? "cancelled":"timeout"))
    }
    for reason in [SteamNativeGameSession.Failure.stopped,.startupFailed] {
      let a=app();Fixture.nativeFailure=reason;start(a);try spin{!a.errors.isEmpty}
      let stopped=reason == .stopped
      try spin{a.steamNativeGame==nil}
      try check(a.pendingLaunch==nil&&a.steamNativeGame==nil&&Fixture.nativeDiagnosticWrites==1,"native-terminal-diagnostic-and-state-"+(stopped ? "stopped":"startup"))
      try check(a.canvas.message==(stopped ? "Preparazione Steam interrotta.":"Il backend Steam nativo non ha completato l’avvio."),"native-terminal-message-"+(stopped ? "stopped":"startup"))
    }
    do {
      let a=app();Fixture.nativeFailure = .stopped;Fixture.stopOrigin="account_session_changed";start(a);try spin{!a.errors.isEmpty}
      try check(a.canvas.message=="Preparazione Steam interrotta: la sessione dell’account è cambiata.","account-stop-message-requires-recorded-account-origin")
      try spin{a.steamNativeGame==nil}
    }
    do {
      let a=app();Fixture.nativeThrow = .invalidSDK;start(a);try spin{!a.errors.isEmpty}
      try check(a.pendingLaunch==nil&&a.canvas.message=="L’SDK Steam non corrisponde all’installazione del gioco selezionata.","synchronous-native-validation-error-ends-progress")
    }
    do {
      let a=app();Fixture.holdNativeReady=true;var ready=0;start(a){_ in ready+=1};try spin{a.steamNativeGame != nil}
      a.cancelSteamGamePreparation();settle()
      try check(ready==0&&a.errors.isEmpty&&a.canvas.message=="Preparazione Steam annullata.","cancel-native-start-cannot-restore-stale-progress ready=\(ready) errors=\(a.errors.count) message=\(a.canvas.message)")
    }
    do {
      let a=app();Fixture.holdNativeReady=true;Fixture.stopDelay=0.15;start(a);try spin{a.steamNativeGame != nil}
      let closing=a.steamNativeGame!,network=a.steamNetwork
      a.cancelSteamGamePreparation()
      try check(a.steamNativeGame===closing && !closing.cleanupDone,"cancel-retains-closing-host-before-reap")
      var secondReady=0;Fixture.requiredCleanup=closing;Fixture.holdNativeReady=false;Fixture.nativeDelay=0.01;start(a){_ in secondReady+=1}
      let secondID=a.pendingLaunch!
      a.prepareSteamGame(game,variant:variant,profile:a.state.activeProfile,launchID:secondID){_ in secondReady+=1}
      try check(Fixture.authorizationCalls==1&&Fixture.nativeCalls==1&&a.canvas.message=="Chiusura del backend Steam precedente…"&&a.steamNetwork===network,"second-launch-waits-without-reauth-or-network-reconfigure")
      try spin{secondReady==1}
      let current=a.steamNativeGame!
      try check(closing.cleanupDone&&current !== closing&&Fixture.authorizationCalls==2&&Fixture.nativeCalls==2,"cleanup-resumes-one-current-preparation-only")
      try check(!Fixture.nativeStartedBeforeCleanup,"new-host-start-never-precedes-old-cleanup-event")
      closing.repeatOldCleanupCallbacks()
      try check(a.steamNativeGame===current&&secondReady==1&&Fixture.nativeCalls==2,"late-duplicate-close-callback-cannot-clear-new-host")
      a.cancelSteamGamePreparation();try spin{a.steamNativeGame==nil}
    }
    do {
      let a=app();Fixture.holdNativeReady=true;Fixture.stopDelay=0.1;start(a);try spin{a.steamNativeGame != nil}
      let closing=a.steamNativeGame!;a.cancelSteamGamePreparation()
      var secondReady=0;start(a){_ in secondReady+=1};a.cancelSteamGamePreparation()
      try spin{closing.cleanupDone&&a.steamNativeGame==nil};settle()
      try check(a.pendingLaunch==nil&&secondReady==0&&Fixture.authorizationCalls==1&&Fixture.nativeCalls==1,"cancelled-second-launch-never-restarts-after-old-cleanup")
    }
    do {
      let a=app();Fixture.holdNativeReady=true;Fixture.stopDelay=0.1;start(a);try spin{a.steamNativeGame != nil};a.cancelSteamGamePreparation()
      var obsolete=0,current=0;start(a){_ in obsolete+=1};Fixture.holdNativeReady=false;Fixture.nativeDelay=0.01;start(a){_ in current+=1}
      try spin{current==1}
      try check(obsolete==0&&Fixture.authorizationCalls==2&&Fixture.nativeCalls==2,"obsolete-close-waiter-does-not-consume-newer-launch")
      a.cancelSteamGamePreparation();try spin{a.steamNativeGame==nil}
    }
    do {
      let a=app();a.session.running=true;a.canvas.message="Game already running";let host=SteamNativeGameSession();a.steamNativeGame=host
      let refreshes=a.canvas.refreshes;a.cancelSteamGamePreparation()
      try check(host.stopCalls==0&&a.canvas.message=="Game already running"&&a.canvas.refreshes==refreshes,"preparation-cleanup-does-not-stop-or-redraw-running-game")
    }
    let report:[String:Any]=["passed":true,"count":checks.count,"checks":checks,"actualSteamGameLaunchSource":true,"collaboratorsAreUIFlowStubs":true,"actualGameOrSDKStarted":false,"accountNetworkKeychainUsed":false]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
  }
}
