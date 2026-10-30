// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

@main struct ReadySteamSessionProbe {
  @MainActor static func main() throws {
    let profile=UUID(), other=UUID()
    let initial=try JSONSerialization.data(withJSONObject:["username":"fixture_account","refresh_token":"fixture_only_secret"])
    var vault=[profile:initial,other:initial], saves=0, failSave=false, checks=[String:Bool]()
    let access=StoreClient.CredentialAccess(load:{id,_ in vault[id]},save:{data,id,_ in if failSave{throw NSError(domain:"FixtureVaultUnavailable",code:1)};vault[id]=data;saves+=1},remove:{id,_ in vault.removeValue(forKey:id)})
    let session=SteamClientSession(profile:profile,command:[CommandLine.arguments[1],CommandLine.arguments[2]],credentialAccess:access)
    var stage="initial_connect"
    func spin(_ condition:()->Bool) throws {
      let end=Date().addingTimeInterval(8)
      while !condition() && Date()<end { _=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
      guard condition() else { throw NSError(domain:"SteamSessionFixtureTimeout_"+stage,code:1) }
    }
    defer{session.stop()}
    session.start();try spin{session.state.online && session.state.accountName=="fixture_account" && session.accountReadyForGame()}
    checks["savedProfileCredentialConnectsWithoutQR"]=session.state.accountName=="fixture_account"
    checks["currentPersonaAndSavedAccountReadyForGame"]=session.accountReadyForGame()
    vault[profile]=try JSONSerialization.data(withJSONObject:["username":"fixture_other","refresh_token":"fixture_only_other"])
    var onlineReply=false
    session.request("fixture_online_before_new_persona"){_ in onlineReply=true};try spin{onlineReply}
    checks["onlineBeforeNewPersonaCannotResumeOldAccount"] = !session.accountReadyForGame() && session.state.accountName=="fixture_account"
    session.request("fixture_new_persona"){_ in};try spin{session.state.accountName=="fixture_other" && session.accountReadyForGame()}
    checks["newPersonaMatchingSavedAccountCanResumeGame"]=session.accountReadyForGame()
    vault[profile]=initial;session.request("fixture_recovered"){_ in};try spin{session.state.accountName=="fixture_account"}
    try spin{session.state.friends.count==1}
    checks["friendsAndActivitySnapshot"]=session.state.friends[0].gameName=="Fixture game"
    session.request("fixture_normalization"){_ in};try spin{session.state.friends.first?.presence=="offline"}
    checks["personaAndEmptyActivityNormalized"]=session.state.presence=="away"&&session.state.friends[0].gameName==nil&&session.state.friends[0].gameID==nil
    var reply=false
    stage="stale_frames"
    session.request("fixture_stale") { _ in reply=true }
    try spin{reply}
    checks["staleGenerationAndProfileEventsIgnored"]=session.state.accountName=="fixture_account"
    stage="manual_offline";session.goOffline();try spin{session.state.connection=="offline"}
    checks["manualOfflinePreservesAccount"]=vault[profile]==initial
    stage="reconnect";session.reconnect();try spin{session.state.online}
    checks["explicitReconnectRestoresOnline"]=true
    stage="restore_missing_service_account";session.request("fixture_missing_server_account"){_ in};try spin{session.state.connection=="offline"&&session.state.reason=="login_incomplete"}
    checks["incompleteStartupPreservesFileAndReportsTransportStage"] = vault[profile]==initial && session.state.connectionResultContext=="transport_cleanup"
    session.reconnect();try spin{session.state.online&&session.accountReadyForGame()}
    checks["manualReconnectReloadsSavedProfileWhenServiceHasNoCredential"] = vault[profile]==initial && session.state.accountName=="fixture_account"
    stage="network_loss";session.request("fixture_network_loss"){_ in}
    try spin{session.state.connection=="reconnecting"}
    checks["networkLossDoesNotForgetCredential"]=vault[profile]==initial
    stage="network_recovered";session.request("fixture_recovered"){_ in};try spin{session.state.online}
    stage="remote_kick";session.request("fixture_remote_kick"){_ in};try spin{session.state.reason=="session_replaced"}
    checks["remoteSessionReplacementKeepsCredentialForExplicitReconnect"]=vault[profile]==initial
    session.reconnect();try spin{session.state.online}
    session.request("fixture_session_expired"){_ in};try spin{session.state.connection=="logged_out"}
    checks["connectionExpiryPreservesSavedRefreshCredential"]=vault[profile]==initial && session.state.steamResult=="Expired" && session.state.connectionResultContext=="logged_off"
    session.reconnect();try spin{session.state.online}
    session.request("fixture_reason_alone"){_ in};try spin{session.state.connection=="offline"}
    checks["reasonStringAloneCannotEraseCredential"]=vault[profile]==initial
    session.reconnect();try spin{session.state.online}
    stage="revocation";session.request("fixture_revoked"){_ in};try spin{vault[profile]==nil}
    checks["revocationInvalidatesOnlyCurrentProfile"]=vault[other]==initial&&session.state.connection=="authorization_required"
    var sawQR=false
    session.onAuthentication={if $0["type"]as?String=="qr"{sawQR=true}}
    stage="qr";session.authenticate();try spin{sawQR}
    failSave=true;session.request("fixture_auth_complete"){_ in}
    try spin{session.state.online && !session.state.warning.isEmpty}
    checks["credentialStorageFailureRemainsVisibleAfterOnline"]=vault[profile]==nil
    failSave=false;sawQR=false
    let cancelledAuth=session.authenticate();try spin{sawQR}
    session.cancel(cancelledAuth);sawQR=false
    session.request("fixture_late_qr"){_ in}
    let settle=Date().addingTimeInterval(0.15)
    while Date()<settle{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    checks["cancelledAuthenticationCannotRedisplayQR"] = !sawQR
    session.authenticate();try spin{sawQR}
    session.logout();try spin{session.state.connection=="logged_out"}
    let end=Date().addingTimeInterval(0.3)
    while Date()<end{_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    checks["lateCredentialAfterLogoutCannotResave"]=vault[profile]==nil&&saves==0
    let empty=SteamClientSession(profile:UUID(),command:[CommandLine.arguments[1],CommandLine.arguments[2]],credentialAccess:access)
    empty.start();try spin{empty.state.connection=="offline"};checks["realSnapshotShapeShowsOfflineWithoutCredential"]=true;empty.stop()
    let stoppedGeneration=empty.generation;empty.cancel(UUID().uuidString)
    checks["lateCancelCannotRestartStoppedService"]=empty.generation==stoppedGeneration && empty.state.connection=="offline"
    let broken=SteamClientSession(profile:other,command:[CommandLine.arguments[1],CommandLine.arguments[2]],credentialAccess:access)
    broken.start();try spin{broken.state.online}
    var inputClosed=false;broken.request("fixture_close_input"){_ in inputClosed=true};try spin{inputClosed}
    var pipeFailure=false;broken.request("snapshot"){event in if event["type"]as?String=="error"{pipeFailure=true}}
    try spin{pipeFailure};checks["closedServicePipeCannotSIGPIPELauncher"]=true;broken.stop()
    checks["allPassed"]=checks.values.allSatisfy{$0}
    print(String(data:try JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys]),encoding:.utf8)!)
    if checks["allPassed"] != true{exit(1)}
  }
}
