// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
import Darwin

private enum NativeBarrierFixtureError:Error { case forbidden,check(String),deadline }
final class SteamGameAuthorizationGrant {
  let profile:UUID,gameID:UInt32=480,steamID="76561198000000001"
  init(_ profile:UUID){self.profile=profile}
  func consume()throws->Data{throw NativeBarrierFixtureError.forbidden}
}
final class SteamNativeHostProcess {
  enum Mode {case credentials,cached,automatic}
  struct Exit {let code:Int32?,signal:Int32?;let cancelled:Bool,invalidEvents:Bool}
  struct Binding {
    struct GameAssets {let clientDirectory,originalStateRoot,sdk,fsAdapter,ipcAdapter,lookupAdapter:URL}
    func verifiedGameAssets()throws->GameAssets{throw NativeBarrierFixtureError.forbidden}
  }
  var onExit:((Exit)->Void)?,waiters=[()->Void](),stopCalls=0,reaped=false,readerEnded=false,exited=false
  var result=Exit(code:42,signal:nil,cancelled:true,invalidEvents:false)
  static func spawn(binding:Binding,credentialPacket:inout Data,profile:UUID,sessionID:UUID,gameID:UInt32,
      profileStateRoot:URL,mode:Mode,onEvent:@escaping @MainActor([String:Any])->Void,
      onExit:@escaping @MainActor(Exit)->Void)throws->SteamNativeHostProcess{throw NativeBarrierFixtureError.forbidden}
  func takeGameHealthReadFD()throws->Int32{throw NativeBarrierFixtureError.forbidden}
  func stop(){stop(completion:{})}
  func stop(completion:@escaping()->Void){
    stopCalls+=1
    if exited{DispatchQueue.main.async(execute:completion)}else{waiters.append(completion)}
  }
  func markReaped(_ exit:Exit){reaped=true;result=exit;finishIfPossible()}
  func markReaderEnded(){readerEnded=true;finishIfPossible()}
  private func finishIfPossible(){
    guard reaped,readerEnded,!exited else{return};exited=true
    let callbacks=waiters;waiters.removeAll();let exit=result
    DispatchQueue.main.async{[self]in onExit?(exit);callbacks.forEach{$0()}}
  }
}

// This extension is concatenated to the production NativeSession source in one
// private compilation unit. No validation bypass enters the shipped sources.
extension SteamNativeGameSession {
  @MainActor fileprivate static func fixture(_ host:SteamNativeHostProcess,revision:SteamNativeCacheRevision.Selection?=nil,completion:@escaping Completion)->SteamNativeGameSession {
    let root=URL(fileURLWithPath:"/controlled-fixture-never-opened")
    let variant=GameVariant(id:"native",platform:.macOS,architecture:.arm64,executable:root.appendingPathComponent("game").path,installed:true)
    let game=Game(id:"steam:480",store:.steam,storeID:"480",title:"Fixture secret-name never diagnostic",variants:[variant])
    let selection=Selection(executable:root.appendingPathComponent("game"),installation:root,bundle:nil,
      sdk:root.appendingPathComponent("libsteam_api.dylib"),executableSHA256:String(repeating:"a",count:64),sdkSHA256:String(repeating:"b",count:64))
    let session=SteamNativeGameSession(binding:.init(),grant:SteamGameAuthorizationGrant(UUID()),game:game,
      variant:variant,profileStateRoot:root,selection:selection,credentialRevision:revision,completion:completion)
    session.host=host
    host.onExit={[weak session]exit in MainActor.assumeIsolated{session?.hostExited(exit)}}
    return session
  }
  @MainActor fileprivate func fixtureEvent(_ value:[String:Any]){receive(value)}
  @MainActor fileprivate func fixtureReady(){
    let ns=sessionID.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
    receive(["type":"ready","reason":0,"authenticated":true,"identityMatches":true,"ownedSubscription":true,"fixtureOnly":false,
      "gameID":480,"namespace":ns,"privateName":"app.ready.steam.ipctool."+ns,
      "masterEndpoint":"127.0.0.1:40001","serviceEndpoint":"127.0.0.1:40002"])
  }
}

