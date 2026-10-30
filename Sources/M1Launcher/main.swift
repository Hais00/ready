// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage
import GameController
import LauncherCore
import Metal

final class ReadyWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
  let paths: LauncherPaths
  let project: URL
  var runtimeRoot: URL
  var repository: LibraryRepository!
  var state = LibraryState.initial()
  var window: ReadyWindow!
  var canvas: MetalCanvas!
  var session: SessionManager!
  var controllerObserver: NSObjectProtocol?
  var storeClient: StoreClient!
  var steamAccounts: SteamAccountCoordinator!
  var steamNetwork: SteamClientSession?
  var steamAccountView: SteamAccountView?
  var steamGuardChallenge: String?
  var steamDownloads: SteamDownloads?
  var steamDownloadsView: SteamDownloadsView?
  var steamLibrary: SteamLibraryCoordinator?
  var gameDetailView: GameDetailView?
  var gameDetailID: String?
  var launchSplash: GameLaunchSplash?
  var launchSplashID: UUID?
  var launchReturnGame: (id:String,profile:UUID)?
  var steamGameAuthorization: SteamGameAuthorization?
  var steamNativeGame: SteamNativeGameSession?
  var hostedPresentation:HostedGamePresentationController?
  var hostedWindowPlacement:HostedWindowPlacement?
  var steamLaunchContinuation: (() -> Void)?
  var steamLaunchCancellation: (() -> Void)?
  var steamAccountDialog: UUID?
  var steamPreparationID: UUID?
  var steamCatalogUpdate: DispatchWorkItem?
  lazy var storageLibraries = StorageLibraryRepository(paths: paths)
  var storageReturnGameID: String?
  var installationPickerView: GameInstallationView?
  var installationPickerID: UUID?
  lazy var gameStorageSizes = GameStorageSizeService(directory: paths.root.appendingPathComponent("Storage",isDirectory:true))
  var gameStorageRequest = UUID()
  let storageWork = DispatchQueue(label:"app.ready.storage-operations",qos:.utility)
  var activeOtherStorageJobs=Set<String>()
  var steamConnectionDiagnosticSignature = ""
  lazy var dialogs = ReadyDialogPresenter(window: { [weak self] in self?.window })
  lazy var pages: ReadyPagePresenter = {
    let presenter = ReadyPagePresenter(window: { [weak self] in self?.window }, host: { [weak self] in self?.canvas })
    presenter.onNeedsLanding = { [weak self] in self?.pageNeedsLanding() }
    presenter.canNavigate = { [weak self] in
      guard let self else { return false }
      return !self.maintenanceInProgress && self.session?.running != true && self.pendingLaunch == nil
    }
    return presenter
  }()
  var settingsPageSection = SettingsPageSection.overview
  var pageNavigationTransition = false
  var qrDialog: UUID?
  var qrImage: NSImageView?
  var steamAuthDiagnostics: SteamAuthDiagnostics?
  var authenticationSession: UUID?
  var authenticationRequest: UUID?
  var steamAuthenticationRequest: UUID?
  var pendingLaunch: UUID?
  var maintenanceInProgress = false
  var backgroundNotices = [String]()
  init(project: URL, runtimeRoot: URL? = nil, paths: LauncherPaths = LauncherPaths()) {
    self.project = project
    self.runtimeRoot = runtimeRoot ?? project.appendingPathComponent("Runtime")
    self.paths = paths
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      repository = LibraryRepository(paths: paths)
      state = try repository.load()
      state = try LegacyMigration.reconcileLibrary(state, paths: paths)
      try repository.save(state)
    } catch { showError(error) }
    guard let device = MTLCreateSystemDefaultDevice() else {
      showError(LauncherError.unavailable("Questo Mac non dispone di Metal."))
      NSApp.terminate(nil)
      return
    }
    configureRuntimeClients()
    window = ReadyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "ready"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = true
    window.backgroundColor = .black
    window.collectionBehavior = [.fullScreenPrimary,.fullScreenDisallowsTiling]
    window.minSize = NSSize(width: 900, height: 620)
    window.delegate = self
    canvas = MetalCanvas(frame: NSRect(x: 0, y: 0, width: 1240, height: 760), device: device)
    canvas.autoresizingMask = [.width, .height]
    canvas.state = state
    if LegacyMigration.requiresRecovery(paths: paths) {
      canvas.message = "Operazione sui dati interrotta · Apri Libreria → Dati e ripristino"
    }
    canvas.evaluationMode = activeRuntime().evaluationModeEnabled == true
    canvas.onAction = { [weak self] in self?.action($0) }
    window.contentView = canvas
    dialogs.attach()
    window.center()
    setupMenu()
    setupControllers()
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--steam-auth-status") {
      do {
        guard args.indices.contains(index + 1), args[index + 1].hasPrefix("/") else {
          throw LauncherError.invalid("Percorso diagnostico dell’accesso non valido.")
        }
        let diagnostics = try SteamAuthDiagnostics(
          delegate: self, status: URL(fileURLWithPath: args[index + 1]))
        steamAuthDiagnostics = diagnostics
        try diagnostics.start()
      } catch { showError(error) }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    if args.contains("--background-error-self-test") {
      runBackgroundErrorProbe()
      return
    }
    if args.contains("--graphics-self-test") {
      window.makeKeyAndOrderFront(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
        canvas.refresh()
        let before = canvas.allocatedTextureBytes
        let gpuBefore = device.currentAllocatedSize
        canvas.releaseGraphics()
        window.orderOut(nil)
        window.contentView = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
          let after = canvas.allocatedTextureBytes
          let report: [String: Any] = [
            "canvasTextureBytesBefore": before, "canvasTextureBytesDuringGame": after,
            "gpuAllocatedBytesBefore": gpuBefore,
            "gpuAllocatedBytesAfter": device.currentAllocatedSize, "pass": before > 0 && after == 0,
            "directToDisplayVerified": false,
          ]
          if var data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          {
            data.append(0x0a)
            FileHandle.standardOutput.write(data)
          }
          NSApp.terminate(nil)
        }
      }
      return
    }
    if let i = args.firstIndex(of: "--preview"), args.indices.contains(i + 1) {
      do {
        try canvas.writePreview(URL(fileURLWithPath: args[i + 1]))
        print("Preview saved: \(args[i+1])")
      } catch { print(error.localizedDescription) }
      NSApp.terminate(nil)
      return
    }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(canvas)
    NSApp.activate(ignoringOtherApps: true)
    if args.contains("--fullscreen") { window.toggleFullScreen(nil) }
    refreshLocal()
    MainActor.assumeIsolated { configureSteamNetwork();bootstrapGameStorage() }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !CommandLine.arguments.contains("--graphics-self-test") && !session.running
      && !maintenanceInProgress
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if hostedPresentation != nil,session?.running==true{session.quit();return false}
    if dialogs.isPresenting {
      dialogs.cancelCurrent()
      return false
    }
    return !maintenanceInProgress
  }
  func windowWillClose(_ notification: Notification) {
    if (notification.object as? NSWindow) === window {
      MainActor.assumeIsolated {
        finishLaunchSplash()
        hostedPresentation?.stop(preserveFullscreen:false)
        hostedWindowPlacement?.restore();hostedWindowPlacement=nil
      }
      pageNavigationTransition = true
      pages.cancelCurrent()
      _ = pages.detachForSession()
      pageNavigationTransition = false
      cancelAuthentication()
      MainActor.assumeIsolated { cancelSteamGamePreparation() }
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    steamCatalogUpdate?.cancel();steamCatalogUpdate=nil
    if let repository{try? repository.save(state)}
    MainActor.assumeIsolated {
      finishLaunchSplash()
      hostedPresentation?.stop(preserveFullscreen:false)
      hostedWindowPlacement?.restore();hostedWindowPlacement=nil
    }
  }
  func cancelAuthentication(closePanel: Bool = true) {
    authenticationSession = nil
    if let request = steamAuthenticationRequest {
      MainActor.assumeIsolated { steamAccounts?.cancel(request) }
    }
    steamAuthenticationRequest = nil
    if let request = authenticationRequest { storeClient?.cancel(request) }
    authenticationRequest = nil
    if closePanel {
      if let id = qrDialog { dismissDialog(id) }
      qrDialog = nil
      qrImage = nil
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if maintenanceInProgress {
      showError(
        LauncherError.failed("Attendi il termine dell’operazione sui dati prima di chiudere ready.")
      )
      return .terminateCancel
    }
    if dialogs.isPresenting { return .terminateCancel }
    if session?.running == true {
      let hosted=MainActor.assumeIsolated{hostedPresentation?.active==true}
      if !hosted{window.contentView = canvas}
      window.makeKeyAndOrderFront(nil)
      presentDialog(
        title: "Chiudere il gioco e ready?", message: "La sessione in corso verrà terminata.",
        actions: [.init("Chiudi sessione", role: .destructive), .init("Annulla", role: .cancel)]
      ) { [weak self] choice in
        guard let self else {
          NSApp.reply(toApplicationShouldTerminate: false)
          return
        }
        if choice == 0 {
          self.session.quit()
          self.storeClient?.cancelAll()
        } else if !hosted {
          self.window.orderOut(nil)
          self.window.contentView = nil
        }
        NSApp.reply(toApplicationShouldTerminate: choice == 0)
      }
      return .terminateLater
    }
    storeClient?.cancelAll()
    pageNavigationTransition = true
    pages.cancelCurrent()
    _ = pages.detachForSession()
    pageNavigationTransition = false
    MainActor.assumeIsolated { cancelSteamGamePreparation() }
    MainActor.assumeIsolated { steamDownloads?.stop() }
    MainActor.assumeIsolated { steamLibrary?.stop(); steamLibrary=nil; steamNetwork?.stop() }
    return .terminateNow
  }
  func windowDidResize(_ notification: Notification) {
    MainActor.assumeIsolated {
      if hostedPresentation?.active==true{hostedPresentation?.resize()}else{canvas?.refresh()}
    }
  }
  func windowDidFailToEnterFullScreen(_ window:NSWindow) {
    guard window === self.window else{return}
    MainActor.assumeIsolated{hostedWindowPlacement?.failedToEnter()}
  }
  func windowDidFailToExitFullScreen(_ window:NSWindow) {
    guard window === self.window else{return}
    MainActor.assumeIsolated{
      hostedWindowPlacement?.failedToExit()
      hostedPresentation?.fullscreenTransitionFailed()
    }
  }
  // Called only at initial startup or while every session/store operation is idle.
  func configureRuntimeClients() {
    MainActor.assumeIsolated { steamLibrary?.stop(); steamLibrary=nil; steamNetwork?.stop(); steamNetwork = nil }
    session = SessionManager(paths: paths, project: project, runtimeRoot: runtimeRoot)
    session.preparePresentation = {[weak self] game,variant,sessionID,completion in
      guard let self else{completion(.failure(LauncherError.failed("Finestra del launcher non disponibile.")));return}
      MainActor.assumeIsolated{self.prepareHostedGamePresentation(game:game,variant:variant,sessionID:sessionID,completion:completion)}
    }
    session.onWillLaunch = { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated{
        self.canvas.artworkCache.beginGameplay(retainingViewport:self.canvas.gameplayViewportGames)
        self.setSteamMaintenanceSuspended(true)
      }
      // Authentication is excluded by launchGame and all pending/session input gates.
      let notices = self.pages.detachForSession() + self.dialogs.detachForSession()
      self.canvas.section = .library
      for notice in notices where !self.backgroundNotices.contains(notice) {
        self.backgroundNotices.append(notice)
      }
      if self.backgroundNotices.count > 8 {
        self.backgroundNotices = Array(self.backgroundNotices.suffix(8))
      }
      if self.session.keepsLauncherWindow && MainActor.assumeIsolated({self.hostedPresentation?.active==true}) {
        // The controller retains the rendered canvas until the first validated
        // host PRESENT replaces it. Releasing here would expose a black layer.
        self.window.makeKeyAndOrderFront(nil)
      } else {
        self.canvas.releaseGraphics()
        self.window.orderOut(nil)
        self.window.contentView = nil
      }
    }
    session.onFinish = { [weak self] message in
      self?.steamNativeGame?.stop(); self?.steamNativeGame = nil
      self?.restoreLauncher(message)
      self?.dialogs.attach()
      if let self,let destination=self.launchReturnGame {
        self.launchReturnGame=nil
        if self.state.activeProfile==destination.profile {
          MainActor.assumeIsolated { self.showGameDetails(id:destination.id) }
        }
      }
    }
    MainActor.assumeIsolated {
      if let steamAccounts { for profile in state.profiles { steamAccounts.cancel(profile: profile.id) } }
    }
    storeClient?.cancelAll()
    storeClient = StoreClient(project: project, stateRoot: paths.root, runtimeRoot: runtimeRoot)
    MainActor.assumeIsolated { steamAccounts = SteamAccountCoordinator(client: storeClient) }
  }
  func setupMenu() {
    let menu = NSMenu()
    let app = NSMenuItem()
    menu.addItem(app)
    app.submenu = NSMenu()
    app.submenu?.addItem(
      withTitle: "Esci da ready", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    let library = NSMenuItem(title: "Libreria", action: nil, keyEquivalent: "")
    menu.addItem(library)
    library.submenu = NSMenu()
    for (name, key, selector) in [
      ("Importa gioco…", "o", #selector(importGame)), ("Cerca…", "f", #selector(search)),
      ("Profili…", "u", #selector(profiles)), ("Impostazioni", ",", #selector(settings)),
      ("Motori…", "", #selector(runtimeLocationSettings)),
      ("Dati e ripristino…", "", #selector(dataMaintenance)),
      ("Notifiche…", "", #selector(showNotifications)),
    ] {
      let item = library.submenu!.addItem(withTitle: name, action: selector, keyEquivalent: key)
      item.target = self
    }
    let steam=NSMenuItem(title:"Steam",action:nil,keyEquivalent:"");menu.addItem(steam);steam.submenu=NSMenu()
    for(name,selector)in [("Account, amici e attività…",#selector(steamAccountAction)),("Download…",#selector(steamDownloadsAction)),("Riconnetti",#selector(steamReconnectAction)),("Modalità offline",#selector(steamOfflineAction))] {
      steam.submenu?.addItem(withTitle:name,action:selector,keyEquivalent:"").target=self
    }
    let w = NSMenuItem(title: "Finestra", action: nil, keyEquivalent: "")
    menu.addItem(w)
    w.submenu = NSMenu()
    let f = w.submenu!.addItem(
      withTitle: "Schermo intero", action: #selector(toggleFullscreen), keyEquivalent: "f")
    f.keyEquivalentModifierMask = [.command, .control]
    f.target = self
    NSApp.mainMenu = menu
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let busy =
      session?.running == true || maintenanceInProgress || pendingLaunch != nil
      || dialogs.isPresenting
    let interfaceActions: [Selector] = [
      #selector(importGame), #selector(search), #selector(profiles),
      #selector(settings), #selector(runtimeLocationSettings), #selector(dataMaintenance),
      #selector(showNotifications),
      #selector(toggleFullscreen),
      #selector(steamAccountAction),#selector(steamDownloadsAction),#selector(steamReconnectAction),#selector(steamOfflineAction),
    ]
    if let action = item.action, interfaceActions.contains(action) {
      if action == #selector(toggleFullscreen),MainActor.assumeIsolated({hostedPresentation?.active==true}){return true}
      if action == #selector(profiles), authenticationSession != nil { return false }
      return !busy
    }
    return true
  }
  func action(_ action: CanvasAction) {
    guard !maintenanceInProgress, !dialogs.isPresenting else { return }
    switch action {
    case .game(let id): MainActor.assumeIsolated { showGameDetails(id: id) }
    case .gameOptions(let id): gameOptions(id)
    case .librarySection(let other): canvas.showOtherContent=other;canvas.selected=0;canvas.refresh()
    case .store(let store):
      navigateToLibrary(store: store)
    case .profiles: profiles()
    case .importGame: importGame()
    case .settings: settings()
    case .steamAccount: MainActor.assumeIsolated { showSteamAccount() }
    case .downloads: MainActor.assumeIsolated { showSteamDownloads() }
    case .search: search()
    case .fullscreen: toggleFullscreen()
    case .refresh:
      if canvas.section == .settings { openSettingsSection(settingsPageSection) }
      else if canvas.section == .steamAccount { _ = MainActor.assumeIsolated { steamNetwork?.request("snapshot") { _ in } } }
      else if canvas.section == .downloads { MainActor.assumeIsolated { steamDownloads?.restore() } }
      else { refreshLocal() }
    }
  }
  @objc func toggleFullscreen() {
    let restored=MainActor.assumeIsolated { () -> Bool in
      guard let placement=hostedWindowPlacement,placement.isFullscreenOrEntering else{return false}
      if let hostedPresentation{hostedPresentation.leaveFullscreen()}else{placement.restore()}
      return true
    }
    if !restored{window.toggleFullScreen(nil)}
  }
  @objc func steamAccountAction(){MainActor.assumeIsolated{showSteamAccount()}}
  @objc func steamDownloadsAction(){MainActor.assumeIsolated{showSteamDownloads()}}
  @objc func steamReconnectAction(){MainActor.assumeIsolated{if steamNetwork==nil{configureSteamNetwork()};steamNetwork?.reconnect()}}
  @objc func steamOfflineAction(){MainActor.assumeIsolated{steamNetwork?.goOffline()}}
  func refreshLocal() {
    guard !maintenanceInProgress else { return }
    do {
      for var item in try LocalDiscovery.steamLibraries() {
        if let index = state.games.firstIndex(where: { $0.id == item.id }) {
          var existing = state.games[index]
          for installed in item.variants {
            if let j = existing.variants.firstIndex(where: { $0.id == installed.id }) {
              existing.variants[j] = installed
            } else {
              existing.variants.append(installed)
            }
          }
          if existing.profileIDs == nil { existing.profileIDs = [state.activeProfile] }
          state.games[index] = existing
        } else {
          item.profileIDs = [state.activeProfile]
          state.games.append(item)
        }
      }
      try persist()
    } catch {
      canvas.message = error.localizedDescription
      canvas.refresh()
    }
  }
  func persist() throws {
    try repository.save(state)
    canvas.state = state
    canvas.refresh()
  }
  @objc func importGame() {
    guard !maintenanceInProgress, !dialogs.isPresenting else { return }
    beginPage(.utility)
    let profile = state.activeProfile
    selectLocalFile(
      title: "Importa un’app macOS o un eseguibile Windows", prompt: "Importa",
      directory: FileManager.default.homeDirectoryForCurrentUser, mode: .file
    ) { [weak self] url in
      guard let self, let url else { return }
      do {
        guard !self.maintenanceInProgress, !self.session.running, self.pendingLaunch == nil,
          self.state.activeProfile == profile
        else { throw LauncherError.busy }
        var game = try LocalDiscovery.importGame(url)
        let importedExecutable = URL(fileURLWithPath: game.storeID).resolvingSymlinksInPath()
        if let existing = self.state.games.firstIndex(where: {
          $0.store == .local
            && URL(fileURLWithPath: $0.storeID).resolvingSymlinksInPath() == importedExecutable
        }) {
          let previous = self.state.games[existing]
          game.id = previous.id
          game.profileIDs = previous.profileIDs.map { Array(Set($0 + [profile])) }
          game.lastPlayed = previous.lastPlayed
          game.engine = previous.engine
          game.selectedVariant = previous.selectedVariant
          game.saveRules = previous.saveRules
          self.state.games[existing] = game
        } else {
          game.profileIDs = [profile]
          self.state.games.append(game)
        }
        self.canvas.filter = nil
        self.canvas.query = ""
        try self.persist()
        self.canvas.selected = self.canvas.visibleGames.firstIndex(where: { $0.id == game.id }) ?? 0
        self.canvas.refresh()
      } catch { self.showError(error) }
    }
  }
  @objc func search() {
    beginPage(.utility)
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 540, height: 28))
    input.stringValue = canvas.query
    input.placeholderString = "Titolo del gioco"
    presentDialog(
      title: "Cerca nella libreria", message: "", content: input,
      actions: [.init("Cerca", role: .primary), .init("Annulla", role: .cancel)]
    ) { [weak self] choice in
      guard let self, choice == 0 else { return }
      self.canvas.query = input.stringValue
      self.canvas.selected = 0
      self.canvas.refresh()
    }
  }
  @objc func profiles() {
    guard authenticationSession == nil, !session.running, pendingLaunch == nil,
      !maintenanceInProgress
    else {
      showError(
        LauncherError.unavailable("Completa le operazioni in corso prima di cambiare profilo."))
      return
    }
    beginPage(.profiles)
    let profiles = state.profiles
    let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 540, height: 30))
    pick.addItems(withTitles: profiles.map { $0.name })
    pick.selectItem(at: profiles.firstIndex { $0.id == state.activeProfile } ?? 0)
    presentDialog(
      title: "Profili ready",
      message:
        "Ogni gioco Windows ha un ambiente isolato per questo profilo. Motori e installazioni restano condivisi.",
      content: pick,
      actions: [
        .init("Seleziona", role: .primary), .init("Nuovo profilo"), .init("Annulla", role: .cancel),
      ]
    ) { [weak self] choice in
      guard let self, choice == 0 || choice == 1 else { return }
      guard self.authenticationSession == nil, !self.session.running, self.pendingLaunch == nil,
        !self.maintenanceInProgress
      else {
        self.showError(LauncherError.busy)
        return
      }
      if choice == 0 {
        guard profiles.indices.contains(pick.indexOfSelectedItem),
          self.state.profiles.contains(where: { $0.id == profiles[pick.indexOfSelectedItem].id })
        else { return }
        MainActor.assumeIsolated { self.steamAccounts.cancel(profile: self.state.activeProfile) }
        self.state.activeProfile = profiles[pick.indexOfSelectedItem].id
        MainActor.assumeIsolated { self.configureSteamNetwork() }
        do { try self.persist() } catch { self.showError(error) }
      } else {
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 540, height: 28))
        input.placeholderString = "Nome del profilo"
        self.presentDialog(
          title: "Nuovo profilo", message: "", content: input,
          actions: [.init("Crea", role: .primary), .init("Annulla", role: .cancel)]
        ) { [weak self] choice in
          guard let self, choice == 0 else { return }
          guard self.authenticationSession == nil, !self.session.running, self.pendingLaunch == nil,
            !self.maintenanceInProgress
          else {
            self.showError(LauncherError.busy)
            return
          }
          let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !name.isEmpty else {
            self.showError(LauncherError.invalid("Inserisci il nome del profilo."))
            return
          }
          let profile = Profile(name: name)
          MainActor.assumeIsolated { self.steamAccounts.cancel(profile: self.state.activeProfile) }
          self.state.profiles.append(profile)
          self.state.activeProfile = profile.id
          MainActor.assumeIsolated { self.configureSteamNetwork() }
          do { try self.persist() } catch { self.showError(error) }
        }
      }
    }
  }
  func activateGame(_ id: String) {
    guard let index = state.games.firstIndex(where: { $0.id == id }) else { return }
    let game = state.configured(state.games[index])
    guard let variant = game.currentVariant else {
      gameOptions(id, advanced: false)
      return
    }
    if variant.installed {
      launchGame(game, variant: variant)
    } else if game.variants.count == 1 {
      installGame(index: index, variant: variant)
    } else {
      gameOptions(id, advanced: false)
    }
  }
  func gameOptions(_ id: String, advanced: Bool = true) {
    guard !maintenanceInProgress else { return }
    guard let index = state.games.firstIndex(where: { $0.id == id }) else { return }
    var game = state.configured(state.games[index])
    let preferenceKey = GamePreferences.key(profile: state.activeProfile, gameID: game.id)
    let profile = state.activeProfile
    var detail =
      advanced
      ? "Opzioni avanzate. Il percorso automatico usa solo combinazioni disponibili e verificate."
      : "Scegli la versione da installare. Il launcher prepara automaticamente il suo ambiente."
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: advanced ? 126 : 34))
    let version = NSPopUpButton(frame: NSRect(x: 0, y: advanced ? 90 : 4, width: 470, height: 28))
    let engine = NSPopUpButton(frame: NSRect(x: 0, y: 47, width: 470, height: 28))
    let controller = NSPopUpButton(frame: NSRect(x: 0, y: 4, width: 470, height: 28))
    controller.addItems(withTitles: ControllerInputMode.allCases.map { $0.title })
    controller.selectItem(
      at: ControllerInputMode.allCases.firstIndex(of: game.controllerInputMode ?? .automatic) ?? 0)
    if advanced {
      detail +=
        "\nController per questo profilo, dal prossimo avvio. Automatico rispetta le DLL XInput note del gioco; Forza richiede i builtin Wine senza modificare i file."
    }
    version.addItems(
      withTitles: game.variants.map {
        $0.title + ($0.installed ? " · installato" : " · da installare")
      })
    if let preferred = game.currentVariant,
      let i = game.variants.firstIndex(where: { $0.id == preferred.id })
    {
      version.selectItem(at: i)
    }
    engine.addItems(withTitles: GraphicsEngine.allCases.map { $0.title })
    engine.selectItem(at: GraphicsEngine.allCases.firstIndex(of: game.engine) ?? 0)
    host.addSubview(version)
    if advanced {
      host.addSubview(engine)
      host.addSubview(controller)
    }
    presentDialog(
      title: game.title, message: detail, content: host,
      actions: [
        .init(
          game.currentVariant?.installed == false ? "Installa" : "Gioca", role: .primary,
          enabled: !game.variants.isEmpty),
        .init(advanced ? "Salva opzioni" : "Opzioni avanzate…"), .init("Annulla", role: .cancel),
      ]
    ) { [weak self] result in
      guard let self, result == 0 || result == 1 else { return }
      guard !self.maintenanceInProgress, !self.session.running, self.pendingLaunch == nil,
        self.authenticationSession == nil, self.state.activeProfile == profile,
        let index = self.state.games.firstIndex(where: { $0.id == id })
      else {
        self.showError(LauncherError.busy)
        return
      }
      if !advanced, result == 1 {
        self.gameOptions(id, advanced: true)
        return
      }
      guard game.variants.indices.contains(version.indexOfSelectedItem),
        GraphicsEngine.allCases.indices.contains(engine.indexOfSelectedItem),
        ControllerInputMode.allCases.indices.contains(controller.indexOfSelectedItem)
      else {
        self.showError(LauncherError.unavailable("Nessuna versione disponibile."))
        return
      }
      let chosen = game.variants[version.indexOfSelectedItem]
      let current = self.state.configured(self.state.games[index])
      guard let currentVariant = current.variants.first(where: { $0.id == chosen.id }),
        currentVariant == chosen
      else {
        self.showError(
          LauncherError.unavailable(
            "La versione del gioco è cambiata. Riapri le opzioni prima di continuare."))
        return
      }
      game = current
      game.engine = GraphicsEngine.allCases[engine.indexOfSelectedItem]
      if advanced {
        game.controllerInputMode = ControllerInputMode.allCases[controller.indexOfSelectedItem]
      }
      guard game.variants.indices.contains(version.indexOfSelectedItem) else {
        self.showError(
          LauncherError.unavailable(
            "Nessun eseguibile verificato. Importa la versione installata o collega lo store."))
        return
      }
      game.selectedVariant = currentVariant.id
      if self.state.gamePreferences == nil { self.state.gamePreferences = [:] }
      let scopedVariants = self.state.gamePreferences?[preferenceKey]?.variants
      self.state.gamePreferences?[preferenceKey] = GamePreferences(
        engine: game.engine, selectedVariant: game.selectedVariant,
        variants: scopedVariants, controllerInputMode: game.controllerInputMode)
      try? self.persist()
      if result == 0 {
        if !currentVariant.installed {
          self.installGame(index: index, variant: currentVariant)
          return
        }
        self.launchGame(game, variant: currentVariant)

      }
    }
  }
  func launchGame(_ game: Game, variant: GameVariant) {
    guard authenticationSession == nil else {
      showError(
        LauncherError.unavailable(
          "Completa o annulla l’accesso allo store prima di avviare un gioco."))
      return
    }
    guard !session.running, pendingLaunch == nil, !maintenanceInProgress else {
      showError(LauncherError.busy)
      return
    }
    var game = game
    if variant.platform == .windows,
      variant.executable?.hasPrefix(paths.legacyPrefix.path + "/") == true
    {
      showError(
        LauncherError.unavailable(
          "Migra prima i vecchi dati da Dati e ripristino: la sorgente originale resta conservata.")
      )
      return
    }
    PEImports.annotate(&game, variant: variant)
    let profile = state.activeProfile
    let launchID = UUID()
    launchReturnGame=nil
    pendingLaunch = launchID
    MainActor.assumeIsolated { showLaunchSplash(game: game, variant: variant, launchID: launchID) }
    var steamLease: SteamGameSessionLease?
    let launch: ([String], [String: String]) -> Void = {
      [weak self] extraArguments, extraEnvironment in
      guard let self else { return }
      guard self.pendingLaunch == launchID else { return }
      self.pendingLaunch = nil
      self.canvas.message = "Caricamento"
      self.canvas.refresh()
      self.session.start(
        game: game, variant: variant, profile: profile, launchArguments: extraArguments,
        launchEnvironment: extraEnvironment, steamSession: steamLease
      ) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          MainActor.assumeIsolated {
            if self.hostedPresentation?.active != true { self.finishLaunchSplash() }
          }
          self.canvas.message = "In esecuzione · " + game.title
          // SessionManager already detached the canvas. Do not redraw it here.
          if let i = self.state.games.firstIndex(where: { $0.id == game.id }) {
            self.state.games[i].lastPlayed = Date()
            try? self.repository.save(self.state)
          }
        case .failure(let error):
          self.steamNativeGame?.stop(); self.steamNativeGame = nil
          MainActor.assumeIsolated{self.restoreLibraryArtworkAfterSession()}
          self.window.contentView = self.canvas
          self.canvas.resumeGraphics()
          self.window.makeKeyAndOrderFront(nil)
          if let destination=self.launchReturnGame,destination.id==game.id,destination.profile==profile {
            self.launchReturnGame=nil
            MainActor.assumeIsolated {
              self.finishLaunchSplash()
              if self.state.activeProfile==profile{self.showGameDetails(id:game.id)}
            }
            return
          }
          MainActor.assumeIsolated { self.resumeLaunchSplash() }
          self.showError(error)
        }
      }
    }
    if game.store == .steam {
      MainActor.assumeIsolated {
        prepareSteamGame(game, variant: variant, profile: profile, launchID: launchID) { host in
          steamLease = host
          launch([], [:])
        }
      }
    } else if game.store == .epic {
      canvas.message = "Caricamento"
      canvas.refresh()
      let options: [String: Any] = [
        "gameID": game.storeID, "platform": variant.platform.rawValue,
        "metadata": game.metadata?.mapValues { $0.foundation } ?? [:],
      ]
      storeClient.request(
        operation: "launch_info", store: game.store, profile: profile, options: options
      ) { [weak self] event in
        if event["type"] as? String == "result" {
          launch(
            event["arguments"] as? [String] ?? [], event["environment"] as? [String: String] ?? [:])
        } else if event["type"] as? String == "error" {
          if self?.pendingLaunch == launchID { self?.pendingLaunch = nil }
          self?.showError(
            LauncherError.failed(event["message"] as? String ?? "Preparazione avvio non riuscita"))
        }
      }
    } else {
      launch([], [:])
    }
  }
  @objc func settings() {
    guard !maintenanceInProgress, session?.running != true, pendingLaunch == nil else { return }
    beginSettingsSection(.overview)
    let cfg = activeRuntime()
    let detail =
      "Organizza account, motori e dati dei profili dalle schede in alto.\n\nProfilo attivo: \(state.profiles.first(where: { $0.id == state.activeProfile })?.name ?? "Giocatore")\nMotore Windows: \(cfg.wineVersion ?? "da configurare")\n\nOgni gioco Windows usa un ambiente separato per profilo. Documenti e salvataggi restano nelle cartelle persistenti del profilo.\n\nDurante il gioco Ready libera le risorse grafiche della propria interfaccia."
    presentDialog(
      title: "Preferenze di Ready", message: detail,
      actions: []
    ) { _ in }
  }
  func connectStore() {
    guard !maintenanceInProgress else { return }
    cancelAuthentication()
    beginSettingsSection(.accounts)
    let profile = state.activeProfile
    let stores: [Store] = [.steam, .epic, .gog, .amazon]
    let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 540, height: 30))
    pick.addItems(withTitles: stores.map { $0.title })
    presentDialog(
      title: "Account degli store",
      message:
        "Gli accessi appartengono solo al profilo selezionato e sono conservati nel Portachiavi.",
      content: pick,
      actions: [
        .init("Accedi", role: .primary), .init("Sincronizza libreria"),
        .init("Annulla", role: .cancel), .init("Disconnetti Steam", role: .destructive),
      ]
    ) { [weak self] choice in
      guard let self, choice == 0 || choice == 1 || choice == 3 else { return }
      guard !self.maintenanceInProgress, !self.session.running, self.pendingLaunch == nil,
        self.state.activeProfile == profile
      else {
        self.showError(LauncherError.busy)
        return
      }
      if choice == 3 {
        self.cancelAuthentication()
        MainActor.assumeIsolated { self.steamDownloads?.stop() }
        MainActor.assumeIsolated { self.steamNetwork?.logout() }
        MainActor.assumeIsolated { self.steamAccounts.signOut(profile: profile) }
        self.canvas.message = "Steam scollegato da questo profilo."
        self.canvas.refresh()
        return
      }
      self.beginStoreConnection(
        stores[pick.indexOfSelectedItem], profile: profile, synchronize: choice == 1)
    }
  }
  private func cancelStoreAuthentication(_ authentication: UUID) {
    guard authenticationSession == authentication else { return }
    cancelAuthentication()
  }
  private func dismissStoreAuthenticationPresentation(_ authentication: UUID) {
    guard authenticationSession == authentication else { return }
    let previous = qrDialog
    qrDialog = nil; qrImage = nil
    if let previous { dismissDialog(previous) } // Internal transition, no onCancel.
  }
  private func showStoreAuthenticationProgress(_ authentication: UUID, store: Store, message: String) {
    guard authenticationSession == authentication else { return }
    dismissStoreAuthenticationPresentation(authentication)
    qrDialog = presentDialog(title:"Accesso a \(store.title)",message:message,
      actions:[.init("Annulla accesso",role:.cancel)],
      onCancel:{[weak self] in self?.cancelStoreAuthentication(authentication)}) { _ in }
  }
  private func finishStoreAuthentication(_ authentication: UUID, store: Store, profile: UUID, error: Error? = nil) {
    guard authenticationSession == authentication else { return }
    dismissStoreAuthenticationPresentation(authentication)
    authenticationSession = nil; authenticationRequest = nil; steamAuthenticationRequest = nil
    if let error { showError(error); return }
    navigateToLibrary(store:store)
    syncStore(store,profile:profile)
  }
  private func beginStoreConnection(_ store: Store, profile: UUID, synchronize: Bool,
      openAuthorizationURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
    if store == .steam && !synchronize {
      MainActor.assumeIsolated { showSteamAccount() }
      return
    }
    if synchronize {
      syncStore(store, profile: profile)
      return
    }
    canvas.message = "Accesso a \(store.title)…"
    canvas.refresh()
    let authentication = UUID()
    authenticationSession = authentication
    showStoreAuthenticationProgress(authentication,store:store,message:"Preparazione dell’accesso…")
    let handleEvent: ([String: Any]) -> Void = {
      [weak self] event in
      guard let self, self.authenticationSession == authentication else { return }
      switch event["type"] as? String {
      case "error":
        self.finishStoreAuthentication(authentication,store:store,profile:profile,
          error:LauncherError.failed(event["message"] as? String ?? "Accesso non riuscito"))
      case "qr":
        if let url = event["url"] as? String ?? event["challengeUrl"] as? String {
          self.showQR(url,authentication:authentication)
        } else {
          self.cancelStoreAuthentication(authentication)
          self.showError(LauncherError.invalid("Risposta QR dello store non valida."))
        }
      case "auth_url":
        guard let address = event["url"] as? String, let url = URL(string: address),
          url.scheme == "https", url.host?.isEmpty == false,
          let authState = event["authState"] as? [String: Any]
        else {
          self.cancelStoreAuthentication(authentication)
          self.showError(LauncherError.invalid("Risposta di accesso dello store non valida."))
          return
        }
        self.dismissStoreAuthenticationPresentation(authentication)
        openAuthorizationURL(url)
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 540, height: 28))
        self.qrDialog = self.presentDialog(
          title: "Completa l’accesso a \(store.title)",
          message:
            "Accedi nel browser e incolla qui l’URL finale o il codice di autorizzazione. Il valore non viene registrato nei log.",
          content: input,
          actions: [.init("Collega", role: .primary), .init("Annulla", role: .cancel)],
          onCancel: { [weak self] in self?.cancelStoreAuthentication(authentication) }
        ) { [weak self] choice in
          guard let self, self.authenticationSession == authentication else { return }
          guard choice == 0 else {
            self.cancelStoreAuthentication(authentication)
            return
          }
          guard !input.stringValue.isEmpty else {
            self.showError(LauncherError.invalid("Inserisci l’URL finale o il codice di autorizzazione.")); return
          }
          let value = input.stringValue
          input.stringValue = ""
          let options: [String: Any] = [
            "authState": authState, value.hasPrefix("https://") ? "redirectURL" : "code": value,
          ]
          self.showStoreAuthenticationProgress(authentication,store:store,message:"Verifica dell’autorizzazione…")
          self.authenticationRequest = self.storeClient.request(
            operation: "auth_complete", store: store, profile: profile, options: options
          ) { [weak self] e in
            guard let self, self.authenticationSession == authentication else { return }
            if e["type"] as? String == "result" {
              self.finishStoreAuthentication(authentication,store:store,profile:profile)
            } else if e["type"] as? String == "error" {
              self.finishStoreAuthentication(authentication,store:store,profile:profile,
                error:LauncherError.failed(e["message"] as? String ?? "Accesso non riuscito"))
            }
          }
        }
      case "result":
        self.finishStoreAuthentication(authentication,store:store,profile:profile)
      default: break
      }
    }
    if store == .steam {
      steamAuthenticationRequest = MainActor.assumeIsolated {
        steamAccounts.authenticate(profile: profile, event: handleEvent)
      }
    } else {
      authenticationRequest = storeClient.request(
        operation: "auth_begin", store: store, profile: profile, event: handleEvent)
    }
  }
  func showQR(_ value: String, authentication: UUID) {
    guard authenticationSession == authentication else { return }
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
      cancelAuthentication()
      showError(LauncherError.failed("Codice QR non disponibile."))
      return
    }
    filter.setValue(Data(value.utf8), forKey: "inputMessage")
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)),
      let cg = CIContext().createCGImage(image, from: image.extent)
    else {
      cancelAuthentication()
      showError(LauncherError.failed("Codice QR non valido."))
      return
    }
    let qr = NSImage(cgImage: cg, size: NSSize(width: 280, height: 280))
    if let view = qrImage {
      view.image = qr
      return
    }
    dismissStoreAuthenticationPresentation(authentication)
    let view = NSImageView(frame: NSRect(x: 130, y: 0, width: 280, height: 280))
    view.image = qr
    view.imageScaling = .scaleProportionallyUpOrDown
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 280))
    host.addSubview(view)
    qrImage = view
    qrDialog = presentDialog(
      title: "Accedi con Steam Guard", message: "Scansiona con l’app Steam del tuo telefono.",
      content: host,
      actions: [.init("Annulla accesso", role: .cancel)],
      onCancel: { [weak self] in self?.cancelStoreAuthentication(authentication) }
    ) { _ in }
  }
  func syncStore(_ store: Store, profile: UUID) {
    if store == .steam {
      guard profile == state.activeProfile else { return }
      MainActor.assumeIsolated { syncSteamLibrary() }
      return
    }
    canvas.message = "Sincronizzazione \(store.title)…"
    canvas.refresh()
    let receive: ([String:Any])->Void = { [weak self] event in
      guard let self else { return }
      if event["type"] as? String == "error" {
        self.showError(
          LauncherError.failed(event["message"] as? String ?? "Sincronizzazione non riuscita"))
        return
      }
      guard let raw = event["games"], let data = try? JSONSerialization.data(withJSONObject: raw),
        let incoming = try? JSONDecoder().decode([Game].self, from: data)
      else { return }
      for var game in incoming {
        game.controllerInputMode = nil  // Only owned per-profile preferences select input policy.
        if let index = self.state.games.firstIndex(where: { $0.id == game.id }) {
          let old = self.state.games[index]
          game.engine = old.engine
          game.lastPlayed = old.lastPlayed
          game.selectedVariant = old.selectedVariant
          game.profileIDs = Array(Set((old.profileIDs ?? []) + [profile]))
          for installed in old.variants where installed.installed {
            if let v = game.variants.firstIndex(where: { $0.platform == installed.platform }) {
              game.variants[v] = installed
            } else {
              game.variants.append(installed)
            }
          }
          self.state.games[index] = game
        } else {
          game.profileIDs = [profile]
          self.state.games.append(game)
        }
      }
      self.canvas.message = "\(incoming.count) giochi sincronizzati da \(store.title)"
      try? self.persist()
    }
    if store == .steam {
      MainActor.assumeIsolated { requestSteamLibrary(profile:profile,event:receive) }
    } else { storeClient.request(operation:"library",store:store,profile:profile,event:receive) }
  }
  func installGame(index:Int,variant:GameVariant,showDownloads:Bool=true){
    MainActor.assumeIsolated { showGameInstallation(index:index,variant:variant,showDownloads:showDownloads) }
  }
  func setupControllers() {
    GCController.shouldMonitorBackgroundEvents = true
    let install: (GCController) -> Void = { [weak self] controller in
      guard let self, let gamepad = controller.extendedGamepad else { return }
      let parentSession = self.session!
      var dpad = ControllerNavigation.AxisGate()
      var stick = ControllerNavigation.AxisGate()
      let route: (ControllerNavigation.Action) -> Void = { [weak self] action in
        guard let self else { return }
        if self.dialogs.isPresenting {
          guard !self.session.running, NSApp.isActive else { return }
          self.dialogs.handleController(action)
          return
        }
        if self.pages.isPresenting {
          guard !self.session.running, !self.maintenanceInProgress, NSApp.isActive else { return }
          if let detail=self.gameDetailView,detail.window===self.window,MainActor.assumeIsolated({detail.handleController(action)}){return}
          if let install=self.installationPickerView,install.window===self.window,MainActor.assumeIsolated({install.handleController(action)}){return}
          if action == .profiles { self.profiles(); return }
          if action == .previousStore || action == .nextStore { self.navigateToLibrary(); return }
          if action == .cancel { self.navigateToLibrary(store:self.canvas.filter); return }
          if !self.pages.handleController(action) { self.canvas.handleShellController(action) }
          return
        }
        let modal = NSApp.modalWindow ?? self.window.attachedSheet
        switch ControllerNavigation.destination(
          running: self.session.running, maintenance: self.maintenanceInProgress,
          active: NSApp.isActive, hasModal: modal != nil,
          authentication: self.authenticationSession != nil)
        {
        case .ignore: return
        case .modal:
          if let modal { ControllerNavigation.handleModal(action, window: modal) }
          return
        case .authentication:
          if action == .cancel { self.cancelAuthentication() }
          return
        case .library: break
        }
        switch action {
        case .move(let direction):
          self.canvas.moveLibrarySelection(direction)
          self.canvas.refresh()
        case .activate:
          if self.canvas.visibleGames.indices.contains(self.canvas.selected) {
            MainActor.assumeIsolated { self.showGameDetails(id:self.canvas.visibleGames[self.canvas.selected].id) }
          }
        case .cancel:
          self.canvas.filter = nil
          self.canvas.query = ""
          self.canvas.selected = 0
          self.canvas.refresh()
        case .profiles: self.profiles()
        case .previousStore, .nextStore:
          let stores: [Store?] = [nil] + Store.allCases.map { Optional($0) }
          let current = stores.firstIndex { $0 == self.canvas.filter } ?? 0
          let delta = action == .previousStore ? -1 : 1
          self.canvas.filter =
            stores[
              ControllerNavigation.wrappedIndex(
                current, count: stores.count, delta: delta)]
          self.canvas.selected = 0
          self.canvas.refresh()
        }
      }
      gamepad.dpad.valueChangedHandler = { _, x, y in
        guard !parentSession.running else { return }
        ControllerNavigation.enqueue {
          if let direction = dpad.update(x: x, y: y, now: ProcessInfo.processInfo.systemUptime) {
            route(.move(direction))
          }
        }
      }
      gamepad.leftThumbstick.valueChangedHandler = { _, x, y in
        guard !parentSession.running else { return }
        ControllerNavigation.enqueue {
          if let direction = stick.update(x: x, y: y, now: ProcessInfo.processInfo.systemUptime) {
            route(.move(direction))
          }
        }
      }
      gamepad.buttonA.pressedChangedHandler = { _, _, pressed in
        guard !parentSession.running else { return }
        if pressed { ControllerNavigation.enqueue { route(.activate) } }
      }
      gamepad.buttonB.pressedChangedHandler = { _, _, pressed in
        guard !parentSession.running else { return }
        if pressed { ControllerNavigation.enqueue { route(.cancel) } }
      }
      gamepad.buttonMenu.pressedChangedHandler = { _, _, pressed in
        guard !parentSession.running else { return }
        if pressed { ControllerNavigation.enqueue { route(.profiles) } }
      }
      gamepad.leftShoulder.pressedChangedHandler = { _, _, pressed in
        guard !parentSession.running else { return }
        if pressed { ControllerNavigation.enqueue { route(.previousStore) } }
      }
      gamepad.rightShoulder.pressedChangedHandler = { _, _, pressed in
        guard !parentSession.running else { return }
        if pressed { ControllerNavigation.enqueue { route(.nextStore) } }
      }
    }
    GCController.controllers().forEach(install)
    controllerObserver = NotificationCenter.default.addObserver(
      forName: .GCControllerDidConnect, object: nil, queue: .main
    ) { n in if let c = n.object as? GCController { install(c) } }
  }
  func showError(_ error: Error) {
    // A background store callback must not recreate a composited dialog or steal
    // focus while the game owns presentation and the launcher has released its GPU work.
    if session?.running == true {
      let message = error.localizedDescription
      if !backgroundNotices.contains(message) {
        backgroundNotices.append(message)
        if backgroundNotices.count > 8 { backgroundNotices.removeFirst() }
      }
      return
    }
    if let splash = launchSplash {
      MainActor.assumeIsolated { resumeLaunchSplash() }
      splash.showError(error.localizedDescription)
      return
    }
    if pages.isPresenting { pages.showNotice(error.localizedDescription); return }
    presentDialog(
      title: "Operazione non riuscita", message: error.localizedDescription,
      actions: [.init("Chiudi", role: .cancel)]
    ) { _ in }
  }
  @objc func showNotifications() {
    guard session?.running != true, !maintenanceInProgress, pendingLaunch == nil else { return }
    beginPage(.utility)
    let notices = backgroundNotices
    presentDialog(
      title: "Notifiche",
      message: notices.isEmpty ? "Nessuna notifica in attesa." : notices.joined(separator: "\n\n"),
      actions: [.init("Chiudi", role: .cancel)]
    ) { [weak self] _ in self?.backgroundNotices.removeAll { notices.contains($0) } }
  }
}

