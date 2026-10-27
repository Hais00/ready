# Native per-prefix session lock keeper

`SessionHost/ReadySessionHost.c` is original GPL-3.0-only C code. The arm64 helper
links only the macOS system C runtime, not AppKit, Metal, Wine, or proprietary libraries.

```sh
sh Scripts/build_session_host.sh
python3 Scripts/test_session_host.py
```

The output is `Build/ReadySessionHost`.

## Launcher handoff

1. Acquire `flock(LOCK_EX | LOCK_NB)` for the particular `(profile, game)` lock file.
2. Duplicate the locked descriptor with `dup`; wrap the duplicate in a `FileHandle`.
3. Pass that handle as the helper's `Process.standardInput`. It refers to the **same
   open-file-description**, not an independently reopened copy of the same pathname.
4. After the helper successfully starts, mark the parent's lease as handed off.
   The parent's destructor must **close without calling `flock(LOCK_UN)`**. An explicit
   unlock would remove the shared lock even while the helper still has fd0 open.
5. Keep the helper's `Process` as the supervised session. Normal completion includes
   waiting for the exact-prefix Wine server when configured.

The helper validates that fd0 is a regular file owned by the current user and obtains
or confirms its exclusive lock. It keeps fd0 until completion. The game child receives
`/dev/null` on stdin and inherits no unrelated descriptors; it does not hold the lease.
`posix_spawn` uses `POSIX_SPAWN_CLOEXEC_DEFAULT`, explicit stdout/stderr inheritance,
and a new child process group.

If the launcher crashes or is force-quit, closing its copy leaves the helper's open
description alive and therefore leaves the prefix locked. A new launcher cannot
reinitialize or swap DLLs in that prefix while this session still runs.

## Arguments

```text
ReadySessionHost [--wine-server /absolute/wineserver --prefix /absolute/prefix] -- /absolute/program [literal arguments...]
```

No shell command string is interpreted. Both program and optional Wine server are
absolute paths. A Wine server requires an explicit absolute prefix; the helper sets
`WINEPREFIX` for the child and waiter so it cannot accidentally wait on the user's
default prefix.

SIGTERM and SIGINT are forwarded only to the supervised game's process group. The
helper reaps that child. SIGHUP is ignored by the helper: disappearance of the launcher
or its terminal is not a request to close the game.

If `--wine-server` is provided, the helper then executes only that server with `-w`
and waits before releasing the lock. SIGTERM during this wait does **not** kill the
waiter and release the lease early. The launcher may separately request a graceful
or forced shutdown through the **same exact prefix's** server; no global `killall`
or unscoped server shutdown exists in this helper.

Exit status follows the main child (`128 + signal` when signalled). A Wine waiter's
nonzero status is returned when the main child otherwise succeeded. Spawn failures
are explicit errors (127 for a missing program, 126 for permission failure).

## Overlay environment

The launcher should **remove `DYLD_INSERT_LIBRARIES` from the helper's own environment**
and retain `READY_OVERLAY_LIBRARY=/absolute/Build/libReadyOverlay.dylib`. The helper
sets `DYLD_INSERT_LIBRARIES` only for the game child. The Wine shell wrapper can then
restore that path again after the protected system shell's normal environment filtering.
The Wine waiter never receives the injection variable.

This keeps the keeper small and avoids loading AppKit/Metal just to hold a lock.
No system security setting is modified.

## Verified evidence

`Evidence/session-host-tests.json` records real process tests:

- Two independent locks and process groups stay independent.
- SIGTERM to A closes only A; B remains live and locked. SIGINT to B is handled.
- The child stdin is `/dev/null`; descriptors 3–127 are closed in the test worker.
- A second independent attempt on an already locked prefix is rejected.
- A launcher shim exits abruptly with `os._exit(19)` after handoff; keeper/game and
  the actual flock survive. Sending SIGHUP does not end the session.
- An already-finished bootstrap does not release the lock while a fake exact-prefix
  `wineserver -w` is still waiting. A signal during that wait does not release it early.
- Quick success, child failure, missing executable, and invalid stdin all end cleanly.
- When the overlay probe is built, helper → injected native Metal host succeeds with
  the helper's own environment free of `DYLD_INSERT_LIBRARIES`.

