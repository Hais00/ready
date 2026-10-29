<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Experimental presentation in the Ready window

The current opt-in experiment keeps Ready's existing NSWindow and requests its
native AppKit fullscreen Space before granting the presentation lease. It then
exchanges the library canvas for a CAMetalLayer. It does not move another
application's actual NSView/NSWindow objects into Ready: the guest uses local
logical AppKit objects whose windowNumber identifies the host resource.
Ready preserves native fullscreen when the game ends; explicit exit uses the
inverse AppKit transition. See [the fullscreen contract](HOSTED_FULLSCREEN.md).

An owned AppKit probe verifies native entry, primary/non-tiling flags, active
Space membership, the same window resource and actual exit. Forty-seven controlled
controller checks cover gating/cancellation/lifetime and failed-exit pointer
restoration. A partial commercial run now presents in this Space. The user confirms
physical cursor hiding and keyboard/mouse input, but the game's video cursor is
stationary in that v2 run. The v3 cursor correction is now implemented and built,
with 14 pointer CPU checks, 11 shim checks, a 30-frame/15-check offscreen GPU
fixture and 14 relocation checks passing. A new live candidate presents frames
with pointer capture and no reported pointer error; the user confirms the software cursor now follows. Input feel/parity and
performance remain open: reported stutter and approximately 37.72 native versus
34 hosted are user observations, not a controlled benchmark. Mission Control visuals and physical display corners
remain unverified. The [new checkpoint](../Validation/ready-hosted-native-space-checkpoint.json)
is separate from the historical commercial display-fill result below.

The loading canvas stays above the target layer until a validated GPU-complete
first PRESENT. A Core Animation transaction exchanges the UI for that surface;
blocking UI-resource cleanup runs only after the transaction commits. Input to
the loading canvas is disabled. A presented-handler timestamp is separate
telemetry; enqueueing a present is not called an on-glass observation.

The new native-Space path suppresses physical display capture: the legacy
`--exclusive-hosted-view` flag does not override that policy. Display capture,
shielding and manually filling the display belonged to the earlier implementation
and remain historical evidence below. A native Space, host-owned pointer and
Metal HUD composition mode are distinct properties; none establishes direct
scanout by itself.

The host acquires its own real drawable and exports that texture's IOSurface as
a Mach right. The injected guest imports that same storage and performs its
original rendering there. After the guest's GPU completion, the host calls the
real drawable's presentation method. The transport adds no host Metal command
queue/buffer/encoder, sampling pass, full-frame copy, blit or pixel readback.
This describes application code, not private driver/WindowServer/HUD work, and
it does not promise zero CPU/IPC/synchronization overhead or direct scanout.

The peer must present a private per-session nonce, the current UID from a kernel
Mach audit trailer and the expected executable path for the audited PID. Frame,
surface, dimensions, pixel format and GPU device identifiers are checked before
presentation. The keeper rechecks the pinned shim after installation admission;
store JSON cannot select this library. Steam's separate current ownership grant,
identity and genuine native-host readiness checks remain required.

There is no hidden guest-window or GPU-copy compatibility fallback. Unsupported
AppKit subclasses/selectors and drawable operations stop the guest with a bounded
error. The prototype adapts the selectors actually exercised; it does not certify
arbitrary Cocoa applications. The executable and its vendor signature are not
modified. The source-built GPL shim is a separately injected local component.

Mouse/key events originate in the host view and travel over the authenticated
session to the guest's local responder. The user-confirmed v3 pointer baseline makes Ready the
physical owner: eligibility requires a valid first frame, completed fullscreen,
focus and active Space. Guest associate/warp/cursor requests express virtual
policy; a guest acknowledgement cannot release Ready's physical pointer, and
warps alter virtual coordinates only. Physical mouse hiding and keyboard/mouse
input have partial user-confirmed evidence, while the stationary in-game video
cursor was the observed v2 bug. V3 adds a coherent virtual-global cursor cache
and caller-scoped `NSEvent.mouseLocation` reads without IPC or the original
framework getter; static callsite checks and scoped regressions pass. The user
confirms the in-game video cursor now follows, while different input feel remains
reported; a system-curve cause is unproven. Complete relative movement
and focus/Space/lock recovery are not certified. Cocoa gestures, multiple displays,
arbitrary dialogs, controllers and accessibility remain separate validation.
The guest Ready overlay is omitted in this experiment so only one transport owns
the presentation hooks; ordinary launches retain their existing overlay path.

