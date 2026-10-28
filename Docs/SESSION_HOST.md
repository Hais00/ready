# Native per-prefix session lock keeper

`SessionHost/ReadySessionHost.c` is original GPL-3.0-only C code. The arm64 helper
links only the macOS system C runtime, not AppKit, Metal, Wine, or proprietary libraries.

```sh
sh Scripts/build_session_host.sh
python3 Scripts/test_session_host.py
```

The output is `Build/ReadySessionHost`. The builder compiles and signs a new temporary
inode, then publishes it with a same-filesystem rename. It never truncates or re-signs
a helper that may already be holding a live session's locks.

## Launcher handoff

1. Acquire `flock(LOCK_EX | LOCK_NB)` for the particular `(profile, game)` lock file.
2. Duplicate the locked descriptor with `dup`; wrap the duplicate in a `FileHandle`.
3. Pass that handle as the helper's `Process.standardInput`. It refers to the **same
   open-file-description**, not an independently reopened copy of the same pathname.
4. After the helper successfully starts, mark the parent's lease as handed off.
   The parent's destructor must **close without calling `flock(LOCK_UN)`**. An explicit
   unlock would remove the shared lock even while the helper still has fd0 open.
5. Keep the helper's `Process` as the supervised session. Normal completion includes
   waiting for the original native process group, or the exact-prefix Wine server
   when configured.

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
helper keeps the group leader waitable until its supervised lifetime is complete,
then reaps it. SIGHUP is ignored by the helper: disappearance of the launcher
or its terminal is not a request to close the game.

If `--wine-server` is provided, the helper then executes only that server with `-w`
and waits before releasing the lock. SIGTERM during this wait does **not** kill the
waiter and release the lease early. The launcher may separately request a graceful
or forced shutdown through the **same exact prefix's** server; no global `killall`
or unscoped server shutdown exists in this helper.

Exit status follows the main child (`128 + signal` when signalled). A Wine waiter's
nonzero status is returned when the main child otherwise succeeded. Spawn failures
are explicit errors (127 for a missing program, 126 for permission failure).

## Native wrappers and group lifetime

A native wrapper may fork the actual game and exit immediately. Without Wine,
the keeper now waits for every live member of the original process group before
releasing either the prefix lease or installation read lease. This includes a
native `.app` bootstrap whose background child stays in that group.

The keeper first uses `waitid(WEXITED | WNOWAIT)` to observe the leader's exit
without reaping it. The waitable zombie reserves the original leader PID/PGID
while descendants continue. SIGTERM/SIGINT therefore still target that group;
there is no interval in which the helper signals a reused group number after
reaping the leader. Immediately before the final reap, the keeper blocks those
signals and clears its forwarding target. It resets inherited SIGCHLD ignore /
`SA_NOCLDWAIT` dispositions before spawn so the reservation cannot disappear
automatically.

Group inspection uses system `libproc` APIs: `proc_listpids(PROC_PGRP_ONLY)` and
`proc_pidinfo(PROC_PIDTBSDINFO, arg=1)`. Darwin requires the nonzero argument to
return zombie information. This behavior was checked on the current macOS 27.0.1
host. Compiling with a macOS 14 deployment target is not runtime proof for macOS
14 or 15; unsupported/unavailable inspection retains the leases. Zombies do not
count as live game processes. A second
group snapshot must contain only the same zombie instances already observed,
verified by PID and start time; a concurrent fork/exit cannot be mistaken for an
empty live group. Both snapshots must include the keeper's own waitable zombie
leader; an empty list or missing anchor is uncertain, never completion. Truncated
lists are retried. If identity or process inspection
is uncertain, the keeper retains its leases instead of declaring the session
finished. No allocation, waiting or group enumeration runs in the signal handler.
The helper still links only the macOS system runtime, with no AppKit/Metal dependency.

The exit result remains the original wrapper/leader's status, including its
original nonzero exit. Signalling descendants after a wrapper already exited does
not rewrite that saved result. Wine continues to use its explicit exact-prefix
server wait rather than this native group-completion rule.

This is process-group supervision, not absolute containment. Processes that
voluntarily call `setsid`/`setpgid`, or games launched through LaunchServices or a
pre-existing service into another group, are outside this guarantee. The keeper
neither discovers nor terminates unrelated processes to compensate. Such launch
paths need their own explicit lifecycle integration; do not treat bootstrap exit
as proof that an independently launched application has finished. Killing the
keeper itself with SIGKILL remains outside the crash-survival guarantee.

The isolated native fixture in `Scripts/test_session_host.py` compiles an original
C executable into two temporary `.app` directories. Each wrapper exits while its
same-group child writes a heartbeat. The test observes the zombie leader through
libproc, verifies both real leases still block mutation, signals A after its leader exited while
B continues, then lets B finish naturally with leader exit 23.
A separate launcher shim crashes via `os._exit(19)`; keeper/child heartbeats and
both leases survive that crash and SIGHUP, then release after targeted SIGTERM.
That shim deliberately ignores SIGCHLD before spawning the keeper, verifying the
keeper restores a waitable child disposition.
The fixture never starts a GUI or a real game. Use
`python3 Scripts/test_session_host.py --headless` to run these process/lease checks
while explicitly skipping the optional existing Metal UI probe.

Primary API implementation references: Apple's
[waitid/reaping implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exit.c)
and [process inspection implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c).
These are references for system behavior, not copied project code.

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
- Rebuilding the actual helper while its old inode runs leaves the old descriptor's
  bytes unchanged, preserves the live child and lock, and publishes a different inode.
  Closing that session still forwards SIGTERM and releases its lease normally.
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