The fake Wine server proves the process/lifetime contract, not Wine's protocol. Real
Wine game and server behavior still needs the runtime integration tests. Helper failure
or SIGKILL of the **keeper itself** is outside the crash-survival guarantee.

## Asynchronous Swift session manager

`Sources/M1Launcher/SessionManager.swift` exposes:

```swift
func start(
    game: Game, variant: GameVariant, profile: UUID,
    launchArguments: [String] = [],
    launchEnvironment: [String: String] = [:],
    completion: @escaping (Result<Void, Error>) -> Void
)
```

`running` includes initialization/stopping, and `initializing` becomes true before
the worker is dispatched. Completion and `onFinish` are delivered on the main queue.
Wine prefix initialization and registry import run on a worker, not AppKit's event loop.
The optional `onWillLaunch` hook runs synchronously on the main queue after prefix
setup and before spawning the game. UI resources can be released there while loading
UI remains available during initialization. Cancellation from this hook is checked
before spawn, returns a startup failure, and releases the unused lease.

The same lease's open-file-description is handed to a keeper for **every** Wine stage,
including `wineboot` and `regedit`. The parent keeps its own reference between stages;
a launcher crash during initialization therefore does not permit another launcher to
mutate that still-active prefix. Helper availability is checked before prefix mutation.

Each initialization stage has a 120-second timeout and a bounded shutdown grace period.
Cancellation signals only that stage's keeper and invokes only the context's configured
Wine server with its explicit `WINEPREFIX`. If a hung child survives the grace period,
the caller receives an error, but the native keeper still owns its lock. Returning an
error is not treated as evidence that the prefix is safe to mutate.

Initialization strips overlay variables and disables Mono/Gecko prompts only for that
stage. It does not impose those overrides on the game. Store launch arguments remain
literal argv values and are not logged; store environment cannot override `WINEPREFIX`,
renderer/loader Wine variables, or `READY_*`, `M1L_*`, and `DYLD_*` isolation controls.

Markers and renderer-failure records use `runtimeIdentity`, not merely Wine's marketing
version, so a new patched runtime cannot silently reuse another build's validation.
The graphics failure classifier reads at most the final 1 MiB of **game-only** output
on the worker, excluding initialization diagnostics. It writes only a classified failure
record before `onFinish`, never the raw diagnostics or command line. User cancellation
and DRM/authentication failures do not invalidate a renderer.

Run `python3 Scripts/test_session_manager.py` for the real Foundation `Process` and
native keeper integration checks. It tests native peer sessions and quick-exit ordering;
the Wine initialization portion uses explicitly labelled protocol fixtures. Its 18
checks include a child-observed marker proving the main-queue hook completed before
spawn, cancellation inside that hook preventing any child launch, and deliberate
ambient prefix/renderer/injection variables not leaking into initialization or game.
Evidence:
`Evidence/session-host-manager.json`. It does not claim real-game compatibility.

## Real Wine session isolation

```sh
python3 Scripts/test_wine_sessions.py
```

This separate integration test compiles an original Windows x64 executable that uses
WinAPI file writes, process identification, and sleep to produce a heartbeat. It invokes
the actual `SessionManager` with the existing local runtime configuration and two new
prefixes beneath a UUID directory in `Runtime/TestPrefixes`. No protocol fixture,
account, game, external prefix template, or existing personal directory is used.

On the verified run, both freshly initialized Windows helpers reached heartbeat 3.
Closing A stopped its heartbeat at 3 and released A's lock while B continued to 8,
remained running, and kept its own lock. Closing B stopped its heartbeat at 12 and
released the second lock after its exact-prefix Wine server wait. Both prefix markers
matched the runtime identity, and lifecycle callbacks stayed on the main thread.
`Evidence/session-host-wine-real.json` records all eight checks, runtime identity,
helper hash, and host PIDs. The script performs exact-prefix cleanup, checks that no
keeper holds a scratch lock, and removes its own UUID directory; it preserves scratch
if a keeper still owns a lock. This proves process/prefix isolation, not graphics or
game compatibility.
