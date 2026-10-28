// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
@main struct ReadySteamDownloadsProbe {
  @MainActor static func main()throws{
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),profile=UUID()
    let credentials=try JSONSerialization.data(withJSONObject:["username":"fixture_account","refresh_token":"fixture_secret"])
    let access=StoreClient.CredentialAccess(load:{_,_ in credentials},save:{_,_,_ in})
    let client=StoreClient(project:root.appendingPathComponent("project"),stateRoot:root.appendingPathComponent("data"),credentialAccess:access)
    let queue=SteamDownloads(profile:profile,client:client)
    var installed=0;queue.onInstalled={_ in installed+=1}
    func spin(_ name:String,_ condition:()->Bool)throws{let end=Date().addingTimeInterval(12);while !condition()&&Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))};if !condition(){throw NSError(domain:name,code:1)}}
    let variant=GameVariant(id:"windows",platform:.windows)
    let game=Game(id:"steam:123",store:.steam,storeID:"123",title:"Download fixture",variants:[variant])
    queue.restore();queue.enqueue(game:game,variant:variant,installation:root.appendingPathComponent("install"))
    try spin("running"){queue.snapshot.first?.state=="running"}
    let id=queue.snapshot[0].id
    queue.control(id,action:"pause");try spin("paused"){queue.snapshot.first?.state=="paused"}
    let pausedBytes=queue.snapshot[0].completed ?? 0
    queue.control(id,action:"resume");try spin("completed"){queue.snapshot.first?.state=="completed"}
    try spin("installed_callback"){installed==1}
    let broken=Game(id:"steam:999",store:.steam,storeID:"999",title:"Terminal error fixture",variants:[variant])
    queue.enqueue(game:broken,variant:variant,installation:root.appendingPathComponent("broken"))
    try spin("terminal_without_dto"){queue.snapshot.contains{$0.gameID=="999"&&$0.state=="failed"}}
    let settle=Date().addingTimeInterval(0.4);while Date()<settle{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    let state=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("data/fixture-jobs.json")))as![String:[String:Any]]
    let failed=state.values.first{$0["gameID"]as?String=="999"}!
    queue.stop();client.cancelAll()
    let checks:[String:Bool]=["pauseAndResumeSameJob":pausedBytes<1000,"verifiedCompletionDeliveredOnce":installed==1,"terminalErrorWithoutDTOCannotLoop":failed["runs"]as?Int==1,"completedFilesRetained":FileManager.default.fileExists(atPath:root.appendingPathComponent("install/game.exe").path)]
    print(String(data:try JSONSerialization.data(withJSONObject:["passed":checks.values.allSatisfy{$0},"checks":checks],options:.sortedKeys),encoding:.utf8)!)
    if !checks.values.allSatisfy({$0}){exit(1)}
  }
}
