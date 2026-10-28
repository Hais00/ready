// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin
import LauncherCore

private enum TestFailure:Error {case check(String)}
@MainActor private final class LocationSuite {
  let root:URL
  let source:URL
  let state:URL
  let runtime:URL
  let tools:URL
  var checks=[String:Bool]()
  init(root:URL,source:URL)throws {
    self.root=root;self.source=source;state=root.appendingPathComponent("data");runtime=root.appendingPathComponent("engine")
    tools=root.appendingPathComponent("components/tools-version")
    for path in [state,runtime,tools]{try directory(path)}
  }
  func directory(_ path:URL)throws {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
  func write(_ data:Data,_ path:URL,mode:mode_t=0o600)throws {
    try directory(path.deletingLastPathComponent())
    var info=stat();if lstat(path.path,&info)==0,info.st_mode&S_IFMT==S_IFREG{guard chmod(path.path,0o600)==0 else{throw TestFailure.check("fixture writable")}}
    try data.write(to:path);guard chmod(path.path,mode)==0 else{throw TestFailure.check("fixture permission")}
  }
  func json(_ object:[String:Any],_ path:URL,mode:mode_t=0o600)throws {try write(JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),path,mode:mode)}
  func sha(_ path:URL)throws->String {SHA256.hash(data:try Data(contentsOf:path)).map{String(format:"%02x",$0)}.joined()}
  func check(_ condition:Bool,_ name:String)throws {guard condition else{throw TestFailure.check(name)};checks[name]=true}
  func reject(_ name:String,_ action:()throws->Void)throws {var refused=false;do{try action()}catch{refused=true};try check(refused,name)}
  var selector:URL {state.appendingPathComponent("Components/StoreBridge/selected.json")}
  var manifest:URL {tools.appendingPathComponent("manifest.json")}
  func select(_ raw:String?=nil,_ hash:String?=nil)throws {
    try json(["schema":1,"kind":"ready-store-tools-location-v1","toolsRoot":raw ?? tools.path,"manifestSHA256":try hash ?? sha(manifest)],selector)
  }
  func resolve(_ env:[String:String]=[:])throws->URL {try StoreToolsLocation.resolve(stateRoot:state,runtimeRoot:runtime,environment:env)}
  func header(_ local:Any=true,_ binary:Any=false,_ schema:Any=1)throws {
    try json(["schema":schema,"kind":"ready-local-steam-tools-v1","localOnly":local,"binaryDistributionApproved":binary,"files":[:]],manifest,mode:0o444)
  }
  func native(_ base:URL,fixture:Bool=false)throws->URL {
    let version=base.appendingPathComponent("versions/first")
    try directory(version)
    let library=root.appendingPathComponent("Steam.AppBundle/Contents/MacOS/steamclient.dylib")
    try write(Data("Synthetic code metadata; never loaded".utf8),library)
    let host=root.appendingPathComponent("fake-host");try write(Data("Never executed".utf8),host,mode:0o700)
    let assets=try Dictionary(uniqueKeysWithValues:["host","library","discoveryLibrary","sdk","fsAdapter","ipcAdapter","lookupAdapter"].map{key -> (String,[String:String]) in
      let path=key=="host" ? host:library;return(key,["path":path.path,"sha256":try sha(path)])
    })
    let binding=version.appendingPathComponent("binding.json")
    try json(["schema":1,"kind":"ready-steam-native-host-binding-v1","fixtureOnly":fixture,"assets":assets,"extraFiles":[]],binding)
    try json(["schema":1,"kind":"ready-native-steam-host-selection-v1","manifestPath":"versions/first/binding.json","manifestSHA256":try sha(binding)],base.appendingPathComponent("selected.json"))
    return binding
  }
  func pump(_ condition:()->Bool)throws {
    let deadline=Date().addingTimeInterval(8)
    while !condition()&&Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    guard condition()else{throw TestFailure.check("process deadline")}
  }
  func run()throws {
    let legacy=runtime.appendingPathComponent("Tools/StoreBridge")
    try check(try resolve().path==legacy.path,"absent-selector-legacy-fallback")
    let runtimeAlias=root.appendingPathComponent("engine-alias");try FileManager.default.createSymbolicLink(at:runtimeAlias,withDestinationURL:runtime)
    try check(try StoreToolsLocation.resolve(stateRoot:root.appendingPathComponent("missing-state"),runtimeRoot:runtimeAlias,environment:[:]).path==legacy.path,"legacy-missing-tools-canonicalize-existing-engine-alias")
    try check(try StoreToolsLocation.resolve(stateRoot:root.appendingPathComponent("missing-data"),runtimeRoot:runtime,environment:[:]).path==legacy.path,"absent-state-root-does-not-create-data")
    try header();try select();try check(try resolve().path==tools.path,"private-selector-resolves-independent-tools")
    let stateAlias=root.appendingPathComponent("data-alias");try FileManager.default.createSymbolicLink(at:stateAlias,withDestinationURL:state)
    try check(try StoreToolsLocation.resolve(stateRoot:stateAlias,runtimeRoot:runtime,environment:[:]).path==tools.path,"data-root-alias-resolved-once")
    try check(try StoreToolsLocation.resolve(stateRoot:stateAlias.appendingPathComponent("not-created/yet"),runtimeRoot:runtime,environment:[:]).path==legacy.path,"missing-data-suffix-keeps-resolved-existing-ancestor")
    let noEngine=root.appendingPathComponent("no-engine")
    try check(try StoreToolsLocation.resolve(stateRoot:state,runtimeRoot:noEngine,environment:[:]).path==tools.path,"selected-tools-do-not-require-engine-installation")
    let explicit=root.appendingPathComponent("explicit-missing")
    try write(Data("bad json".utf8),selector)
    try check(try resolve(["READY_STORE_TOOLS_ROOT":explicit.path]).path==explicit.path,"explicit-root-precedes-broken-selector-without-fallback")
    for value in ["","relative","/tmp/../escape"]{try reject("invalid-explicit-root-"+value){_=try resolve(["READY_STORE_TOOLS_ROOT":value])}}
    let alias=root.appendingPathComponent("tools-alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:tools)
    try check(try resolve(["READY_STORE_TOOLS_ROOT":alias.path]).path==tools.path,"explicit-legacy-alias-frozen-to-canonical-target")
    try check(try resolve(["READY_STORE_TOOLS_ROOT":alias.appendingPathComponent("not-created").path]).path==tools.appendingPathComponent("not-created").path,"explicit-missing-tools-canonicalize-existing-ancestor-alias")
    try reject("malformed-selector-never-legacy-fallback"){_=try resolve()}
    try select();try check(try resolve().path==tools.path,"valid-selector-restored")
    try select(alias.path);try reject("selected-tools-root-alias-rejected"){_=try resolve()};try select()
    try select(nil,String(repeating:"0",count:64));try reject("manifest-digest-mismatch-rejected"){_=try resolve()};try select()
    try json(["schema":true,"kind":"ready-store-tools-location-v1","toolsRoot":tools.path,"manifestSHA256":try sha(manifest)],selector)
    try reject("boolean-selector-schema-rejected"){_=try resolve()};try select()
    try json(["schema":2,"kind":"ready-store-tools-location-v1","toolsRoot":tools.path,"manifestSHA256":try sha(manifest)],selector)
    try reject("unknown-selector-schema-rejected"){_=try resolve()};try select()
    chmod(selector.path,0o644);try reject("public-selector-permissions-rejected"){_=try resolve()};chmod(selector.path,0o600)
    chmod(selector.deletingLastPathComponent().path,0o755);try reject("nonprivate-selector-directory-rejected"){_=try resolve()};chmod(selector.deletingLastPathComponent().path,0o700)
    let original=root.appendingPathComponent("original-selector");try FileManager.default.moveItem(at:selector,to:original);try FileManager.default.createSymbolicLink(at:selector,withDestinationURL:original)
    try reject("selector-symlink-rejected"){_=try resolve()};try FileManager.default.removeItem(at:selector);try FileManager.default.moveItem(at:original,to:selector)
    for (label,local,binary,schema) in [("nonlocal",false,false,1),("distribution-claim",true,true,1)] {
      try header(local,binary,schema);try select();try reject("manifest-"+label+"-rejected"){_=try resolve()}
    }
    try header(1,false);try select();try reject("numeric-localOnly-is-not-boolean"){_=try resolve()}
    try header(true,0);try select();try reject("numeric-binaryApproved-is-not-boolean"){_=try resolve()}
    try header(true,false,true);try select();try reject("boolean-manifest-schema-rejected"){_=try resolve()}
    try header();try select();chmod(manifest.path,0o666);try reject("writable-manifest-rejected"){_=try resolve()};chmod(manifest.path,0o444)
    let savedManifest=root.appendingPathComponent("saved-manifest");try FileManager.default.moveItem(at:manifest,to:savedManifest);try FileManager.default.createSymbolicLink(at:manifest,withDestinationURL:savedManifest)
    try reject("manifest-symlink-rejected"){_=try resolve()};try FileManager.default.removeItem(at:manifest);try FileManager.default.moveItem(at:savedManifest,to:manifest)
    try FileManager.default.removeItem(at:selector);guard mkfifo(selector.path,0o600)==0 else{throw TestFailure.check("fifo fixture")}
    try reject("selector-fifo-rejected-without-blocking"){_=try resolve()};try FileManager.default.removeItem(at:selector);try select()

    let dotnet=tools.appendingPathComponent("dotnet/dotnet"),helper=tools.appendingPathComponent("SteamBridge/ReadySteamBridge.dll")
    try write(Data("Locator fixture only".utf8),dotnet,mode:0o700);try write(Data("DLL metadata fixture only".utf8),helper)
    let command=SteamClientSession.installedCommand(project:root,runtimeRoot:runtime,stateRoot:state)
    try check(command==[dotnet.path,helper.path,"--service"],"persistent-client-uses-selected-component-root")
    try write(Data("corrupt".utf8),selector)
    try check(SteamClientSession.installedCommand(project:root,runtimeRoot:runtime,stateRoot:state)==nil,"persistent-client-invalid-selector-fails-closed");try select()
    try FileManager.default.removeItem(at:dotnet);try directory(dotnet)
    try check(SteamClientSession.installedCommand(project:root,runtimeRoot:runtime,stateRoot:state)==nil,"persistent-client-rejects-executable-directory")
    try FileManager.default.removeItem(at:dotnet);try write(Data("Locator fixture only".utf8),dotnet,mode:0o700)

    let oldNative=legacy.appendingPathComponent("NativeSteamHost/480"),nativeState=state.appendingPathComponent("Components/SteamNativeHost/480")
    let legacyBinding=try native(oldNative)
    func load(_ environment:[String:String]=[:])throws->SteamNativeHostProcess.Binding {try SteamNativeHostSelection.load(runtimeRoot:runtime,gameID:"480",stateRoot:state,environment:environment)}
    try check(try load().manifestURL==legacyBinding,"native-legacy-independent-of-selected-store-tools")
    let selectedBinding=try native(nativeState)
    try check(try load().manifestURL==selectedBinding,"native-user-component-precedes-engine-legacy")
    try check(try SteamNativeHostSelection.load(runtimeRoot:runtime,gameID:"480",stateRoot:stateAlias,environment:[:]).manifestURL==selectedBinding,"native-data-root-alias-resolved-once")
    let nativeSelector=nativeState.appendingPathComponent("selected.json"),nativeSaved=try Data(contentsOf:nativeSelector)
    try write(Data("invalid".utf8),nativeSelector)
    try reject("invalid-native-selector-never-legacy-fallback"){_=try load()}
    try check(try load(["READY_STEAM_NATIVE_BINDING":legacyBinding.path,"READY_STEAM_NATIVE_BINDING_SHA256":sha(legacyBinding)]).manifestURL==legacyBinding,"explicit-native-binding-precedes-invalid-user-selector")
    for environment in [["READY_STEAM_NATIVE_BINDING":legacyBinding.path],["READY_STEAM_NATIVE_BINDING_SHA256":try sha(legacyBinding)]] {
      try reject("partial-native-override-rejected-"+environment.keys.first!){_=try load(environment)}
    }
    try write(nativeSaved,nativeSelector)
    for relative in ["../binding.json","/absolute/binding.json","versions//binding.json","versions/./binding.json",""] {
      try json(["schema":1,"kind":"ready-native-steam-host-selection-v1","manifestPath":relative,"manifestSHA256":try sha(selectedBinding)],nativeSelector)
      try reject("native-relative-path-traversal-rejected-"+relative){_=try load()}
    }
    try write(nativeSaved,nativeSelector);chmod(nativeSelector.path,0o644);try reject("public-native-selector-rejected"){_=try load()};chmod(nativeSelector.path,0o600)
    try json(["schema":true,"kind":"ready-native-steam-host-selection-v1","manifestPath":"versions/first/binding.json","manifestSHA256":try sha(selectedBinding)],nativeSelector)
    try reject("native-boolean-schema-rejected"){_=try load()};try write(nativeSaved,nativeSelector)
    let fixture=try native(root.appendingPathComponent("fixture-native"),fixture:true)
    try reject("fixture-native-binding-rejected"){_=try load(["READY_STEAM_NATIVE_BINDING":fixture.path,"READY_STEAM_NATIVE_BINDING_SHA256":sha(fixture)])}
    // Restore assets' bytes and hashes (same exact synthetic data) and remove only
    // this owned user selection to exercise the explicit legacy tools override.
    try FileManager.default.removeItem(at:nativeSelector)
    let alternate=root.appendingPathComponent("alternate-tools"),alternateBinding=try native(alternate.appendingPathComponent("NativeSteamHost/480"))
    let alternateAlias=root.appendingPathComponent("alternate-alias");try FileManager.default.createSymbolicLink(at:alternateAlias,withDestinationURL:alternate)
    try check(try load(["READY_STORE_TOOLS_ROOT":alternateAlias.path]).manifestURL==alternateBinding,"native-explicit-legacy-tools-alias-resolved-once")

    let code=root.appendingPathComponent("code"),bridge=code.appendingPathComponent("StoreBridge")
    try directory(bridge);try FileManager.default.copyItem(at:source.appendingPathComponent("StoreBridge/supervisor.py"),to:bridge.appendingPathComponent("supervisor.py"))
    try write(Data("import json,os,sys\nr=json.loads(sys.stdin.readline())\nprint(json.dumps({'type':'result','toolsRoot':os.environ.get('READY_STORE_TOOLS_ROOT'),'dataRoot':os.environ.get('READY_DATA_ROOT')}),flush=True)\n".utf8),bridge.appendingPathComponent("bridge.py"))
    let client=StoreClient(project:code,stateRoot:state,runtimeRoot:runtime,credentialAccess:.init(load:{_,_ in nil},save:{_,_,_ in}))
    var event:[String:Any]?
    client.request(operation:"capabilities",store:.steam,profile:UUID()){event=$0}
    try pump{event != nil && !client.hasActiveRequests}
    try check(event?["toolsRoot"]as?String==tools.path&&event?["dataRoot"]as?String==state.path,"bridge-process-receives-canonical-component-root-and-state-root")
    try write(Data("bad".utf8),selector);event=nil
    client.request(operation:"capabilities",store:.steam,profile:UUID()){event=$0}
    try pump{event != nil && !client.hasActiveRequests}
    try check(event?["type"]as?String=="error","bridge-invalid-selector-does-not-launch-fallback")
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"count":checks.count,"checks":checks,"realAccountUsed":false,"realKeychainUsed":false,"ValveOrSDKExecuted":false,"fixtureOnly":true],options:[.sortedKeys]),as:UTF8.self))
  }
}
@main private struct ReadyStoreToolsLocationProbe {
  @MainActor static func main(){do{try LocationSuite(root:URL(fileURLWithPath:CommandLine.arguments[1]),source:URL(fileURLWithPath:CommandLine.arguments[2])).run()}catch{fputs("Component locator fixture failed: \(error)\n",stderr);exit(1)}}
}
