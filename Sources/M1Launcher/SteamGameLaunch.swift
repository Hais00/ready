// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor private func steamPreparationMessage(_ message:String) {
    canvas?.message=message
    // A background terminal callback must not recreate GPU work during play.
    if session?.running != true{canvas?.refresh()}
  }
  @MainActor private func nativeSteamPreparationFailureMessage(_ failure:SteamNativeGameSession.Failure,stopOrigin:String?=nil)->String {
    switch failure {
    case .stopped,.invalidated:return stopOrigin=="account_session_changed"
      ? "Preparazione Steam interrotta: la sessione dell’account è cambiata.":"Preparazione Steam interrotta."
    case .grantUnavailable:return "L’autorizzazione locale non è più valida. Ripeti la preparazione del gioco."
    case .unsupportedArchitecture:return "Questa variante non è compatibile con il backend Steam per Apple Silicon."
    case .incompatibleSignature:return "La firma o l’isolamento di questa app non consente il collegamento Steam selezionato."
    case .invalidSDK:return "L’SDK Steam non corrisponde all’installazione del gioco selezionata."
    case .invalidGame,.invalidVariant,.invalidExecutable:return "Il gioco o la variante selezionata sono cambiati. Selezionali di nuovo."
    case .invalidStateRoot:return "La cartella privata Steam di questo profilo non è disponibile."
    case .hostSetupFailed:return "Non è stato possibile avviare il processo Steam nativo."
    case .startupFailed:return "Il backend Steam nativo non ha completato l’avvio."
    case .healthUnavailable,.alreadyHandedOff:return "Il collegamento alla sessione Steam non è disponibile."
    }
  }
  @MainActor private func closeSteamPreparationHost(_ closing:SteamNativeGameSession) {
    closing.stop{[weak self,weak closing]in
      guard let self,let closing,self.steamNativeGame===closing else{return}
      // A newer preparation owns a cleanup waiter and must resume itself.
      guard self.steamPreparationID==nil else{return}
      self.steamNativeGame=nil
    }
  }
  @MainActor func cancelSteamGamePreparation() {
    let ownedPreparation = steamPreparationID != nil || steamLaunchContinuation != nil || steamGameAuthorization != nil || steamNativeGame != nil
    steamPreparationID = nil
    if ownedPreparation, session?.running != true {
      pendingLaunch = nil
      steamPreparationMessage("Preparazione Steam annullata.")
    }
    steamLaunchContinuation = nil
    let cancelled = steamLaunchCancellation; steamLaunchCancellation = nil
    steamGameAuthorization?.cancel(); steamGameAuthorization = nil
    if session?.running != true,let closing=steamNativeGame{closeSteamPreparationHost(closing)}
    cancelled?()
  }
  @MainActor func steamAccountReady(_ network: SteamClientSession) -> Bool {
    network.accountReadyForGame()
  }
  @MainActor func prepareSteamGame(_ game: Game, variant: GameVariant, profile: UUID,
                                  launchID: UUID, ready: @escaping (SteamNativeGameSession) -> Void) {
    guard pendingLaunch==launchID,state.activeProfile==profile else{return}
    if let closing=steamNativeGame {
      steamPreparationID=launchID
      steamPreparationMessage("Chiusura del backend Steam precedente…")
      closing.stop{[weak self,weak closing]in
        guard let self,let closing,self.steamNativeGame===closing else{return}
        guard self.pendingLaunch==launchID,self.steamPreparationID==launchID,self.state.activeProfile==profile else{
          if self.pendingLaunch==nil,self.steamPreparationID==nil{self.steamNativeGame=nil}
          return
        }
        // Identity ownership makes duplicate/obsolete close callbacks no-ops.
        self.steamNativeGame=nil;self.steamPreparationID=nil
        self.prepareSteamGame(game,variant:variant,profile:profile,launchID:launchID,ready:ready)
      }
      return
    }
    guard variant.platform == .macOS else {
      pendingLaunch = nil
      steamPreparationID=nil
      steamPreparationMessage("Avvio Steam per Windows non ancora disponibile.")
      showError(LauncherError.unavailable("Il collegamento Steam per i giochi Windows è ancora in verifica."))
      return
    }
    if steamNetwork == nil { configureSteamNetwork() }
    steamPreparationID = launchID
    steamPreparationMessage("Verifica del componente Steam…")
    let selectedRuntime = runtimeRoot
    let selectedStateRoot = paths.root
    // Only immutable identifiers cross the worker queue. The continuation stays
    // on the main actor, including every profile and pending-launch check.
    let appID = game.storeID
    Task { @MainActor [weak self] in
      let selection = await Task.detached(priority: .userInitiated) {
        Result { try SteamNativeHostSelection.load(runtimeRoot: selectedRuntime, gameID: appID, stateRoot: selectedStateRoot) }
      }.value
          guard let self, self.pendingLaunch == launchID, self.steamPreparationID == launchID,
            self.state.activeProfile == profile else { return }
          switch selection {
          case .failure:
            self.pendingLaunch = nil
            self.steamPreparationID = nil
            self.steamPreparationMessage("Componente Steam nativo non disponibile.")
            self.showError(LauncherError.unavailable("Il componente Steam nativo verificato per questo gioco non è installato nel runtime centrale."))
          case .success(let binding):
            self.authorizeSteamGame(game, variant: variant, profile: profile, launchID: launchID, binding: binding, ready: ready)
          }
    }
  }
  @MainActor private func authorizeSteamGame(_ game: Game, variant: GameVariant, profile: UUID,
      launchID: UUID, binding: SteamNativeHostProcess.Binding, ready: @escaping (SteamNativeGameSession) -> Void) {
    guard pendingLaunch == launchID, state.activeProfile == profile else { return }
    guard let network = steamNetwork else {
      pendingLaunch = nil; steamPreparationID = nil
      steamPreparationMessage("Servizio Steam non disponibile.")
      showError(LauncherError.unavailable("Il servizio Steam centrale non è disponibile.")); return
    }
    guard steamAccountReady(network) else {
      steamPreparationMessage("Attesa dell’accesso Steam…")
      steamLaunchContinuation = { [weak self] in
        self?.authorizeSteamGame(game, variant: variant, profile: profile, launchID: launchID, binding: binding, ready: ready)
      }
      steamLaunchCancellation = { [weak self] in
        if self?.pendingLaunch == launchID {
          self?.pendingLaunch = nil; self?.steamPreparationID = nil
          self?.steamPreparationMessage("Preparazione Steam annullata.")
        }
      }
      showSteamAccount()
      return
    }
    let authorization = SteamGameAuthorization(network: network, credentialAccess: .keychain(stateRoot: paths.root))
    steamGameAuthorization?.cancel(); steamGameAuthorization = authorization
    steamPreparationMessage("Verifica della licenza Steam…")
    authorization.prepare(profile: profile, gameID: game.storeID) { [weak self, weak authorization] result in
      guard let self, let authorization, self.steamGameAuthorization === authorization,
        self.pendingLaunch == launchID, self.state.activeProfile == profile else { return }
      switch result {
      case .failure(let reason):
        self.pendingLaunch = nil; self.steamGameAuthorization = nil
        self.steamPreparationID = nil
        self.steamPreparationMessage(reason.userMessage)
        if reason != .cancelled {
          if let detail=authorization.lastFailureDetail {try? detail.writePrivate(logs:self.paths.logs)}
          self.showError(LauncherError.unavailable(reason.userMessage))
        }
      case .success(let grant):
        do {
          self.steamPreparationMessage("Avvio del backend Steam…")
          let root = try SteamNativeStateDirectory.prepare(paths: self.paths, profile: profile, gameID: grant.gameID)
          weak var preparedHost:SteamNativeGameSession?
          let host = try SteamNativeGameSession.start(binding: binding, grant: grant, game: game,
            variant: variant, profileStateRoot: root) { [weak self] result in
              guard let self,let attemptHost=preparedHost,self.steamNativeGame===attemptHost,
                self.pendingLaunch == launchID,self.state.activeProfile == profile else {
                if case .success(let host) = result { host.stop() }; return
              }
              self.steamGameAuthorization = nil
              self.steamPreparationID = nil
              switch result {
              case .success(let host):
                self.steamPreparationMessage("Avvio di \(game.title)…")
                ready(host)
              case .failure(let reason):
                let detail=attemptHost.lastFailureDetail
                if let detail{try? detail.writePrivate(logs:self.paths.logs)}
                self.pendingLaunch = nil
                self.closeSteamPreparationHost(attemptHost)
                let message=self.nativeSteamPreparationFailureMessage(reason,stopOrigin:detail?.stopOrigin)
                self.steamPreparationMessage(message)
                self.showError(LauncherError.unavailable(message))
              }
            }
          preparedHost=host
          self.steamNativeGame = host
        } catch {
          self.pendingLaunch = nil; self.steamGameAuthorization = nil
          self.steamPreparationID = nil
          let message=(error as? SteamNativeGameSession.Failure).map{self.nativeSteamPreparationFailureMessage($0)}
            ?? "Non è possibile preparare questa versione del gioco con il backend Steam selezionato."
          self.steamPreparationMessage(message)
          self.showError(LauncherError.unavailable(message))
        }
      }
    }
  }
}
