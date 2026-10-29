// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
import CryptoKit
import LauncherCore
import Darwin

/// Private, short-lived handoff for a separately supervised game host. Creating
/// this grant says nothing about whether that host or its launch gate is ready.
@MainActor
final class SteamGameAuthorizationGrant: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  nonisolated var description: String { "[private Steam game authorization]" }
  nonisolated var debugDescription: String { description }
  nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
  let profile: UUID
  let gameID: UInt32
  let steamID: String
  private var packet: NSMutableData?
  private let valid: () -> Bool
  private let deadline: TimeInterval
  private let uptime: () -> TimeInterval

  fileprivate init(profile: UUID, gameID: UInt32, steamID: String, packet: NSMutableData, valid: @escaping () -> Bool,
                   uptime: @escaping () -> TimeInterval, lifetime: TimeInterval) {
    self.profile = profile; self.gameID = gameID; self.steamID = steamID
    self.packet = packet; self.valid = valid; self.uptime = uptime
    deadline = uptime() + lifetime
  }
  /// The caller must use only a private anonymous pipe and clear its returned
  /// Data after handing it off. Every attempt consumes and erases this grant.
  func consume() throws -> Data {
    guard let packet else { throw SteamGameAuthorization.Failure.consumed }
    defer { invalidate() }
    guard uptime() < deadline, valid() else { throw SteamGameAuthorization.Failure.stale }
    return Data(bytes: packet.bytes, count: packet.length)
  }
  fileprivate func invalidate() {
    if let packet { packet.resetBytes(in: NSRange(location: 0, length: packet.length)); packet.length = 0 }
    packet = nil
  }
  deinit {
    if let packet { packet.resetBytes(in: NSRange(location: 0, length: packet.length)); packet.length = 0 }
  }
}

