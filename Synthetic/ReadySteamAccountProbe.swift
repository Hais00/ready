// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
import Security

private enum Failure: Error { case check(String) }
private func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
  if !value() { throw Failure.check(label) }
}
private final class Vault {
  private let lock = NSLock()
  private var values = [UUID: Data]()
  var writes = 0
  func seed(_ profile: UUID, expired: Bool = false) {
    let suffix = profile.uuidString.hasSuffix("0001") ? "one" : "two"
    var object: [String: Any] = ["username":"fixture_" + suffix,"refresh_token":"opaque_" + suffix]
    if expired { object["refresh_token_expires_at_epoch"] = 1.0 }
    lock.lock(); defer { lock.unlock() }
    values[profile] = try! JSONSerialization.data(withJSONObject: object)
  }
  var access: StoreClient.CredentialAccess {
    .init(load: { [self] profile, _ in lock.lock(); defer { lock.unlock() }; return values[profile] },
      save: { [self] data, profile, _ in lock.lock(); defer { lock.unlock() }; values[profile] = data; writes += 1 },
      remove: { [self] profile, _ in lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: profile) })
  }
}
@MainActor
private final class Suite {
  let project: URL
  let source: URL
  let profile = UUID(uuidString:"00000000-0000-4000-8000-000000000001")!
  let other = UUID(uuidString:"00000000-0000-4000-8000-000000000002")!
  var clients = [StoreClient]()
  var results = [String: Bool]()
  init(source: URL) throws {
    self.source = source
    project = FileManager.default.temporaryDirectory.appendingPathComponent("ready-steam-sso-" + UUID().uuidString).resolvingSymlinksInPath()
    let bridge = project.appendingPathComponent("StoreBridge")
    try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source.appendingPathComponent("StoreBridge/supervisor.py"), to: bridge.appendingPathComponent("supervisor.py"))
    try fixture.write(to: bridge.appendingPathComponent("bridge.py"), atomically: true, encoding: .utf8)
  }
  func pump(_ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(8)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    try check(condition(), "deadline")
  }
  func records() -> [[String: Any]] {
    guard let data = try? Data(contentsOf: project.appendingPathComponent("calls.jsonl")), let text = String(data:data,encoding:.utf8) else { return [] }
    return text.split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String:Any] }
  }
  func setup(_ vault: Vault) -> (StoreClient, SteamAccountCoordinator) {
    let client = StoreClient(project:project,stateRoot:project.appendingPathComponent("data"),credentialAccess:vault.access)
    clients.append(client)
    return (client,SteamAccountCoordinator(client:client))
  }
  func mode(_ value: String) throws { try value.write(to:project.appendingPathComponent("mode"),atomically:true,encoding:.utf8) }
  func run() throws {
    defer { clients.forEach{$0.cancelAll()};try? pump{!self.clients.contains{$0.hasActiveRequests}};try? FileManager.default.removeItem(at:project) }
    do {
      let vault=Vault();let (client,coordinator)=setup(vault);var first=[[String:Any]](),second=[[String:Any]](),login=0
      let before=records().count
      coordinator.authorize(profile:profile,gameID:"480",target:.nativeMac){first.append($0)}
      coordinator.authorize(profile:profile,gameID:"480",target:.wineWindows){second.append($0)}
      try check((first+second).filter{$0["type"]as?String=="authentication_required"}.count==1,"one explicit profile login prompt")
      try check(records().count==before,"no per-backend auth begun")
      coordinator.authenticate(profile:profile){if $0["type"]as?String=="result"{login += 1}}
      coordinator.authenticate(profile:profile){if $0["type"]as?String=="result"{login += 1}}
      try pump { first.last?["type"]as?String=="result" && second.last?["type"]as?String=="result" && login==2 && !client.hasActiveRequests }
      let calls=Array(records().dropFirst(before))
      try check(calls.filter{$0["operation"]as?String=="auth_begin"}.count==1,"one auth flight")
      try check(calls.filter{$0["operation"]as?String=="authorize_game"}.count==1,"native/Wine share one preflight")
      try check(calls.allSatisfy{$0["credentialsMatch"]as?Bool==true && $0["platformOptionAbsent"]as?Bool==true && $0["toolsRootForwarded"]as?Bool==true},"same private identity no platform credential key and explicit central tools")
      try check(vault.writes==1,"one profile credential save")
      try check(first.last?["credentialRevision"]as?String==second.last?["credentialRevision"]as?String,"same account revision")
      try check(first.last?["backendSessionReady"]as?Bool==false,"no backend readiness invented")
      var reuse=false;coordinator.authenticate(profile:profile){reuse=$0["reusedStoredAccount"]as?Bool==true}
      try pump{reuse};try check(records().count==before+2,"present vault reuses login without new process")
      try check(!String(describing:first+second).contains("opaque_one"),"events do not expose credentials")
      results["oneQRSharedIdentityAndPreflightForTwoTargets"]=true
    }
    do {
      let vault=Vault();vault.seed(profile);vault.seed(other);let (client,coordinator)=setup(vault)
      var one:[String:Any]?,two:[String:Any]?
      coordinator.authorize(profile:profile,gameID:"480",target:.nativeMac){one=$0}
      coordinator.authorize(profile:other,gameID:"480",target:.wineWindows){two=$0}
      try pump{one?["type"]as?String=="result" && two?["type"]as?String=="result" && !client.hasActiveRequests}
      try check(one?["steamID"]as?String != two?["steamID"]as?String,"distinct profiles isolated")
      results["profilesHaveSeparateCredentialsAndIdentity"]=true
    }
    for failureMode in ["network","expired","wrong-app","wrong-identity","integer-true"] {
      let vault=Vault();vault.seed(profile);let (client,coordinator)=setup(vault);try mode(failureMode);var events=[[String:Any]]()
      coordinator.authorize(profile:profile,gameID:"480",target:.nativeMac,expectedSteamID:"76561197960265839"){events.append($0)}
      try pump{!events.isEmpty && !client.hasActiveRequests}
      let required=events.contains{$0["type"]as?String=="authentication_required"}
      try check(required == (failureMode=="expired"),"only exact rejection requires login")
      try check((client.steamCredentialStatus(profile:profile) == .expired) == (failureMode=="expired"),"exact server rejection changes credential status only")
      try check(events.allSatisfy{$0["authorized"]as?Bool != true},"invalid authority not promoted")
      coordinator.cancel(profile:profile)
      results["failure-"+failureMode]=true
    }
    try mode("normal")
    for expired in [false, true] {
      let vault=Vault();if expired { vault.seed(profile,expired:true) }
      let (client,coordinator)=setup(vault);var cancelledEvents=0,retryPrompts=0,retrySucceeded=false
      let before=records().count
      let cancelled=coordinator.authorize(profile:profile,gameID:"480",target:.nativeMac){_ in cancelledEvents += 1}
      try check(cancelledEvents==1,"initial missing/expired login prompt delivered")
      coordinator.cancel(cancelled)
      coordinator.authorize(profile:profile,gameID:"480",target:.wineWindows){value in
        if value["type"]as?String=="authentication_required" { retryPrompts += 1 }
        if value["type"]as?String=="result" { retrySucceeded=true }
      }
      try check(retryPrompts==1 && records().count==before,"cancelled prompt permits retry without implicit auth")
      coordinator.authenticate(profile:profile){_ in}
      try pump{retrySucceeded && !client.hasActiveRequests}
      try check(cancelledEvents==1,"cancelled prompt subscriber never resumes")
      results[expired ? "expiredPromptCancellationCanRetry" : "missingPromptCancellationCanRetry"]=true
    }
    do {
      let vault=Vault();let (client,coordinator)=setup(vault);var firstEvents=0,secondPrompts=0,secondSucceeded=false
      let before=records().count
      let owner=coordinator.authorize(profile:profile,gameID:"480",target:.nativeMac){_ in firstEvents += 1}
      coordinator.authorize(profile:profile,gameID:"481",target:.wineWindows){value in
        if value["type"]as?String=="authentication_required" { secondPrompts += 1 }
        if value["type"]as?String=="result" { secondSucceeded=true }
      }
      try check(firstEvents==1 && secondPrompts==0,"one prompt for two waiting games")
      coordinator.cancel(owner)
      try check(secondPrompts==1 && records().count==before,"prompt ownership transfers to remaining game without implicit auth")
      coordinator.authenticate(profile:profile){_ in}
      try pump{secondSucceeded && !client.hasActiveRequests}
      try check(firstEvents==1,"cancelled game receives no late result")
      let calls=Array(records().dropFirst(before))
      try check(calls.filter{$0["operation"]as?String=="auth_begin"}.count==1 && calls.filter{$0["operation"]as?String=="authorize_game"}.count==1,"only remaining game resumes after one explicit login")
      results["cancelledPromptOwnerTransfersToWaitingGame"]=true
    }
    do {
      let vault=Vault();vault.seed(profile,expired:true);let (_,coordinator)=setup(vault);var prompts=0;let before=records().count
      coordinator.authorize(profile:profile,gameID:"480",target:.nativeMac){if $0["type"]as?String=="authentication_required"{prompts += 1}}
      coordinator.authorize(profile:profile,gameID:"481",target:.wineWindows){if $0["type"]as?String=="authentication_required"{prompts += 1}}
      try check(prompts==1 && records().count==before,"expiry is one explicit login not automatic requests")
      coordinator.cancel(profile:profile);results["refreshExpiryIsOneProfilePrompt"]=true
    }
    do {
      let vault=Vault();let (client,coordinator)=setup(vault);var callbacks=0
      let id=coordinator.authenticate(profile:profile){_ in callbacks += 1};coordinator.cancel(id)
      try pump{!client.hasActiveRequests};try check(callbacks==0 && vault.writes==0,"cancel auth blocks late save and callbacks")
      vault.seed(profile);try mode("slow");var preflight=0
      coordinator.authorize(profile:profile,gameID:"480",target:.nativeMac){_ in preflight += 1}
      coordinator.signOut(profile:profile);try pump{!client.hasActiveRequests}
      try check(preflight==0 && client.steamCredentialStatus(profile:profile) == .missing,"signout invalidates queued authority and account")
      try mode("normal");results["cancelAndAccountSwitchBarriers"]=true
    }
    let a=CredentialVault.query(profile:profile,store:.steam,stateRoot:project.appendingPathComponent("root-a"))
    let b=CredentialVault.query(profile:profile,store:.steam,stateRoot:project.appendingPathComponent("root-b"))
    try check(a[kSecAttrService as String]as?String != b[kSecAttrService as String]as?String,"data root namespaces remain distinct")
    results["dataRootNamespacePreserved"]=true
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"checks":results,"checkCount":results.count,
      "realFoundationProcess":true,"realKeychainUsed":false,"realStoreAccountUsed":false,"nativeOrWineWorkerStarted":false],options:[.sortedKeys]),as:UTF8.self))
  }
  let fixture = #"""
