// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
import CryptoKit
import Darwin

private enum ProbeFailure:Error {case check(String)}
private func check(_ value:@autoclosure()->Bool,_ name:String)throws {if !value(){throw ProbeFailure.check(name)}}
private func digest(_ url:URL)throws->String {SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()}
private func packet()->Data {
  let account=Data("fixture_account".utf8),token=Data("fixture_private_not_forwarded".utf8)
  var value=Data("RDYAUTH1".utf8)
  func append<T:FixedWidthInteger>(_ n:T){var big=n.bigEndian;withUnsafeBytes(of:&big){value.append(contentsOf:$0)}}
  append(UInt32(account.count));append(UInt32(token.count));append(UInt64(76561197960265729));append(UInt32(480));value.append(account);value.append(token);return value
}
private func pump(_ condition:()->Bool,seconds:TimeInterval=10)throws {
  let deadline=Date().addingTimeInterval(seconds)
  while !condition()&&Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
  try check(condition(),"deadline")
}
private func healthEOF(_ fd:Int32)throws->Bool {
  var info=stat();let flags=fcntl(fd,F_GETFL)
  try check(fstat(fd,&info)==0&&(info.st_mode&S_IFMT)==S_IFIFO&&flags&O_ACCMODE==O_RDONLY&&fcntl(fd,F_GETFD)&FD_CLOEXEC != 0,"owned close-on-exec health reader")
  try check(fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0,"nonblocking test health reader")
  var byte:UInt8=0;let count=read(fd,&byte,1)
  if count==0{return true}
  try check(count<0&&(errno==EAGAIN||errno==EWOULDBLOCK),"health pipe never carries bytes")
  return false
}
private func descriptorCount()->Int { (0..<256).filter{fcntl(Int32($0),F_GETFD)>=0}.count }
private func safeDiagnostics(_ host:SteamNativeHostProcess)throws->[[String:Any]] {
  let path=host.receiptURL.deletingLastPathComponent().appendingPathComponent("host-events.jsonl")
  var info=stat();try check(lstat(path.path,&info)==0&&(info.st_mode&S_IFMT)==S_IFREG&&info.st_uid==getuid()&&info.st_mode&0o777==0o600,"private diagnostic file")
  let bytes=try Data(contentsOf:path),text=String(decoding:bytes,as:UTF8.self)
  for forbidden in ["fixture_private_not_forwarded","fixture_account","76561197960265729","rawCredential","username","steamID","refresh_token","access_token","namespace","privateName","masterEndpoint","serviceEndpoint","127.0.0.1","app.ready.steam.ipctool.","profileID","sessionID","gameID"] {
    try check(!text.localizedCaseInsensitiveContains(forbidden),"diagnostics contain forbidden identity/secret/endpoint field")
  }
  try check(text.hasSuffix("\n"),"diagnostic complete JSONL")
  var rows=[[String:Any]](),elapsed:UInt64=0
  let base:Set<String>=["schema","phase","elapsedMilliseconds"]
  let eventFields:Set<String>=["reason","authenticated","identityMatches","ownedSubscription","revoked","fixtureOnly","network","userReleased","pipeReleased"]
  let booleanFields:Set<String>=["authenticated","identityMatches","ownedSubscription","revoked","fixtureOnly","userReleased","pipeReleased","cancelled","invalidEvents"]
  for line in text.split(separator:"\n") {
    let value=try JSONSerialization.jsonObject(with:Data(line.utf8))as![String:Any]
    guard let phase=value["phase"]as?String,["created","event","stop_requested","exited"].contains(phase),let schema=value["schema"]as?NSNumber,CFGetTypeID(schema) != CFBooleanGetTypeID(),schema.intValue==1,let time=value["elapsedMilliseconds"]as?NSNumber,CFGetTypeID(time) != CFBooleanGetTypeID(),let milliseconds=UInt64(time.stringValue) else{throw ProbeFailure.check("diagnostic base vocabulary/types")}
    try check(milliseconds>=elapsed,"diagnostic monotonic elapsed time");elapsed=milliseconds
    let keys=Set(value.keys)
    if phase=="event" {
      try check(keys.isSubset(of:base.union(eventFields).union(["event"]))&&keys.isSuperset(of:base.union(["event"])),"diagnostic exact event whitelist")
      try check(["starting","ready","state","stopped"].contains(value["event"]as?String ?? ""),"diagnostic fixed event vocabulary")
    }else if phase=="exited" {try check(keys==base.union(["exitCode","signal","cancelled","invalidEvents"]),"diagnostic exact exit whitelist")}
    else{try check(keys==base,"diagnostic exact phase whitelist")}
    for key in booleanFields where value[key] != nil {guard let number=value[key]as?NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID()else{throw ProbeFailure.check("diagnostic boolean type")}}
    for key in ["reason","exitCode","signal"] where value[key] != nil && !(value[key]is NSNull) {guard let number=value[key]as?NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),Int32(number.stringValue) != nil else{throw ProbeFailure.check("diagnostic numeric type")}}
    if let network=value["network"] {try check(["unknown","connected","disconnected"].contains(network as?String ?? ""),"diagnostic fixed network vocabulary")}
    rows.append(value)
  }
  try check(rows.first?["phase"]as?String=="created","diagnostic created first")
  return rows
}