/// Uses only an already-online persistent client. Never logs in, requests a QR,
/// starts a one-shot StoreClient, or puts credentials in an event dictionary.
@MainActor
final class SteamGameAuthorization {
  enum Failure: String, Error {
    case unavailable, invalidRequest, rejected, stale, consumed, cancelled
    case offline, timeout, network, authenticationRequired, notAuthorized, rateLimited, serviceFailure
    var userMessage:String {
      switch self {
      case .offline: return "La connessione Steam non è attiva. Apri il pannello account e riprova quando risulta connesso."
      case .timeout: return "La verifica ha superato il tempo previsto. Puoi riprovare senza rifare il login."
      case .network: return "La verifica non è riuscita per un problema di connessione. L’account salvato è stato conservato."
      case .authenticationRequired: return "L’accesso salvato richiede una verifica. Apri il pannello account; non è stato avviato un nuovo login."
      case .notAuthorized: return "Steam ha rifiutato la verifica della licenza. Controlla l’account e il gioco selezionati."
      case .rateLimited: return "Steam sta limitando le richieste. Attendi prima di riprovare; non occorre ripetere il login."
      case .stale: return "L’account o la sessione locale sono cambiati durante la verifica. Riprova con il profilo attuale."
      case .rejected: return "Il componente Steam ha restituito una verifica incompleta o non valida. L’avvio è stato fermato."
      case .invalidRequest: return "La richiesta locale di avvio Steam non è valida."
      case .unavailable: return "L’account Steam di questo profilo non è ancora pronto per la verifica. Apri il pannello account."
      case .consumed: return "Questa autorizzazione locale è già stata utilizzata. Ripeti la preparazione del gioco."
      case .cancelled: return "Preparazione Steam annullata."
      case .serviceFailure: return "Il componente di verifica Steam ha incontrato un errore. L’account salvato è stato conservato."
      }
    }
  }
  /// Fixed vocabulary and comparison facts only. No account/app identifiers,
  /// credential or ticket bytes, digests, backend messages or exceptions.
  struct FailureDetail:Encodable {
    let code:String
    let steamResult:String?
    let epochMatches:Bool
    let stateOnline:Bool
    let vaultMatches:Bool
    let appMatched:Bool?
    let identityMatched:Bool?
    let ticketReported:Bool?
    init(code:String,steamResult:String?,epochMatches:Bool,stateOnline:Bool,vaultMatches:Bool,
         appMatched:Bool?,identityMatched:Bool?,ticketReported:Bool?) {
      self.code=Self.codes.contains(code) ? code:"unknown_error"
      self.steamResult=steamResult.map{Self.results.contains($0) ? $0:"Unknown"}
      self.epochMatches=epochMatches;self.stateOnline=stateOnline;self.vaultMatches=vaultMatches
      self.appMatched=appMatched;self.identityMatched=identityMatched;self.ticketReported=ticketReported
    }
    fileprivate func withCode(_ value:String)->Self {
      .init(code:value,steamResult:steamResult,epochMatches:epochMatches,stateOnline:stateOnline,vaultMatches:vaultMatches,
        appMatched:appMatched,identityMatched:identityMatched,ticketReported:ticketReported)
    }
    func writePrivate(logs:URL)throws {
      let fd=open(logs.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
      guard fd>=0 else{throw Failure.serviceFailure};defer{close(fd)}
      var info=stat(),path=[CChar](repeating:0,count:Int(PATH_MAX)+1)
      guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o077==0,
        fcntl(fd,F_GETPATH,&path)==0,let actual=String(validatingUTF8:path) else{throw Failure.serviceFailure}
      let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
      try AtomicFile.writePrivate(encoder.encode(self),to:URL(fileURLWithPath:actual,isDirectory:true).appendingPathComponent("steam-last-authorization-failure.json"))
    }
    private static let codes:Set<String>=["unknown_error","invalid_request","invalid_game_id","authentication_required","auth_required","steam_login_failed",
      "not_authorized","ownership_invalid_response","ownership_request_failed","steam_error","timeout","network_error","rate_limited","cancelled","disconnected","not_online","busy",
      "service_unavailable","service_disconnected","service_unresponsive","service_pipe","invalid_service_response","local_session_changed","local_offline","local_credentials_changed","local_identity_changed"]
    private static let results:Set<String>=["OK","Fail","NoConnection","InvalidPassword","LoggedInElsewhere","InvalidProtocolVer","InvalidParam","AccessDenied","Timeout","AccountNotFound","InvalidSteamID","ServiceUnavailable","NotLoggedOn","Pending","InsufficientPrivilege","LimitExceeded","Revoked","Expired","DuplicateRequest","LogonSessionReplaced","ConnectFailed","HandshakeFailed","IOFailure","RemoteDisconnect","AccountDisabled","TryAnotherCM","AlreadyLoggedInElsewhere","Suspended","Cancelled","AccountLogonDenied","InvalidLoginAuthCode","AccountLogonDeniedNoMail","ExpiredLoginAuthCode","AccountLockedDown","AccountLogonDeniedVerifiedEmailRequired","RateLimitExceeded","AccountLoginDeniedNeedTwoFactor","AccountLoginDeniedThrottle","TwoFactorCodeMismatch","Unknown"]
  }
  typealias Completion = (Result<SteamGameAuthorizationGrant, Failure>) -> Void
  private let network: SteamClientSession
  private let credentialAccess: StoreClient.CredentialAccess
  private let uptime: () -> TimeInterval
  private let grantLifetime: TimeInterval
  private var requestID: String?
  private var pendingCompletion: Completion?
  private var revision = UUID()
  private weak var grant: SteamGameAuthorizationGrant?
  private var pendingDetail:(()->FailureDetail)?
  private(set) var lastFailureDetail:FailureDetail?

  init(network: SteamClientSession, credentialAccess: StoreClient.CredentialAccess,
       uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       grantLifetime: TimeInterval = 15) {
    self.network = network; self.credentialAccess = credentialAccess; self.uptime = uptime
    self.grantLifetime = grantLifetime.isFinite ? min(15, max(0, grantLifetime)) : 0
  }

