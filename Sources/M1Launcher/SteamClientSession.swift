// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
import Darwin
import LauncherCore

struct SteamFriendState: Identifiable, Equatable {
  let id: String
  var displayName: String
  var presence: String
  var gameID: String?
  var gameName: String?
  var relationship = "Friend"
}
struct SteamClientState {
  var connection = "offline"
  var reason = ""
  var steamResult: String?
  var connectionResultContext: String?
  var accountName = ""
  var displayName = ""
  var steamID = ""
  var presence = "offline"
  var friends = [SteamFriendState]()
  var retryAfter: Double?
  var warning = ""
  var online: Bool { connection == "online" }
}

private final class SteamCredentialBaseline {
  private let lock = NSLock()
  private var initialized = false
  private var value: Data?
  func initialize(_ data: Data?) { lock.lock(); defer { lock.unlock() }; if !initialized { initialized=true;value=data } }
  func load() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
  func replace(_ data: Data?) { lock.lock();value=data;initialized=true;lock.unlock() }
}
private final class SteamCredentialWritePermit {
  private let lock=NSLock();private var value=true
  var active:Bool {lock.lock();defer{lock.unlock()};return value}
  func cancel(){lock.lock();value=false;lock.unlock()}
}

/// One profile's persistent network service. Game workers remain independently
/// supervised. This channel never exposes credentials to frontend subscribers.
@MainActor
final class SteamClientSession {
  typealias Event = ([String: Any]) -> Void
  private struct Pending { let operation: String; let deadline: Date; let callback: Event }
  let profile: UUID
  private(set) var generation = UUID()
  private(set) var state = SteamClientState()
  var onChange: ((SteamClientState) -> Void)?
  var onAuthentication: Event?
  private let credentialAccess: StoreClient.CredentialAccess
  private let command: [String]
  private var process: Process?
  private var writer: FileHandle?
  private let io = DispatchQueue(label: "ready.steam.session.io")
  private let writes = DispatchQueue(label: "ready.steam.session.write")
  private var pending = [String: Pending]()
  private var sequence: UInt64 = 0
  private var lastEvent = Date()
  private var watchdog: Timer?
  private var manualStop = true
  private var automaticRestartSuppressed = false
  private var restartCount = 0
  private var credentialAtStart: Data?
  private var credentialBaseline = SteamCredentialBaseline()
  private var credentialWrites = [String:SteamCredentialWritePermit]()
  private var credentialSnapshot: Data?
  private var credentialSnapshotValid = false
  private var credentialReadID = UUID()
  private var authenticationID: String?

  init(profile: UUID, command: [String], credentialAccess: StoreClient.CredentialAccess) {
    self.profile = profile; self.command = command; self.credentialAccess = credentialAccess
  }
  var serviceRunning:Bool { process != nil && writer != nil && !manualStop }

