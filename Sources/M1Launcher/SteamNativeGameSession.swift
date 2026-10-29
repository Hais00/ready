// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import CoreFoundation
import Darwin
import Security
import LauncherCore

/// A capability created only from a current, one-use Steam authorization grant.
/// It supervises the genuine native host; it never executes the selected game.
final class SteamNativeGameSession: SteamGameSessionLease, @unchecked Sendable {
  enum Failure: String, Error {
    case invalidGame, invalidVariant, invalidExecutable, unsupportedArchitecture
    case invalidSDK, invalidStateRoot, incompatibleSignature, grantUnavailable
    case hostSetupFailed, startupFailed, invalidated, stopped, healthUnavailable, alreadyHandedOff
  }
  struct FailureDetail:Encodable {
    let failure:String
    let stopOrigin:String?
    let hostExitCode:Int32?
    let hostExitSignal:Int32?
    let hostCancelled:Bool?
    let invalidEvents:Bool?
    let lastHostReason:Int32?
    let loginMethod:String?
    let readyReceived:Bool
    let elapsedMilliseconds:UInt64
    func writePrivate(logs:URL)throws {
      let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
      try AtomicFile.writePrivate(encoder.encode(self),to:logs.appendingPathComponent("steam-last-native-failure.json"))
    }
  }
  typealias Completion = @MainActor (Result<SteamNativeGameSession, Failure>) -> Void

  let sessionID=UUID()
  let profile:UUID
  let gameID:UInt32
  let title:String
  let executable:URL
  let platform:GamePlatform = .macOS
  var keeperArguments:[String] {
    ["--steam-executable-sha256",selection.executableSHA256,
     "--steam-sdk",selection.sdk.path,"--steam-sdk-sha256",selection.sdkSHA256]
  }
  private let steamID:String
  private let binding:SteamNativeHostProcess.Binding
  private let gameIdentifier:String
  private let storeIdentifier:String
  private let selectedVariant:GameVariant
  private let profileStateRoot:URL
  private let selection:Selection
  private let credentialRevision:SteamNativeCacheRevision.Selection?
  private let lock=NSLock()
  private var host:SteamNativeHostProcess?
  private var completion:Completion?
  private var ready=false,wasReady=false,stopped=false,invalidated=false
  private var healthTaken=false,keeperIssued=false,invalidationDelivered=false
  private var invalidationHandler:(()->Void)?
  private var endpointEnvironment=[String:String]()
  private let startedAt=DispatchTime.now().uptimeNanoseconds
  private var stopOrigin:String?
  private var lastHostReason:Int32?
  private var loginMethod:String?
  private var lastExit:SteamNativeHostProcess.Exit?
  private var firstFailure:Failure?
  var lastFailureDetail:FailureDetail? {
    lock.lock();defer{lock.unlock()}
    guard let firstFailure else{return nil}
    return FailureDetail(failure:firstFailure.rawValue,stopOrigin:stopOrigin,
      hostExitCode:lastExit?.code,hostExitSignal:lastExit?.signal,hostCancelled:lastExit?.cancelled,
      invalidEvents:lastExit?.invalidEvents,lastHostReason:lastHostReason,loginMethod:loginMethod,readyReceived:wasReady,
      elapsedMilliseconds:(DispatchTime.now().uptimeNanoseconds-startedAt)/1_000_000)
  }

