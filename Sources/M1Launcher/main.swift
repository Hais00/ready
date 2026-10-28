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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let paths: LauncherPaths
  let project: URL
  var repository: LibraryRepository!
  var state = LibraryState.initial()
  var window: ReadyWindow!
  var canvas: MetalCanvas!
  var session: SessionManager!
  var controllerObserver: NSObjectProtocol?
  var storeClient: StoreClient!
  var qrPanel: NSPanel?
  var authenticationSession: UUID?
  var authenticationRequest: UUID?
  var pendingLaunch: UUID?
  var maintenanceInProgress = false
  init(project: URL, paths: LauncherPaths = LauncherPaths()) {
    self.project = project
    self.paths = paths
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      repository = LibraryRepository(paths: paths)
      state = try repository.load()
      if let plan = LegacyMigration.loadPlan(paths: paths),
        plan.status == "copied-awaiting-real-validation-original-retained"
      {
        state = try LegacyMigration.bindLibrary(state, plan: plan, paths: paths)
        try repository.save(state)
      }
    } catch { showError(error) }
    guard let device = MTLCreateSystemDefaultDevice() else {
      showError(LauncherError.unavailable("Questo Mac non dispone di Metal."))
      NSApp.terminate(nil)
      return
    }
    session = SessionManager(paths: paths, project: project)
    session.onWillLaunch = { [weak self] in
      guard let self else { return }
      self.canvas.releaseGraphics()
      self.window.orderOut(nil)
      self.window.contentView = nil
    }
    storeClient = StoreClient(project: project, stateRoot: paths.root)
    window = ReadyWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "ready"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = true
    window.backgroundColor = .black
    window.minSize = NSSize(width: 900, height: 620)
    window.delegate = self
    canvas = MetalCanvas(frame: NSRect(x: 0, y: 0, width: 1240, height: 760), device: device)
    canvas.autoresizingMask = [.width, .height]
    canvas.state = state
    canvas.onAction = { [weak self] in self?.action($0) }
    window.contentView = canvas
    window.center()
    setupMenu()
    setupControllers()
    session.onFinish = { [weak self] message in
      guard let self else { return }
      self.canvas.resumeGraphics()
      self.canvas.message = message
      self.window.contentView = self.canvas
      self.window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      self.canvas.refresh()
    }
    let args = CommandLine.arguments
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
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !CommandLine.arguments.contains("--graphics-self-test") && !session.running
      && !maintenanceInProgress
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { !maintenanceInProgress }
  func windowWillClose(_ notification: Notification) {
    if let panel = qrPanel, (notification.object as? NSWindow) === panel {
      cancelAuthentication(closePanel: false)
      qrPanel = nil
    }
  }
  func cancelAuthentication(closePanel: Bool = true) {
    authenticationSession = nil
    if let request = authenticationRequest { storeClient?.cancel(request) }
    authenticationRequest = nil
    if closePanel {
      qrPanel?.close()
      qrPanel = nil
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if maintenanceInProgress {
      showError(
        LauncherError.failed("Attendi il termine dell’operazione sui dati prima di chiudere ready.")
      )
      return .terminateCancel
    }
    if session?.running == true {
      let a = NSAlert()
      a.messageText = "Chiudere il gioco e ready?"
      a.addButton(withTitle: "Chiudi sessione")
      a.addButton(withTitle: "Annulla")
      if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
      session.quit()
    }
    storeClient?.cancelAll()
    return .terminateNow
  }
  func windowDidResize(_ notification: Notification) { canvas?.refresh() }
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
      ("Profili…", "u", #selector(profiles)), ("Account e runtime…", ",", #selector(settings)),
      ("Dati e ripristino…", "", #selector(dataMaintenance)),
    ] {
      let item = library.submenu!.addItem(withTitle: name, action: selector, keyEquivalent: key)
      item.target = self
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
  func action(_ action: CanvasAction) {
    guard !maintenanceInProgress else { return }
    switch action {
    case .game(let id): activateGame(id)
    case .gameOptions(let id): gameOptions(id)
    case .store(let store):
      canvas.filter = store
      canvas.selected = 0
      canvas.refresh()
    case .profiles: profiles()
    case .importGame: importGame()
    case .settings: settings()
    case .search: search()
    case .fullscreen: toggleFullscreen()
    case .refresh: refreshLocal()
    }
  }
  @objc func toggleFullscreen() { window.toggleFullScreen(nil) }
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
    guard !maintenanceInProgress else { return }
    let panel = NSOpenPanel()
    panel.title = "Importa un’app macOS o un eseguibile Windows"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      var game = try LocalDiscovery.importGame(url)
      game.profileIDs = [state.activeProfile]
      state.games.append(game)
      canvas.filter = nil
      try persist()
    } catch { showError(error) }
  }
  @objc func search() {
    let a = NSAlert()
    a.messageText = "Cerca nella libreria"
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
    input.stringValue = canvas.query
    a.accessoryView = input
    a.addButton(withTitle: "Cerca")
    a.addButton(withTitle: "Annulla")
    if a.runModal() == .alertFirstButtonReturn {
      canvas.query = input.stringValue
      canvas.selected = 0
      canvas.refresh()
    }
  }
  @objc func profiles() {
    guard authenticationSession == nil else {
      showError(
        LauncherError.unavailable(
          "Completa o annulla l’accesso allo store prima di cambiare profilo."))
      return
    }
    guard !session.running, pendingLaunch == nil, !maintenanceInProgress,
      authenticationSession == nil
    else {
      showError(LauncherError.busy)
      return
    }
    let a = NSAlert()
    a.messageText = "Profili ready"
    a.informativeText =
      "Ogni gioco Windows ha un ambiente isolato per questo profilo. Motori e installazioni restano condivisi."
    let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
    pick.addItems(withTitles: state.profiles.map { $0.name })
    pick.selectItem(at: state.profiles.firstIndex { $0.id == state.activeProfile } ?? 0)
    a.accessoryView = pick
    a.addButton(withTitle: "Seleziona")
    a.addButton(withTitle: "Nuovo profilo")
    a.addButton(withTitle: "Annulla")
    let result = a.runModal()
    if result == .alertFirstButtonReturn {
      state.activeProfile = state.profiles[pick.indexOfSelectedItem].id
      try? persist()
    } else if result == .alertSecondButtonReturn {
      let b = NSAlert()
      b.messageText = "Nome del profilo"
      let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
      b.accessoryView = input
      b.addButton(withTitle: "Crea")
      b.addButton(withTitle: "Annulla")
      if b.runModal() == .alertFirstButtonReturn,
        !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        let p = Profile(name: input.stringValue)
        state.profiles.append(p)
        state.activeProfile = p.id
        try? persist()
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
    let a = NSAlert()
    a.messageText = game.title
    a.informativeText =
      advanced
      ? "Opzioni avanzate. Il percorso automatico usa solo combinazioni disponibili e verificate."
      : "Scegli la versione da installare. Il launcher prepara automaticamente il suo ambiente."
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: advanced ? 83 : 34))
    let version = NSPopUpButton(frame: NSRect(x: 0, y: advanced ? 46 : 4, width: 470, height: 28))
    let engine = NSPopUpButton(frame: NSRect(x: 0, y: 4, width: 470, height: 28))
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
    if advanced { host.addSubview(engine) }
    a.accessoryView = host
    a.addButton(withTitle: game.currentVariant?.installed == false ? "Installa" : "Gioca")
    a.addButton(withTitle: advanced ? "Salva opzioni" : "Opzioni avanzate…")
    a.addButton(withTitle: "Annulla")
    let result = a.runModal()
    guard result == .alertFirstButtonReturn || result == .alertSecondButtonReturn else { return }
    if !advanced, result == .alertSecondButtonReturn {
      gameOptions(id, advanced: true)
      return
    }
    game.engine = GraphicsEngine.allCases[engine.indexOfSelectedItem]
    guard game.variants.indices.contains(version.indexOfSelectedItem) else {
      showError(
        LauncherError.unavailable(
          "Nessun eseguibile verificato. Importa la versione installata o collega lo store."))
      return
    }
    game.selectedVariant = game.variants[version.indexOfSelectedItem].id
    if state.gamePreferences == nil { state.gamePreferences = [:] }
    let scopedVariants = state.gamePreferences?[preferenceKey]?.variants
    state.gamePreferences?[preferenceKey] = GamePreferences(
      engine: game.engine, selectedVariant: game.selectedVariant,
      variants: scopedVariants)
    try? persist()
    if result == .alertFirstButtonReturn {
      if !game.variants[version.indexOfSelectedItem].installed {
        installGame(index: index, variant: game.variants[version.indexOfSelectedItem])
        return
      }
      launchGame(game, variant: game.variants[version.indexOfSelectedItem])

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
    pendingLaunch = launchID
    let launch: ([String], [String: String]) -> Void = {
      [weak self] extraArguments, extraEnvironment in
      guard let self else { return }
      guard self.pendingLaunch == launchID else { return }
      self.pendingLaunch = nil
      self.canvas.message = "Avvio di \(game.title)…"
      self.canvas.refresh()
      self.session.start(
        game: game, variant: variant, profile: profile, launchArguments: extraArguments,
        launchEnvironment: extraEnvironment
      ) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          if let i = self.state.games.firstIndex(where: { $0.id == game.id }) {
            self.state.games[i].lastPlayed = Date()
            try? self.repository.save(self.state)
          }
        case .failure(let error):
          self.window.contentView = self.canvas
          self.canvas.resumeGraphics()
          self.window.makeKeyAndOrderFront(nil)
          self.showError(error)
        }
      }
    }
    if game.store == .epic {
      canvas.message = "Preparazione accesso Epic…"
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
    let cfg = RuntimeConfiguration.load(project.appendingPathComponent("Runtime/runtime.json"))
    let a = NSAlert()
    a.messageText = "Account e runtime"
    a.informativeText =
      "Wine: \(cfg.wineVersion ?? "in preparazione")\nKosmicKrisp: \(cfg.kosmicICD == nil ? "in preparazione":"rilevato")\nGPTK 4 beta 3: componente proprietario opzionale per valutazione\n\nAmbienti isolati per gioco e profilo. Motori condivisi.\n\nDurante il gioco il frontend rilascia texture e drawable. Il direct-to-display deve essere verificato con Metal HUD."
    a.addButton(withTitle: "Chiudi")
    a.addButton(withTitle: "Collega uno store…")
    a.addButton(withTitle: "Dati e ripristino…")
    let choice = a.runModal()
    if choice == .alertSecondButtonReturn { connectStore() }
    if choice == .alertThirdButtonReturn { dataMaintenance() }
  }
  func connectStore() {
    guard !maintenanceInProgress else { return }
    cancelAuthentication()
    let profile = state.activeProfile
    let a = NSAlert()
    a.messageText = "Account degli store"
    a.informativeText =
      "Gli accessi appartengono solo al profilo selezionato e sono conservati nel Portachiavi."
    let stores: [Store] = [.steam, .epic, .gog, .amazon]
    let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 30))
    pick.addItems(withTitles: stores.map { $0.title })
    a.accessoryView = pick
    a.addButton(withTitle: "Accedi")
    a.addButton(withTitle: "Sincronizza libreria")
    a.addButton(withTitle: "Annulla")
    let choice = a.runModal()
    guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
    let store = stores[pick.indexOfSelectedItem]
    if choice == .alertSecondButtonReturn {
      syncStore(store, profile: profile)
      return
    }
    canvas.message = "Accesso a \(store.title)…"
    canvas.refresh()
    let authentication = UUID()
    authenticationSession = authentication
    authenticationRequest = storeClient.request(
      operation: "auth_begin", store: store, profile: profile
    ) {
      [weak self] event in
      guard let self, self.authenticationSession == authentication else { return }
      switch event["type"] as? String {
      case "error":
        self.authenticationSession = nil
        self.authenticationRequest = nil
        self.qrPanel?.close()
        self.showError(LauncherError.failed(event["message"] as? String ?? "Accesso non riuscito"))
      case "qr":
        if let url = event["url"] as? String ?? event["challengeUrl"] as? String {
          self.showQR(url)
        }
      case "auth_url":
        guard let address = event["url"] as? String, let url = URL(string: address),
          url.scheme == "https", let authState = event["authState"] as? [String: Any]
        else { return }
        NSWorkspace.shared.open(url)
        let prompt = NSAlert()
        prompt.messageText = "Completa l’accesso a \(store.title)"
        prompt.informativeText =
          "Accedi nel browser e incolla qui l’URL finale o il codice di autorizzazione. Il valore non viene registrato nei log."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
        prompt.accessoryView = input
        prompt.addButton(withTitle: "Collega")
        prompt.addButton(withTitle: "Annulla")
        guard prompt.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else {
          self.authenticationSession = nil
          self.authenticationRequest = nil
          return
        }
        let value = input.stringValue
        let options: [String: Any] = [
          "authState": authState, value.hasPrefix("https://") ? "redirectURL" : "code": value,
        ]
        self.authenticationRequest = self.storeClient.request(
          operation: "auth_complete", store: store, profile: profile, options: options
        ) { [weak self] e in
          guard let self, self.authenticationSession == authentication else { return }
          if e["type"] as? String == "result" {
            self.authenticationSession = nil
            self.authenticationRequest = nil
            self.syncStore(store, profile: profile)
          } else if e["type"] as? String == "error" {
            self.authenticationSession = nil
            self.authenticationRequest = nil
            self.showError(LauncherError.failed(e["message"] as? String ?? "Accesso non riuscito"))
          }
        }
      case "result":
        self.authenticationSession = nil
        self.authenticationRequest = nil
        self.qrPanel?.close()
        self.qrPanel = nil
        self.syncStore(store, profile: profile)
      default: break
      }
    }
  }
  func showQR(_ value: String) {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
    filter.setValue(Data(value.utf8), forKey: "inputMessage")
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)),
      let cg = CIContext().createCGImage(image, from: image.extent)
    else { return }
    if let panel = qrPanel,
      let view = panel.contentView?.subviews.compactMap({ $0 as? NSImageView }).first
    {
      view.image = NSImage(cgImage: cg, size: NSSize(width: 300, height: 300))
      panel.makeKeyAndOrderFront(nil)
      return
    }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 390), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    panel.title = "Accedi con Steam Guard"
    panel.delegate = self
    let view = NSImageView(frame: NSRect(x: 30, y: 70, width: 300, height: 300))
    view.image = NSImage(cgImage: cg, size: NSSize(width: 300, height: 300))
    view.imageScaling = .scaleProportionallyUpOrDown
    let label = NSTextField(labelWithString: "Scansiona con l’app Steam del tuo telefono.")
    label.frame = NSRect(x: 20, y: 18, width: 330, height: 45)
    label.maximumNumberOfLines = 2
    panel.contentView?.addSubview(view)
    panel.contentView?.addSubview(label)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    qrPanel = panel
  }
  func syncStore(_ store: Store, profile: UUID) {
    canvas.message = "Sincronizzazione \(store.title)…"
    canvas.refresh()
    storeClient.request(operation: "library", store: store, profile: profile) { [weak self] event in
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
  }
  func installGame(index: Int, variant: GameVariant) {
    guard !maintenanceInProgress else { return }
    let profile = state.activeProfile
    let game = state.games[index]
    let base = paths.root.appendingPathComponent(
      "Games/\(game.store.rawValue)/\(SafePath.component(game.storeID))/\(variant.platform.rawValue)"
    )
    do {
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    } catch {
      showError(error)
      return
    }
    canvas.message = "Installazione di \(game.title)…"
    canvas.refresh()
    let options: [String: Any] = [
      "gameID": game.storeID, "platform": variant.platform.rawValue, "installDir": base.path,
      "metadata": game.metadata?.mapValues { $0.foundation } ?? [:],
    ]
    storeClient.request(
      operation: "download", store: game.store, profile: profile, options: options
    ) { [weak self] event in
      guard let self else { return }
      switch event["type"] as? String {
      case "error":
        self.showError(LauncherError.failed(event["message"] as? String ?? "Download non riuscito"))
      case "progress":
        self.canvas.message =
          "Download \(game.title) · \(event["message"] as? String ?? "in corso")"
        self.canvas.refresh()
      case "result":
        if let raw = event["installedVariant"] as? [String: Any],
          let data = try? JSONSerialization.data(withJSONObject: raw),
          var installed = try? JSONDecoder().decode(GameVariant.self, from: data),
          let i = self.state.games.firstIndex(where: { $0.id == game.id })
        {
          installed.id = variant.id
          installed.installationRoot = event["installDir"] as? String ?? base.path
          self.state.clearVariantOverride(profile: profile, gameID: game.id, variantID: variant.id)
          PEImports.annotate(&self.state.games[i], variant: installed)
          if let j = self.state.games[i].variants.firstIndex(where: { $0.id == variant.id }) {
            self.state.games[i].variants[j] = installed
          } else {
            self.state.games[i].variants.append(installed)
          }
          self.canvas.message = "\(game.title) installato · \(installed.title)"
          try? self.persist()
          return
        }
        let message = NSAlert()
        message.messageText = "File di \(game.title) scaricati"
        message.informativeText = "Seleziona il programma di avvio per verificare l’architettura."
        message.addButton(withTitle: "Seleziona eseguibile")
        message.addButton(withTitle: "Più tardi")
        if message.runModal() == .alertFirstButtonReturn {
          let panel = NSOpenPanel()
          panel.directoryURL = base
          if panel.runModal() == .OK, let url = panel.url,
            let imported = try? LocalDiscovery.importGame(url),
            let checked = imported.variants.first,
            let i = self.state.games.firstIndex(where: { $0.id == game.id })
          {
            var v = checked
            v.id = variant.id
            v.installationRoot = base.path
            self.state.clearVariantOverride(
              profile: profile, gameID: game.id, variantID: variant.id)
            if let j = self.state.games[i].variants.firstIndex(where: { $0.id == variant.id }) {
              self.state.games[i].variants[j] = v
            }
            try? self.persist()
          }
        }
      default: break
      }
    }
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
          let delta = direction == .left || direction == .up ? -1 : 1
          self.canvas.selected = ControllerNavigation.movedSelection(
            self.canvas.selected, count: self.canvas.visibleGames.count, delta: delta)
          self.canvas.refresh()
        case .activate:
          if self.canvas.visibleGames.indices.contains(self.canvas.selected) {
            self.activateGame(self.canvas.visibleGames[self.canvas.selected].id)
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
    let a = NSAlert()
    a.messageText = "ready"
    a.informativeText = error.localizedDescription
    a.alertStyle = .warning
    a.runModal()
  }
}

let args = CommandLine.arguments
let executable = URL(fileURLWithPath: args[0]).standardizedFileURL
let developmentRoot = Bundle.main.resourceURL.flatMap {
  try? String(contentsOf: $0.appendingPathComponent("development-root.txt"))
}?.trimmingCharacters(in: .whitespacesAndNewlines)
let project = URL(
  fileURLWithPath: ProcessInfo.processInfo.environment["READY_PROJECT_ROOT"]
    ?? developmentRoot ?? FileManager.default.currentDirectoryPath)
if args.contains("--diagnostics") {
  let device = MTLCreateSystemDefaultDevice()
  let record: [String: Any] = [
    "device": device?.name ?? "none", "unifiedMemory": device?.hasUnifiedMemory ?? false,
    "gpuAllocatedBytes": device?.currentAllocatedSize ?? 0,
    "recommendedWorkingSet": device?.recommendedMaxWorkingSetSize ?? 0,
    "prefixRoot": LauncherPaths().root.appendingPathComponent("Prefixes").path,
    "project": project.path,
  ]
  print(
    String(
      data: try JSONSerialization.data(
        withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
} else {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  var dataPaths = LauncherPaths()
  if let index = args.firstIndex(of: "--data-root") {
    guard args.indices.contains(index + 1), args[index + 1].hasPrefix("/"), args[index + 1] != "/"
    else {
      FileHandle.standardError.write(
        Data("--data-root requires an absolute application-data directory.\n".utf8))
      exit(64)
    }
    dataPaths = LauncherPaths(root: URL(fileURLWithPath: args[index + 1]).standardizedFileURL)
  }
  let delegate = AppDelegate(project: project, paths: dataPaths)
  app.delegate = delegate
  withExtendedLifetime(delegate) { app.run() }
}
