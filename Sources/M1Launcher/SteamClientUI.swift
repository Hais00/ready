// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor func configureSteamNetwork() {
    cancelSteamGamePreparation()
    steamDownloads?.stop()
    steamNetwork?.stop()
    steamNetwork = nil; steamAccountView = nil; steamGuardChallenge = nil
    let profile = state.activeProfile
    let downloads=SteamDownloads(profile:profile,client:storeClient)
    steamDownloads=downloads
    downloads.onChange = {[weak self,weak downloads] jobs in
      guard let self,let downloads,self.steamDownloads===downloads,self.state.activeProfile==profile else{return}
      self.steamDownloadsView?.update(jobs)
    }
    downloads.onError = {[weak self] message in self?.showError(LauncherError.failed(message))}
    downloads.onInstalled = {[weak self] job in self?.acceptSteamInstallation(job,profile:profile)}
    downloads.restore()
    guard let command = SteamClientSession.installedCommand(project: project, runtimeRoot: runtimeRoot, stateRoot: paths.root) else { return }
    let network = SteamClientSession(profile: profile, command: command, credentialAccess: .keychain(stateRoot: paths.root))
    steamNetwork = network
    network.onChange = { [weak self, weak network] status in
      guard let self, let network, self.steamNetwork === network, self.state.activeProfile == profile else { return }
      let signature = status.connection + ":" + status.reason + ":" + (status.steamResult ?? "") + ":" + (status.connectionResultContext ?? "")
      if signature != self.steamConnectionDiagnosticSignature {
        self.steamConnectionDiagnosticSignature = signature
        let reasons:Set<String> = ["explicit_connect","explicit_authentication","manual_offline","manual_logout","shutdown","reconnect_budget_exhausted","server_logoff","server_rejected","network_disconnected","network_lost","login_rejected","invalid_password","revoked","expired","credentials_rejected","not_connected","service_pipe","service_unresponsive","service_disconnected","service_unavailable","invalid_service_response","session_replaced","logged_in_elsewhere","remote_logout","session_expired","server_session_revoked","server_session_rejected","account_disabled","account_locked"]
        let diagnostic:[String:Any] = ["schema":1,"connection":status.connection,
          "reason":reasons.contains(status.reason) ? status.reason : "unspecified",
          "steamResult":status.steamResult as Any? ?? NSNull(),
          "connectionResultContext":status.connectionResultContext as Any? ?? NSNull()]
        if let data=try?JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys]) {
          try?FileManager.default.createDirectory(at:self.paths.logs,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
          try?AtomicFile.writePrivate(data,to:self.paths.logs.appendingPathComponent("steam-last-connection-state.json"))
          if let result=status.steamResult,result != "OK",result != "Unknown",status.connectionResultContext != nil {
            // A later idle/successful startup must not erase the last actual
            // server failure needed to diagnose a user-reported interruption.
            try?AtomicFile.writePrivate(data,to:self.paths.logs.appendingPathComponent("steam-last-connection-failure.json"))
          }
        }
      }
      let becameOnline=status.online && self.canvas?.steamOnline != true
      self.steamAccountView?.update(status)
      self.canvas?.steamStatus = status.online ? (status.displayName.isEmpty ? "Steam online" : status.displayName) : "Steam · " + status.connection
      self.canvas?.steamOnline = status.online
      if !self.session.running { self.canvas?.refresh() }
      if becameOnline{self.steamDownloads?.resumeAfterAuthorization()}
      if let continuation = self.steamLaunchContinuation, self.steamAccountReady(network) {
        self.steamLaunchContinuation = nil; self.steamLaunchCancellation = nil
        if let dialog = self.steamAccountDialog { self.dismissDialog(dialog) }
        self.steamAccountDialog = nil; self.steamAccountView = nil
        continuation()
      }
      if ["logged_out", "authorization_required"].contains(status.connection)
        || ["logged_in_elsewhere", "session_replaced", "remote_logout"].contains(status.reason) {
        self.steamGameAuthorization?.cancel()
        self.steamNativeGame?.stop()
      }
    }
    network.onAuthentication = { [weak self, weak network] event in
      guard let self, let network, self.steamNetwork === network, self.state.activeProfile == profile else { return }
      if event["type"]as?String=="guard" { self.steamGuardChallenge = event["challengeID"]as?String }
      self.steamAccountView?.authenticationEvent(event)
    }
    if CredentialVault.steamStatus(CredentialVault.load(profile:profile,store:.steam,stateRoot:paths.root)) == .available { network.start() }
  }
  @MainActor func showSteamDownloads() {
    if steamDownloads==nil{configureSteamNetwork()}
    guard let downloads=steamDownloads else{return}
    let view=SteamDownloadsView(frame:NSRect(x:0,y:0,width:670,height:430));steamDownloadsView=view
    view.titleForGame = {[weak self]id in self?.state.games.first(where:{$0.store == .steam && $0.storeID==id})?.title ?? id}
    view.onControl = {[weak downloads]id,action in downloads?.control(id,action:action)}
    view.update(downloads.snapshot)
    _=presentDialog(title:"Download Steam",message:"Le installazioni sono condivise fra profili; account e salvataggi personali restano separati. Pausa e annullamento conservano i file.",content:view,actions:[.init("Chiudi",role:.cancel)]){[weak self]_ in self?.steamDownloadsView=nil}
  }
  @MainActor private func acceptSteamInstallation(_ job:SteamDownloadJob,profile:UUID) {
    guard state.activeProfile==profile,let value=job.raw["installedVariant"]as?[String:Any],
      let data=try?JSONSerialization.data(withJSONObject:value),var variant=try?JSONDecoder().decode(GameVariant.self,from:data),
      let index=state.games.firstIndex(where:{$0.store == .steam && $0.storeID==job.gameID})else{return}
    if let selected=state.games[index].variants.first(where:{$0.platform.rawValue==job.platform}){variant.id=selected.id}
    variant.installationRoot=job.raw["installDir"]as?String ?? variant.installationRoot
    if let position=state.games[index].variants.firstIndex(where:{$0.id==variant.id}){state.games[index].variants[position]=variant}else{state.games[index].variants.append(variant)}
    PEImports.annotate(&state.games[index],variant:variant)
    do{try persist()}catch{showError(error)}
  }
  @MainActor func showSteamAccount() {
    guard !session.running, !maintenanceInProgress else { return }
    if steamNetwork == nil { configureSteamNetwork() }
    guard let network = steamNetwork else {
      showError(LauncherError.unavailable("Installa il servizio Steam centrale prima di collegare l’account.")); return
    }
    let profile = state.activeProfile
    let view = SteamAccountView(frame:NSRect(x:0,y:0,width:660,height:710))
    steamAccountView = view; view.update(network.state)
    view.onQRLogin = { [weak self,weak network] in self?.steamGuardChallenge=nil;network?.authenticate() }
    view.onPasswordLogin = { [weak self,weak network] name, password in self?.steamGuardChallenge=nil;network?.authenticate(method:"password",username:name,password:password) }
    view.onGuard = { [weak self, weak network] code in
      guard let challenge = self?.steamGuardChallenge else { return }; network?.submitGuard(challengeID:challenge,code:code)
    }
    view.onPresence = { [weak network] in network?.setPresence($0) }
    view.onReconnect = { [weak network] in network?.reconnect() }
    view.onOffline = { [weak network] in network?.goOffline() }
    view.onDisplayName = {[weak self,weak network]name in network?.request("set_persona_name",options:["displayName":name]){event in self?.steamAccountView?.actionEvent(event)}}
    view.onFriendAction = {[weak self,weak network]operation,id in
      guard let self,self.state.activeProfile==profile,UInt64(id) != nil else{return}
      network?.request(operation,options:["steamID":id]){[weak self]event in
        self?.steamAccountView?.actionEvent(event)
      }
    }
    view.onLogout = { [weak self, weak network] in
      guard let self, self.state.activeProfile == profile else { return }
      self.steamGameAuthorization?.cancel(); self.steamNativeGame?.stop()
      self.steamDownloads?.stop();network?.logout(); self.steamAccounts.signOut(profile:profile)
    }
    steamAccountDialog = presentDialog(title:"Steam · account, amici e attività",message:"Un solo accesso per questo profilo, condiviso da giochi macOS e Windows. La password non viene salvata.",content:view,actions:[.init("Chiudi",role:.cancel)]) { [weak self,weak network] _ in
      network?.cancelAuthentication()
      self?.steamAccountView = nil; self?.steamAccountDialog = nil
      self?.steamLaunchContinuation = nil
      let cancelled = self?.steamLaunchCancellation; self?.steamLaunchCancellation = nil
      cancelled?()
    }
    network.start()
    network.request("snapshot") { _ in }
  }
  @MainActor func requestSteamLibrary(profile:UUID, event:@escaping ([String:Any])->Void) {
    guard profile == state.activeProfile else { return }
    if steamNetwork == nil { configureSteamNetwork() }
    guard let network = steamNetwork else { event(["type":"error","message":"Servizio Steam non installato."]); return }
    network.request("library",event:event)
  }
}
