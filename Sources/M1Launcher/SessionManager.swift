import AppKit
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

/// An internal capability created by an authenticated backend, never decoded
/// from store JSON or launch environment variables. A fixture is not a licence.
struct SteamKeeperHandoff {
  let input: FileHandle
  let didSpawn: () throws -> Void
}
protocol SteamGameSessionLease: AnyObject {
  var sessionID: UUID { get }
  var profile: UUID { get }
  var gameID: UInt32 { get }
  var platform: GamePlatform { get }
  var isReady: Bool { get }
  var keeperArguments: [String] { get }
  var onInvalidated: (() -> Void)? { get set }
  func validatedEnvironment(game: Game, variant: GameVariant, profile: UUID) throws -> [String: String]
  func keeperInput(prefixLease: FileHandle) throws -> SteamKeeperHandoff
  func takeGameHealthReadFD() throws -> Int32
  func stop()
  func stop(completion: @escaping () -> Void)
}
extension SteamGameSessionLease {
  // Simple fixtures/leases have no asynchronous process to reap. Real native
  // hosts override this barrier and complete only after process AND reader EOF.
  func stop(completion: @escaping () -> Void) { stop(); completion() }
}

/// Main-queue lifecycle + a worker for prefix initialization. Every Wine process is supervised.
final class SessionManager {
  private enum Phase { case idle, initializing, playing, stopping }
  private final class Context {
    let id: UUID
    let game: Game
    let variant: GameVariant
    let profile: UUID
    let runtime: RuntimeConfiguration
    let prefix: URL?
    let directory: URL
    let host: URL
    let extraArguments: [String]
    let extraEnvironment: [String: String]
    let steamSession: SteamGameSessionLease?
    var steamHandoff: SteamKeeperHandoff?
    var completion: ((Result<Void, Error>) -> Void)?  // Accessed on the main queue only.
    var reportedStart = false
    var pendingExit: Int32?
    var finishing = false  // Main-queue-only exit de-duplication.
    var cleaning = false, cleanupCompleted = false  // Main-queue-only barrier ownership.
    var selectedEngine: GraphicsEngine = .automatic
    var logURL: URL?
    var gameLogOffset: UInt64 = 0
    var lease: PrefixLease?  // Worker owns until it publishes a result on the main queue.
    var log: FileHandle?
    private let lock = NSLock()
    private var cancelled = false
    private var child: Process?
    init(
      game: Game, variant: GameVariant, profile: UUID, runtime: RuntimeConfiguration,
      paths: LauncherPaths, host: URL, arguments: [String], environment: [String: String],
      steamSession: SteamGameSessionLease?,
      completion: @escaping (Result<Void, Error>) -> Void
    ) {
      id = steamSession?.sessionID ?? UUID()
      self.game = game
      self.variant = variant
      self.profile = profile
      self.runtime = runtime
      prefix = variant.platform == .windows ? paths.prefix(profile: profile, gameID: game.id) : nil
      directory = paths.session(id)
      self.host = host
      extraArguments = arguments
      extraEnvironment = environment
      self.steamSession = steamSession
      self.completion = completion
    }
    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }
    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }
    func setProcess(_ value: Process?) {
      lock.lock()
      child = value
      lock.unlock()
    }
    func currentProcess() -> Process? {
      lock.lock()
      defer { lock.unlock() }
      return child
    }
    func clearProcess(_ value: Process) {
      lock.lock()
      if child === value { child = nil }
      lock.unlock()
    }
    var controlFile: URL { directory.appendingPathComponent("control.json") }
  }
  let paths: LauncherPaths
  let project: URL
  let runtimeRoot: URL
  private let stateLock = NSLock()
  private let worker = DispatchQueue(label: "ready.session.initialize", qos: .userInitiated)
  private var phase: Phase = .idle
  private var context: Context?
  private var lastSessionID = UUID()
  private var monitor: Timer?
  private var sequence = 0, selection = 0
  private var visible = false
  private var lastActionSequence = -1, lastActionPID = -1
  private var statusSnapshot: [String: Any] = [:]
  private let initializationTimeout: TimeInterval
  private let shutdownGrace: TimeInterval
  var onFinish: ((String) -> Void)?
  /// Main queue, synchronously before the game is spawned. Loading UI can stay alive during prefix setup.
  var onWillLaunch: (() -> Void)?
  var running: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return phase != .idle
  }
  var initializing: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return phase == .initializing
  }
  var overlayStatus: [String: Any] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return statusSnapshot
  }
  var controlFile: URL {
    stateLock.lock()
    defer { stateLock.unlock() }
    return context?.controlFile
      ?? paths.session(lastSessionID).appendingPathComponent("control.json")
  }
  var sessionProcessIdentifier: Int32? { currentContext()?.currentProcess()?.processIdentifier }
  init(
    paths: LauncherPaths, project: URL, runtimeRoot: URL? = nil, initializationTimeout: TimeInterval = 120,
    shutdownGrace: TimeInterval = 10
  ) {
    self.paths = paths
    self.project = project
    self.runtimeRoot = runtimeRoot ?? project.appendingPathComponent("Runtime")
    self.initializationTimeout = max(0.05, initializationTimeout)
    self.shutdownGrace = max(0.05, shutdownGrace)
  }
  private func onMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
  }
  private func currentContext() -> Context? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return context
  }
  private func isCurrent(_ value: Context) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return context === value
  }
  private func setPhase(_ value: Phase) {
    stateLock.lock()
    phase = value
    stateLock.unlock()
  }
  private func checkCancellation(_ value: Context) throws {
    if value.isCancelled { throw LauncherError.failed("Avvio annullato.") }
  }
  private static func reservedEnvironment(_ key: String) -> Bool {
    key == "WINEPREFIX" || key == "WINEDLLOVERRIDES" || key == "WINEARCH" || key == "WINELOADER"
      || key == "WINESERVER" || key == "WINEDLLPATH" || key == "VK_DRIVER_FILES"
      || key == "VK_ICD_FILENAMES" || key.hasPrefix("READY_") || key.hasPrefix("M1L_")
      || key.hasPrefix("DYLD_")
      || key.hasPrefix("Steam") || key.hasPrefix("STEAM") || key.hasPrefix("steam_")
  }
  func start(
    game: Game, variant: GameVariant, profile: UUID, launchArguments: [String] = [],
    launchEnvironment: [String: String] = [:], steamSession: SteamGameSessionLease? = nil,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    onMain { [self] in
      let complete: (Result<Void, Error>) -> Void = { result in
        if case .failure = result { steamSession?.stop() }
        completion(result)
      }
      guard !running else {
        complete(.failure(LauncherError.busy))
        return
      }
      // Direct execution can invoke SteamAPI_RestartAppIfNecessary and launch
      // Steam.app. Do not offer that path as the requested headless backend.
      // Only a typed ready host lease can replace the former blanket gate.
      // Windows remains gated until its own host/lifetime path is verified.
      if game.store == .steam {
        guard let steamSession, steamSession.isReady, steamSession.profile == profile,
          steamSession.platform == variant.platform, variant.platform == .macOS,
          UInt32(game.storeID) == steamSession.gameID else {
        complete(
          .failure(
            LauncherError.unavailable(
              "Il backend Steam senza client completo è in preparazione. L’avvio è sospeso finché autenticazione, licenza e collegamento del gioco non sono verificati."
            )))
        return
        }
      } else if steamSession != nil {
        complete(.failure(LauncherError.invalid("Sessione Steam associata allo store errato.")))
        return
      }
      if let key = launchEnvironment.keys.first(where: Self.reservedEnvironment) {
        complete(
          .failure(
            LauncherError.invalid("Lo store non può sovrascrivere la variabile riservata \(key).")))
        return
      }
      let host = project.appendingPathComponent("Build/ReadySessionHost")
      // Fail before any prefix, DLL, registry, or personal-data mutation.
      guard FileManager.default.isExecutableFile(atPath: host.path) else {
        complete(
          .failure(
            LauncherError.unavailable("Compila il supervisore con Scripts/build_session_host.sh.")))
        return
      }
      let runtime = RuntimeConfiguration.load(
        FrontendSupportPaths.configuration(paths: paths, runtimeRoot: runtimeRoot))
      let ctx = Context(
        game: game, variant: variant, profile: profile, runtime: runtime, paths: paths, host: host,
        arguments: launchArguments, environment: launchEnvironment, steamSession: steamSession,
        completion: complete)
      steamSession?.onInvalidated = { [weak self, weak ctx] in
        guard let self, let ctx else { return }
        self.onMain {
          guard self.isCurrent(ctx) else { return }
          ctx.cancel(); self.setPhase(.stopping); self.stopCurrent(ctx)
        }
      }
      stateLock.lock()
      context = ctx
      phase = .initializing
      lastSessionID = ctx.id
      statusSnapshot = [:]
      stateLock.unlock()
      lastActionSequence = -1
      lastActionPID = -1
      visible = false
      selection = 0
      sequence = 0
      worker.async { [self, ctx] in
        do { try initializeAndLaunch(ctx) } catch {
          onMain { [self, ctx] in startupFailed(ctx, error: error) }
        }
      }
    }
  }
  private func initializationEnvironment(_ ctx: Context) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in Array(env.keys)
    where Self.reservedEnvironment(key) {
      env.removeValue(forKey: key)
    }
    if let prefix = ctx.prefix { env["WINEPREFIX"] = prefix.path }
    env["WINEDEBUG"] = "-all"
    env["WINEDLLOVERRIDES"] = "mscoree,mshtml=d"
    return env
  }
  private func configureHost(
    _ ctx: Context, program: String, arguments: [String], environment: [String: String],
    directory: URL? = nil, installation: String? = nil
  ) throws -> (Process, FileHandle) {
    guard let lease = ctx.lease else { throw LauncherError.failed("Lock del prefix assente.") }
    let task = Process()
    task.executableURL = ctx.host
    var hostArguments = [String]()
    if let prefix = ctx.prefix,
      let server = ctx.runtime.engineWineServers?[ctx.selectedEngine.rawValue]
        ?? ctx.runtime.wineServer
    {
      guard server.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: server) else {
        throw LauncherError.unavailable("Wineserver non disponibile per questo runtime.")
      }
      hostArguments = ["--wine-server", server, "--prefix", prefix.path]
    }
    if let installation {
      hostArguments += [
        "--installation", installation,
        "--installation-lock-root", paths.root.appendingPathComponent("InstallLocks").path,
      ]
    }
    if let steam = ctx.steamSession { hostArguments += ["--steam-bootstrap"] + steam.keeperArguments }
    task.arguments = hostArguments + ["--", program] + arguments
    task.currentDirectoryURL = directory
    var env = environment
    env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
    task.environment = env
    let input = try lease.handleForSessionHost()
    if let steam = ctx.steamSession {
      let handoff = try steam.keeperInput(prefixLease: input)
      ctx.steamHandoff = handoff
      task.standardInput = handoff.input
    } else { task.standardInput = input }
    task.standardOutput = ctx.log ?? FileHandle.nullDevice
    task.standardError = ctx.log ?? FileHandle.nullDevice
    return (task, input)
  }
  private func runInitializationStage(
    _ ctx: Context, name: String, program: String, arguments: [String]
  ) throws {
    try checkCancellation(ctx)
    let (task, input) = try configureHost(
      ctx, program: program, arguments: arguments, environment: initializationEnvironment(ctx))
    defer { try? input.close() }
    let ended = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in ended.signal() }
    try task.run()
    ctx.lease?.markTransferredToSessionHost()
    try? input.close()
    ctx.setProcess(task)
    if ctx.isCancelled { stopCurrent(ctx) }
    if ended.wait(timeout: .now() + initializationTimeout) == .timedOut {
      ctx.cancel()
      stopCurrent(ctx)
      // The native keeper continues holding the same open-file-description even
      // if this bounded shutdown wait expires and the UI receives an error.
      _ = ended.wait(timeout: .now() + shutdownGrace)
      throw LauncherError.failed(
        "Timeout durante \(name). L’ambiente rimane protetto finché i suoi processi non terminano.")
    }
    ctx.clearProcess(task)
    try checkCancellation(ctx)
    guard task.terminationStatus == 0 else {
      throw LauncherError.failed("\(name) non riuscito · codice \(task.terminationStatus).")
    }
  }
  private func initializeAndLaunch(_ ctx: Context) throws {
    try checkCancellation(ctx)
    try paths.prepare()
    try FileManager.default.createDirectory(
      at: ctx.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    ctx.lease = try PrefixLease(paths: paths, profile: ctx.profile, gameID: ctx.game.id)
    try checkCancellation(ctx)
    let logPath = paths.logs.appendingPathComponent("session-" + ctx.id.uuidString + ".log")
    guard
      FileManager.default.createFile(
        atPath: logPath.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw LauncherError.failed("Impossibile creare il log privato della sessione.") }
    ctx.log = try FileHandle(forWritingTo: logPath)
    ctx.logURL = logPath
    let overlay = project.appendingPathComponent("Build/libReadyOverlay.dylib")
    let plan = try LaunchPlan.build(
      game: ctx.game, variant: ctx.variant, runtime: ctx.runtime, paths: paths,
      profile: ctx.profile, overlay: overlay, controlURL: ctx.controlFile)
    let installation = try ctx.variant.installationDirectory().path
    ctx.selectedEngine = plan.engine
    if plan.usesWine, let prefix = ctx.prefix {
      guard !LegacyMigration.blocksSession(paths: paths, profile: ctx.profile, gameID: ctx.game.id)
      else {
        throw LauncherError.unavailable(
          "Recupera la migrazione interrotta da Dati e ripristino prima di avviare il gioco.")
      }
      _ = try PrefixManager(paths: paths).prepare(
        profile: ctx.profile, gameID: ctx.game.id, saveRules: ctx.game.saveRules)
      try checkCancellation(ctx)
      let marker = prefix.appendingPathComponent(".ready/runtime-initialized")
      let version = ctx.runtime.initializationIdentity(engine: plan.engine)
      try EngineInstaller.prepareForRuntimeChange(version, prefix: prefix)
      // Project pure Wine PE32 builtins before wineboot. Renderer DLLs are selected
      // afterwards, so switching engines can restore the matching pure originals.
      try WindowsBuiltinBootstrap.prepare(runtime: ctx.runtime, prefix: prefix, engine: plan.engine)
      if (try? String(contentsOf: marker, encoding: .utf8)) != version {
        try runInitializationStage(
          ctx, name: "Inizializzazione Wine", program: plan.executable,
          arguments: ["wineboot", "-u"])
        _ = try PrefixManager(paths: paths).prepare(
          profile: ctx.profile, gameID: ctx.game.id, saveRules: ctx.game.saveRules)
        let registry = prefix.appendingPathComponent(".ready/folders.reg")
        let dosPath = "Z:" + registry.path.replacingOccurrences(of: "/", with: "\\")
        try runInitializationStage(
          ctx, name: "Configurazione cartelle Windows", program: plan.executable,
          arguments: ["regedit", "/S", dosPath])
        try AtomicFile.writePrivate(Data(version.utf8), to: marker)
      }
      try checkCancellation(ctx)
      try EngineInstaller.configure(plan.engine, runtime: ctx.runtime, paths: paths, prefix: prefix)
    }
    try checkCancellation(ctx)
    try AtomicFile.writePrivate(
      JSONSerialization.data(withJSONObject: ["visible": false, "selection": 0, "sequence": 1]),
      to: ctx.controlFile)
    var baseEnvironment = ProcessInfo.processInfo.environment
    for key in Array(baseEnvironment.keys) where Self.reservedEnvironment(key) {
      baseEnvironment.removeValue(forKey: key)
    }
    var gameEnvironment = baseEnvironment.merging(plan.environment) { _, new in
      new
    }
    gameEnvironment.merge(ctx.extraEnvironment) { _, new in new }
    if let steam = ctx.steamSession {
      gameEnvironment.merge(try steam.validatedEnvironment(
        game: ctx.game, variant: ctx.variant, profile: ctx.profile)) { _, trusted in trusted }
    }
    // Initialization diagnostics must not poison classification of a later DRM/game failure.
    ctx.gameLogOffset = (try? ctx.log?.seekToEnd()) ?? 0
    let (task, input) = try configureHost(
      ctx, program: plan.executable, arguments: plan.arguments + ctx.extraArguments,
      environment: gameEnvironment, directory: URL(fileURLWithPath: plan.currentDirectory),
      installation: installation)
    defer { try? input.close() }
    task.terminationHandler = { [weak self, ctx] exited in
      self?.onMain { [weak self, ctx] in self?.gameExited(ctx, status: exited.terminationStatus) }
    }
    DispatchQueue.main.sync { [self, ctx] in if isCurrent(ctx), !ctx.isCancelled { onWillLaunch?() }
    }
    try checkCancellation(ctx)
    try task.run()
    ctx.setProcess(task)
    // Before SCM_RIGHTS can duplicate the lock into the keeper, relinquish the
    // parent's right to explicitly unlock that shared open-file-description.
    ctx.lease?.markTransferredToSessionHost()
    if let handoff = ctx.steamHandoff {
      do { try handoff.didSpawn(); ctx.steamHandoff = nil }
      catch { ctx.cancel(); stopCurrent(ctx); throw error }
    }
    try? input.close()
    if ctx.isCancelled {
      stopCurrent(ctx)
      throw LauncherError.failed("Avvio annullato.")
    }
    onMain { [self, ctx, task] in
      guard isCurrent(ctx) else { return }
      sequence = 1
      ctx.reportedStart = true
      setPhase(ctx.isCancelled ? .stopping : .playing)
      let callback = ctx.completion
      ctx.completion = nil
      callback?(.success(()))
      monitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
        [weak self, weak ctx] _ in if let ctx { self?.pollOverlay(ctx) }
      }
      // A quick-exiting game may finish before this main-queue callback. Deliver
      // completion first, then a single onFinish, rather than losing the exit.
      if let exit = ctx.pendingExit {
        finishGame(ctx, status: exit)
      } else if !task.isRunning {
        finishGame(ctx, status: task.terminationStatus)
      }
    }
  }
  private func gameExited(_ ctx: Context, status: Int32) {
    guard isCurrent(ctx) else { return }
    if !ctx.reportedStart {
      ctx.pendingExit = status
      return
    }
    finishGame(ctx, status: status)
  }
  private func finishGame(_ ctx: Context, status: Int32) {
    guard isCurrent(ctx), !ctx.finishing else { return }
    ctx.finishing = true
    // At most 1 MiB is read, off the UI thread. Never persist log contents or command lines.
    worker.async { [self, ctx] in
      var diagnostic = ""
      if let file = ctx.logURL {
        if let handle = try? FileHandle(forReadingFrom: file) {
          defer { try? handle.close() }
          if let end = try? handle.seekToEnd() {
            let tailStart = end > 1_048_576 ? end - 1_048_576 : 0
            try? handle.seek(toOffset: min(end, max(tailStart, ctx.gameLogOffset)))
            if let bytes = try? handle.read(upToCount: 1_048_576) {
              diagnostic = String(decoding: bytes, as: UTF8.self)
            }
          }
        }
      }
      if ctx.prefix != nil, !ctx.isCancelled, ctx.selectedEngine != .automatic {
        if RendererFailureLedger.graphicsInitializationFailed(
          exitCode: status, userRequestedStop: ctx.isCancelled, diagnostic: diagnostic)
        {
          try? RendererFailureLedger(paths: paths).record(
            profile: ctx.profile, gameID: ctx.game.id, wineVersion: ctx.runtime.runtimeIdentity,
            engine: ctx.selectedEngine)
        }
      }
      let message =
        status == 75 && ctx.steamSession != nil
        ? "La sessione Steam non è più disponibile. Il gioco è stato chiuso."
        : status == 73 && diagnostic.contains("ReadySessionHost: installation lease busy")
        ? "Installazione in aggiornamento. Attendi il termine del download o aggiornamento e riprova."
        : "Sessione terminata · codice \(status)"
      onMain { [self, ctx] in finish(ctx, message) }
    }
  }
  private func startupFailed(_ ctx: Context, error: Error) {
    guard isCurrent(ctx), !ctx.cleaning else { return }
    let callback = ctx.completion
    ctx.completion = nil
    cleanup(ctx) { callback?(.failure(error)) }
  }
  private func cleanup(_ ctx: Context, completion: @escaping () -> Void) {
    guard isCurrent(ctx), !ctx.cleaning else { return }
    ctx.cleaning = true
    setPhase(.stopping)
    monitor?.invalidate()
    monitor = nil
    try? ctx.log?.close()
    ctx.log = nil
    ctx.steamSession?.onInvalidated = nil
    let stopped = { [self, ctx] in
      onMain { [self, ctx] in
        guard isCurrent(ctx), ctx.cleaning, !ctx.cleanupCompleted else { return }
        ctx.cleanupCompleted = true
        ctx.steamHandoff = nil
        // Break Context -> Process -> terminationHandler -> Context retention after exit.
        // A timed-out native keeper is independent and keeps its own inherited lease.
        if let task = ctx.currentProcess(), !task.isRunning { task.terminationHandler = nil }
        ctx.setProcess(nil)
        // Retain the parent lease and stopping context through native host reap.
        // A handed-off lease only closes; it never unlocks a surviving keeper.
        ctx.lease = nil
        stateLock.lock()
        if context === ctx { context = nil; phase = .idle }
        stateLock.unlock()
        completion()
      }
    }
    if let steam = ctx.steamSession { steam.stop(completion: stopped) }
    else { stopped() }
  }
  private func finish(_ ctx: Context, _ message: String) {
    guard isCurrent(ctx), !ctx.cleaning else { return }
    cleanup(ctx) { [self] in onFinish?(message) }
  }
  private func stopCurrent(_ ctx: Context) {
    guard let process = ctx.currentProcess() else { return }
    if process.isRunning { process.terminate() }
    // Scope shutdown to this context's exact prefix. No global killall/default prefix.
    if let prefix = ctx.prefix,
      let server = ctx.runtime.engineWineServers?[ctx.selectedEngine.rawValue]
        ?? ctx.runtime.wineServer,
      FileManager.default.isExecutableFile(atPath: server)
    {
      let stop = Process()
      stop.executableURL = URL(fileURLWithPath: server)
      stop.arguments = ["-k"]
      var env = initializationEnvironment(ctx)
      env["WINEPREFIX"] = prefix.path
      env.removeValue(forKey: "WINEDLLOVERRIDES")
      stop.environment = env
      stop.standardOutput = FileHandle.nullDevice
      stop.standardError = FileHandle.nullDevice
      try? stop.run()
    }
  }
  func quit() {
    onMain { [self] in
      guard let ctx = currentContext() else { return }
      ctx.cancel()
      setPhase(.stopping)
      try? writeControl(ctx, visible: false)
      stopCurrent(ctx)
    }
  }
  func overlayToggle() {
    onMain { [self] in
      guard let ctx = currentContext(), ctx.reportedStart else { return }
      try? writeControl(ctx, visible: !visible)
    }
  }
  func overlayMove(_ delta: Int) {
    onMain { [self] in
      guard let ctx = currentContext(), ctx.reportedStart, visible else { return }
      selection = (selection + delta + 2) % 2
      try? writeControl(ctx, visible: true)
    }
  }
  func overlayConfirm() {
    onMain { [self] in
      guard let ctx = currentContext(), ctx.reportedStart, visible else { return }
      if selection == 1 { quit() } else { try? writeControl(ctx, visible: false) }
    }
  }
  func resume() {
    onMain { [self] in if let ctx = currentContext() { try? writeControl(ctx, visible: false) } }
  }
  private func writeControl(_ ctx: Context, visible: Bool) throws {
    self.visible = visible
    sequence += 1
    try AtomicFile.writePrivate(
      JSONSerialization.data(withJSONObject: [
        "visible": visible, "selection": selection, "sequence": sequence,
      ]), to: ctx.controlFile)
  }
  private func pollOverlay(_ ctx: Context) {
    guard isCurrent(ctx),
      let bytes = try? Data(
        contentsOf: ctx.directory.appendingPathComponent("overlay-status.json")),
      let status = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
      (status["frameCount"] as? Int ?? 0) > 0
    else { return }
    stateLock.lock()
    statusSnapshot = status
    stateLock.unlock()
    if (status["controlSequence"] as? Int ?? -1) >= sequence {
      if let shown = status["visible"] as? Bool { visible = shown }
      if let current = status["selection"] as? Int { selection = max(0, min(current, 1)) }
    }
    let actionSequence = status["actionSequence"] as? Int ?? -1
    let actionPID = status["pid"] as? Int ?? -1
    if actionPID != lastActionPID || actionSequence != lastActionSequence,
      let action = status["requestedAction"] as? String
    {
      lastActionSequence = actionSequence
      lastActionPID = actionPID
      if action == "quit" { quit() } else if action == "resume" { resume() }
    }
  }
}