  @discardableResult
  func prepare(profile: UUID, gameID: String, completion: @escaping Completion) -> String {
    let attempt = cancelPending()
    let fallback = UUID().uuidString
    // Cancellation completions can themselves start a newer preparation.
    guard revision == attempt else { completion(.failure(.cancelled)); return fallback }
    lastFailureDetail=nil
    let initialSource=credentialAccess.load(profile,.steam)
    let initialAccount=initialSource.flatMap{try? JSONSerialization.jsonObject(with:$0)as?[String:Any]}?["username"]as?String
    let initialVaultMatches=CredentialVault.steamStatus(initialSource) == .available &&
      initialAccount?.caseInsensitiveCompare(network.state.accountName) == .orderedSame
    let initialDetail=FailureDetail(code:"invalid_request",steamResult:network.state.steamResult,epochMatches:network.profile==profile,stateOnline:network.state.online,
      vaultMatches:initialVaultMatches,appMatched:nil,identityMatched:nil,ticketReported:nil)
    guard let app = Self.number(gameID), app > 0, app < UInt64(UInt32.max) else {
      lastFailureDetail=initialDetail
      completion(.failure(.invalidRequest)); return fallback
    }
    guard network.profile == profile, network.state.online,
      let identity = Self.individual(network.state.steamID),
      let source = initialSource, CredentialVault.steamStatus(source) == .available,
      let credentials = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
      let account = credentials["username"] as? String,
      account.caseInsensitiveCompare(network.state.accountName) == .orderedSame else {
      let code = !network.state.online ? "local_offline":network.profile != profile ? "local_session_changed":
        CredentialVault.steamStatus(initialSource) != .available ? "authentication_required":"local_identity_changed"
      lastFailureDetail=initialDetail.withCode(code)
      completion(.failure(network.state.online ? .unavailable:.offline)); return fallback
    }
    let epoch = network.generation, digest = Data(SHA256.hash(data: source))
    let access = credentialAccess
    let inspect:([String:Any]?)->FailureDetail = { [weak network] event in
      let current=access.load(profile,.steam)
      let epochMatches=network?.profile==profile && network?.generation==epoch
      let online=network?.state.online==true
      let vaultMatches=current.map{CredentialVault.steamStatus($0) == .available && Data(SHA256.hash(data:$0))==digest} ?? false
      let currentIdentity=network.map{Self.individual($0.state.steamID)==identity && account.caseInsensitiveCompare($0.state.accountName) == .orderedSame} ?? false
      var appMatched:Bool?,identityMatched:Bool?=currentIdentity,ticketReported:Bool?
      if let event {
        if event["type"]as?String=="result" {
          appMatched=Self.number(event["appID"])==app
          identityMatched=currentIdentity && Self.individual(event["steamID"])==identity
          ticketReported=Self.trueValue(event["ownershipTicketReceived"])
        } else {
          appMatched=Self.boolean(event["ownershipAppMatched"])
          identityMatched=currentIdentity && Self.boolean(event["ownershipSteamIDPresent"]) != false ? nil:false // Presence alone cannot prove a matching identity.
          if Self.boolean(event["ownershipResponseReceived"])==true{ticketReported=Self.boolean(event["ownershipTicketNonEmpty"])}
        }
      }
      let result=(event?["steamResult"]as?String) ?? (!online ? network?.state.steamResult:nil)
      return FailureDetail(code:event?["code"]as?String ?? "unknown_error",steamResult:result,
        epochMatches:epochMatches,stateOnline:online,vaultMatches:vaultMatches,appMatched:appMatched,identityMatched:identityMatched,ticketReported:ticketReported)
    }
    let stillValid: () -> Bool = { [weak network] in
      guard let network, network.profile == profile, network.generation == epoch, network.state.online,
        Self.individual(network.state.steamID) == identity,
        account.caseInsensitiveCompare(network.state.accountName) == .orderedSame,
        let current = access.load(profile, .steam), CredentialVault.steamStatus(current) == .available else { return false }
      return Data(SHA256.hash(data: current)) == digest
    }
    // A synchronous transport failure may run completion before request returns.
    var finished = false
    pendingCompletion = completion
    pendingDetail={inspect(nil).withCode("cancelled")}
    let id = network.request("authorize_game", options: ["gameID": String(app)]) { [weak self] event in
      guard let self, self.revision == attempt else { return }
      let type = event["type"] as? String
      guard type == "result" || type == "error" else { return }
      finished = true; self.requestID = nil; self.pendingCompletion = nil;self.pendingDetail=nil
      let local=inspect(nil),detail=inspect(event)
      guard local.epochMatches,local.stateOnline,local.vaultMatches,local.identityMatched==true,stillValid() else {
        let code = !local.epochMatches ? "local_session_changed":!local.stateOnline ? "local_offline":!local.vaultMatches ? "local_credentials_changed":"local_identity_changed"
        self.lastFailureDetail=detail.withCode(code)
        completion(.failure(local.stateOnline ? .stale:.offline));return
      }
      if type=="error" {
        self.lastFailureDetail=detail
        completion(.failure(Self.classify(detail)));return
      }
      guard type == "result", Self.trueValue(event["authorized"]), Self.trueValue(event["ownershipTicketReceived"]),
        Self.number(event["appID"]) == app, Self.individual(event["steamID"]) == identity,
        let current = access.load(profile, .steam), Data(SHA256.hash(data: current)) == digest,
        let packet = Self.packet(current, identity: identity, app: UInt32(app)) else {
        self.lastFailureDetail=detail.withCode("ownership_invalid_response")
        completion(.failure(.rejected)); return
      }
      let grant = SteamGameAuthorizationGrant(profile: profile, gameID: UInt32(app), steamID: String(identity),
        packet: packet, valid: stillValid, uptime: self.uptime, lifetime: self.grantLifetime)
      self.grant = grant
      self.lastFailureDetail=nil
      completion(.success(grant))
    }
    if !finished, revision == attempt { requestID = id }
    return id
  }
  func cancel() { _ = cancelPending() }
  private func cancelPending() -> UUID {
    let epoch = UUID(); revision = epoch; grant?.invalidate(); grant = nil
    let completion = pendingCompletion; pendingCompletion = nil
    if completion != nil{lastFailureDetail=pendingDetail?()};pendingDetail=nil
    if let id = requestID { requestID = nil; network.cancel(id) }
    completion?(.failure(.cancelled))
    return epoch
  }
  private static func trueValue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
    return number.boolValue
  }
  private static func boolean(_ value:Any?)->Bool? {
    guard let value=value as?NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID() else{return nil};return value.boolValue
  }
  private static func classify(_ detail:FailureDetail)->Failure {
    if detail.code=="cancelled"{return .cancelled}
    if detail.code=="timeout"||detail.steamResult=="Timeout"{return .timeout}
    if detail.code=="rate_limited"||["RateLimitExceeded","AccountLoginDeniedThrottle","LimitExceeded"].contains(detail.steamResult ?? ""){return .rateLimited}
    if detail.code=="not_online"{return .offline}
    if ["network_error","disconnected","service_disconnected","service_unresponsive","service_pipe"].contains(detail.code) ||
      ["NoConnection","IOFailure","RemoteDisconnect","ConnectFailed","HandshakeFailed","ServiceUnavailable","TryAnotherCM"].contains(detail.steamResult ?? ""){return .network}
    if ["authentication_required","auth_required"].contains(detail.code) ||
      (detail.code=="steam_login_failed" && ["Expired","Revoked","InvalidPassword","NotLoggedOn","AccountDisabled","AccountLockedDown"].contains(detail.steamResult ?? "")){return .authenticationRequired}
    if detail.code=="not_authorized",["AccessDenied","InsufficientPrivilege"].contains(detail.steamResult ?? ""){return .notAuthorized}
    if detail.code=="ownership_invalid_response"{return .rejected}
    return .serviceFailure
  }
  private static func number(_ value: Any?) -> UInt64? {
    let text: String
    if let string = value as? String { text = string }
    else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
    else { return nil }
    guard !text.isEmpty, text.utf8.count <= 20, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return UInt64(text)
  }
  private static func individual(_ value: Any?) -> UInt64? {
    guard let id = number(value), id >> 56 == 1, (id >> 52) & 15 == 1,
      (id >> 32) & 0xfffff == 1, id & 0xffffffff != 0 else { return nil }
    return id
  }
  private static func packet(_ source: Data, identity: UInt64, app: UInt32) -> NSMutableData? {
    guard CredentialVault.steamStatus(source) == .available,
      let value = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
      let account = value["username"] as? String, let token = value["refresh_token"] as? String else { return nil }
    let packet = NSMutableData(data: Data("RDYAUTH1".utf8))
    func append<T: FixedWidthInteger>(_ input: T) {
      var big = input.bigEndian
      withUnsafeBytes(of: &big) { packet.append($0.baseAddress!, length: $0.count) }
    }
    append(UInt32(account.utf8.count)); append(UInt32(token.utf8.count)); append(identity); append(app)
    for text in [account, token] { for byte in text.utf8 { var value = byte; packet.append(&value, length: 1) } }
    return packet
  }
}