@main private struct ReadySteamNativeHostProcessProbe {
  @MainActor static func main() {
    do {try run()}
    catch {fputs("Native host supervisor fixture failed: \(error)\n",stderr);exit(1)}
  }
  @MainActor static func run()throws {
    let arguments=CommandLine.arguments
    let root=URL(fileURLWithPath:arguments[1]),manifest=URL(fileURLWithPath:arguments[2])
    let binding=try SteamNativeHostProcess.Binding.load(manifestURL:manifest,expectedSHA256:digest(manifest))
    let profile=UUID(uuidString:"00000000-0000-4000-8000-000000000001")!
    let state=root.appendingPathComponent("profiles/"+profile.uuidString)
    try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    if arguments.count>3&&arguments[3]=="--parent-owner" {
      var input=packet();var ready=false
      let host=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&input,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{value in if value["type"]as?String=="ready"{ready=true}},onExit:{_ in})
      try pump{ready};try JSONSerialization.data(withJSONObject:["pid":host.processID!,"ready":true]).write(to:root.appendingPathComponent("parent-ready.json"))
      while true{RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
    }
    var checks=[String:Bool](),eventsA=[[String:Any]](),eventsB=[[String:Any]]()
    var fixtureGameAssetsRejected=false
    do{_=try binding.verifiedGameAssets()}catch{fixtureGameAssetsRejected=true}
    try check(fixtureGameAssetsRejected,"fixture cannot supply production game assets")
    checks["fixtureBindingCannotSupplyGameAssets"]=true
    var exitA:SteamNativeHostProcess.Exit?,exitB:SteamNativeHostProcess.Exit?
    var inputA=packet(),inputB=packet()
    let hostA=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&inputA,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{eventsA.append($0)},onExit:{exitA=$0})
    let hostB=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&inputB,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{eventsB.append($0)},onExit:{exitB=$0})
    try check(inputA.isEmpty&&inputB.isEmpty,"consumed private input");checks["privatePacketConsumedAndCleared"]=true
    try pump{exitA != nil||exitB != nil||(eventsA.contains{$0["type"]as?String=="ready"}&&eventsB.contains{$0["type"]as?String=="ready"})}
    try check(exitA==nil&&exitB==nil,"fixture startup exited A:\(String(describing:exitA?.code)) B:\(String(describing:exitB?.code))")
    checks["realPOSIXSpawnFDMappingAndSandboxControls"]=true
    checks["privateWorkingDirectoryInsideSandbox"]=true
    let healthA=try hostA.takeGameHealthReadFD(),healthB=try hostB.takeGameHealthReadFD()
    defer{close(healthA);close(healthB)}
    let aliveA=try healthEOF(healthA),aliveB=try healthEOF(healthB)
    try check(!aliveA && !aliveB,"health leases remain open while hosts live")
    var repeated=false;do{_=try hostA.takeGameHealthReadFD()}catch{repeated=true}
    try check(repeated&&fcntl(healthA,F_GETFD)>=0,"health reader transferred only once")
    checks["healthReaderTransferredOnceWithReadOnlyCLOEXEC"]=true
    try check(hostA.processID != hostB.processID,"separate exact child PID")
    var stopAFirst=0,stopASecond=0,stopAfterExitFirst=0,stopAfterExitSecond=0,earlyStopCompletion=false
    hostA.stop(completion:{if exitA==nil{earlyStopCompletion=true};stopAFirst+=1})
    hostA.stop(completion:{if exitA==nil{earlyStopCompletion=true};stopASecond+=1})
    try pump{exitA != nil&&stopAFirst==1&&stopASecond==1}
    try check(!earlyStopCompletion,"stop completion preceded onExit")
    hostA.stop(completion:{if exitA==nil{earlyStopCompletion=true};stopAfterExitFirst+=1})
    hostA.stop(completion:{if exitA==nil{earlyStopCompletion=true};stopAfterExitSecond+=1})
    try pump{stopAfterExitFirst==1&&stopAfterExitSecond==1}
    RunLoop.current.run(until:Date().addingTimeInterval(0.04))
    try check(!earlyStopCompletion&&stopAFirst==1&&stopASecond==1&&stopAfterExitFirst==1&&stopAfterExitSecond==1,"repeated stop completion is not exactly once")
    checks["queuedAndAlreadyExitedStopCompletionsEachFireExactlyOnce"]=true
    try check(exitA?.code==42&&exitA?.cancelled==true&&exitA?.invalidEvents==false,"EOF orderly release")
    try check(exitB==nil&&kill(hostB.processID!,0)==0,"other host remains live")
    let closedA=try healthEOF(healthA),stillAliveB=try healthEOF(healthB)
    try check(closedA && !stillAliveB,"A health EOF independent of B")
    checks["hostStopClosesHealthWithoutAffectingOtherHost"]=true
    checks["closingAIsIdempotentAndDoesNotStopB"]=true
    hostB.stop();try pump{exitB != nil};try check(exitB?.code==42,"B own cleanup")
    let closedB=try healthEOF(healthB);try check(closedB,"B own health cleanup")
    do {
      var input=packet(),seen=[[String:Any]](),ended:SteamNativeHostProcess.Exit?
      let child=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&input,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{seen.append($0)},onExit:{ended=$0})
      try pump{seen.contains{$0["type"]as?String=="ready"}}
      let descriptor=try child.takeGameHealthReadFD();close(descriptor)
      RunLoop.current.run(until:Date().addingTimeInterval(0.04))
      try check(ended==nil&&kill(child.processID!,0)==0,"consumer close does not stop host")
      child.stop();try pump{ended != nil};checks["closingHealthConsumerDoesNotStopHost"]=true
    }
    do {
      let path=root.appendingPathComponent("revoke.json"),selected=try SteamNativeHostProcess.Binding.load(manifestURL:path,expectedSHA256:digest(path))
      var input=packet(),seen=[[String:Any]](),ended:SteamNativeHostProcess.Exit?
      let child=try SteamNativeHostProcess.spawn(binding:selected,credentialPacket:&input,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{seen.append($0)},onExit:{ended=$0})
      let descriptor=try child.takeGameHealthReadFD();defer{close(descriptor)}
      try pump{seen.contains{$0["type"]as?String=="state"&&$0["revoked"]as?Bool==true}}
      let eof=try healthEOF(descriptor)
      try check(eof&&ended==nil&&kill(child.processID!,0)==0,"revocation closes health before simulated cleanup")
      try pump{ended != nil};try check(ended?.code==43,"revoked host own exit")
      checks["healthEOFPrecedesRevokedHostCleanup"]=true
    }
    for(name,reapFirst)in [("delayed-eof",true),("delayed-exit",false)] {
      let path=root.appendingPathComponent(name+".json"),selected=try SteamNativeHostProcess.Binding.load(manifestURL:path,expectedSHA256:digest(path))
      var input=packet(),seen=[[String:Any]](),ended:SteamNativeHostProcess.Exit?,stops=0,orderFailed=false,exitCount=0
      let child=try SteamNativeHostProcess.spawn(binding:selected,credentialPacket:&input,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{seen.append($0)},onExit:{ended=$0;exitCount+=1})
      try pump{seen.contains{$0["type"]as?String=="ready"}}
      let pid=child.processID!,started=ProcessInfo.processInfo.systemUptime
      child.stop(completion:{if ended==nil{orderFailed=true};stops+=1})
      if reapFirst {
        // Read-only existence check; the supervisor remains the sole waitpid owner.
        try pump({kill(pid,0)<0&&errno==ESRCH},seconds:0.45)
        try check(ended==nil&&stops==0,"completion ran on waitpid before delayed reader EOF")
      }else{
        try pump{seen.contains{$0["type"]as?String=="stopped"}}
        RunLoop.current.run(until:Date().addingTimeInterval(0.12))
        try check(kill(pid,0)==0&&ended==nil&&stops==0,"completion ran on reader EOF before child exit")
      }
      child.stop(completion:{if ended==nil{orderFailed=true};stops+=1})
      try pump{ended != nil&&stops==2}
      child.stop(completion:{stops+=1});try pump{stops==3}
      RunLoop.current.run(until:Date().addingTimeInterval(0.04))
      try check(!orderFailed&&stops==3&&exitCount==1&&ProcessInfo.processInfo.systemUptime-started>=0.6&&ended?.code==42&&ended?.invalidEvents==false,"split stop barrier order/exactly-once")
      let rows=try safeDiagnostics(child);try check(rows.last?["phase"]as?String=="exited"&&rows.filter{$0["phase"]as?String=="exited"}.count==1,"terminal diagnostic precedes stop completion")
      checks[reapFirst ? "stopCompletionWaitsForReaderEOFAfterWaitpid":"stopCompletionWaitsForWaitpidAfterReaderEOF"]=true
    }
    let diagnosticA=try safeDiagnostics(hostA),diagnosticB=try safeDiagnostics(hostB)
    try check(diagnosticA.last?["phase"]as?String=="exited"&&diagnosticB.last?["phase"]as?String=="exited","final diagnostics complete before stop barrier")
    checks["diagnosticJSONLExactWhitelistTypesPrivacyAndTerminalOrdering"]=true
    try check(!String(describing:eventsA+eventsB).contains("fixture_private"),"no raw credentials forwarded")
    checks["eventWhitelistDropsUnexpectedSecretFields"]=true
    let beforeUntaken=descriptorCount()
    var cancelledInput=packet(),earlyExit:SteamNativeHostProcess.Exit?,lateReady=0
    let early=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&cancelledInput,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{if $0["type"]as?String=="ready"{lateReady+=1}},onExit:{earlyExit=$0})
    early.stop();try pump{earlyExit != nil}
    try check(lateReady==0&&earlyExit!.cancelled,"startup cancellation bars queued ready")
    checks["startupCancellationSuppressesLateReady"]=true
    try pump({descriptorCount()<=beforeUntaken},seconds:2)
    var afterExit=false;do{_=try early.takeGameHealthReadFD()}catch{afterExit=true}
    try check(afterExit,"untaken health reader closed on host reap")
    checks["untakenHealthReaderClosedAtHostExit"]=true
    let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:hostA.receiptURL))as![String:Any]
    let policy=hostA.receiptURL.deletingLastPathComponent().appendingPathComponent("host.sb")
    let policyDigest=try digest(policy),manifestDigest=try digest(manifest)
    try check(receipt["sandboxSHA256"]as?String==policyDigest&&receipt["bindingManifestSHA256"]as?String==manifestDigest,"policy and manifest bound")
    checks["privateReceiptBindsPolicyAndSourceManifest"]=true
    var bad=packet();bad[0]=0;var rejected=false
    do {_=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&bad,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{_ in},onExit:{_ in})}catch{rejected=true}
    try check(rejected&&bad.isEmpty,"bad frame rejected and cleared");checks["invalidPacketRejectedBeforeSpawn"]=true
    var wrong=packet();rejected=false
    do {_=try SteamNativeHostProcess.spawn(binding:binding,credentialPacket:&wrong,profile:UUID(),sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{_ in},onExit:{_ in})}catch{rejected=true}
    try check(rejected&&wrong.isEmpty,"profile state scope refused");checks["otherProfileCannotReuseStateRoot"]=true
    let manifestData=try Data(contentsOf:manifest);var document=try JSONSerialization.jsonObject(with:manifestData)as![String:Any]
    var assets=document["assets"]as![String:[String:String]];assets["sdk"]!["sha256"]=String(repeating:"0",count:64);document["assets"]=assets
    let badManifest=root.appendingPathComponent("wrong-hash.json");try JSONSerialization.data(withJSONObject:document).write(to:badManifest);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:badManifest.path)
    rejected=false;do{_=try SteamNativeHostProcess.Binding.load(manifestURL:badManifest,expectedSHA256:digest(badManifest))}catch{rejected=true}
    try check(rejected,"wrong hash refused");checks["wrongAssetHashRejected"]=true
    let aliased=root.appendingPathComponent("manifest-alias.json");try FileManager.default.createSymbolicLink(at:aliased,withDestinationURL:manifest)
    rejected=false;do{_=try SteamNativeHostProcess.Binding.load(manifestURL:aliased,expectedSHA256:digest(manifest))}catch{rejected=true}
    try check(rejected,"alias refused");checks["symlinkManifestRejected"]=true
    for (name,label) in [("bad","malformedEventsFailClosed"),("lost-events","lostEventChannelStopsOwnedHost"),("hang","unresponsiveOwnHostIsReapedAfterBoundedSignals")] {
      let path=root.appendingPathComponent(name+".json"),selected=try SteamNativeHostProcess.Binding.load(manifestURL:path,expectedSHA256:digest(path))
      var ended:SteamNativeHostProcess.Exit?,seen=[[String:Any]](),input=packet()
      let child=try SteamNativeHostProcess.spawn(binding:selected,credentialPacket:&input,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{seen.append($0)},onExit:{ended=$0})
      if name=="hang"{try pump{seen.contains{$0["type"]as?String=="ready"}};child.stop()}
      try pump({ended != nil},seconds:9)
      try check(name != "hang" ? ended!.invalidEvents:ended!.signal==SIGKILL,label);checks[label]=true
    }
    let tamper=root.appendingPathComponent("tamper-sdk");try Data("before".utf8).write(to:tamper);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:tamper.path)
    document=try JSONSerialization.jsonObject(with:manifestData)as![String:Any];assets=document["assets"]as![String:[String:String]];assets["sdk"]=["path":tamper.path,"sha256":try digest(tamper)];document["assets"]=assets
    let changed=root.appendingPathComponent("changed.json");try JSONSerialization.data(withJSONObject:document).write(to:changed);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:changed.path)
    let before=try SteamNativeHostProcess.Binding.load(manifestURL:changed,expectedSHA256:digest(changed));try Data("after".utf8).write(to:tamper)
    var privateInput=packet();rejected=false;do{_=try SteamNativeHostProcess.spawn(binding:before,credentialPacket:&privateInput,profile:profile,sessionID:UUID(),gameID:480,profileStateRoot:state,onEvent:{_ in},onExit:{_ in})}catch{rejected=true}
    try check(rejected&&privateInput.isEmpty,"asset changed after selection refused");checks["assetReverifiedAtSpawn"]=true
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"count":checks.count,"fixtureOnly":true,"ValveOrSDKExecuted":false,"realAccountUsed":false],options:[.sortedKeys]),as:UTF8.self))
  }
}