import json,os,pathlib,sys,time
p=pathlib.Path(__file__).parent.parent
r=json.loads(sys.stdin.readline());op=r['operation'];suffix='one' if r['profileID'].endswith('0001') else 'two'
account='fixture_'+suffix;token='opaque_'+suffix
mode=(p/'mode').read_text() if (p/'mode').exists() else 'normal'
matches=op=='auth_begin' or r['credentials'].get('username')==account and r['credentials'].get('refresh_token')==token
assert token not in ' '.join(sys.argv) and all(token not in v for v in os.environ.values())
with (p/'calls.jsonl').open('a') as f:f.write(json.dumps({'operation':op,'profile':r['profileID'],'credentialsMatch':matches,'platformOptionAbsent':'platform' not in r['options'],'toolsRootForwarded':os.environ.get('READY_STORE_TOOLS_ROOT','').endswith('/ReadySSOFixtureTools')})+'\n')
def emit(x):print(json.dumps(x),flush=True)
if op=='auth_begin':
 emit({'type':'qr','url':'https://s.team/q/fixture'});time.sleep(.12)
 emit({'type':'result','credentials':{'username':account,'refresh_token':token}})
elif op=='authorize_game':
 time.sleep(.15 if mode!='slow' else 1)
 if mode in ['network','expired']:
  emit({'type':'error','code':'steam_login_failed','steamResult':'NoConnection' if mode=='network' else 'Expired'});sys.exit(1)
 if not matches:emit({'type':'error','code':'authentication_required'});sys.exit(1)
 identity=((1<<56)|(1<<52)|(1<<32))+(111 if suffix=='one' else 222)
 if mode=='wrong-identity':identity+=1
 emit({'type':'result','authorized':1 if mode=='integer-true' else True,'ownershipTicketReceived':True,
       'appID':int(r['options']['gameID'])+(1 if mode=='wrong-app' else 0),'steamID':str(identity)})
else:emit({'type':'error','code':'unsupported_operation'});sys.exit(1)
"""#
}
@main struct Probe {
  @MainActor static func main() {
    do { try Suite(source:URL(fileURLWithPath:CommandLine.arguments[1])).run() }
    catch { fputs("Steam account coordinator synthetic checks failed.\n",stderr);exit(1) }
  }
}