Prefix/DLL initialization markers use `initializationIdentity(engine:)`: the global
runtime identity, selected Wine binary, and selected pure-32-bit bootstrap directory.
Switching from one Wine provider to another therefore reruns initialization even if
the shared runtime ID has not changed. Renderer-failure records continue to use
`runtimeIdentity`; neither mechanism relies only on Wine's marketing version.
The graphics failure classifier reads at most the final 1 MiB of **game-only** output
on the worker, excluding initialization diagnostics. It writes only a classified failure
record before `onFinish`, never the raw diagnostics or command line. User cancellation
and DRM/authentication failures do not invalidate a renderer.

Run `python3 Scripts/test_session_manager.py` for the real Foundation `Process` and
native keeper integration checks. Standalone Swift probes call
`Scripts/swift_probe_support.py` to explicitly rebuild the static LauncherCore product
and link that exact archive with its matching module. They reject an older leftover
archive instead of mixing Swift value-type layouts. The suite tests native peer sessions and quick-exit ordering;
the Wine initialization portion uses explicitly labelled protocol fixtures. Its 20
checks include a child-observed marker proving the main-queue hook completed before
spawn, cancellation inside that hook preventing any child launch, and deliberate
ambient prefix/renderer/injection variables not leaking into initialization or game.
A same-prefix fixture switches only the selected Wine provider under one unchanged
runtime ID, verifies Wineboot and registry import run through the second provider,
and checks its new builtin DLL is retained instead of an obsolete managed DLL or
backup. This is a manager regression fixture, not proof of arbitrary real Wine-version
upgrades. Evidence:
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
remained running, and kept its own lock. Closing B stopped its heartbeat and
released the second lock after its exact-prefix Wine server wait. Both prefix markers
matched the selected provider initialization identity, and lifecycle callbacks stayed on the main thread.
`Evidence/session-host-wine-real.json` records all twelve checks, runtime identity,
helper hash, and host PIDs. The script performs exact-prefix cleanup, checks that no
keeper holds a scratch lock, and removes its own UUID directory; it preserves scratch
if a keeper still owns a lock. This proves process/prefix isolation, not graphics or
game compatibility.

The real test also calls the actual `StoreBridge.install_lock.installation_lease`
writer from its separate Python coordinator process. While the two Wine sessions
run, writer admission on their shared installation returns `installation_busy`.
Next, an admitted writer remains held while a third `SessionManager` initializes a
new prefix: Wineboot, registry import, and its runtime marker complete, but the
keeper exits 73 before the Windows helper can create any heartbeat. After releasing
the writer, the **same manager, prefix, executable, and launch arguments** start
successfully and are then closed cleanly. This checks both directions of the real
launcher/store integration, including that installation leases apply only to game
execution. The test routes the writer to the same selected data root's `InstallLocks` directory
as SessionManager, beneath its scratch UUID. It removes that inactive scratch only
after checking that every keeper and lock has finished.

## Shared installation files during a session

The keeper accepts `--installation /absolute/existing/game-root` before `--`. It
canonicalizes the directory, takes a shared installation lease **before spawning the
game**, verifies its path/inode identity again, and holds every lease descriptor until
the game and exact-prefix server wait have completed. Initialization stages omit this
option. Different profile prefixes can therefore run the same installation together,
while an overlapping store download/update is rejected. Busy admission exits 73 before
the game runs; invalid roots exit 64 and unsafe lock storage exits 71.

The helper's default lock directory is the same as `StoreBridge/install_lock.py`:
`~/Library/Application Support/M1Launcher/InstallLocks`. The launcher explicitly passes
`--installation-lock-root <selected-data-root>/InstallLocks`, matching the store bridge's
selected data root. The option also allows isolated integration tests. SHA-256 is provided by CommonCrypto through
libSystem; the helper still links only `/usr/lib/libSystem.B.dylib`.

Protocol v2 uses the SHA-256 filename of each path/inode key, with a brief exclusive
`admission.lock` gate around admission. The gate is released before launch. The three
channels provide symmetric ancestor/descendant conflict detection without serializing
independent sibling downloads:

| Channel | Session reader | Store writer |
| --- | --- | --- |
| Original `path:` / `inode:` keys | Shared target and ancestors for lifetime | Exclusive target, shared ancestors for lifetime |
| `intent:` plus each original key | Exclusive target probe, released under gate | Shared target and ancestors for lifetime |
| `reader:` plus each original key | Shared target for lifetime | Exclusive target and ancestor probes, released under gate |

The admission gate makes the probes and lifetime locks one atomic admission step.
Path keys survive a directory replacement; inode keys catch case/Unicode/symlink
aliases. Readers can coexist with readers, and sibling writers can coexist. Every
reader/writer must use v2; stop older v1 download processes before upgrading. Never
remove persistent lock files to clear a busy installation.

The game receives no installation lock descriptors. The native keeper remains the
owner after a launcher crash, just as it does for the prefix lock. Its exact-prefix
wait also retains the installation lease if the initial Wine wrapper exits before
the actual game. `python3 Scripts/test_session_host.py` verifies native/Python
interoperability using the real StoreBridge lease implementation, nested and parent
updates, concurrent readers, sibling writers, failure before child spawn, parent
crash survival, server-wait lifetime, and invalid/symlinked lock roots.