let args = CommandLine.arguments
// Read before NSApplication/device construction. Only the user experiment
// enables the Ready process HUD; hosted guests explicitly receive HUD=0.
if args.contains("--metal-hud"){setenv("MTL_HUD_ENABLED","1",1)}
if let index=args.firstIndex(of:"--host-game-view") {
  guard args.filter({$0=="--host-game-view"}).count==1,args.indices.contains(index+1),
    !args[index+1].isEmpty,!args[index+1].hasPrefix("--"),args[index+1].utf8.count<=256,
    !args[index+1].unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{
    FileHandle.standardError.write(Data("--host-game-view requires one explicit storeID.\n".utf8));exit(64)
  }
}
if args.contains("--exclusive-hosted-view"),!args.contains("--host-game-view") {
  FileHandle.standardError.write(Data("--exclusive-hosted-view requires --host-game-view.\n".utf8));exit(64)
}
var dataPaths = LauncherPaths()
if let index = args.firstIndex(of: "--data-root") {
  guard args.indices.contains(index + 1), args[index + 1].hasPrefix("/"), args[index + 1] != "/"
  else {
    FileHandle.standardError.write(
      Data("--data-root requires an absolute application-data directory.\n".utf8))
    exit(64)
  }
  dataPaths = LauncherPaths(root: URL(fileURLWithPath: args[index + 1]))
}
let runtimeLocationActions = [
  "--set-runtime-root", "--reset-runtime-root", "--restore-runtime-root",
]
if runtimeLocationActions.contains(where: args.contains) {
  do {
    let actions = runtimeLocationActions.filter(args.contains)
    guard actions.count == 1, let dataIndex = args.firstIndex(of: "--data-root"),
      args[dataIndex + 1] == dataPaths.root.path
    else {
      throw LauncherError.invalid(
        "Runtime location changes require exactly one action and an explicit canonical --data-root."
      )
    }
    if let index = args.firstIndex(of: "--set-runtime-root") {
      guard args.indices.contains(index + 1), args[index + 1].hasPrefix("/") else {
        throw LauncherError.invalid("--set-runtime-root requires an absolute runtime directory.")
      }
      try RuntimeLocationStore.set(URL(fileURLWithPath: args[index + 1]), paths: dataPaths)
    } else if args.contains("--restore-runtime-root") {
      try RuntimeLocationStore.restorePrevious(paths: dataPaths)
    } else {
      try RuntimeLocationStore.reset(paths: dataPaths)
    }
  } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(64)
  }
}
let support = FrontendSupportPaths(paths: dataPaths)
let project = support.codeRoot
if runtimeLocationActions.contains(where: args.contains) || args.contains("--diagnostics")
  || args.contains("--frontend-self-test")
{
  // Report generation is headless and read-only. Only an explicit location
  // action above writes its owned pointer/history; no accounts or engines run.
  let config = FrontendSupportPaths.configuration(
    paths: dataPaths, runtimeRoot: support.runtimeRoot)
  let fm = FileManager.default
  let complete =
    [
      support.sessionHost, support.overlay, support.storeBridge,
      project.appendingPathComponent("StoreBridge/supervisor.py"),
      project.appendingPathComponent("LICENSE"), project.appendingPathComponent("Docs/LICENSES.md"),
    ].allSatisfy { fm.isReadableFile(atPath: $0.path) }
    && fm.isExecutableFile(atPath: support.sessionHost.path)
  var record: [String: Any] = [
    "prefixRoot": dataPaths.root.appendingPathComponent("Prefixes").path,
    "dataRoot": dataPaths.root.path, "project": project.path,
    "codeRoot": project.path, "runtimeRoot": support.runtimeRoot.path,
    "runtimeConfiguration": config.path,
    "runtimeConfigurationAvailable": fm.isReadableFile(atPath: config.path),
    "runtimeLocationOrigin": support.runtimeLocationOrigin,
    "runtimeLocationIssue": support.runtimeLocationIssue ?? "",
    "bundledFrontend": support.isBundled, "frontendSupportAvailable": complete,
    "sessionHost": support.sessionHost.path, "overlay": support.overlay.path,
    "storeBridge": support.storeBridge.path,
  ]
  do {
    let tools = try StoreToolsLocation.resolve(stateRoot: dataPaths.root, runtimeRoot: support.runtimeRoot)
    record["storeToolsRoot"] = tools.path
    record["storeToolsSelectionValid"] = true
    record["steamServiceAvailable"] = MainActor.assumeIsolated {
      SteamClientSession.installedCommand(project: project, runtimeRoot: support.runtimeRoot, stateRoot: dataPaths.root) != nil
    }
  } catch {
    record["storeToolsSelectionValid"] = false
    record["steamServiceAvailable"] = false
    record["storeToolsIssue"] = "invalid-component-selection"
  }
  if let index = args.firstIndex(of: "--native-steam-app") {
    var available = false
    if args.indices.contains(index + 1) {
      do {
        let binding = try SteamNativeHostSelection.load(runtimeRoot: support.runtimeRoot,
          gameID: args[index + 1], stateRoot: dataPaths.root)
        _ = try binding.verifiedGameAssets()
        available = true
      } catch { record["nativeSteamBindingIssue"] = "missing-or-invalid-component" }
    }
    record["nativeSteamBindingAvailable"] = available
    record["nativeSteamComponentCheckExecutedCode"] = false
  }
  if args.contains("--diagnostics") {
    let device = MTLCreateSystemDefaultDevice()
    record["device"] = device?.name ?? "none"
    record["unifiedMemory"] = device?.hasUnifiedMemory ?? false
    record["gpuAllocatedBytes"] = device?.currentAllocatedSize ?? 0
    record["recommendedWorkingSet"] = device?.recommendedMaxWorkingSetSize ?? 0
  }
  print(
    String(
      data: try JSONSerialization.data(
        withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
  if args.contains("--frontend-self-test") && !complete { exit(1) }
  if args.contains("--native-steam-app") && (record["nativeSteamBindingAvailable"] as? Bool != true) { exit(1) }
} else {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let delegate = AppDelegate(project: project, runtimeRoot: support.runtimeRoot, paths: dataPaths)
  app.delegate = delegate
  withExtendedLifetime(delegate) { app.run() }
}
