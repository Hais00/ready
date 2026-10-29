// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import CoreFoundation
import Darwin

/// Owns one exact spawned host, never adopts a PID. Credentials are consumed
/// through stdin; only the read end of an anonymous lifeline reaches the host.
/// This supervisor does not authenticate accounts or grant game entitlements.
final class SteamNativeHostProcess: @unchecked Sendable {
  enum Failure: Error { case invalidBinding, invalidStateRoot, invalidPacket, healthUnavailable, system(Int32) }
  enum Mode: String, Sendable { case credentials, cached, automatic }
  struct Exit: Sendable {
    let code: Int32?
    let signal: Int32?
    let cancelled: Bool
    let invalidEvents: Bool
  }
  struct Binding: Sendable {
    struct Asset: Codable, Sendable { let path: String; let sha256: String }
    struct GameAssets: Sendable {
      let clientDirectory:URL
      let originalStateRoot:URL
      let sdk:URL
      let fsAdapter:URL
      let ipcAdapter:URL
      let lookupAdapter:URL
    }
    private struct Manifest: Decodable {
      let schema: Int
      let kind: String
      let fixtureOnly: Bool
      let assets: [String: Asset]
      let extraFiles: [Asset]
    }
    let manifestURL: URL
    let manifestSHA256: String
    fileprivate let assets: [String: Asset]
    fileprivate let extraFiles: [Asset]
    let fixtureOnly: Bool
    fileprivate let bundle: URL
    private init(manifestURL: URL, manifestSHA256: String, document: Manifest, bundle: URL) {
      self.manifestURL=manifestURL; self.manifestSHA256=manifestSHA256
      assets=document.assets; extraFiles=document.extraFiles; fixtureOnly=document.fixtureOnly; self.bundle=bundle
    }
    /// The expected digest must come from the caller's trusted selected manifest,
    /// never from the manifest itself or an untrusted incoming host event.
    static func load(manifestURL: URL, expectedSHA256: String) throws -> Binding {
      let data=try checkedFile(manifestURL, digest: expectedSHA256, privateFile: true)
      guard data.count<=256*1024, let document=try? JSONDecoder().decode(Manifest.self,from:data),
        document.schema==1, document.kind=="ready-steam-native-host-binding-v1",
        Set(document.assets.keys)==Set(["host","library","discoveryLibrary","sdk","fsAdapter","ipcAdapter","lookupAdapter"]),
        document.extraFiles.count<=256 else { throw Failure.invalidBinding }
      for (key,asset) in document.assets {
        _=try checkedFile(URL(fileURLWithPath:asset.path),digest:asset.sha256,executable:key=="host")
      }
      for asset in document.extraFiles { _=try checkedFile(URL(fileURLWithPath:asset.path),digest:asset.sha256) }
      let library=URL(fileURLWithPath:document.assets["library"]!.path)
      guard library.lastPathComponent=="steamclient.dylib",
        let bundle=library.ancestors.first(where:{$0.lastPathComponent=="Steam.AppBundle"}) else { throw Failure.invalidBinding }
      return Binding(manifestURL:manifestURL,manifestSHA256:expectedSHA256,document:document,bundle:bundle)
    }
    fileprivate func revalidate() throws {
      let actual=try Self.load(manifestURL:manifestURL,expectedSHA256:manifestSHA256)
      guard actual.fixtureOnly==fixtureOnly else { throw Failure.invalidBinding }
    }
    /// Read-only code paths for a separately authorized game launch. The caller
    /// must additionally bind the SDK to that game's selected installation.
    func verifiedGameAssets() throws -> GameAssets {
      guard !fixtureOnly else{throw Failure.invalidBinding}
      try revalidate()
      return GameAssets(clientDirectory:URL(fileURLWithPath:path("library")).deletingLastPathComponent(),
        originalStateRoot:bundle.deletingLastPathComponent(),sdk:URL(fileURLWithPath:path("sdk")),
        fsAdapter:URL(fileURLWithPath:path("fsAdapter")),ipcAdapter:URL(fileURLWithPath:path("ipcAdapter")),
        lookupAdapter:URL(fileURLWithPath:path("lookupAdapter")))
    }
    fileprivate func path(_ name: String) -> String { assets[name]!.path }
  }
  typealias EventHandler = @MainActor ([String: Any]) -> Void
  typealias ExitHandler = @MainActor (Exit) -> Void
  private let guardian=DispatchQueue(label:"ready.steam.native.guardian")
  private let reader=DispatchQueue(label:"ready.steam.native.events")
  private let writer=DispatchQueue(label:"ready.steam.native.credentials")
  private let callbacks: EventHandler
  private let completion: ExitHandler
  private let binding: Binding
  private let profile: UUID
  private let sessionID: UUID
  private let gameID: UInt32
  private let namespace: String
  private let service: String
  private let masterEndpoint: String
  private let serviceEndpoint: String
  private var pid: pid_t = -1
  private var lifeline: Int32 = -1
  private var input: Int32 = -1
  private var events: Int32 = -1
  private var reaped=false, readerEnded=false, exited=false, cancelled=false, invalidEvents=false
  private var childStatus: Int32?
  private var stopping=false
  private var stopWaiters=[() -> Void]()
  private var diagnosticFD:Int32 = -1
  private let startedAt=DispatchTime.now().uptimeNanoseconds
  private var readyReceived=false
  private let publicLock=NSLock()
  private var publicPID: pid_t?
  private var publicReapedAt: UInt64?
  private var publicReadySuppressed=false
  private var healthRead:Int32 = -1
  var processID: pid_t? { publicLock.lock(); defer{publicLock.unlock()}; return publicPID }
  let receiptURL: URL

