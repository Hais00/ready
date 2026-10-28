// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import LauncherCore
import Security

private enum ProbeFailure: Error { case failed(String) }
private func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
  if !value() { throw ProbeFailure.failed(label) }
}
private final class MemoryVault {
  private let lock = NSLock()
  private var loads = 0
  private var writes = [(UUID, Store, Data)]()
  var failSave = false
  var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (loads, writes.count) }
  var access: StoreClient.CredentialAccess {
    .init(load: { [self] _, _ in
      lock.lock(); defer { lock.unlock() }; loads += 1
      return Data(#"{"access_token":"fixture-private"}"#.utf8)
    }, save: { [self] data, profile, store in
      lock.lock(); defer { lock.unlock() }
      if failSave { throw ProbeFailure.failed("fixture vault rejection") }
      writes.append((profile, store, data))
    })
  }
}
private final class Suite {
  let root: URL
  let source: URL
  var clients = [StoreClient]()
  var results = [String: Bool]()
  let profile = UUID()
  init(source: URL) throws {
    self.source = source
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ready-store-client-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  func pump(_ label: String, timeout: TimeInterval = 8, until condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() >= deadline { throw ProbeFailure.failed(label + " timeout") }
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }
  func client(_ name: String, vault: MemoryVault, queue: DispatchQueue? = nil) throws -> (StoreClient, URL) {
    let project = root.appendingPathComponent(name)
    let bridge = project.appendingPathComponent("StoreBridge")
    try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source.appendingPathComponent("StoreBridge/supervisor.py"), to: bridge.appendingPathComponent("supervisor.py"))
    try fixture.write(to: bridge.appendingPathComponent("bridge.py"), atomically: true, encoding: .utf8)
    let client = StoreClient(project: project, stateRoot: root.appendingPathComponent("data-" + name), credentialAccess: vault.access, workerQueue: queue ?? .global(qos: .userInitiated))
    clients.append(client)
    return (client, project)
  }
  func leaseHeld(_ root: URL) -> Bool {
    let descriptor = open(root.appendingPathComponent("lease.lock").path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    return flock(descriptor, LOCK_EX | LOCK_NB) != 0
  }
  func run() throws {
    defer {
      clients.forEach { $0.cancelAll() }
      try? pump("cleanup") { self.clients.allSatisfy { !$0.hasActiveRequests } }
      try? FileManager.default.removeItem(at: root)
    }
    do {
      let original = CredentialVault.query(profile: profile, store: .gog)
      let explicit = CredentialVault.query(profile: profile, store: .gog, stateRoot: LauncherPaths().root)
      try check(NSDictionary(dictionary: original).isEqual(to: explicit), "default Keychain service preserved")
      let first = CredentialVault.query(profile: profile, store: .gog, stateRoot: root.appendingPathComponent("namespace-one"))
      let second = CredentialVault.query(profile: profile, store: .gog, stateRoot: root.appendingPathComponent("namespace-two"))
      let otherProfile = CredentialVault.query(profile: UUID(), store: .gog, stateRoot: root.appendingPathComponent("namespace-one"))
      try check(first[kSecAttrService as String] as? String != second[kSecAttrService as String] as? String, "custom data roots use distinct Keychain services")
      try check(first[kSecAttrAccount as String] as? String != otherProfile[kSecAttrAccount as String] as? String, "profiles remain isolated within data root")
      results["dataRootKeychainNamespacesWithoutAccess"] = true
    }
    for mode in ["success", "fragmented", "crash", "result_crash", "duplicate", "quiet", "error", "auth_url"] {
      let vault = MemoryVault(); let (client, _) = try client(mode, vault: vault)
      var events = [[String: Any]](); var activeDuringCallback = true
      client.request(operation: mode, store: .gog, profile: profile) { value in
        activeDuringCallback = activeDuringCallback && client.hasActiveRequests
        events.append(value)
      }
      try pump(mode) { !client.hasActiveRequests }
      let types = events.compactMap { $0["type"] as? String }
      let expected = ["success", "fragmented"].contains(mode) ? ["progress", "result"] : ["crash", "duplicate"].contains(mode) ? ["progress", "error"] : mode == "auth_url" ? ["auth_url"] : ["error"]
      try check(types == expected && activeDuringCallback, mode + " terminal ordering")
      try check(events.allSatisfy { $0["credentials"] == nil }, mode + " private events")
      try check(vault.counts.1 == (["success", "fragmented"].contains(mode) ? 1 : 0), mode + " terminal credential persistence")
      if mode == "success" {
        try check(events.last?["stateRoot"] as? String == root.appendingPathComponent("data-" + mode).path, "explicit state root environment")
      }
      results[mode] = true
    }
    do {
      let queue = DispatchQueue(label: "ready.store.fixture.suspended"); queue.suspend()
      let vault = MemoryVault(); let (client, project) = try client("cancel-before-spawn", vault: vault, queue: queue)
      var callbacks = 0
      let id = client.request(operation: "success", store: .gog, profile: profile) { _ in callbacks += 1 }
      _ = client.request(operation: "success", store: .steam, profile: UUID()) { _ in callbacks += 1 }
      client.cancel(id); client.cancelAll()
      try check(client.hasActiveRequests, "cancelled work remains pending until drained")
      queue.resume(); try pump("cancel before spawn") { !client.hasActiveRequests }
      try check(callbacks == 0 && vault.counts == (0, 0), "cancel before spawn suppresses vault and events")
      try check(!FileManager.default.fileExists(atPath: project.appendingPathComponent("started").path), "cancel before spawn launches no bridge")
      results["cancelBeforeSpawnAndCancelAll"] = true
    }
    do {
      let queue = DispatchQueue(label: "ready.store.fixture.serial")
      let vault = MemoryVault(); let (client, _) = try client("cancel-queued-result", vault: vault, queue: queue)
      var callbacks = 0
      let id = client.request(operation: "success", store: .gog, profile: profile) { _ in callbacks += 1 }
      let finished = DispatchSemaphore(value: 0); queue.async { finished.signal() }
      try check(finished.wait(timeout: .now() + 8) == .success, "worker process completed before callback queue drain")
      try check(client.hasActiveRequests && callbacks == 0, "pending includes queued callbacks")
      client.cancel(id); try pump("cancel queued callbacks") { !client.hasActiveRequests }
      try check(callbacks == 0 && vault.counts.1 == 0, "cancel drops queued result and credential save")
      results["cancelQueuedTerminal"] = true
    }
    do {
      let vault = MemoryVault(); let (client, project) = try client("invalid-request", vault: vault)
      var types = [String]()
      client.request(operation: "success", store: .gog, profile: profile, options: ["invalid": NSObject()]) { types.append($0["type"] as? String ?? "") }
      try pump("invalid request") { !client.hasActiveRequests }
      try check(types == ["error"] && !FileManager.default.fileExists(atPath: project.appendingPathComponent("started").path), "invalid request has no process")
      results["invalidRequestCleanup"] = true
    }
    do {
      let vault = MemoryVault(); let (client, project) = try client("broken-input", vault: vault)
      FileManager.default.createFile(atPath: project.appendingPathComponent("close-input").path, contents: Data())
      var types = [String]()
      client.request(operation: "success", store: .gog, profile: profile, options: ["payload": String(repeating: "x", count: 1_000_000)]) { types.append($0["type"] as? String ?? "") }
      try pump("broken input cleanup") { !client.hasActiveRequests }
      try check(types == ["error"] && vault.counts.1 == 0, "broken pipe does not terminate app or save credentials")
      results["brokenInputPipeCleanup"] = true
    }
    do {
      let vault = MemoryVault()
      let client = StoreClient(project: root.appendingPathComponent("missing-project"), credentialAccess: vault.access)
      clients.append(client); var types = [String]()
      client.request(operation: "success", store: .gog, profile: profile) { types.append($0["type"] as? String ?? "") }
      try pump("launch failure") { !client.hasActiveRequests }
      try check(types == ["error"] && vault.counts.1 == 0, "launch failure closes pending state")
      results["launchFailureCleanup"] = true
    }
    do {
      let vault = MemoryVault(); vault.failSave = true
      let (client, _) = try client("vault-failure", vault: vault)
      var types = [String]()
      client.request(operation: "success", store: .gog, profile: profile) { types.append($0["type"] as? String ?? "") }
      try pump("vault failure") { !client.hasActiveRequests }
      try check(types == ["progress", "error"] && vault.counts.1 == 0, "vault failure is terminal error")
      results["vaultFailure"] = true
    }
    do {
      let vault = MemoryVault(); let (client, _) = try client("cancel-tree", vault: vault)
      let a = root.appendingPathComponent("tree-one"), b = root.appendingPathComponent("tree-two")
      var callbacksA = 0
      let first = client.request(operation: "hang", store: .gog, profile: profile, options: ["job": a.path]) { _ in callbacksA += 1 }
      _ = client.request(operation: "hang", store: .gog, profile: UUID(), options: ["job": b.path]) { _ in }
      try pump("job readiness") { FileManager.default.fileExists(atPath: a.appendingPathComponent("ready").path) && FileManager.default.fileExists(atPath: b.appendingPathComponent("ready").path) }
      let beforeCancel = callbacksA; client.cancel(first)
      Thread.sleep(forTimeInterval: 0.1)
      try check(client.hasActiveRequests && leaseHeld(a), "pending and installation lease survive until stubborn children stop")
      try pump("first tree stopped") { !self.leaseHeld(a) }
      try check(callbacksA == beforeCancel && leaseHeld(b) && client.hasActiveRequests, "cancel has no late events and leaves other job alive")
      client.cancelAll(); try pump("all trees stopped") { !client.hasActiveRequests }
      try check(!leaseHeld(a) && !leaseHeld(b) && vault.counts.1 == 0, "children and grandchildren release descriptors before inactive")
      results["cancelExactChildrenAndGrandchildren"] = true
    }
    let summary: [String: Any] = ["passed": results.values.allSatisfy { $0 }, "checks": results, "checkCount": results.count, "realFoundationProcess": true, "realKeychainUsed": false, "realStoreAccountsUsed": false]
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
  let fixture = #"""
import fcntl,json,os,pathlib,signal,subprocess,sys,time
project=pathlib.Path(__file__).parent.parent
if (project/'close-input').exists():
 os.close(0)
 time.sleep(30)
 sys.exit(0)
request=json.loads(sys.stdin.readline())
(project/'started').touch()
mode=request['operation']
if mode=='quiet':sys.exit(0)
if mode=='error':
 print(json.dumps({'type':'error','code':'fixture_error','message':'Fixture error'}),flush=True)
 sys.exit(1)
if mode=='auth_url':
 print(json.dumps({'type':'auth_url','url':'https://example.invalid/oauth','authState':{}}),flush=True)
 sys.exit(0)
if mode=='hang':
 root=pathlib.Path(request['options']['job']);root.mkdir()
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 fd=os.open(root/'lease.lock',os.O_CREAT|os.O_RDWR,0o600);fcntl.flock(fd,fcntl.LOCK_EX)
 subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'],pass_fds=(fd,))
 (root/'ready').touch()
 print(json.dumps({'type':'progress','fraction':0.1,'credentials':request['credentials']}),flush=True)
 while True:time.sleep(.02)
if mode!='result_crash':
 print(json.dumps({'type':'progress','fraction':0.1,'credentials':request['credentials']}),flush=True)
if mode=='crash':os._exit(23)
result=json.dumps({'type':'result','credentials':{'refresh_token':'fixture-private'},'stateRoot':os.environ.get('READY_DATA_ROOT')})
if mode=='fragmented':
 sys.stdout.write(result[:len(result)//2]);sys.stdout.flush();time.sleep(.03)
 sys.stdout.write(result[len(result)//2:]+'\n');sys.stdout.flush()
else:print(result,flush=True)
if mode=='duplicate':print(result,flush=True)
if mode=='result_crash':os._exit(23)
"""#
}
@main
private enum ReadyStoreClientProbe {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else { throw ProbeFailure.failed("source root required") }
    try Suite(source: URL(fileURLWithPath: CommandLine.arguments[1])).run()
  }
}