Logical NSApplication window/menu/visibility getters are caller-scoped: the
selected main executable receives the adapted values, while framework callers
retain their original getter behavior. This avoids passing an NSObject proxy
into AppKit internals expecting real NSWindow ivars. It does not make the proxy
a fully initialized native window or establish compatibility for other helper,
plugin or framework call paths. Gesture recognizers are associated logically
with hosted views; no private native gesture provider is created. Cursor
rectangles are validated logical state rather than native OS registration.
These adaptations must not be described as complete gesture recognition,
physical cursor/relative capture, responder-chain or controller support.

The actual host layer can show Metal HUD. Its FPS/frame interval/presentation mode
belong to that layer. Host GPU timing cannot be presented as total guest frame GPU
time: the host itself encodes no game command buffers, and an optional guest
presenting-buffer interval would not account for every queue in a commercial game.
HUD instrumentation itself is additional diagnostic work.

Developer entry points:

```sh
Build/ready.app/Contents/MacOS/ready --host-game-view 1091500 --metal-hud
# The legacy --exclusive-hosted-view flag is suppressed for native Spaces.
# Optional explicit local development override; each launch pins its bytes:
Build/ready.app/Contents/MacOS/ready --host-game-view 1091500 --metal-hud \
  --host-game-shim /absolute/owned/libReadyHostedGame.dylib
```

The default path remains unchanged without the explicit experiment. A successful
synthetic-app run is not a commercial-game compatibility certificate. Exact live
checkpoints and remaining limits must accompany any claim of game support.

## Historical display-fill commercial presentation — 2026-10-29

This run predates native-Space/pointer-v2 integration. It is retained unchanged
and is not evidence that the new path works with this commercial game.

Cyberpunk 2077 completed 7,038 valid PRESENT operations and 7,038 acquisitions in
172,213.096 ms of host journal time (23,891 Mach requests). Ready PID 1694 kept its
existing window resource 8480; guest PID 3461 had no WindowServer window in the
observed census. The user confirmed that exit code zero resulted from their own
interaction. A CUA image shows the game and Metal HUD in Ready. This establishes
this bounded presentation session, not complete gameplay, all menus, physical
controllers or a performance benchmark. The elapsed time includes host/session
work and must not be converted into a general game-FPS claim.

Exclusive capture and release both returned zero. The observed shielding window
was 8533, while Ready's window remained 8480. The Metal HUD explicitly reported
**Composited**; capture success is not direct scanout. The host's application
transport recorded zero queues, command buffers, encoders, surface copies and
pixel readbacks. CPU/Mach synchronization and private framework, HUD, driver and
WindowServer work are outside that zero-counter statement.

The first GPU-complete UI transition was journaled, but the first drawable's
presented-handler result was `skipped-no-display-timestamp`. The later screenshot
confirms a rendered image, not a timestamp for that first present or a guarantee
that every startup frame was visible. The final bundle was rebuilt afterwards;
its later library CUA inspection timed out, so no final-library visual retest is
asserted here.

The [sanitized checkpoint](../Validation/ready-hosted-presentation-checkpoint.json)
binds the journal, capture metadata and screenshot hashes. Raw logs, the full
image, account identifiers and proprietary code remain local. Earlier partial
frames and failures remain historical evidence; they were not rewritten as
successful runs. No whole-application redistribution approval follows.

## V4 performance work: build verified, recovery pending

The committed v3 cursor/input evidence remains unchanged. A separate
[performance checkpoint](../Validation/ready-hosted-performance-checkpoint.json)
binds the matching-settings engine exports (37.71597 native / 34.20225 hosted
FPS, −9.3163%, +2.723 ms mean engine frame time), the pre-v4 intro/title profile
and the protocol-4 scoped fixtures. Engine CSVs describe engine timings, not
on-glass display pacing. The sampled guest VSync was false while host VSync
was true; that mismatch alone does not isolate the slowdown or stutter cause.

V4 propagates the typed VSync property/ACK/cache, avoids foreground queries in
render operations while retaining per-POLL/input checks without permission
caching across turns, and includes mode-aware input FIFO and GPU completion
deferral. Build and relocation pass. The current launch has no verified v4
frames because CUA returned no window while unlock was pending. No recovery
of stutter, input feel or performance parity is claimed. See the
[implementation and measurement audit](HOSTED_PERFORMANCE_AUDIT.md).
