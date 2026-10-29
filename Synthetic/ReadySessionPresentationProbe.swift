// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

private enum Failure:Error{case check(String)}
@main private struct ReadySessionPresentationProbe {
  static func main()throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),helper=root.appendingPathComponent("installation/program"),shim=root.appendingPathComponent("presentation.dylib")
    let hash=CommandLine.arguments[2]
    var checks=[String:Bool](),managers=[SessionManager]()
    func check(_ value:Bool,_ label:String)throws{guard value else{throw Failure.check(label)};checks[label]=true}
    func spin(_ condition:()->Bool,timeout:TimeInterval=5)throws{let deadline=Date().addingTimeInterval(timeout);while !condition()&&Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))};if !condition(){throw Failure.check("deadline")}}
    func make(_ name:String)->(SessionManager,Game,GameVariant,URL){
      let directory=root.appendingPathComponent("data-"+name),paths=LauncherPaths(root:directory),report=root.appendingPathComponent(name+".json")
      let variant=GameVariant(id:"native",platform:.macOS,architecture:.arm64,executable:helper.path,installationRoot:helper.deletingLastPathComponent().path,arguments:[report.path,"100"],installed:true)
      let game=Game(id:name,store:.local,storeID:name,title:"Own finite presentation helper",variants:[variant])
      let manager=SessionManager(paths:paths,project:root);managers.append(manager);return(manager,game,variant,report)
    }
    func cap(stop:@escaping()->Void)->SessionGamePresentation{.init(environment:["READY_HOSTED_GAME_SERVICE":"local.ready.own-fixture","READY_HOSTED_GAME_NONCE":"fixture-nonce","MTL_HUD_ENABLED":"0"],shim:shim,shimSHA256:hash,keepLauncherWindow:true,stop:stop)}
    defer{managers.forEach{$0.quit()}}
    do {
      let(m,g,v,report)=make("default");var started=false,finished=false,hooks=0
      m.onWillLaunch={hooks+=1};m.onFinish={_ in finished=true}
      m.start(game:g,variant:v,profile:UUID()){if case .success=$0{started=true}}
      try spin{finished};try check(started&&hooks==1,"default-lifecycle-launch-hook-unchanged")
      let data=try JSONSerialization.jsonObject(with:Data(contentsOf:report))as![String:Any]
      try check(data["overlay"]as?Bool==true&&data["presentation"]as?Bool==false,"default-overlay-preserved-without-experiment")
    }
    do {
      let(m,g,v,report)=make("hosted");var ready=false,started=false,finished=false,stops=0,stopMain=false,stopAfterProducer=false,hookAfterReady=false
      let owned=cap{stops+=1;stopMain=Thread.isMainThread;stopAfterProducer=FileManager.default.fileExists(atPath:report.path+".ended")}
      m.preparePresentation={_,_,_,completion in
        DispatchQueue.main.asyncAfter(deadline:.now()+0.03){ready=true;completion(.success(owned));completion(.success(owned))}
      }
      m.onWillLaunch={hookAfterReady=ready&&m.keepsLauncherWindow}
      m.onFinish={_ in finished=true}
      m.start(game:g,variant:v,profile:UUID()){if case .success=$0{started=true}}
      try spin{finished}
      let data=try JSONSerialization.jsonObject(with:Data(contentsOf:report))as![String:Any]
      try check(started&&hookAfterReady,"async-presentation-ready-precedes-keeper-launch")
      try check(data["presentation"]as?Bool==true&&data["overlay"]as?Bool==false&&data["hud"]as?String=="0","keeper-injects-only-pinned-presentation-and-disables-guest-overlay-HUD")
      try check(stops==1 && stopMain && stopAfterProducer && !m.running,"presentation-stops-once-on-main-after-producer-quiescent")
    }
    do {
      let(m,g,v,report)=make("cancelled");var reply:((Result<SessionGamePresentation?,Error>)->Void)?,failed=false,stops=0
      m.preparePresentation={_,_,_,completion in reply=completion}
      m.start(game:g,variant:v,profile:UUID()){if case .failure=$0{failed=true}}
      try spin{reply != nil};m.quit();try spin{failed && !m.running}
      let late=cap{stops+=1};reply?(.success(late));reply?(.success(late));try spin{stops==1}
      try check(!FileManager.default.fileExists(atPath:report.path)&&stops==1,"cancelled-preparation-never-spawns-and-stops-late-cap-once")
    }
    do {
      let(m,g,v,report)=make("bad-env");var failed=false,stops=0
      m.preparePresentation={_,_,_,reply in reply(.success(.init(environment:["SteamAppId":"untrusted"],shim:shim,shimSHA256:hash,keepLauncherWindow:true,stop:{stops+=1})))}
      m.start(game:g,variant:v,profile:UUID()){if case .failure=$0{failed=true}}
      try spin{failed};try check(stops==1 && !m.running && !FileManager.default.fileExists(atPath:report.path),"presentation-cannot-override-steam-or-other-reserved-environment")
    }
    do {
      let(m,g,v,report)=make("timeout");var reply:((Result<SessionGamePresentation?,Error>)->Void)?,failed=false,stops=0,ticks=0
      let timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){_ in ticks+=1};defer{timer.invalidate()}
      m.preparePresentation={_,_,_,completion in reply=completion}
      m.start(game:g,variant:v,profile:UUID()){if case .failure=$0{failed=true}}
      try spin({failed},timeout:18)
      let late=cap{stops+=1};reply?(.success(late));try spin{stops==1}
      try check(ticks>=100 && !m.running && !FileManager.default.fileExists(atPath:report.path),"real-15-second-presentation-deadline-keeps-main-responsive-and-stops-late-success")
    }
    print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"count":checks.count,"fixtureOnly":true,"actualGameAccountOrSDKUsed":false,"realWindowOrFullscreenUsed":false],options:[.sortedKeys]),as:UTF8.self))
  }
}