  /// A new logon can report online before publishing its new persona. Wait for
  /// the persona to match the currently saved account before resuming a game.
  func accountReadyForGame() -> Bool {
    guard state.online, !state.steamID.isEmpty, !state.accountName.isEmpty,
      credentialSnapshotValid, let data = credentialSnapshot, CredentialVault.steamStatus(data) == .available,
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let account = value["username"] as? String else { return false }
    return account.caseInsensitiveCompare(state.accountName) == .orderedSame
  }
  static func installedCommand(project: URL, runtimeRoot: URL, stateRoot:URL?=nil) -> [String]? {
    guard let tools=try? StoreToolsLocation.resolve(stateRoot:stateRoot,runtimeRoot:runtimeRoot) else{return nil}
    let dotnet=tools.appendingPathComponent("dotnet/dotnet").resolvingSymlinksInPath()
    let helper=tools.appendingPathComponent("SteamBridge/ReadySteamBridge.dll").resolvingSymlinksInPath()
    var executable=stat(),assembly=stat()
    guard lstat(dotnet.path,&executable)==0,executable.st_mode&S_IFMT==S_IFREG,
      FileManager.default.isExecutableFile(atPath:dotnet.path),lstat(helper.path,&assembly)==0,assembly.st_mode&S_IFMT==S_IFREG else{return nil}
    return [dotnet.path,helper.path,"--service"]
  }
  func start() {
    guard process == nil else { return }
    manualStop = false
    launch()
  }
  private func launch() {
    guard !manualStop, process == nil, command.count >= 2 else { return }
    let epoch = UUID(); generation = epoch; sequence = 0; lastEvent = Date()
    credentialBaseline = SteamCredentialBaseline()
    let task = Process(), input = Pipe(), output = Pipe()
    task.executableURL = URL(fileURLWithPath: command[0]); task.arguments = Array(command.dropFirst())
    var environment = ProcessInfo.processInfo.environment
    for key in Array(environment.keys) where key.hasPrefix("DYLD_") || key.hasPrefix("STEAM") || key.hasPrefix("Steam") { environment.removeValue(forKey: key) }
    environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
    task.environment = environment; task.standardInput = input; task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    _=fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
    do { try task.run() } catch { transition("offline", reason: "service_unavailable"); return }
    process = task; writer = input.fileHandleForWriting
    try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    transition("connecting")
    io.async { [weak self] in
      let handle = output.fileHandleForReading
      var buffer = Data(); var malformed = false
      var storage = [UInt8](repeating:0,count:8192)
      while true {
        let count = Darwin.read(handle.fileDescriptor, &storage, storage.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        buffer.append(contentsOf:storage.prefix(count))
        while let newline = buffer.firstIndex(of: 10) {
          let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
          guard line.count <= 4 * 1024 * 1024,
            let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { malformed = true; break }
          DispatchQueue.main.async { self?.receive(value, epoch: epoch) }
        }
        if malformed || buffer.count > 4 * 1024 * 1024 { malformed = true; break }
      }
      try? handle.close()
      let truncated = malformed || !buffer.isEmpty
      DispatchQueue.main.async { self?.ended(task, epoch: epoch, malformed: truncated) }
    }
    watchdog?.invalidate()
    watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self,self.process != nil else{return}
        for(id,request)in Array(self.pending) where request.deadline<Date(){
          self.pending.removeValue(forKey:id)
          if self.authenticationID==id{self.authenticationID=nil}
          request.callback(["type":"error","code":"timeout"])
          if request.operation != "cancel" {self.request("cancel",options:["requestID":id]){_ in}}
        }
        if Date().timeIntervalSince(self.lastEvent)>45{self.failProcess(reason:"service_unresponsive")}
      }
    }
    refreshCredentialSnapshot { [weak self] data in
      guard let self, self.generation == epoch, !self.manualStop, self.process === task else { return }
      self.credentialAtStart = data
      // A user-requested authentication owns the service once it has begun.
      guard self.authenticationID == nil,!self.automaticRestartSuppressed else { return }
      if CredentialVault.steamStatus(data) == .available, let data,
        let account = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        self.request("connect", options: ["credentials": account]) { _ in }
      } else { self.request("snapshot") { _ in } }
    }
  }
  /// No Keychain call runs on Main, including persona/startup readiness checks.
  /// A new read invalidates the old snapshot until its profile/epoch is checked.
  func refreshCredentialSnapshot(completion: ((Data?) -> Void)? = nil) {
    let read = UUID(), epoch = generation, access = credentialAccess, profile = profile, baseline = credentialBaseline
    credentialReadID = read; credentialSnapshotValid = false
    CredentialVault.perform({ let data=access.load(profile,.steam);baseline.initialize(data);return data }) { [weak self] data in
      MainActor.assumeIsolated {
        guard let self, self.generation == epoch, self.credentialReadID == read, !self.manualStop else { return }
        self.credentialSnapshot = data; self.credentialSnapshotValid = true
        completion?(data); self.notify()
      }
    }
  }

  @discardableResult
  func request(_ operation: String, options: [String: Any] = [:], event: @escaping Event) -> String {
    start()
    let id = UUID().uuidString
    guard writer != nil else { event(["type":"error", "code":"service_unavailable"]); return id }
    var payload = options
    payload["id"] = id; payload["operation"] = operation
    payload["profileID"] = profile.uuidString; payload["profileGeneration"] = generation.uuidString
    guard JSONSerialization.isValidJSONObject(payload),
      var bytes = try? JSONSerialization.data(withJSONObject: payload), bytes.count <= 64 * 1024 else {
      event(["type":"error", "code":"invalid_request"]); return id
    }
    let timeout:TimeInterval=["authenticate","library"].contains(operation) ? 240:operation=="authorize_game" ? 90:["connect","reconnect"].contains(operation) ? 45:30
    bytes.append(10); pending[id] = Pending(operation: operation,deadline:Date().addingTimeInterval(timeout), callback: event)
    let handle = writer, epoch = generation
    ioWrite(bytes, to: handle, epoch: epoch)
    return id
  }
  private func ioWrite(_ bytes: Data, to handle: FileHandle?, epoch: UUID) {
    // A separate writer prevents a blocked service stdout read starving stdin.
    writes.async { [weak self] in
      do { try handle?.write(contentsOf: bytes) }
      catch { DispatchQueue.main.async { if self?.generation == epoch { self?.failProcess(reason: "service_pipe") } } }
    }
  }
  @discardableResult func authenticate(method: String = "qr", username: String = "", password: String = "") -> String {
    manualStop = false; automaticRestartSuppressed = false
    cancelAuthentication()
    let id=request("authenticate", options: ["method": method, "username": username, "password": password]) { [weak self] event in self?.onAuthentication?(event) }
    authenticationID=id;return id
  }
  func cancelAuthentication() {if let id=authenticationID {authenticationID=nil;cancel(id)}}
  func submitGuard(challengeID: String, code: String) {
    request("guard_code", options: ["challengeID":challengeID, "code":code]) { [weak self] event in self?.onAuthentication?(event) }
  }
  func setPresence(_ presence: String) { request("set_presence", options: ["presence":presence]) { _ in } }
  func reconnect() {
    manualStop=false;automaticRestartSuppressed=false
    guard process != nil else{launch();return}
    let epoch=generation
    // An initial transport cleanup can fail before the service has selected
    // any account. Restore from the saved profile rather than assuming it has
    // an in-memory credential and unnecessarily requesting another QR.
    refreshCredentialSnapshot{[weak self]data in
      guard let self,self.generation==epoch,!self.manualStop,!self.automaticRestartSuppressed,self.authenticationID==nil else{return}
      if CredentialVault.steamStatus(data) == .available,let data,let account=try?JSONSerialization.jsonObject(with:data)as?[String:Any]{
        self.credentialAtStart=data;self.request("connect",options:["credentials":account]){_ in}
      }else{self.request("reconnect"){_ in}}
    }
  }
  func goOffline() { automaticRestartSuppressed = true; request("offline") { _ in } }
  func logout() {
    manualStop = true
    automaticRestartSuppressed = true
    credentialWrites.values.forEach{$0.cancel()};credentialWrites.removeAll()
    let access = credentialAccess, profile = profile
    CredentialVault.perform({ access.remove(profile, .steam) }) { _ in }
    credentialAtStart = nil; credentialSnapshot = nil; credentialSnapshotValid = false; credentialReadID = UUID()
    if process != nil { request("logout") { [weak self] _ in
      self?.stop(); self?.state.connection = "logged_out"; self?.notify()
    } }
    state = SteamClientState(); state.connection = "logged_out"; notify()
  }
  func cancel(_ id: String) {
    credentialWrites.removeValue(forKey:id)?.cancel()
    guard pending.removeValue(forKey:id) != nil,writer != nil,!manualStop else{return}
    request("cancel", options: ["requestID":id]) { _ in }
  }
  func stop() {
    manualStop = true; generation = UUID(); watchdog?.invalidate(); watchdog = nil
    let task = process; process = nil
    try? writer?.close(); writer = nil; pending.removeAll(); credentialAtStart = nil
    authenticationID=nil; credentialWrites.values.forEach{$0.cancel()};credentialWrites.removeAll(); credentialSnapshot=nil; credentialSnapshotValid=false; credentialReadID=UUID()
    if let task, task.isRunning {
      task.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if task.isRunning { kill(task.processIdentifier, SIGKILL) } }
    }
    state = SteamClientState(); notify()
  }
  private func receive(_ value: [String: Any], epoch: UUID) {
    guard generation == epoch, UUID(uuidString: value["profileID"] as? String ?? "") == profile,
      UUID(uuidString: value["profileGeneration"] as? String ?? "") == epoch,
      let number = value["sequence"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let next = UInt64(number.stringValue), next > sequence,
      let type = value["type"] as? String else { return }
    sequence = next; lastEvent = Date()
    let id = value["id"] as? String
    if type == "credentials" {
      guard !manualStop, let id, let entry = pending[id], ["authenticate","guard_code","connect"].contains(entry.operation),
        let account = value["credentials"] as? [String: Any],
        let name = account["username"] as? String, !name.isEmpty, name.utf8.count <= 128,
        let token = account["refresh_token"] as? String, !token.isEmpty, token.utf8.count <= 16384,
        let bytes = try? JSONSerialization.data(withJSONObject: ["username":name,"refresh_token":token]) else { return }
      let access = credentialAccess, profile = profile, baseline=credentialBaseline, permit=SteamCredentialWritePermit()
      credentialWrites[id]=permit
      CredentialVault.perform({ () -> Result<Bool, Error> in
        Result {
          let expected=baseline.load()
          guard permit.active,access.load(profile,.steam)==expected else{return false}
          try access.save(bytes,profile,.steam)
          guard permit.active else {
            if access.load(profile,.steam)==bytes {
              if let expected{try access.save(expected,profile,.steam)}else{access.remove(profile,.steam)}
            }
            return false
          }
          baseline.replace(bytes);return true
        }
      }) { [weak self] result in
        MainActor.assumeIsolated {
          guard let self, self.generation == epoch, !self.manualStop else { return }
          if self.credentialWrites[id] === permit {self.credentialWrites.removeValue(forKey:id)}
          guard permit.active else{return}
          switch result {
          case .success(true): self.credentialAtStart = bytes; self.credentialSnapshot = bytes; self.credentialSnapshotValid = true; self.state.warning = ""
          case .success(false): self.credentialSnapshotValid = false; self.state.warning = "L’account salvato è cambiato durante l’accesso."
          case .failure: self.state.warning = "Accesso attivo solo in memoria: impossibile salvare nell’archivio account."
          }
          self.notify()
        }
      }
      return
    }
    if type == "state" || (type == "result" && value["state"] != nil) {
      let results:Set<String> = ["OK","Fail","Unknown","Expired","Revoked","InvalidPassword","AccessDenied","AccountDisabled","AccountLockedDown","AccountLogonDenied","AccountLoginDeniedNeedTwoFactor","NoConnection","Timeout","ConnectFailed","ServiceUnavailable","RateLimitExceeded","TryAnotherCM","RemoteDisconnect","LoggedInElsewhere","LogonSessionReplaced","NotLoggedOn"]
      state.steamResult = (value["steamResult"] as? String).flatMap { results.contains($0) ? $0 : nil }
      state.connectionResultContext = (value["connectionResultContext"] as? String).flatMap { ["logged_off","logon_response","transport_cleanup","transport_connect","logon_start"].contains($0) ? $0 : nil }
    }
    if type == "state" {
      let connection = value["state"] as? String ?? "offline"
      if ["connecting","authenticating","online","reconnecting","offline","authorization_required","logged_out"].contains(connection) {
        let becameOnline=connection=="online" && state.connection != "online"
        transition(connection, reason: value["reason"] as? String ?? "")
        if ["authorization_required","logged_out"].contains(connection)
          || ["logged_in_elsewhere","session_replaced","remote_logout","revoked","expired"].contains(state.reason) { automaticRestartSuppressed = true }
        state.retryAfter = value["retryAfter"] as? Double
        if connection == "online" { restartCount = 0 }
        if becameOnline { request("snapshot") { _ in } }
        let invalidation = (value["invalidateCredentials"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        if invalidation {
          let access = credentialAccess, profile = profile, baseline=credentialBaseline
          credentialAtStart = nil; credentialSnapshot = nil; credentialSnapshotValid = false; credentialReadID = UUID()
          CredentialVault.perform({
            if access.load(profile,.steam)==baseline.load(){access.remove(profile,.steam);baseline.replace(nil)}
          }) { _ in }
        } else if connection == "online" { refreshCredentialSnapshot() }
      }
    } else if type == "persona" { updateAccount(value["account"] as? [String: Any] ?? value); refreshCredentialSnapshot() }
    else if type == "friends", let friends = value["friends"] as? [[String: Any]] { updateFriends(friends) }
    else if type == "result" {
      if let connection=value["state"]as?String,["connecting","authenticating","online","reconnecting","offline","authorization_required","logged_out"].contains(connection) {
        transition(connection,reason:value["reason"]as?String ?? "")
      }
      if let account = value["account"] as? [String: Any] { updateAccount(account); refreshCredentialSnapshot() }
      if let friends = value["friends"] as? [[String: Any]] { updateFriends(friends) }
    }
    var safe = value; safe.removeValue(forKey: "credentials"); safe.removeValue(forKey: "password")
    if type != "error" { safe.removeValue(forKey:"code") }
    if let id, let entry = pending[id] {
      if type == "result" || type == "error" { pending.removeValue(forKey: id);if authenticationID==id{authenticationID=nil} }
      entry.callback(safe)
    }
    notify()
  }
  private func updateAccount(_ account: [String: Any]) {
    state.accountName = String((account["accountName"] as? String ?? "").prefix(128))
    state.displayName = String((account["displayName"] as? String ?? "").prefix(256))
    state.steamID = account["steamID"] as? String ?? ""; state.presence = (account["presence"] as? String ?? "offline").lowercased()
  }
  private func updateFriends(_ friends: [[String: Any]]) {
    state.friends = friends.prefix(20000).compactMap { friend in
      guard let id = friend["steamID"] as? String, UInt64(id) != nil else { return nil }
      let name=(friend["gameName"]as?String).flatMap{$0.isEmpty ? nil : String($0.prefix(256))}
      let game=(friend["gameID"]as?String).flatMap{$0.isEmpty||$0=="0" ? nil : $0}
      return SteamFriendState(id:id, displayName:String((friend["displayName"] as? String ?? "").prefix(256)), presence:(friend["presence"] as? String ?? "offline").lowercased(), gameID:game, gameName:name,relationship:friend["relationship"]as?String ?? "Friend")
    }
  }
  private func transition(_ connection: String, reason: String = "") { state.connection = connection; state.reason = reason; notify() }
  private func notify() { onChange?(state) }
  private func failProcess(reason: String) {
    if let task = process, task.isRunning {
      task.terminate()
      DispatchQueue.global().asyncAfter(deadline:.now()+3) { if task.isRunning { kill(task.processIdentifier,SIGKILL) } }
    }
    transition("offline", reason: reason)
  }
  private func ended(_ task: Process, epoch: UUID, malformed: Bool) {
    guard generation == epoch, process === task else { return }
    if task.isRunning {
      task.terminate()
      DispatchQueue.global().asyncAfter(deadline:.now()+3) { if task.isRunning { kill(task.processIdentifier,SIGKILL) } }
    }
    process = nil; try? writer?.close(); writer = nil; watchdog?.invalidate(); watchdog = nil
    let callbacks = Array(pending.values); pending.removeAll()
    for entry in callbacks { entry.callback(["type":"error","code":malformed ? "invalid_service_response":"service_disconnected"]) }
    guard !manualStop else { return }
    if !automaticRestartSuppressed { transition("offline", reason: malformed ? "invalid_service_response":"service_disconnected") }
    guard !automaticRestartSuppressed, restartCount < 3 else { return }
    restartCount += 1; let wait = pow(2.0, Double(restartCount))
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
      guard let self, self.generation == epoch, !self.manualStop else { return }; self.launch()
    }
  }
}