@main struct ReadyNativeSessionBarrierProbe {
  @MainActor static func main()throws {
    var checks=[String:Bool]()
    func check(_ value:Bool,_ name:String)throws{if !value{throw NativeBarrierFixtureError.check(name)};checks[name]=true}
    func settle(){for _ in 0..<5{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}}
    func pump(_ condition:()->Bool)throws {
      let deadline=Date().addingTimeInterval(3)
      while !condition(),Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
      if !condition(){throw NativeBarrierFixtureError.deadline}
    }
    let host=SteamNativeHostProcess();var startup=0,startupFailure:SteamNativeGameSession.Failure?,mainCallbacks=true
    let session=SteamNativeGameSession.fixture(host){result in startup+=1;mainCallbacks=mainCallbacks && Thread.isMainThread;if case .failure(let failure)=result{startupFailure=failure}}
    session.fixtureEvent(["type":"starting","reason":0,"account":"fixture_private_account","token":"fixture_private_token"])
    session.fixtureEvent(["type":"login","loginMethod":"cached"])
    try check(startup==0 && !session.isReady&&session.lastFailureDetail==nil,"cached-login-method-event-does-not-grant-readiness-or-ownership")
    session.fixtureEvent(["type":"login","loginMethod":"fixture_private_token"])
    session.stopForAccountChange();settle()
    try check(startup==0 && !session.isReady&&host.stopCalls>=1,"account-change-blocks-ready-but-defers-startup-failure-before-reap")
    session.fixtureReady();settle()
    try check(startup==0 && !session.isReady,"late-ready-cannot-resurrect-account-cancelled-preparation")
    session.fixtureEvent(["type":"stopped","reason":42])
    host.markReaped(.init(code:42,signal:nil,cancelled:true,invalidEvents:false));settle()
    try check(startup==0,"reap-alone-does-not-release-startup-failure-before-reader-EOF")
    host.markReaderEnded();try pump{startup==1}
    let detail=session.lastFailureDetail!
    try check(startupFailure == .stopped && detail.failure=="stopped" && detail.stopOrigin=="account_session_changed" &&
      detail.hostExitCode==42 && detail.hostExitSignal==nil && detail.hostCancelled==true && detail.invalidEvents==false &&
      detail.lastHostReason==42 && detail.loginMethod=="cached" && !detail.readyReceived && mainCallbacks,"account-stop-diagnostic-preserves-origin-exit-and-reason-after-complete-barrier")
    try check(detail.loginMethod=="cached","cached-login-method-is-retained-and-unknown-method-cannot-overwrite-it")
    session.stopForAccountChange();host.markReaderEnded();settle()
    try check(startup==1&&session.lastFailureDetail?.stopOrigin=="account_session_changed","repeated-stop-and-exit-complete-startup-once-with-first-origin")
    var afterExit=0
    session.stop{afterExit+=1;mainCallbacks=mainCallbacks && Thread.isMainThread};try pump{afterExit==1}
    try check(afterExit==1&&mainCallbacks,"explicit-stop-barrier-after-exit-completes-on-main")
    let data=try JSONEncoder().encode(detail),object=try JSONSerialization.jsonObject(with:data)as![String:Any],text=String(decoding:data,as:UTF8.self)
    let allowed:Set<String>=["failure","stopOrigin","hostExitCode","hostExitSignal","hostCancelled","invalidEvents","lastHostReason","loginMethod","readyReceived","elapsedMilliseconds"]
    try check(Set(object.keys).isSubset(of:allowed) && !text.contains("76561198000000001") && !text.contains("fixture_private") &&
      !text.contains("controlled-fixture") && !text.contains("secret-name") && !text.contains(String(repeating:"a",count:64)),"failure-detail-contains-only-fixed-safe-diagnostic-fields")

    let signalHost=SteamNativeHostProcess();var signalFailure:SteamNativeGameSession.Failure?
    let signalSession=SteamNativeGameSession.fixture(signalHost){if case .failure(let failure)=$0{signalFailure=failure}}
    signalSession.fixtureEvent(["type":"starting","reason":70]);signalHost.markReaderEnded();settle()
    try check(signalFailure==nil,"reader-EOF-alone-does-not-publish-autonomous-exit")
    signalHost.markReaped(.init(code:nil,signal:SIGKILL,cancelled:false,invalidEvents:true));try pump{signalFailure != nil}
    let signalDetail=signalSession.lastFailureDetail!
    try check(signalFailure == .startupFailed && signalDetail.stopOrigin==nil && signalDetail.hostExitSignal==SIGKILL &&
      signalDetail.hostExitCode==nil && signalDetail.invalidEvents==true && signalDetail.hostCancelled==false && signalDetail.lastHostReason==70,
      "autonomous-startup-exit-preserves-signal-invalid-events-and-host-reason")

    let malformedHost=SteamNativeHostProcess();var malformed:SteamNativeGameSession.Failure?
    let malformedSession=SteamNativeGameSession.fixture(malformedHost){if case .failure(let failure)=$0{malformed=failure}}
    malformedSession.fixtureEvent(["type":"ready","authenticated":true,"identityMatches":true,"ownedSubscription":true,"fixtureOnly":false,"gameID":480,"namespace":"wrong"])
    settle();try check(malformed==nil&&malformedHost.stopCalls>0,"invalid-ready-failure-also-waits-for-owned-host-cleanup")
    malformedHost.markReaped(.init(code:65,signal:nil,cancelled:true,invalidEvents:true));malformedHost.markReaderEnded();try pump{malformed != nil}
    try check(malformed == .startupFailed&&malformedSession.lastFailureDetail?.hostExitCode==65,"invalid-ready-diagnostic-includes-exit-before-startup-callback")

    let readyHost=SteamNativeHostProcess();var readyCallbacks=0,invalidations=0,barrierCallbacks=0
    let readySession=SteamNativeGameSession.fixture(readyHost){if case .success=$0{readyCallbacks+=1}}
    readySession.fixtureEvent(["type":"login","loginMethod":"credentials"])
    readySession.fixtureReady();try check(readyCallbacks==1&&readySession.isReady,"genuine-shaped-ready-completes-startup-once")
    readySession.onInvalidated={invalidations+=1;mainCallbacks=mainCallbacks && Thread.isMainThread}
    readySession.stop(completion:{barrierCallbacks+=1;mainCallbacks=mainCallbacks && Thread.isMainThread});settle()
    try check(invalidations==1&&barrierCallbacks==0 && !readySession.isReady,"ready-session-revokes-immediately-but-stop-completion-waits-for-host")
    readyHost.markReaderEnded();settle();try check(barrierCallbacks==0,"explicit-stop-reader-EOF-still-waits-for-reap")
    readyHost.markReaped(.init(code:42,signal:nil,cancelled:true,invalidEvents:false));try pump{barrierCallbacks==1}
    readySession.stop();settle()
    try check(readyCallbacks==1&&invalidations==1&&barrierCallbacks==1&&mainCallbacks&&readySession.lastFailureDetail?.readyReceived==true,
      "ready-session-stop-barrier-and-invalidation-deliver-once")
    try check(readySession.lastFailureDetail?.loginMethod=="credentials","credentials-login-method-is-preserved-in-safe-diagnostic")
    let revisionRoot=URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("private-revision-state")
    try FileManager.default.createDirectory(at:revisionRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let packet=Data("public synthetic native credential revision".utf8)
    let marker=revisionRoot.appendingPathComponent(".ready-native-credential-revision.json")
    let failedRevision=try SteamNativeCacheRevision.select(packet:packet,root:revisionRoot)
    let revisionHost=SteamNativeHostProcess();var revisionFailed=false
    let revisionSession=SteamNativeGameSession.fixture(revisionHost,revision:failedRevision){if case .failure=$0{revisionFailed=true}}
    revisionSession.stopForAccountChange();revisionHost.markReaped(.init(code:42,signal:nil,cancelled:true,invalidEvents:false));revisionHost.markReaderEnded();try pump{revisionFailed}
    try check(!FileManager.default.fileExists(atPath:marker.path),"failed-native-startup-never-publishes-credential-revision-marker")
    let successfulRevision=try SteamNativeCacheRevision.select(packet:packet,root:revisionRoot)
    let successfulRevisionHost=SteamNativeHostProcess();var readySawCommittedRevision=false
    let successfulRevisionSession=SteamNativeGameSession.fixture(successfulRevisionHost,revision:successfulRevision){result in
      if case .success=result{readySawCommittedRevision=(try?SteamNativeCacheRevision.select(packet:packet,root:revisionRoot).mode) == .reuse}
    }
    successfulRevisionSession.fixtureReady()
    try check(readySawCommittedRevision&&successfulRevisionSession.isReady,"strict-native-ready-publishes-revision-before-success-callback")
    try check(try SteamNativeCacheRevision.select(packet:Data("another synthetic credential".utf8),root:revisionRoot).mode == .fresh,"fresh-credential-remains-fresh-after-previous-native-success")
    let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"count":checks.count,"checks":checks,"fixtureOnly":true,
      "accountKeychainSDKOrGameUsed":false,"networkUsed":false,"hostProcessSpawned":false]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"count":checks.count]),as:UTF8.self))
  }
}