  var isReady:Bool {lock.lock();defer{lock.unlock()};return ready && !stopped && !invalidated}
  /// Assignment may occur on the session worker. Delivery always occurs on main,
  /// including when revocation happened before the handler was installed.
  var onInvalidated:(()->Void)? {
    get{lock.lock();defer{lock.unlock()};return invalidationHandler}
    set{
      lock.lock();invalidationHandler=newValue
      let deliver=wasReady && invalidated && !invalidationDelivered && newValue != nil
      if deliver{invalidationDelivered=true}
      lock.unlock()
      if deliver,let callback=newValue{DispatchQueue.main.async{callback()}}
    }
  }
  @MainActor private init(binding:SteamNativeHostProcess.Binding,grant:SteamGameAuthorizationGrant,
               game:Game,variant:GameVariant,profileStateRoot:URL,selection:Selection,
               credentialRevision:SteamNativeCacheRevision.Selection?=nil,completion:@escaping Completion) {
    self.binding=binding;profile=grant.profile;gameID=grant.gameID;steamID=grant.steamID
    title=game.title;gameIdentifier=game.id;storeIdentifier=game.storeID;selectedVariant=variant
    self.profileStateRoot=profileStateRoot;self.selection=selection;executable=selection.executable
    self.completion=completion
    self.credentialRevision=credentialRevision
  }
  /// Setup errors throw without invoking completion. A returned handle receives
  /// exactly one asynchronous startup completion, and may be stopped immediately.
  @MainActor static func start(binding:SteamNativeHostProcess.Binding,grant:SteamGameAuthorizationGrant,
                              game:Game,variant:GameVariant,profileStateRoot:URL,
                              completion:@escaping Completion) throws -> SteamNativeGameSession {
    guard game.store == .steam,!game.id.isEmpty,strictAppID(game.storeID)==grant.gameID,
      game.profileIDs == nil || game.profileIDs!.contains(grant.profile) else{throw Failure.invalidGame}
    guard variant.platform == .macOS,variant.installed,game.variants.contains(variant) else{throw Failure.invalidVariant}
    // These validations intentionally precede consumption of the short-lived
    // private grant. None of them obtains or manufactures account credentials.
    let assets=try binding.verifiedGameAssets()
    guard environmentPaths(assets,profileStateRoot:profileStateRoot) else{throw Failure.invalidSDK}
    let selection=try Selection.inspect(variant:variant,assets:assets)
    try validateStateRoot(profileStateRoot,installation:selection.installation)
    var packet:Data
    do{packet=try grant.consume()}catch{throw Failure.grantUnavailable}
    defer{packet.resetBytes(in:0..<packet.count);packet.removeAll(keepingCapacity:false)}
    let revision=try SteamNativeCacheRevision.select(packet:packet,root:profileStateRoot)
    let session=SteamNativeGameSession(binding:binding,grant:grant,game:game,variant:variant,
      profileStateRoot:profileStateRoot,selection:selection,credentialRevision:revision,completion:completion)
    do {
      let host=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&packet,profile:session.profile,
        sessionID:session.sessionID,gameID:session.gameID,profileStateRoot:profileStateRoot,mode:revision.mode == .fresh ? .credentials:.automatic,
        onEvent:{[weak session] event in session?.receive(event)},onExit:{[weak session] result in session?.hostExited(result)})
      session.lock.lock();session.host=host;session.lock.unlock()
    } catch {
      session.lock.lock();session.completion=nil;session.stopped=true;session.lock.unlock()
      throw Failure.hostSetupFailed
    }
    return session
  }
  @MainActor private func receive(_ event:[String:Any]) {
    if event["type"]as?String=="login",let method=event["loginMethod"]as?String,["cached","credentials"].contains(method) {
      lock.lock();loginMethod=method;lock.unlock()
    }
    if let reason=event["reason"]as?NSNumber,let parsed=Int32(reason.stringValue) {
      lock.lock();lastHostReason=parsed;lock.unlock()
    }
    if event["type"]as?String=="ready" {
      guard strictTrue(event["authenticated"]),strictTrue(event["identityMatches"]),strictTrue(event["ownedSubscription"]),
        strictFalse(event["fixtureOnly"]),number(event["gameID"])==UInt64(gameID),
        let namespace=event["namespace"]as?String,
        namespace==sessionID.uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
        let service=event["privateName"]as?String,service=="app.ready.steam.ipctool."+namespace,
        let master=event["masterEndpoint"]as?String,validEndpoint(master),
        let clientService=event["serviceEndpoint"]as?String,validEndpoint(clientService),master != clientService else{
        invalidate(.startupFailed,stopHost:true);return
      }
      lock.lock()
      guard !stopped,!invalidated,!wasReady else{lock.unlock();return}
      do{try credentialRevision?.recordReady()}
      catch{lock.unlock();invalidate(.startupFailed,stopHost:true);return}
      endpointEnvironment=["READY_STEAM_IPC_NAMESPACE":namespace,"READY_STEAM_DISCOVERY_SERVICE":service,
        "steam_master_ipc_name_override":master,"Steam3Master":master,"SteamClientService":clientService]
      ready=true;wasReady=true;let callback=completion;completion=nil
      lock.unlock()
      callback?(.success(self))
    } else if event["type"]as?String=="state" {
      lock.lock();let active=wasReady;lock.unlock()
      if active && (strictTrue(event["revoked"]) || !strictTrue(event["authenticated"]) ||
        !strictTrue(event["identityMatches"]) || !strictTrue(event["ownedSubscription"])) {
        invalidate(.invalidated,stopHost:true)
      }
    }
  }
  @MainActor private func hostExited(_ result:SteamNativeHostProcess.Exit) {
    lock.lock();lastExit=result;let started=wasReady;lock.unlock()
    invalidate(started ? .invalidated:.startupFailed,stopHost:false)
  }
  private func invalidate(_ reason:Failure,stopHost:Bool) {
    lock.lock()
    if firstFailure==nil { firstFailure=reason }
    ready=false;stopped=true;invalidated=true;endpointEnvironment.removeAll()
    let ownedHost=host
    let startup=completion;completion=nil
    let notify=wasReady && !invalidationDelivered ? invalidationHandler:nil
    if notify != nil{invalidationDelivered=true}
    lock.unlock()
    if stopHost{ownedHost?.stop()}
    if let startup {
      // A failed/cancelled preparation must not enable another login against
      // the same private client/cache until its worker has actually been reaped.
      if stopHost,let ownedHost {
        ownedHost.stop { DispatchQueue.main.async{startup(.failure(reason))} }
      } else { DispatchQueue.main.async{startup(.failure(reason))} }
    }
    if let notify{DispatchQueue.main.async{notify()}}
  }
  func stop() {
    lock.lock();if stopOrigin==nil{stopOrigin="owner_stop"};lock.unlock()
    invalidate(.stopped,stopHost:true)
  }
  func stopForAccountChange() {
    lock.lock();if stopOrigin==nil{stopOrigin="account_session_changed"};lock.unlock()
    invalidate(.stopped,stopHost:true)
  }
  func stop(completion:@escaping () -> Void) {
    stop()
    lock.lock();let owned=host;lock.unlock()
    if let owned { owned.stop(completion:completion) }
    else { DispatchQueue.main.async(execute:completion) }
  }
  deinit{host?.stop()}

  /// Preflight before building a native launch plan. The keeper acquires the
  /// installation read lease later, then must check keeperArguments' executable
  /// and SDK digests before acknowledging admission or spawning the game.
  /// This preflight alone does not close that interval. No tokens are returned.
  func validatedEnvironment(game:Game,variant:GameVariant,profile:UUID) throws -> [String:String] {
    lock.lock()
    let valid=ready && !stopped && !invalidated && self.profile==profile && game.store == .steam &&
      game.id==gameIdentifier && game.storeID==storeIdentifier && game.title==title && variant==selectedVariant && game.variants.contains(variant)
    let endpoints=endpointEnvironment
    lock.unlock()
    guard valid else{throw Failure.invalidated}
    let assets=try binding.verifiedGameAssets()
    guard Self.environmentPaths(assets,profileStateRoot:profileStateRoot) else{throw Failure.invalidSDK}
    let current=try Selection.inspect(variant:variant,assets:assets)
    guard current==selection else{throw Failure.invalidExecutable}
    try Self.validateStateRoot(profileStateRoot,installation:selection.installation)
    lock.lock();defer{lock.unlock()}
    guard ready,!stopped,!invalidated,self.profile==profile,endpointEnvironment==endpoints else{throw Failure.invalidated}
    let app=String(gameID)
    var environment=endpoints
    environment["SteamAppId"]=app;environment["SteamGameId"]=app;environment["SteamClientLaunch"]="1";environment["STEAMID"]=steamID
    environment["READY_STEAM_STATE_FS_LIBRARY"]=assets.fsAdapter.path
    environment["READY_STEAM_IPC_LIBRARY"]=assets.ipcAdapter.path
    environment["READY_STEAM_ORIGINAL_STATE_ROOT"]=assets.originalStateRoot.path
    environment["READY_STEAM_PRIVATE_STATE_ROOT"]=profileStateRoot.appendingPathComponent("client").path
    environment["READY_STEAM_ADAPTER_LIBRARIES"]=[assets.fsAdapter.path,assets.ipcAdapter.path,assets.lookupAdapter.path].joined(separator:":")
    environment["DYLD_LIBRARY_PATH"]=assets.clientDirectory.path
    return environment
  }
  func takeGameHealthReadFD() throws -> Int32 {
    lock.lock()
    guard ready,!stopped,!invalidated,!healthTaken,let host else{lock.unlock();throw Failure.healthUnavailable}
    healthTaken=true;lock.unlock()
    return try host.takeGameHealthReadFD()
  }
  func keeperInput(prefixLease:FileHandle) throws -> SteamKeeperHandoff {
    lock.lock();let permitted=ready && !stopped && !invalidated && !keeperIssued && !healthTaken;lock.unlock()
    guard permitted else{throw Failure.alreadyHandedOff}
    let transport=try SteamSessionLeaseTransport()
    lock.lock()
    guard ready,!stopped,!invalidated,!keeperIssued,!healthTaken else{lock.unlock();throw Failure.alreadyHandedOff}
    keeperIssued=true;lock.unlock()
    return SteamKeeperHandoff(input:transport.childInput,didSpawn:{[self,transport] in
      transport.childDidSpawn()
      do{
        let health=try takeGameHealthReadFD()
        try transport.transfer(prefixLease:prefixLease,healthReadFD:health)
      }catch{stop();throw error}
    })
  }

  private struct Selection:Equatable {
    let executable:URL
    let installation:URL
    let bundle:URL?
    let sdk:URL
    let executableSHA256:String
    let sdkSHA256:String
    static func inspect(variant:GameVariant,assets:SteamNativeHostProcess.Binding.GameAssets) throws -> Selection {
      guard variant.platform == .macOS,let raw=variant.executable,raw.hasPrefix("/") else{throw Failure.invalidVariant}
      let entry=URL(fileURLWithPath:raw)
      guard SteamNativeGameSession.canonical(entry) else{throw Failure.invalidExecutable}
      var isDirectory:ObjCBool=false
      guard FileManager.default.fileExists(atPath:entry.path,isDirectory:&isDirectory) else{throw Failure.invalidExecutable}
      let executable:URL
      if isDirectory.boolValue {
        guard entry.pathExtension.lowercased()=="app" else{throw Failure.invalidExecutable}
        executable=try NativeBinaryProbe.applicationExecutable(entry)
      } else{executable=entry}
      guard SteamNativeGameSession.canonical(executable),FileManager.default.isExecutableFile(atPath:executable.path) else{throw Failure.invalidExecutable}
      let architecture=try NativeBinaryProbe.inspect(executable)
      guard architecture == .arm64 || architecture == .universal else{throw Failure.unsupportedArchitecture}
      let bundle=SteamNativeGameSession.appBundle(executable)
      if let declared=variant.installationRoot,!declared.hasPrefix("/"){throw Failure.invalidExecutable}
      let installation=variant.installationRoot.map{URL(fileURLWithPath:$0)} ?? bundle ?? executable.deletingLastPathComponent()
      guard installation.path != "/",SteamNativeGameSession.canonical(installation),SteamNativeGameSession.directory(installation),SteamNativeGameSession.contains(installation,executable) else{throw Failure.invalidExecutable}
      let sdk=assets.sdk
      guard SteamNativeGameSession.canonical(sdk),SteamNativeGameSession.contains(installation,sdk),sdk.lastPathComponent=="libsteam_api.dylib" else{throw Failure.invalidSDK}
      if let bundle{guard SteamNativeGameSession.contains(bundle,sdk),SteamNativeGameSession.appBundle(sdk)==bundle else{throw Failure.invalidSDK}}
      let hash=try SteamNativeGameSession.executableHash(executable)
      let sdkHash=try SteamNativeGameSession.executableHash(sdk)
      try SteamNativeGameSession.compatibleSignature(executable)
      return Selection(executable:executable,installation:installation,bundle:bundle,sdk:sdk,executableSHA256:hash,sdkSHA256:sdkHash)
    }
  }
  private static func strictAppID(_ text:String)->UInt32? {
    guard !text.isEmpty,text.utf8.allSatisfy({(48...57).contains($0)}),let app=UInt32(text),app>0 else{return nil};return app
  }
  private static func environmentPaths(_ assets:SteamNativeHostProcess.Binding.GameAssets,profileStateRoot:URL)->Bool {
    [assets.clientDirectory,assets.originalStateRoot,assets.sdk,assets.fsAdapter,assets.ipcAdapter,assets.lookupAdapter,profileStateRoot].allSatisfy{
      !$0.path.contains(":") && !$0.path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
  }
  private static func canonical(_ path:URL)->Bool {
    path.isFileURL && path.path.hasPrefix("/") && path.standardizedFileURL==path && path.resolvingSymlinksInPath()==path
  }
  private static func contains(_ root:URL,_ file:URL)->Bool {file.path.hasPrefix(root.path+"/")}
  private static func directory(_ path:URL)->Bool {var info=stat();return lstat(path.path,&info)==0 && info.st_mode&S_IFMT==S_IFDIR}
  private static func appBundle(_ file:URL)->URL? {
    var value=file.deletingLastPathComponent()
    while value.path != "/" {if value.pathExtension.lowercased()=="app"{return value};value=value.deletingLastPathComponent()}
    return nil
  }
  private static func validateStateRoot(_ root:URL,installation:URL) throws {
    var info=stat()
    guard canonical(root),root.path != "/",lstat(root.path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,
      info.st_uid==getuid(),info.st_mode&0o077==0,root != installation,!contains(installation,root),!contains(root,installation) else{throw Failure.invalidStateRoot}
  }
  private static func executableHash(_ file:URL) throws -> String {
    let fd=open(file.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);guard fd>=0 else{throw Failure.invalidExecutable};defer{close(fd)}
    var before=stat(),after=stat()
    guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_mode&0o022==0,
      before.st_mode&(S_ISUID|S_ISGID)==0 else{throw Failure.invalidExecutable}
    var hash=SHA256(),buffer=[UInt8](repeating:0,count:1024*1024)
    while true {
      let size=read(fd,&buffer,buffer.count);if size<0&&errno==EINTR{continue};guard size>=0 else{throw Failure.invalidExecutable};if size==0{break}
      hash.update(data:Data(buffer.prefix(size)))
    }
    guard fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
      before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec else{throw Failure.invalidExecutable}
    return hash.finalize().map{String(format:"%02x",$0)}.joined()
  }
  private static func compatibleSignature(_ file:URL) throws {
    var code:SecStaticCode?
    let created=SecStaticCodeCreateWithPath(file as CFURL,SecCSFlags(rawValue:0),&code)
    if created==errSecCSUnsigned{return}
    guard created==errSecSuccess,let code else{throw Failure.incompatibleSignature}
    var information:CFDictionary?
    let copied=SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&information)
    if copied==errSecCSUnsigned{return}
    guard copied==errSecSuccess,let info=information as? [String:Any] else{throw Failure.incompatibleSignature}
    // This validates the on-disk executable/entitlements, not game resources,
    // and explicitly forbids network certificate lookups. It never runs code.
    // CSCommon.h defines kSecCSNoNetworkAccess as 1 << 29; this SDK does not
    // export that constant to Swift. Preserve its documented flag explicitly.
    let noNetwork:UInt32=1<<29
    let checked=SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:noNetwork|kSecCSDoNotValidateResources),nil)
    if checked==errSecCSUnsigned{return}
    guard checked==errSecSuccess else{throw Failure.incompatibleSignature}
    let entitlements=info[kSecCodeInfoEntitlementsDict as String] as? [String:Any] ?? [:]
    func flag(_ name:String)throws->Bool {
      guard let value=entitlements[name] else{return false}
      guard let number=value as? NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else{throw Failure.incompatibleSignature}
      return number.boolValue
    }
    if try flag("com.apple.security.app-sandbox"){throw Failure.incompatibleSignature}
    guard let flags=info[kSecCodeInfoFlags as String]as?NSNumber else{throw Failure.incompatibleSignature}
    let bits=flags.uint32Value
    // Security.framework CSCommon.h: runtime=0x10000, library validation=0x2000,
    // restricted dyld=0x0800. No signing/entitlement modifications are attempted.
    let allowDYLD=try flag("com.apple.security.cs.allow-dyld-environment-variables")
    let disableLV=try flag("com.apple.security.cs.disable-library-validation")
    if bits&0x0800 != 0 || (bits&0x10000 != 0 && (!allowDYLD || !disableLV)) || (bits&0x2000 != 0 && !disableLV) {
      throw Failure.incompatibleSignature
    }
  }
  private func strictTrue(_ value:Any?)->Bool {Self.boolean(value)==true}
  private func strictFalse(_ value:Any?)->Bool {Self.boolean(value)==false}
  private static func boolean(_ value:Any?)->Bool? {
    guard let number=value as?NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else{return nil};return number.boolValue
  }
  private func number(_ value:Any?)->UInt64? {
    guard let n=value as?NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID() else{return nil};return UInt64(n.stringValue)
  }
  private func validEndpoint(_ value:String)->Bool {
    guard value.hasPrefix("127.0.0.1:") else{return false}
    let port=value.dropFirst(10)
    return !port.isEmpty && port.utf8.allSatisfy({(48...57).contains($0)}) && UInt16(port).map{$0>0}==true
  }
}
