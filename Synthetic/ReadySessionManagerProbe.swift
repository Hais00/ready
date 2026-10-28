import Darwin
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore

@main struct ReadySessionManagerProbe {
  static var checks = [String: Bool]()
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw LauncherError.failed(message) }
  }
  static func spin(_ timeout: TimeInterval = 8, until predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    try require(predicate(), "Timed out waiting for test state")
  }
  static func locked(_ paths: LauncherPaths, _ profile: UUID, _ game: String) -> Bool {
    do {
      _ = try PrefixLease(paths: paths, profile: profile, gameID: game)
      return false
    } catch { return true }
  }
  static func native(
    _ id: String, _ executable: String = "/bin/sleep", _ arguments: [String] = ["15"]
  ) -> (Game, GameVariant) {
    let v = GameVariant(
      id: "native", platform: .macOS, architecture: .arm64, executable: executable,
      arguments: arguments, installed: true)
    return (Game(id: id, store: .local, storeID: id, title: id, variants: [v]), v)
  }
  static func main() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let project = root.appendingPathComponent("project")
    let paths = LauncherPaths(root: root.appendingPathComponent("data"))
    let profile = UUID()
    try fm.createDirectory(
      at: project.appendingPathComponent("Build"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(
      at: project.appendingPathComponent("Build/ReadySessionHost"),
      withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[2]))
    var managers = [SessionManager]()
    defer {
      for m in managers { m.quit() }
      try? spin(3) { managers.allSatisfy { !$0.running } }
    }
    // Native processes establish real lease/keeper behavior without any account or Wine dependency.
    let first = SessionManager(paths: paths, project: project)
    let second = SessionManager(paths: paths, project: project)
    managers += [first, second]
    var firstStarted = false
    var secondStarted = false
    var firstFinished = false
    var secondFinished = false
    let (ga, va) = native("native-A")
    let (gb, vb) = native("native-B")
    first.onFinish = { _ in
      firstFinished = true
      checks["finishCallbackMainQueue"] = Thread.isMainThread
    }
    second.onFinish = { _ in secondFinished = true }
    first.start(game: ga, variant: va, profile: profile) { result in
      if case .success = result { firstStarted = true }
      checks["completionCallbackMainQueue"] = Thread.isMainThread
    }
    try require(
      first.running && first.initializing, "Initializing must be synchronous before worker dispatch"
    )
    second.start(game: gb, variant: vb, profile: profile) {
      if case .success = $0 { secondStarted = true }
    }
    try spin { firstStarted && secondStarted }
    try require(
      locked(paths, profile, ga.id) && locked(paths, profile, gb.id),
      "Both sessions must hold their own leases")
    first.quit()
    try spin { firstFinished }
    try require(second.running && locked(paths, profile, gb.id), "Stopping A changed B")
    second.quit()
    try spin { secondFinished }
    try require(
      !locked(paths, profile, ga.id) && !locked(paths, profile, gb.id), "Session lease leaked")
    checks["independentNativeSessions"] = true
    // A child may terminate before main publishes success. Completion must precede exactly one finish.
    let quick = SessionManager(paths: paths, project: project)
    managers.append(quick)
    for i in 0..<5 {
      var order = [String]()
      let (g, v) = native("quick-\(i)", "/usr/bin/true", [])
      quick.onFinish = { _ in order.append("finish") }
      quick.start(game: g, variant: v, profile: profile) { result in
        if case .success = result { order.append("start") } else { order.append("error") }
      }
      try spin { order.count >= 2 }
      try require(order == ["start", "finish"], "Quick child lost/duplicated lifecycle callbacks")
    }
    checks["quickExitLifecycleOrdering"] = true
    // Reject launch data that would escape the selected prefix/runtime; never echo its secret value.
    let blocked = SessionManager(paths: paths, project: project)
    managers.append(blocked)
    var rejected = false
    let (blockedGame, blockedVariant) = native("blocked", "/usr/bin/true", [])
    blocked.start(
      game: blockedGame, variant: blockedVariant, profile: profile,
      launchEnvironment: ["WINEPREFIX": "DO_NOT_LOG_THIS_VALUE"]
    ) { if case .failure = $0 { rejected = true } }
    try require(rejected && !blocked.running, "Reserved environment override was accepted")
    checks["reservedEnvironmentRejectedBeforeMutation"] = true
    let missing = SessionManager(
      paths: paths, project: root.appendingPathComponent("missing-project"))
    managers.append(missing)
    var missingRejected = false
    missing.start(game: blockedGame, variant: blockedVariant, profile: profile) {
      if case .failure = $0 { missingRejected = true }
    }
    try require(
      missingRejected
        && !fm.fileExists(atPath: paths.prefix(profile: profile, gameID: blockedGame.id).path),
      "Missing host modified prefix")
    checks["missingHostPreflight"] = true
    // Fake Wine is a real child process protocol fixture, not a substitute for real renderer tests.
    let runtimeDir = project.appendingPathComponent("Runtime")
    try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
    let python = CommandLine.arguments[3]
    let wine = project.appendingPathComponent("fixture-wine")
    let server = project.appendingPathComponent("fixture-wineserver")
    let mode = project.appendingPathComponent("mode")
    let wineSource = """
      #!\(python)
      import json,os,pathlib,signal,sys,time
      prefix=pathlib.Path(os.environ['WINEPREFIX']);kind=sys.argv[1]
      mode=(pathlib.Path(__file__).parent/'mode').read_text()
      data={'pid':os.getpid(),'keeperPID':os.getppid(),'kind':kind,'overlay':any(k.startswith('M1L_') or k=='READY_OVERLAY_LIBRARY' or k=='DYLD_INSERT_LIBRARIES' for k in os.environ),'overrides':os.environ.get('WINEDLLOVERRIDES'),'extraArgs':sys.argv[2:],'extraEnv':os.environ.get('EPIC_LAUNCH_FIXTURE'),'ambientReserved':[k for k,v in os.environ.items() if v=='ready-ambient-test-value'],'launchHookAlreadyRan':(prefix/'.ready'/'launch-hook-complete').exists(),'providerPath':__file__}
      (prefix/'.ready'/('fixture-'+kind.replace('/','_')+'.json')).write_text(json.dumps(data))
      if kind=='wineboot':
       system=prefix/'drive_c'/'windows'/'system32';system.mkdir(parents=True,exist_ok=True)
       (system/'d3d11.dll').write_text('builtin:'+__file__)
       if mode=='drm-fail':print('Failed to create a DXGI factory',file=sys.stderr,flush=True)
       if mode=='hang':
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        while True:time.sleep(.03)
       if mode=='slow':time.sleep(4)
      elif kind!='regedit':
       if mode=='graphics-fail':
        print('Failed to create a DXGI factory',file=sys.stderr,flush=True)
        raise SystemExit(42)
       if mode=='drm-fail':
        print('Steam authentication failed',file=sys.stderr,flush=True)
        raise SystemExit(42)
       if mode=='graphics-hold':
        print('Failed to create a DXGI factory',file=sys.stderr,flush=True)
        (prefix/'.ready'/'graphics-ready').touch()
        time.sleep(10)
       else:time.sleep(.15)
      """
    try Data(wineSource.utf8).write(to: wine)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wine.path)
    let serverSource = """
      #!\(python)
      import json,os,pathlib,signal,sys
      prefix=pathlib.Path(os.environ['WINEPREFIX'])
      if sys.argv[1]=='-k' and (pathlib.Path(__file__).parent/'mode').read_text()!='hang':
       for p in (prefix/'.ready').glob('fixture-*.json'):
        try:os.kill(json.loads(p.read_text())['pid'],signal.SIGTERM)
        except (FileNotFoundError,ProcessLookupError):pass
      """
    try Data(serverSource.utf8).write(to: server)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
    var cfg = RuntimeConfiguration(wine: wine.path, wineServer: server.path)
    cfg.wineVersion = "fixture-1"
    cfg.runtimeID = "fixture-abi-1"
    cfg.verifiedEngines = [GraphicsEngine.wineD3D.rawValue]
    try JSONEncoder().encode(cfg).write(to: runtimeDir.appendingPathComponent("runtime.json"))
    let dummy = root.appendingPathComponent("game.exe")
    try Data("fixture".utf8).write(to: dummy)
    func windows(_ id: String) -> (Game, GameVariant) {
      let v = GameVariant(
        id: "windows", platform: .windows, executable: dummy.path, installed: true)
      return (
        Game(id: id, store: .local, storeID: id, title: id, variants: [v], engine: .wineD3D), v
      )
    }
    // Successful initialization proves stages and transitory store launch data are separated.
    try Data("normal".utf8).write(to: mode)
    let normal = SessionManager(paths: paths, project: project)
    managers.append(normal)
    var normalStarted = false
    var normalFinished = false
    let (normalGame, normalVariant) = windows("wine-normal")
    normal.onFinish = { _ in normalFinished = true }
    let normalPrefix = paths.prefix(profile: profile, gameID: normalGame.id)
    var launchHookCount = 0
    var launchHookMain = false
    var launchHookAfterInitialization = false
    var launchHookBeforeGame = false
    normal.onWillLaunch = {
      launchHookCount += 1
      launchHookMain = Thread.isMainThread
      launchHookAfterInitialization =
        fm.fileExists(
          atPath: normalPrefix.appendingPathComponent(".ready/runtime-initialized").path)
        && fm.fileExists(
          atPath: normalPrefix.appendingPathComponent(".ready/fixture-regedit.json").path)
      launchHookBeforeGame =
        normal.sessionProcessIdentifier == nil
        && !fm.fileExists(
          atPath: normalPrefix.appendingPathComponent(
            ".ready/fixture-" + dummy.path.replacingOccurrences(of: "/", with: "_") + ".json"
          ).path)
      try? Data("ready".utf8).write(
        to: normalPrefix.appendingPathComponent(".ready/launch-hook-complete"))
    }
    normal.start(
      game: normalGame, variant: normalVariant, profile: profile,
      launchArguments: ["literal;DO_NOT_LOG_THIS_VALUE"],
      launchEnvironment: ["EPIC_LAUNCH_FIXTURE": "DO_NOT_LOG_THIS_VALUE"]
    ) { if case .success = $0 { normalStarted = true } }
    try spin { normalStarted && normalFinished }
    try require(
      try String(
        contentsOf: normalPrefix.appendingPathComponent(".ready/runtime-initialized"),
        encoding: .utf8) == cfg.initializationIdentity(engine: .wineD3D),
      "Prefix marker did not use the selected provider initialization identity")
    let bootData =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: normalPrefix.appendingPathComponent(".ready/fixture-wineboot.json")))
      as! [String: Any]
    try require(
      bootData["overlay"] as? Bool == false
        && bootData["overrides"] as? String == "mscoree,mshtml=d",
      "Initialization inherited game injection or prompts")
    let gameData =
      try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: normalPrefix.appendingPathComponent(
            ".ready/fixture-" + dummy.path.replacingOccurrences(of: "/", with: "_") + ".json")))
      as! [String: Any]
    try require(
      (gameData["extraArgs"] as? [String]) == ["literal;DO_NOT_LOG_THIS_VALUE"]
        && gameData["extraEnv"] as? String == "DO_NOT_LOG_THIS_VALUE",
      "Transient store launch data was lost")
    try require(
      launchHookCount == 1 && launchHookMain && launchHookAfterInitialization
        && launchHookBeforeGame && gameData["launchHookAlreadyRan"] as? Bool == true,
      "Launch hook must finish on the main queue after initialization and before child spawn")
    checks["launchHookMainAfterInitializationBeforeSpawn"] = true
    try require(
      (bootData["ambientReserved"] as? [String]) == []
        && (gameData["ambientReserved"] as? [String]) == [],
      "Ambient renderer/prefix/injection environment reached initialization or game")
    checks["ambientReservedEnvironmentScrubbed"] = true
    checks["initializationWithoutOverlayOrMonoPrompt"] = true
    checks["transientLaunchDataSeparated"] = true
    // The marketing/global runtime ID is unchanged, but a different Wine provider
    // requires real reinitialization of this SAME prefix and fresh builtin DLLs.
    let originalInitializationIdentity = cfg.initializationIdentity(engine: .wineD3D)
    let secondWine = project.appendingPathComponent("fixture-wine-provider-2")
    try Data(wineSource.utf8).write(to: secondWine)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secondWine.path)
    let system32 = normalPrefix.appendingPathComponent("drive_c/windows/system32")
    let oldBackups = normalPrefix.appendingPathComponent(".ready/OriginalDLLs")
    try fm.createDirectory(at: oldBackups, withIntermediateDirectories: true)
    try Data("obsolete-provider-builtin".utf8).write(
      to: oldBackups.appendingPathComponent("d3d11.dll"))
    try Data("old-managed-renderer".utf8).write(to: system32.appendingPathComponent("d3d11.dll"))
    try JSONEncoder().encode(["d3d11.dll"]).write(
      to: normalPrefix.appendingPathComponent(".ready/managed-dlls.json"))
    cfg.engineWineBinaries = [GraphicsEngine.wineD3D.rawValue: secondWine.path]
    try JSONEncoder().encode(cfg).write(to: runtimeDir.appendingPathComponent("runtime.json"))
    normal.onWillLaunch = nil
    normalStarted = false
    normalFinished = false
    var providerStartError: String?
    normal.start(game: normalGame, variant: normalVariant, profile: profile) { result in
      if case .success = result { normalStarted = true }
      if case .failure(let error) = result { providerStartError = error.localizedDescription }
    }
    try spin { providerStartError != nil || (normalStarted && normalFinished) }
    try require(
      providerStartError == nil, "Changed provider failed to start: " + (providerStartError ?? ""))
    let changedInitializationIdentity = cfg.initializationIdentity(engine: .wineD3D)
    let changedMarker = try String(
      contentsOf: normalPrefix.appendingPathComponent(".ready/runtime-initialized"), encoding: .utf8
    )
    let changedBoot =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: normalPrefix.appendingPathComponent(".ready/fixture-wineboot.json")))
      as! [String: Any]
    let changedRegistry =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: normalPrefix.appendingPathComponent(".ready/fixture-regedit.json")))
      as! [String: Any]
    try require(
      originalInitializationIdentity != changedInitializationIdentity
        && changedMarker == changedInitializationIdentity
        && changedBoot["providerPath"] as? String == secondWine.path
        && changedRegistry["providerPath"] as? String == secondWine.path,
      "Changing Wine providers under one global runtime ID reused old initialization")
    let newBuiltin = try String(
      contentsOf: system32.appendingPathComponent("d3d11.dll"), encoding: .utf8)
    try require(
      newBuiltin == "builtin:" + secondWine.path
        && !fm.fileExists(atPath: oldBackups.appendingPathComponent("d3d11.dll").path),
      "Provider change restored an obsolete builtin or retained a stale original-DLL backup")
    checks["providerChangeReinitializesSamePrefix"] = true
    checks["providerChangeDoesNotRestoreObsoleteDLLs"] = true
    // A cancellation from the main-queue launch hook must prevent spawn and release its idle lease.
    let hookCancel = SessionManager(paths: paths, project: project)
    managers.append(hookCancel)
    let (hookGame, hookVariant) = native(
      "cancel-in-launch-hook", "/usr/bin/touch",
      [root.appendingPathComponent("unexpected-hook-child").path])
    var hookCancelled = false
    var hookFinished = false
    var cancelHookCount = 0
    hookCancel.onFinish = { _ in hookFinished = true }
    hookCancel.onWillLaunch = {
      cancelHookCount += 1
      hookCancel.quit()
    }
    hookCancel.start(game: hookGame, variant: hookVariant, profile: profile) {
      if case .failure = $0 { hookCancelled = true }
    }
    try spin { hookCancelled && !hookCancel.running }
    try require(
      cancelHookCount == 1 && !hookFinished
        && !fm.fileExists(atPath: root.appendingPathComponent("unexpected-hook-child").path)
        && !locked(paths, profile, hookGame.id),
      "Cancellation in launch hook spawned a child, duplicated lifecycle, or leaked the idle lease")
    checks["launchHookCancellationPreventsSpawn"] = true
    // The ledger is written BEFORE finish is delivered and only for actual graphics errors.
    for (kind, id, shouldRecord) in [
      ("graphics-fail", "wine-graphics-failure", true), ("drm-fail", "wine-drm-failure", false),
    ] {
      try Data(kind.utf8).write(to: mode)
      let manager = SessionManager(paths: paths, project: project)
      managers.append(manager)
      var ended = false
      let (game, variant) = windows(id)
      manager.onFinish = { _ in ended = true }
      manager.start(game: game, variant: variant, profile: profile) { _ in }
      try spin { ended }
      let recorded = RendererFailureLedger(paths: paths).failed(
        profile: profile, gameID: game.id, wineVersion: cfg.runtimeIdentity
      ).contains(.wineD3D)
      try require(
        recorded == shouldRecord, "Renderer ledger confused a graphics failure with a DRM failure")
    }
    checks["graphicsFailureRecordedBeforeFinish"] = true
    checks["drmFailureDoesNotPoisonRenderer"] = true
    try Data("graphics-hold".utf8).write(to: mode)
    let held = SessionManager(paths: paths, project: project)
    managers.append(held)
    var heldStarted = false
    var heldEnded = false
    let (heldGame, heldVariant) = windows("wine-user-quit")
    held.onFinish = { _ in heldEnded = true }
    held.start(game: heldGame, variant: heldVariant, profile: profile) {
      if case .success = $0 { heldStarted = true }
    }
    let heldReady = paths.prefix(profile: profile, gameID: heldGame.id).appendingPathComponent(
      ".ready/graphics-ready")
    try spin { heldStarted && fm.fileExists(atPath: heldReady.path) }
    held.quit()
    try spin { heldEnded }
    try require(
      RendererFailureLedger(paths: paths).failed(
        profile: profile, gameID: heldGame.id, wineVersion: cfg.runtimeIdentity
      ).isEmpty, "User quit was misclassified as renderer failure")
    checks["userQuitDoesNotPoisonRenderer"] = true
    // Main queue keeps servicing work during a slow initialization; quit cancels only this context.
    try Data("slow".utf8).write(to: mode)
    let cancel = SessionManager(paths: paths, project: project)
    managers.append(cancel)
    var cancelled = false
    var heartbeat = false
    let (cancelGame, cancelVariant) = windows("wine-cancel")
    cancel.start(game: cancelGame, variant: cancelVariant, profile: profile) {
      if case .failure = $0 { cancelled = true }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { heartbeat = true }
    let cancelInfo = paths.prefix(profile: profile, gameID: cancelGame.id).appendingPathComponent(
      ".ready/fixture-wineboot.json")
    try spin { heartbeat && fm.fileExists(atPath: cancelInfo.path) }
    try require(cancel.initializing, "Slow Wine blocked main queue or finished unexpectedly")
    cancel.quit()
    try spin { cancelled && !cancel.running }
    try spin { !locked(paths, profile, cancelGame.id) }
    checks["initializationIsAsynchronous"] = true
    checks["initializationCancellation"] = true
    // Even after timeout returns an error, the hung keeper's fd0 continues blocking mutations.
    try Data("hang".utf8).write(to: mode)
    let timeout = SessionManager(
      paths: paths, project: project, initializationTimeout: 0.35, shutdownGrace: 0.10)
    managers.append(timeout)
    var timedOut = false
    let (timeoutGame, timeoutVariant) = windows("wine-timeout")
    timeout.start(game: timeoutGame, variant: timeoutVariant, profile: profile) {
      if case .failure = $0 { timedOut = true }
    }
    let timeoutInfo = paths.prefix(profile: profile, gameID: timeoutGame.id).appendingPathComponent(
      ".ready/fixture-wineboot.json")
    try spin { timedOut }
    try require(
      !timeout.running && locked(paths, profile, timeoutGame.id),
      "Timeout released a living keeper's lock")
    let info =
      try JSONSerialization.jsonObject(with: Data(contentsOf: timeoutInfo)) as! [String: Any]
    let pid = (info["pid"] as! NSNumber).int32Value
    try require(kill(pid, 0) == 0, "Hung test child was not actually alive")
    kill(pid, SIGKILL)
    try spin { !locked(paths, profile, timeoutGame.id) }
    checks["timeoutKeepsLivePrefixLocked"] = true
    for file in (try? fm.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: nil)) ?? []
    {
      let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      try require(!text.contains("DO_NOT_LOG_THIS_VALUE"), "Transient launch secret reached logs")
    }
    checks["noCommandLineOrLaunchSecretLogging"] = true
    let report: [String: Any] = [
      "passed": checks.values.allSatisfy { $0 }, "checks": checks,
      "testType":
        "real-Foundation-Process-and-native-keeper; Wine protocol fixtures, not real game compatibility",
    ]
    let output = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
