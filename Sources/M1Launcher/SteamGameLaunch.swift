// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LauncherCore

extension AppDelegate {
  @MainActor func cancelSteamGamePreparation() {
    let ownedPreparation = steamPreparationID != nil || steamLaunchContinuation != nil || steamGameAuthorization != nil || steamNativeGame != nil
    steamPreparationID = nil
    if ownedPreparation, session?.running != true { pendingLaunch = nil }
    steamLaunchContinuation = nil
    let cancelled = steamLaunchCancellation; steamLaunchCancellation = nil
    steamGameAuthorization?.cancel(); steamGameAuthorization = nil
    if session?.running != true { steamNativeGame?.stop(); steamNativeGame = nil }
    cancelled?()
  }
  @MainActor func steamAccountReady(_ network: SteamClientSession) -> Bool {
    network.accountReadyForGame()
  }
  @MainActor func prepareSteamGame(_ game: Game, variant: GameVariant, profile: UUID,
                                  launchID: UUID, ready: @escaping (SteamNativeGameSession) -> Void) {
    guard variant.platform == .macOS else {
      pendingLaunch = nil
      showError(LauncherError.unavailable("Il collegamento Steam per i giochi Windows è ancora in verifica."))
      return
    }
    if steamNetwork == nil { configureSteamNetwork() }
    steamPreparationID = launchID
    canvas.message = "Preparazione del backend Steam…"; canvas.refresh()
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
      showError(LauncherError.unavailable("Il servizio Steam centrale non è disponibile.")); return
    }
    guard steamAccountReady(network) else {
      steamLaunchContinuation = { [weak self] in
        self?.authorizeSteamGame(game, variant: variant, profile: profile, launchID: launchID, binding: binding, ready: ready)
      }
      steamLaunchCancellation = { [weak self] in
        if self?.pendingLaunch == launchID { self?.pendingLaunch = nil; self?.steamPreparationID = nil }
      }
      showSteamAccount()
      return
    }
    let authorization = SteamGameAuthorization(network: network, credentialAccess: .keychain(stateRoot: paths.root))
    steamGameAuthorization?.cancel(); steamGameAuthorization = authorization
    authorization.prepare(profile: profile, gameID: game.storeID) { [weak self, weak authorization] result in
      guard let self, let authorization, self.steamGameAuthorization === authorization,
        self.pendingLaunch == launchID, self.state.activeProfile == profile else { return }
      switch result {
      case .failure(let reason):
        self.pendingLaunch = nil; self.steamGameAuthorization = nil
        self.steamPreparationID = nil
        if reason != .cancelled {
          if let detail=authorization.lastFailureDetail {try? detail.writePrivate(logs:self.paths.logs)}
          self.showError(LauncherError.unavailable(reason.userMessage))
        }
      case .success(let grant):
        do {
          let root = try SteamNativeStateDirectory.prepare(paths: self.paths, profile: profile, gameID: grant.gameID)
          let host = try SteamNativeGameSession.start(binding: binding, grant: grant, game: game,
            variant: variant, profileStateRoot: root) { [weak self] result in
              guard let self, self.pendingLaunch == launchID, self.state.activeProfile == profile else {
                if case .success(let host) = result { host.stop() }; return
              }
              self.steamGameAuthorization = nil
              self.steamPreparationID = nil
              switch result {
              case .success(let host): ready(host)
              case .failure:
                self.pendingLaunch = nil; self.steamNativeGame = nil
                self.showError(LauncherError.unavailable("Il backend Steam nativo non è pronto. Avvio annullato."))
              }
            }
          self.steamNativeGame = host
        } catch {
          self.pendingLaunch = nil; self.steamGameAuthorization = nil
          self.steamPreparationID = nil
          self.showError(LauncherError.unavailable("Non è possibile preparare questa versione del gioco con il backend Steam selezionato."))
        }
      }
    }
  }
}
