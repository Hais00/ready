// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor func configureSteamNetwork() {
    cancelSteamGamePreparation()
    steamDownloads?.stop()
    steamLibrary?.stop(); steamLibrary = nil
    steamNetwork?.stop()
    steamNetwork = nil; steamAccountView = nil; steamGuardChallenge = nil
    // Cached public platform data can fill download choices before account
    // restoration. No installed/path/ownership field is inferred from it.
    if SteamLibraryMerge.projectCachedAvailability(in:&state){try? persist()}
    let profile = state.activeProfile
    let downloads=SteamDownloads(profile:profile,client:storeClient)
    steamDownloads=downloads
    configureStorageDownloads(downloads)
    downloads.onChange = {[weak self,weak downloads] jobs in
      guard let self,let downloads,self.steamDownloads===downloads,self.state.activeProfile==profile else{return}
      self.handleStorageDownloadProgress(jobs,profile:profile)
      self.steamDownloadsView?.update(jobs)
      if self.canNavigateInterfaceWhilePlaying { self.refreshGameDetails() }
    }
    downloads.onError = {[weak self] message in self?.showError(LauncherError.failed(message))}
    downloads.onInstalled = {[weak self] job in self?.acceptSteamInstallation(job,profile:profile)}
    downloads.restore()
    guard let command = SteamClientSession.installedCommand(project: project, runtimeRoot: runtimeRoot, stateRoot: paths.root) else { return }
    let network = SteamClientSession(profile: profile, command: command, credentialAccess: .persistent(stateRoot: paths.root))
    steamNetwork = network
    let library = SteamLibraryCoordinator(profile: profile, network: network)
    library.setMaintenanceSuspended(canvas.artworkCache.maintenanceSuspended || session.running)
    steamLibrary = library
    library.onAccountChanged = { [weak self, weak library] account in
      guard let self, let library, self.steamLibrary === library, self.state.activeProfile == profile else { return }
      SteamLibraryMerge.clearOtherAccountMembership(in: &self.state, profile: profile, account: account)
      try? self.persist()
      if self.canNavigateInterfaceWhilePlaying { self.refreshGameDetails() }
    }
    library.onGames = { [weak self, weak library] games, account in
      guard let self, let library, self.steamLibrary === library, self.state.activeProfile == profile,
        network.state.online, network.state.steamID == account else { return }
      SteamLibraryMerge.apply(games, to: &self.state, profile: profile, account: account, retainMissing: !library.lastMembershipComplete)
      self.canvas.showStatus("")
      do { try self.persist() } catch { self.showError(error) }
      self.repairSteamLibraryCache()
      if self.canNavigateInterfaceWhilePlaying { self.refreshGameDetails() }
    }
    library.onScopeChanged = {[weak self,weak library] in
      guard let self,let library,self.steamLibrary===library,self.state.activeProfile==profile else{return}
      self.repairSteamLibraryCache()
    }
    library.onError = { [weak self, weak library] message in
      guard let self, let library, self.steamLibrary === library, self.state.activeProfile == profile else { return }
      self.canvas.showErrorNotice(message)
      if self.canNavigateInterfaceWhilePlaying { self.canvas.refresh() }
    }
    network.onChange = { [weak self, weak network] status in
      guard let self, let network, self.steamNetwork === network, self.state.activeProfile == profile else { return }
      let signature = status.connection + ":" + status.reason + ":" + (status.steamResult ?? "") + ":" + (status.connectionResultContext ?? "")
      if signature != self.steamConnectionDiagnosticSignature {
        self.steamConnectionDiagnosticSignature = signature
        let reasons:Set<String> = ["explicit_connect","explicit_authentication","manual_offline","manual_logout","shutdown","reconnect_budget_exhausted","server_logoff","server_rejected","network_disconnected","network_lost","login_rejected","invalid_password","revoked","expired","credentials_rejected","not_connected","service_pipe","service_unresponsive","service_disconnected","service_unavailable","invalid_service_response","session_replaced","logged_in_elsewhere","remote_logout","session_expired","server_session_revoked","server_session_rejected","account_disabled","account_locked","logon","logon_failed","login_incomplete","logon_success","reconnected","reconnect_exhausted","startup_retry"]
        let diagnostic:[String:Any] = ["schema":1,"uptimeMilliseconds":DispatchTime.now().uptimeNanoseconds/1_000_000,"connection":status.connection,
          "reason":reasons.contains(status.reason) ? status.reason : "unspecified",
          "steamResult":status.steamResult as Any? ?? NSNull(),
          "connectionResultContext":status.connectionResultContext as Any? ?? NSNull()]
        if let data=try?JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys]) {
          try?FileManager.default.createDirectory(at:self.paths.logs,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
          try?AtomicFile.writePrivate(data,to:self.paths.logs.appendingPathComponent("steam-last-connection-state.json"))
          let transportFailure=["offline","reconnecting"].contains(status.connection)&&["transport_cleanup","transport_connect"].contains(status.connectionResultContext ?? "")
          if transportFailure || (status.steamResult != nil && status.steamResult != "OK" && status.steamResult != "Unknown" && status.connectionResultContext != nil) {
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
      if self.canNavigateInterfaceWhilePlaying { self.canvas?.refresh() }
      self.steamLibrary?.observe(status)
      if becameOnline{self.steamDownloads?.resumeAfterAuthorization()}
      if let continuation = self.steamLaunchContinuation, self.steamAccountReady(network) {
        self.steamLaunchContinuation = nil; self.steamLaunchCancellation = nil
        if let dialog = self.steamAccountDialog { self.dismissDialog(dialog) }
        self.steamAccountDialog = nil; self.steamAccountView = nil
        self.resumeLaunchSplash()
        continuation()
      }
      if ["logged_out", "authorization_required"].contains(status.connection)
        || ["logged_in_elsewhere", "session_replaced", "remote_logout"].contains(status.reason) {
        self.steamGameAuthorization?.cancel()
        self.steamNativeGame?.stopForAccountChange()
      }
    }
    network.onAuthentication = { [weak self, weak network] event in
      guard let self, let network, self.steamNetwork === network, self.state.activeProfile == profile else { return }
      if event["type"]as?String=="guard" { self.steamGuardChallenge = event["challengeID"]as?String }
      self.steamAccountView?.authenticationEvent(event)
    }
    // Startup is nonblocking even when Keychain authorization is locked.
    network.start()
    repairSteamLibraryCache()
    canvas.artworkCache.prepare(games:canvas.allProfileGames,visibleGameIDs:canvas.visibleGames.prefix(24).map(\.id))
  }
  @MainActor func showSteamDownloads() {
    if canvas.section == .downloads, steamDownloadsView != nil, pages.isPresenting { return }
    guard canNavigateInterfaceWhilePlaying else{return}
    if steamDownloads==nil{guard !session.running else{return};configureSteamNetwork()}
    guard let downloads=steamDownloads else{return}
    beginPage(.downloads)
    let view=SteamDownloadsView(frame:NSRect(x:0,y:0,width:670,height:430));steamDownloadsView=view
    view.titleForGame = {[weak self]id in self?.state.games.first(where:{$0.store == .steam && $0.storeID==id})?.title ?? id}
    view.onControl = {[weak downloads]id,action in downloads?.control(id,action:action)}
    view.update(downloads.snapshot)
    _=presentDialog(title:"Download Steam",message:"Le installazioni sono condivise fra profili; account e salvataggi personali restano separati. Pausa e annullamento conservano i file.",content:view,actions:[]){[weak self]_ in self?.steamDownloadsView=nil}
  }
  @MainActor private func acceptSteamInstallation(_ job:SteamDownloadJob,profile:UUID) {
    guard state.activeProfile==profile,let value=job.raw["installedVariant"]as?[String:Any],
      let data=try?JSONSerialization.data(withJSONObject:value),var variant=try?JSONDecoder().decode(GameVariant.self,from:data),
      let index=state.games.firstIndex(where:{$0.store == .steam && $0.storeID==job.gameID})else{return}
    if let selected=state.games[index].variants.first(where:{$0.platform.rawValue==job.platform}){variant.id=selected.id}
    variant.installationRoot=job.raw["installDir"]as?String ?? variant.installationRoot
    if let position=state.games[index].variants.firstIndex(where:{$0.id==variant.id}){state.games[index].variants[position]=variant}else{state.games[index].variants.append(variant)}
    gameStorageSizes.invalidate(game:state.games[index])
    PEImports.annotate(&state.games[index],variant:variant)
    do{try persist()}catch{showError(error)}
  }
  @MainActor func showSteamAccount() {
    if pendingLaunch != nil { suspendLaunchSplashForAccount() }
    guard canNavigateInterfaceWhilePlaying, !maintenanceInProgress else { return }
    if canvas.section == .steamAccount, steamAccountView != nil, pages.isPresenting { return }
    if steamNetwork == nil { guard !session.running else{return};configureSteamNetwork() }
    guard let network = steamNetwork else {
      showError(LauncherError.unavailable("Installa il servizio Steam centrale prima di collegare l’account.")); return
    }
    beginPage(.steamAccount)
    let profile = state.activeProfile
    let view = SteamAccountView(frame:NSRect(x:0,y:0,width:660,height:710))
    steamAccountView = view; view.update(network.state);view.protectDuringGame(session.running)
    view.onQRLogin = { [weak self,weak network] in guard self?.session.running != true else{return};self?.steamGuardChallenge=nil;network?.authenticate() }
    view.onPasswordLogin = { [weak self,weak network] name, password in guard self?.session.running != true else{return};self?.steamGuardChallenge=nil;network?.authenticate(method:"password",username:name,password:password) }
    view.onGuard = { [weak self, weak network] code in
      guard self?.session.running != true,let challenge = self?.steamGuardChallenge else { return }; network?.submitGuard(challengeID:challenge,code:code)
    }
    view.onPresence = { [weak network] in network?.setPresence($0) }
    view.onReconnect = { [weak self,weak network] in guard self?.session.running != true else{return};network?.reconnect() }
    view.onOffline = { [weak self,weak network] in guard self?.session.running != true else{return};network?.goOffline() }
    view.onDisplayName = {[weak self,weak network]name in network?.request("set_persona_name",options:["displayName":name]){event in self?.steamAccountView?.actionEvent(event)}}
    view.onFriendAction = {[weak self,weak network]operation,id in
      guard let self,self.state.activeProfile==profile,UInt64(id) != nil else{return}
      network?.request(operation,options:["steamID":id]){[weak self]event in
        self?.steamAccountView?.actionEvent(event)
      }
    }
    view.onLogout = { [weak self, weak network] in
      guard let self, self.state.activeProfile == profile,!self.session.running else { return }
      self.pendingLaunch=nil
      self.cancelSteamGamePreparation(); self.finishLaunchSplash()
      self.steamGameAuthorization?.cancel(); self.steamNativeGame?.stop()
      self.steamDownloads?.stop(); self.steamLibrary?.stop()
      SteamLibraryMerge.clearRemoteMembership(in: &self.state, profile: profile); try? self.persist()
      network?.logout(); self.steamAccounts.signOut(profile:profile)
    }
    let storageHint = CredentialVault.storage(for:.steam) == .privateFile
      ? "Accesso Steam salvato in un file privato di questo Mac. La password Steam non viene salvata."
      : "Accesso Steam salvato nel Portachiavi. La password Steam non viene salvata."
    steamAccountDialog = presentDialog(title:"Account, amici e attività",message:"Un solo accesso per questo profilo, condiviso da giochi macOS e Windows. " + storageHint,content:view,actions:[]) { [weak self,weak network] _ in
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
    guard !canvas.artworkCache.maintenanceSuspended else{event(["type":"error","code":"maintenance_suspended"]);return}
    if steamNetwork == nil { guard !session.running else{return};configureSteamNetwork() }
    guard let network = steamNetwork else { event(["type":"error","message":"Servizio Steam non installato."]); return }
    network.request("library",event:event)
  }
  @MainActor func syncSteamLibrary() {
    if steamNetwork == nil { guard !session.running else{return};configureSteamNetwork() }
    steamLibrary?.sync()
  }
  @MainActor func requestSteamGameDetails(gameID: String, refresh: Bool = false, completion: @escaping ([String:Any]) -> Void) {
    if steamNetwork == nil { guard !session.running else{return};configureSteamNetwork() }
    let profile = state.activeProfile
    guard let library = steamLibrary, let network = steamNetwork else {
      completion(["type":"error", "code":"service_unavailable"]); return
    }
    library.metadata(gameID: gameID, refresh: refresh, priority: refresh) { [weak self, weak library, weak network] event in
      guard let self, let library, let network, self.steamLibrary === library, self.steamNetwork === network,
        self.state.activeProfile == profile else { return }
      if event["type"] as? String == "result", let value = event["metadata"] as? [String:Any],
        let data = try? JSONSerialization.data(withJSONObject: value),
        let metadata = try? JSONDecoder().decode([String:JSONValue].self, from: data) {
        SteamLibraryMerge.enrich(metadata, gameID: gameID, in: &self.state)
        self.scheduleSteamCatalogUpdate(gameID:gameID)
      }
      completion(event)
    }
  }

  @MainActor private func repairSteamLibraryCache() {
    guard let library=steamLibrary,let network=steamNetwork else{return}
    let profile=state.activeProfile
    library.repairCached(games:state.games,prepare:{[weak self]ids in
      guard let self,self.steamLibrary===library,self.state.activeProfile==profile else{return}
      var changed=false
      for id in ids {if SteamLibraryMerge.addArtworkFallback(gameID:id,in:&self.state){changed=true}}
      if changed{self.scheduleSteamCatalogUpdate()}
    },event:{[weak self,weak library,weak network]id,event in
      guard let self,let library,let network,self.steamLibrary===library,self.steamNetwork===network,self.state.activeProfile==profile else{return}
      if event["type"]as?String=="result",let value=event["metadata"]as?[String:Any],
        let bytes=try?JSONSerialization.data(withJSONObject:value),let metadata=try?JSONDecoder().decode([String:JSONValue].self,from:bytes) {
        SteamLibraryMerge.enrich(metadata,gameID:id,in:&self.state)
        self.scheduleSteamCatalogUpdate(gameID:id)
      } else if event["code"]as?String=="metadata_not_found",
        SteamLibraryMerge.markPublicMetadataUnavailable(gameID:id,in:&self.state) {
        self.scheduleSteamCatalogUpdate(gameID:id)
      }

    })
  }

  /// Metadata arrives in batches. Keep serialization and fsync off the input
  /// thread and coalesce model publication rather than rebuild on every reply.
  @MainActor func scheduleSteamCatalogUpdate(gameID:String?=nil) {
    // Replies from the two already-active metadata requests may enrich the
    // model. Publication/artwork warming waits until the game has finished.
    guard !canvas.artworkCache.maintenanceSuspended else{return}
    if let gameID,let game=state.games.first(where:{$0.store == .steam && $0.storeID==gameID}) {
      canvas.artworkCache.prepare(games:[game])
      if gameDetailID==game.id{refreshGameDetails()}
    }
    guard steamCatalogUpdate==nil else{return}
    let work=DispatchWorkItem{[weak self]in
      guard let self else{return};self.steamCatalogUpdate=nil
      guard !self.canvas.artworkCache.maintenanceSuspended else{return}
      let snapshot=self.state
      self.repository.saveAsync(snapshot){[weak self]result in
        if case .failure = result{self?.canvas.showErrorNotice("Impossibile salvare la cache della libreria.")}
      }
      self.canvas.state=snapshot
      if !self.session.running{self.canvas.refresh()}
    }
    steamCatalogUpdate=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.6,execute:work)
  }

  @MainActor func setSteamMaintenanceSuspended(_ value:Bool){
    canvas.artworkCache.setMaintenanceSuspended(value)
    steamLibrary?.setMaintenanceSuspended(value)
    if value {
      steamCatalogUpdate?.cancel();steamCatalogUpdate=nil
    }else{
      repairSteamLibraryCache()
      canvas.artworkCache.prepare(games:canvas.allProfileGames,visibleGameIDs:canvas.visibleGames.prefix(24).map(\.id))
      scheduleSteamCatalogUpdate()
    }
  }

}