  /// Transfers the sole parent read-end to its caller exactly once. The caller
  /// owns/ closes it and may pass it via SCM_RIGHTS to a game keeper. This class
  /// never reads this pipe; closing a consumer does not stop the Steam host.
  func takeGameHealthReadFD() throws -> Int32 {
    publicLock.lock();defer{publicLock.unlock()}
    guard healthRead>=0,publicReapedAt==nil else{throw Failure.healthUnavailable}
    let fd=healthRead;healthRead = -1;return fd
  }
  private func closeUnusedHealthRead() {
    publicLock.lock();defer{publicLock.unlock()}
    if healthRead>=0{close(healthRead);healthRead = -1}
  }
  deinit { closeUnusedHealthRead(); if diagnosticFD>=0 { close(diagnosticFD) } }

  private init(binding:Binding, profile:UUID, sessionID:UUID, gameID:UInt32, sessionRoot:URL,
               master:String, serviceEndpoint:String, onEvent:@escaping EventHandler, onExit:@escaping ExitHandler) {
    self.binding=binding; self.profile=profile; self.sessionID=sessionID; self.gameID=gameID
    namespace=sessionID.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
    service="app.ready.steam.ipctool."+namespace; masterEndpoint=master; self.serviceEndpoint=serviceEndpoint
    callbacks=onEvent; completion=onExit; receiptURL=sessionRoot.appendingPathComponent("host-receipt.json")
  }
  /// Consumes and clears the caller's mutable packet, including on failure.
  /// Call only after the current profile's genuine authorize_game result and
  /// credential revision have been checked by the account coordinator.
  static func spawn(binding:Binding, credentialPacket:inout Data, profile:UUID, sessionID:UUID,
                    gameID:UInt32, profileStateRoot:URL, mode:Mode = .credentials,
                    onEvent:@escaping EventHandler, onExit:@escaping ExitHandler) throws -> SteamNativeHostProcess {
    defer { credentialPacket.resetBytes(in:0..<credentialPacket.count); credentialPacket.removeAll(keepingCapacity:false) }
    try validatePacket(credentialPacket,gameID:gameID,mode:mode)
    try binding.revalidate()
    try directory(profileStateRoot,create:false)
    try profileMarker(profileStateRoot,profile:profile)
    let client=profileStateRoot.appendingPathComponent("client"),cache=profileStateRoot.appendingPathComponent("cache")
    let sessions=profileStateRoot.appendingPathComponent("sessions")
    for path in [client,cache,sessions] { try directory(path,create:true) }
    let session=sessions.appendingPathComponent(sessionID.uuidString.lowercased())
    guard mkdir(session.path,0o700)==0 else { throw Failure.invalidStateRoot }
    let temporary=session.appendingPathComponent("tmp");try directory(temporary,create:true)
    let ports=try allocatePorts()
    let instance=SteamNativeHostProcess(binding:binding,profile:profile,sessionID:sessionID,gameID:gameID,sessionRoot:session,
      master:"127.0.0.1:\(ports.0)",serviceEndpoint:"127.0.0.1:\(ports.1)",onEvent:onEvent,onExit:onExit)
    instance.diagnosticFD=open(session.appendingPathComponent("host-events.jsonl").path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
    guard instance.diagnosticFD>=0 else { throw Failure.invalidStateRoot }
    instance.recordDiagnostic("created")
    let policy=instance.policy(privateRoot:profileStateRoot,sessionRoot:session,ports:ports)
    let policyURL=session.appendingPathComponent("host.sb")
    try writePrivate(Data(policy.utf8),to:policyURL)
    let receipt:[String:Any] = ["schema":1,"kind":"ready-steam-native-host-spawn-v1","profileID":profile.uuidString,
      "sessionID":sessionID.uuidString,"gameID":gameID,"bindingManifestSHA256":binding.manifestSHA256,
      "sandboxSHA256":hex(Data(policy.utf8)),"namespace":instance.namespace,"discoveryService":instance.service,
      "masterEndpoint":instance.masterEndpoint,"serviceEndpoint":instance.serviceEndpoint,"credentialTransport":"anonymous-stdin-EOF",
      "endpointReservationRaceFree":false,"fixtureOnly":binding.fixtureOnly,
      "gameHealthTransport":"anonymous-fifo-EOF","gameHealthChildWriterFD":4]
    try writePrivate(try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]),to:instance.receiptURL)
    var packet=credentialPacket.withUnsafeBytes { Data(bytes:$0.baseAddress!,count:$0.count) }
    do {
      try instance.start(policyURL:policyURL,client:client,cache:cache,temporary:temporary,mode:mode)
      instance.send(&packet)
      return instance
    } catch { packet.resetBytes(in:0..<packet.count); packet.removeAll(); throw error }
  }
  private static func validatePacket(_ packet:Data,gameID:UInt32,mode:Mode) throws {
    guard packet.count>=30,packet.count<=8284,packet.prefix(8)==Data("RDYAUTH1".utf8),gameID>0 else { throw Failure.invalidPacket }
    try packet.withUnsafeBytes { raw in
    let bytes=raw.bindMemory(to:UInt8.self)
    func number(_ at:Int,_ count:Int)->UInt64 { var value:UInt64=0;for index in at..<at+count{value=value<<8|UInt64(bytes[index])};return value }
    let name=Int(number(8,4)),token=Int(number(12,4)),identity=number(16,8)
    guard (1...64).contains(name),(1...8192).contains(token),packet.count==28+name+token,number(24,4)==UInt64(gameID),
      identity>>56==1,(identity>>52)&15==1,(identity>>32)&0xfffff==1,identity&0xffffffff != 0,
      bytes[28..<28+name].allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==95}),
      bytes[28+name..<bytes.count].allSatisfy({(33...126).contains($0)}) else { throw Failure.invalidPacket }
    if mode == .cached,Data(bytes[28+name..<bytes.count]) != Data("READY_USE_GENUINE_CACHED_LOGIN".utf8) { throw Failure.invalidPacket }
    }
  }
  private func start(policyURL:URL,client:URL,cache:URL,temporary:URL,mode:Mode) throws {
    var descriptors=[Int32]()
    func pair() throws -> (Int32,Int32) {
      var raw=[Int32](repeating:-1,count:2)
      guard pipe(&raw)==0 else { throw Failure.system(errno) }
      var moved=[Int32]()
      for (index,source) in raw.enumerated() {
        let fd=fcntl(source,F_DUPFD_CLOEXEC,10);let saved=errno;close(source)
        if fd<0 { for value in moved{close(value)};for value in raw.dropFirst(index+1){close(value)};throw Failure.system(saved) }
        moved.append(fd)
      }
      descriptors.append(contentsOf:moved);return(moved[0],moved[1])
    }
    var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
    defer { for fd in descriptors{close(fd)};if actions != nil{posix_spawn_file_actions_destroy(&actions)};if attributes != nil{posix_spawnattr_destroy(&attributes)} }
    let stdinPipe=try pair(),lifePipe=try pair(),eventPipe=try pair(),healthPipe=try pair()
    guard fcntl(stdinPipe.1,F_SETNOSIGPIPE,1)==0,fcntl(lifePipe.1,F_SETNOSIGPIPE,1)==0 else { throw Failure.system(errno) }
    let eventFlags=fcntl(eventPipe.0,F_GETFL)
    guard eventFlags>=0,fcntl(eventPipe.0,F_SETFL,eventFlags|O_NONBLOCK)==0 else { throw Failure.system(errno) }
    func require(_ code:Int32) throws { if code != 0 {throw Failure.system(code)} }
    try require(posix_spawn_file_actions_init(&actions));try require(posix_spawnattr_init(&attributes))
    // Relative paths must begin inside the allowed private filesystem. Inherit
    // neither the launcher's repository cwd nor its caller's denied directory.
    try require(posix_spawn_file_actions_addchdir_np(&actions,temporary.path))
    try require(posix_spawn_file_actions_adddup2(&actions,stdinPipe.0,0))
    try require(posix_spawn_file_actions_adddup2(&actions,eventPipe.1,1))
    try require(posix_spawn_file_actions_addopen(&actions,2,"/dev/null",O_WRONLY,0))
    try require(posix_spawn_file_actions_adddup2(&actions,lifePipe.0,3))
    try require(posix_spawn_file_actions_adddup2(&actions,healthPipe.1,4))
    for fd in descriptors { try require(posix_spawn_file_actions_addclose(&actions,fd)) }
    let flags=Int16(POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_CLOEXEC_DEFAULT)
    try require(posix_spawnattr_setflags(&attributes,flags));try require(posix_spawnattr_setpgroup(&attributes,0))
    var mask=sigset_t();sigemptyset(&mask);var defaults=sigset_t();sigemptyset(&defaults)
    for signal in [SIGPIPE,SIGTERM,SIGINT,SIGHUP]{sigaddset(&defaults,signal)}
    try require(posix_spawnattr_setsigmask(&attributes,&mask));try require(posix_spawnattr_setsigdefault(&attributes,&defaults))
    let arguments=["/usr/bin/sandbox-exec","-f",policyURL.path,binding.path("host"),"--host-session","--library",binding.path("library"),
      "--lifeline-fd","3","--events-fd","1","--game-health-fd","4","--mode",mode.rawValue,"--discovery-library",binding.path("discoveryLibrary"),"--discovery-service",service,"--sdk",binding.path("sdk")]
    guard let passwd=getpwuid(getuid()) else { throw Failure.invalidStateRoot }
    let environment=["PATH=/usr/bin:/bin","LANG=C","LC_ALL=C","HOME="+String(cString:passwd.pointee.pw_dir),
      "USER="+String(cString:passwd.pointee.pw_name),"LOGNAME="+String(cString:passwd.pointee.pw_name),
      "TMPDIR="+temporary.path+"/","XDG_CACHE_HOME="+cache.path,"READY_STEAM_STATE_FS_LIBRARY="+binding.path("fsAdapter"),
      "READY_STEAM_IPC_LIBRARY="+binding.path("ipcAdapter"),"READY_STEAM_IPC_NAMESPACE="+namespace,
      "READY_STEAM_ORIGINAL_STATE_ROOT="+binding.bundle.deletingLastPathComponent().path,"READY_STEAM_PRIVATE_STATE_ROOT="+client.path,
      "READY_STEAM_DISCOVERY_SERVICE="+service,"steam_master_ipc_name_override="+masterEndpoint,"SteamClientService="+serviceEndpoint]
    var argv=arguments.map{strdup($0)}+[nil],env=environment.map{strdup($0)}+[nil]
    defer{for value in argv{free(value)};for value in env{free(value)}}
    try require(posix_spawn(&pid,"/usr/bin/sandbox-exec",&actions,&attributes,&argv,&env))
    lifeline=lifePipe.1;input=stdinPipe.1;events=eventPipe.0
    descriptors.removeAll(where:{$0==lifeline||$0==input||$0==events})
    publicLock.lock();publicPID=pid;healthRead=healthPipe.0;publicLock.unlock()
    descriptors.removeAll(where:{$0==healthPipe.0})
    reader.async{self.readEvents()}
    guardian.async{self.poll()}
    guardian.asyncAfter(deadline:.now()+50){if !self.readyReceived && !self.reaped{self.stopInternal(invalid:true)}}
  }
  private func send(_ packet:inout Data) {
    var privatePacket=packet;packet.removeAll(keepingCapacity:false)
    let fd=input
    writer.async {
      defer {privatePacket.resetBytes(in:0..<privatePacket.count);privatePacket.removeAll(keepingCapacity:false);close(fd)}
      let success=privatePacket.withUnsafeBytes { bytes -> Bool in
        var offset=0
        while offset<bytes.count {
          let result=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
          if result<0&&errno==EINTR{continue};if result<=0{return false};offset+=result
        }
        return true
      }
      self.guardian.async { self.input = -1;if !success{self.stopInternal(invalid:true)} }
    }
  }
  func stop() { stop(completion:{}) }
  /// Completion follows waitpid and event-reader EOF, never merely a stop request.
  /// Callers may retain their state/installation lease until this barrier fires.
  func stop(completion:@escaping () -> Void) {
    publicLock.lock();publicReadySuppressed=true;publicLock.unlock()
    guardian.async {
      if self.exited { DispatchQueue.main.async(execute:completion); return }
      self.stopWaiters.append(completion)
      self.cancelled=true
      self.recordDiagnostic("stop_requested")
      self.stopInternal(invalid:false)
    }
  }
  private func stopInternal(invalid:Bool) {
    invalidEvents = invalidEvents || invalid
    if invalid{publicLock.lock();publicReadySuppressed=true;publicLock.unlock()}
    guard !stopping,!reaped else{return};stopping=true
    if lifeline>=0{close(lifeline);lifeline = -1}
    guardian.asyncAfter(deadline:.now()+3) {
      guard !self.reaped else{return}
      // The serial reaper has not reaped this child: its PID still pins our
      // process group even if it exited between the last poll and this signal.
      _=kill(-self.pid,SIGTERM)
      self.guardian.asyncAfter(deadline:.now()+3){if !self.reaped{_=kill(-self.pid,SIGKILL)}}
    }
  }
  private func poll() {
    guard !reaped else{return}
    var status:Int32=0
    let result=waitpid(pid,&status,WNOHANG)
    if result==pid {
      reaped=true;childStatus=status
      publicLock.lock();publicReapedAt=DispatchTime.now().uptimeNanoseconds;publicLock.unlock()
      closeUnusedHealthRead()
      if lifeline>=0{close(lifeline);lifeline = -1}
      finishIfPossible();return
    }
    if result<0&&errno != EINTR {
      reaped=true;invalidEvents=true
      publicLock.lock();publicReapedAt=DispatchTime.now().uptimeNanoseconds;publicLock.unlock()
      closeUnusedHealthRead()
      if lifeline>=0{close(lifeline);lifeline = -1}
      finishIfPossible();return // Never signal an unowned/reaped PID.
    }
    guardian.asyncAfter(deadline:.now()+0.025){self.poll()}
  }
  private func readEvents() {
    let fd=events
    var buffer=Data(),storage=[UInt8](repeating:0,count:4096);var invalid=false,sawStopped=false,sawReady=false
    while true {
      publicLock.lock();let reapedAt=publicReapedAt;publicLock.unlock()
      if let reapedAt,DispatchTime.now().uptimeNanoseconds-reapedAt>1_000_000_000{invalid=true;break}
      let count=Darwin.read(fd,&storage,storage.count)
      if count<0&&errno==EINTR{continue}
      if count<0&&(errno==EAGAIN||errno==EWOULDBLOCK){var waiting=pollfd(fd:fd,events:Int16(POLLIN|POLLHUP),revents:0);_=Darwin.poll(&waiting,1,50);continue}
      if count<0{invalid=true;break};if count==0{break}
      buffer.append(contentsOf:storage.prefix(count))
      while let newline=buffer.firstIndex(of:10) {
        let line=Data(buffer[..<newline]);buffer.removeSubrange(...newline)
        guard line.count<=65536,let raw=try? JSONSerialization.jsonObject(with:line) as? [String:Any],let safe=sanitize(raw) else{invalid=true;break}
        if safe["type"]as?String=="ready" {if sawReady{invalid=true;break};sawReady=true;guardian.async{self.readyReceived=true}}
        if safe["type"]as?String=="stopped" {sawStopped=true}
        self.guardian.async { self.recordDiagnostic("event", event:safe) }
        DispatchQueue.main.async{
          self.publicLock.lock();let suppressed=self.publicReadySuppressed;self.publicLock.unlock()
          if safe["type"]as?String != "ready" || !suppressed{self.callbacks(safe)}
        }
      }
      if invalid||buffer.count>65536{invalid=true;break}
    }
    if !buffer.isEmpty{invalid=true};close(fd)
    let channelFailed=invalid || !sawStopped
    guardian.async { self.events = -1;self.readerEnded=true;if channelFailed{self.stopInternal(invalid:true)};self.finishIfPossible() }
  }
  private func sanitize(_ value:[String:Any])->[String:Any]? {
    guard let type=value["type"]as?String,["starting","login","ready","state","stopped"].contains(type) else{return nil}
    var safe:[String:Any] = ["type":type,"profileID":profile.uuidString,"sessionID":sessionID.uuidString]
    if type=="login" {
      guard let method=value["loginMethod"]as?String,["cached","credentials"].contains(method)else{return nil}
      safe["loginMethod"]=method
    }
    for key in ["authenticated","identityMatches","ownedSubscription","fixtureOnly","revoked","userReleased","pipeReleased"] {
      if let value=value[key] {guard let number=value as?NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else{return nil};safe[key]=number.boolValue}
    }
    if let number=value["gameID"]as?NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID(),let parsed=UInt32(number.stringValue),parsed==gameID||(parsed==0&&type != "ready") else{return nil};safe["gameID"]=parsed
    }
    if let number=value["reason"]as?NSNumber {guard CFGetTypeID(number) != CFBooleanGetTypeID(),let parsed=Int32(number.stringValue) else{return nil};safe["reason"]=parsed}
    if let network=value["network"]as?String {guard ["unknown","connected","disconnected"].contains(network) else{return nil};safe["network"]=network}
    for (key,expected) in [("namespace",namespace),("privateName",service),("masterEndpoint",masterEndpoint),("serviceEndpoint",serviceEndpoint)] {
      if let actual=value[key] {guard actual as?String==expected else{return nil};safe[key]=expected}
    }
    if type=="ready" {
      guard safe["authenticated"]as?Bool==true,safe["identityMatches"]as?Bool==true,safe["ownedSubscription"]as?Bool==true,
        safe["fixtureOnly"]as?Bool==binding.fixtureOnly,safe["gameID"] != nil,
        safe["namespace"] != nil,safe["privateName"] != nil,safe["masterEndpoint"] != nil,safe["serviceEndpoint"] != nil else{return nil}
    }
    return safe
  }
  private func finishIfPossible() {
    guard reaped,readerEnded,!exited else{return};exited=true
    let status=childStatus
    let result=Exit(code:status.flatMap{($0&0x7f)==0 ? ($0>>8)&0xff:nil},signal:status.flatMap{($0&0x7f)>0&&($0&0x7f) != 0x7f ? $0&0x7f:nil},cancelled:cancelled,invalidEvents:invalidEvents)
    recordDiagnostic("exited", exit:result)
    if diagnosticFD>=0 { close(diagnosticFD); diagnosticFD = -1 }
    let waiters=stopWaiters;stopWaiters.removeAll()
    DispatchQueue.main.async{self.completion(result);for callback in waiters{callback()}}
  }
  /// Fixed event vocabulary, booleans and numeric results only. Never raw output,
  /// account identity, credential/ticket bytes, endpoint or environment values.
  private func recordDiagnostic(_ phase:String,event:[String:Any]?=nil,exit:Exit?=nil) {
    guard diagnosticFD>=0 else{return}
    var value:[String:Any] = ["schema":1,"phase":phase,
      "elapsedMilliseconds":(DispatchTime.now().uptimeNanoseconds-startedAt)/1_000_000]
    if let event {
      value["event"]=event["type"]
      if let method=event["loginMethod"]{value["loginMethod"]=method}
      for key in ["reason","authenticated","identityMatches","ownedSubscription","revoked","fixtureOnly","network","userReleased","pipeReleased"] {
        if let field=event[key]{value[key]=field}
      }
    }
    if let exit {
      value["exitCode"]=exit.code as Any? ?? NSNull();value["signal"]=exit.signal as Any? ?? NSNull()
      value["cancelled"]=exit.cancelled;value["invalidEvents"]=exit.invalidEvents
    }
    guard var data=try?JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])else{return}
    data.append(10)
    data.withUnsafeBytes { raw in
      var offset=0
      while offset<raw.count {
        let count=Darwin.write(diagnosticFD,raw.baseAddress!.advanced(by:offset),raw.count-offset)
        if count<0 && errno==EINTR{continue};if count<=0{break};offset+=count
      }
    }
  }
  private func policy(privateRoot:URL,sessionRoot:URL,ports:(UInt16,UInt16))->String {
    func quote(_ value:String)->String {String(decoding:try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes]),as:UTF8.self)}
    var result="(version 1)\n(allow default)\n(deny network*)\n(deny mach-lookup)\n"
    for name in ["com.apple.dyld","com.apple.mDNSResponder","com.apple.SystemConfiguration.configd","com.apple.trustd.agent",service] {result+="(allow mach-lookup (global-name \(quote(name))))\n"}
    result+="(allow mach-register (global-name \(quote(service))))\n"
    result+="(allow network-outbound (require-not (remote ip \"localhost:*\")))\n(deny network-outbound (remote unix-socket (path-regex #\".*\")))\n"
    result+="(allow network-outbound (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")) (remote unix-socket (path-literal \"/var/run/mDNSResponder\")))\n(allow network-bind)\n"
    for port in [ports.0,ports.1] {let address=quote("localhost:\(port)");result+="(allow network-bind (local ip \(address)))\n(allow network-inbound (local ip \(address)))\n(allow network-outbound (remote ip \(address)))\n"}
    result+="(deny ipc-posix-shm ipc-posix-sem)\n"
    for (kind,operation) in [("S","ipc-posix-shm"),("E","ipc-posix-sem")] {
      let pattern="^/R"+kind+namespace.prefix(16)+"_"+String(repeating:"[a-f0-9]",count:10)+"$"
      result+="(allow \(operation) (ipc-posix-name-regex #\(quote(pattern))))\n"
    }
    let denied=["/Users","/Volumes","/private/var/root","/Library/Keychains","/private/var/folders","/private/tmp","/tmp","/opt/homebrew","/usr/local"]
    result+="(deny file-read* "+denied.map{"(subpath \(quote($0)))"}.joined(separator:" ")+")\n(allow file-read-metadata)\n"
    result+="(allow file-read* (subpath \(quote(binding.bundle.path))) (subpath \(quote(privateRoot.path))))\n"
    for asset in Array(binding.assets.values)+binding.extraFiles {result+="(allow file-read* (literal \(quote(asset.path))))\n"}
    result+="(deny file-write*)\n(allow file-write* (subpath \(quote(privateRoot.path))) (literal \"/dev/null\"))\n"
    result+="(deny file-map-executable (subpath \(quote(privateRoot.path))))\n(deny process-exec)\n(allow process-exec (literal \(quote(binding.path("host")))))\n"
    return result
  }
  private static func allocatePorts() throws -> (UInt16,UInt16) {
    var sockets=[Int32]();defer{for fd in sockets{close(fd)}}
    var ports=[UInt16]()
    for _ in 0..<2 {
      let fd=socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else{throw Failure.system(errno)};sockets.append(fd)
      guard fcntl(fd,F_SETFD,FD_CLOEXEC)==0 else{throw Failure.system(errno)}
      var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
      let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
      guard bound==0 else{throw Failure.system(errno)}
      var size=socklen_t(MemoryLayout<sockaddr_in>.size)
      let named=withUnsafeMutablePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&size)}}
      guard named==0 else{throw Failure.system(errno)};ports.append(UInt16(bigEndian:address.sin_port))
    }
    guard ports[0] != ports[1] else{throw Failure.invalidStateRoot};return(ports[0],ports[1])
  }
  private static func directory(_ path:URL,create:Bool) throws {
    if create,mkdir(path.path,0o700) != 0,errno != EEXIST{throw Failure.invalidStateRoot}
    var info=stat();guard path.isFileURL,path.path.hasPrefix("/"),path.standardizedFileURL==path,path.resolvingSymlinksInPath()==path,
      lstat(path.path,&info)==0,(info.st_mode&S_IFMT)==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o077==0 else{throw Failure.invalidStateRoot}
  }
  private static func profileMarker(_ root:URL,profile:UUID) throws {
    let path=root.appendingPathComponent(".ready-steam-profile.json")
    if access(path.path,F_OK)==0 {
      let data=try checkedFile(path,digest:nil,privateFile:true)
      guard let value=try? JSONSerialization.jsonObject(with:data)as?[String:String],value==["profileID":profile.uuidString] else{throw Failure.invalidStateRoot}
    } else {try writePrivate(try JSONSerialization.data(withJSONObject:["profileID":profile.uuidString],options:[.sortedKeys]),to:path)}
  }
  private static func writePrivate(_ data:Data,to path:URL) throws {
    let fd=open(path.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
    guard fd>=0 else{throw Failure.invalidStateRoot};defer{close(fd)}
    var offset=0
    try data.withUnsafeBytes { bytes in
      while offset<bytes.count {let count=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if count<0&&errno==EINTR{continue};guard count>0 else{throw Failure.system(errno)};offset+=count}
    }
    guard fsync(fd)==0 else{throw Failure.system(errno)}
  }
  private static func checkedFile(_ path:URL,digest:String?,privateFile:Bool=false,executable:Bool=false) throws -> Data {
    guard path.isFileURL,path.path.hasPrefix("/"),path.standardizedFileURL==path,path.resolvingSymlinksInPath()==path,
      digest==nil||(digest!.count==64&&digest!.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)})) else{throw Failure.invalidBinding}
    let fd=open(path.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw Failure.invalidBinding};defer{close(fd)}
    var before=stat(),after=stat()
    guard fstat(fd,&before)==0,(before.st_mode&S_IFMT)==S_IFREG,before.st_uid==getuid(),before.st_mode&0o022==0,
      !privateFile||before.st_mode&0o077==0,!executable||before.st_mode&0o100 != 0 else{throw Failure.invalidBinding}
    var hash=SHA256(),data=Data(),buffer=[UInt8](repeating:0,count:1024*1024)
    while true {
      let count=Darwin.read(fd,&buffer,buffer.count);if count<0&&errno==EINTR{continue};guard count>=0 else{throw Failure.invalidBinding};if count==0{break}
      let chunk=Data(buffer.prefix(count));hash.update(data:chunk);if digest==nil||privateFile{guard data.count+count<=256*1024 else{throw Failure.invalidBinding};data.append(chunk)}
    }
    guard fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
      before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
      digest==nil||hash.finalize().map({String(format:"%02x",$0)}).joined()==digest else{throw Failure.invalidBinding}
    return data
  }
  private static func hex(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}
private extension URL {
  var ancestors:[URL] { var result=[URL](),value=deletingLastPathComponent();while value.path != "/"{result.append(value);value=value.deletingLastPathComponent()};return result }
}
