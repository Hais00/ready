# Ready in-process Metal overlay

Original GPL-3.0-only source: `Overlay/ReadyOverlay.m` and `Overlay/ReadyOverlay.h`.
The build links only macOS system frameworks. It does not embed or patch D3DMetal,
GameNative's closed helpers, or Valve binaries.

## Contract

Launch an injection-compatible game process with:

```sh
M1L_CONTROL_FILE=/absolute/private/session/control.json \
M1L_OVERLAY_STATUS=/absolute/private/session/overlay-status.json \
DYLD_INSERT_LIBRARIES=/absolute/path/Build/libReadyOverlay.dylib \
/path/to/game
```

Both paths are per **session**, not global and not tied to a shared Wine prefix.
Different game/profile pairs may run in different processes with independent paths.
The parent launcher owns process termination and prefix/save lifecycle.

The private session directory must already exist. Write the control file to a temporary
file, set mode `0600`, then atomically rename it to `M1L_CONTROL_FILE`. It must be a
regular file owned by the same user and no larger than 16 KiB. Directory vnode events
are coalesced by macOS; this is not a low-latency IPC guarantee.

```json
{"sequence": 1, "visible": false, "selection": 0}
```

- Increment `sequence` for each parent command. `selection` is 0 (resume) or 1 (quit).
- An optional `action` is `resume` or `quit`. A quit command is a **request only**;
  this library never calls `exit`, kills processes, or invokes `wineserver`.
- Status includes `pid`, `visible`, `selection`, `controlSequence`, `requestedAction`,
  and `actionSequence`. Consume each `(pid, actionSequence)` only once. Acknowledge
  an action by writing a fresh control sequence with `visible:false` and no action.
- `injectionSupported` means Metal hooks are installed. Require `frameCount>0` to
  establish that the process is passing actual drawable work through the hooks.
- `metalAllocatedBytes` / `trackedTextureBytes` count the overlay panel texture only,
  not every internal driver allocation. The probe separately records the device's
  `currentAllocatedSize`. Neither metric measures WindowServer's memory.
- `gpuOverlaySubmissions` counts encoded overlay passes, while
  `completedGPUOverlaySubmissions` counts those whose command buffer completed
  successfully. `failedGPUOverlaySubmissions` and `error` report failures. In-flight
  completions can arrive just after hide; wait for them before comparing snapshots.
- `metal3OverlaySubmissions` and `metal4OverlaySubmissions` identify the actual
  entry path that injected the pass. The tiny Metal 3 helper queue in a Metal 4
  path does not count again as a Metal 3 path. Installed hook flags alone do not
  establish which API the game actually used.
- `directToDisplayVerified` deliberately remains false. The overlay cannot infer
  direct scanout merely from an opaque layer or full-screen window.

## Rendering paths

No additional `NSWindow`, `CAMetalLayer`, or compositor surface is created.

### Metal 3

The library observes the game's `CAMetalLayer.nextDrawable` and records render passes
that target that drawable. Immediately before the game's command buffer is committed,
it appends a load/store render pass into the **same texture**. It also observes the
three command-buffer `presentDrawable` variants.

Tracking render-target attachments supports the common MoltenVK style of presenting
from a scheduled handler instead of calling `presentDrawable`. The synthetic suite
tests both forms. It is not a proof of all possible compute-only or unusual multi-queue
presentation schemes.

### Metal 4

The library observes `MTL4CommandQueue.signalDrawable:`. When visible, a shared GPU
event orders:

1. The game's already committed Metal 4 work.
2. A small Metal 3 overlay command buffer writing to the same drawable.
3. The game's original drawable signal and presentation.

There is no CPU `waitUntilCompleted` in the production rendering path. No extra GPU
commands are encoded while hidden. Pipeline/panel/auxiliary queue/event references
are released on hide; command completion handlers retain the needed resources for
in-flight work, including hosts using unretained command buffers.

The panel is generated lazily at 640 × 320 pixels. Its tracked texture allocation on
the tested M1 is **835,584 bytes**, falling to **0** after hide. Status writes are
event-driven and periodically sampled, rather than written every frame.

## Input

### Hosted native games

The hosted path deliberately omits `libReadyOverlay.dylib` from the guest's
injection list. `HostedGameOverlay.swift` handles the window-scoped shortcut;
`HostedGamePresentation.swift` mounts the actual Ready canvas and navigation
pages above the game in the same NSWindow. This is the same interface, geometry
and backing scale as the launcher, without a second rasterized shell. The game
page is the default; the dock opens the real library, friends and settings, and
the running-game icon resumes play. State-changing settings remain protected
while a session is running.

Ctrl+Shift+Space opens/closes the interface and Escape resumes the game. Opening
calls `RHGHostSetOverlayVisible`, suspending guest input and pointer ownership.
The host sends a bounded `RHG_OVERLAY_STATE` edge over the already authenticated
input poll. The guest consumes it on the polling worker into an atomic flag; it
never appears as keyboard input. Optional rendering work can arm from that flag
on open and disarm on close, leaving the per-frame path untouched during normal
play.
Ordinary UI keys reach the actual controls. Closing restores the game responder;
foreground, active Space and console checks still decide pointer eligibility.

The background is a single image of Ready's own window taken before mounting
the UI, bounded to 640 pixels per dimension. A CPU software Gaussian blur and
50% black tint in the output bitmap are applied once; the displayed background is frozen while
navigating. There is no continuously filtered backdrop or capture stream. The
actual UI keeps its native resolution. On macOS 14.4+, capture uses only
`SCShareableContent.currentProcess`, matching Ready's PID and exact window ID;
it does not enumerate other applications, request screen permission, save an
image or start recording. Unsupported systems, errors and a 1.5-second timeout
fall back to a plain 55% black shade.

Closing invalidates pending captures, clears the image, detaches the actual UI
and releases its graphics/artwork. The game view becomes the sole window content
again. The UI is composited while open, so zero GPU overhead or direct display
with the UI visible is not claimed. The native closed-UI rendering path is
unchanged; the cost of the static composite and real UI is distinct from live
blur cost.

`Scripts/test_hosted_fullscreen.py` covers 119 controlled lifecycle checks,
including same-canvas/window geometry, input routing, capture failure/timeout,
cancel/reopen races and image release. `Scripts/test_backdrop_cpu.py` checks the
actual software filter and completion gate. The separate owned two-process
Metal fixture confirms that the own-window snapshot includes a remote hosted
Metal layer. Synthetic checks do not certify a commercial game's frame times
or physical-controller behavior.

`Scripts/test_hosted_overlay.py` adds 28 checks of the actual local event monitor,
normal-key forwarding, window scope and reentrant shortcut callbacks. Its owned
Metal pixel readback is not a screen capture. Historical panel receipts describe
the earlier small menu, not the current unified interface.

#### Optional live GPU blur experiment

For an explicitly requested native-game trial, launch Ready with
`--host-game-gpu-blur` alongside `--host-game-view <storeID>` and the
`remote-layer` transport. The option is rejected for the surface transport. The
authenticated overlay state edge arms the Metal 3 drawable hooks on open and
restores the original command-buffer methods on close. With a shader-readable
drawable, the guest downsamples to at most 640 pixels per dimension, applies
`MPSImageGaussianBlur` (sigma 8), then draws the dimmed result back into that
same drawable before commit. Ready removes its dark placeholder after the first
blurred frame is actually presented. There is no screenshot, CPU pixel readback
or extra presentation window in this path.

This experiment has been run on the installed native Cyberpunk 2077 build: its
first drawable reported `shader-readable`; the overlay logged `MPS-low-resolution`
encoding and Ready received the first-presented-frame acknowledgement. This
proves the path ran, not its FPS cost. The pass adds GPU work while the overlay
is visible, and this trial has not measured frame time or validated other games
or Metal presentation APIs. Unsupported/non-readable drawables keep the dark
placeholder and skip the GPU pass. The default path remains the one-shot static
backdrop.

### Games using the injected overlay

- Ctrl+Shift+Space toggles the overlay inside the game process.
- Up/Down, Enter, and Escape navigate/resume; mouse can select either button.
- Key/button releases are matched to consumed presses, so a key held before opening
  the overlay is still released to the game.
- Menu, D-pad, A, and B are sampled through GameController without replacing the
  game's installed controller handlers.

**Not yet proved:** a physical controller was not available in the synthetic suite.
The active runtime's polling does not suppress a game's independent Wine
XInput/SDL/RawInput path, so game input may also react to controller buttons.
A separate [diagnostic Wine XInput provider](XINPUT_CAPTURE.md) now passes neutral
input, release-latch and two-session tests, including the actual injected Metal
overlay's status. It is not activated by default; its device input is simulated.
Physical controllers and other input APIs remain unverified.

## Build and verification

```sh
sh Scripts/build_overlay.sh
python3 Scripts/test_overlay.py
```

Both `Build/libReadyOverlay.dylib` and `Build/ReadyMetalProbe` contain arm64 and x86_64
slices. The tests run native arm64 and x86_64 through Rosetta on the actual M1:

- Metal 3 `presentDrawable` path.
- Metal 3 scheduled-handler presentation path.
- Metal 4 queue-level presentation path.
- Actual injected code, rather than statically linking the overlay into the probe.
- Readback changes 204,800 pixels while shown, then returns byte-identically to the
  baseline after hide.
- No hidden overlay GPU submissions; tracked overlay texture allocation returns to 0.
- Keyboard toggle, quit request, resume, mouse quit selection, control-file show/hide,
  and rejection of a group/world-readable control file.
- A capture epoch advances only when the overlay opens, so a game that misses an
  entire open/close interval can still suppress held resume input. CPU-only
  heartbeat updates during paused presentation add no GPU work or hidden textures.
- Two simultaneous injected processes have independent controls and status. Sending
  quit/resume to one does not hide, quit, or modify the other's action state.

Builds compile and sign fresh temporary inodes, then publish the dylib and probe
with same-filesystem renames. They do not overwrite the inode a running process has
mapped. Evidence lives in `Evidence/overlay-*.json` and PNGs. Timings are diagnostics of a
synchronized synthetic probe, **not gaming performance benchmarks**.

The real Windows Vulkan swapchain probe also passes through ReadySessionHost →
ready-wine → Wine 11.20 → KosmicKrisp → Metal → injected overlay. Run:

```sh
python3 Scripts/test_wine_overlay.py --exe Runtime/Probes/runtime_vulkan_present.exe
```

The test creates a private temporary prefix, initializes it under the native keeper,
checks the game PID's actual presentation counters while hidden/shown/hidden, then
waits for the exact prefix and removes its temporary files. On the tested M1 runtime,
tracked overlay texture bytes change 0 → 835,584 → 0. Evidence is
`Evidence/overlay-wine-present.json`. This verifies that Windows Vulkan path; it does
not establish arbitrary game or Direct3D backend compatibility.

The optional local Apple/WineCX evaluation has a separate integration probe:

```sh
python3 Scripts/test_apple_overlay.py --api d3d11
python3 Scripts/test_apple_overlay.py --api d3d12
```

It requires the frozen local provider referenced by `Runtime/evaluation-runtime.json`,
keeps that configuration disabled for consumer play, and checks that the default
`Runtime/runtime.json` remains byte-identical. It starts a fresh private prefix under
the native keeper and clones the matching pure WineCX PE32 bootstrap before Wineboot.
The resulting Apple graphics DLLs are checked against the frozen provider's hashes.
No Apple binary or license is added to tracked source or the application bundle.

The real D3D11 run on M1 completed 600 Windows presentations at feature level
11_0. With the overlay shown, GPU-completed passes increased; after hide they drained
without failures and stayed stable while game frames continued, and the tracked
panel texture returned from 835,584 bytes to 0. In the instrumented repeat, the
observed overlay entry was Metal 3 (119 passes, all completed / 0 failed) even though
Metal 4 was requested; installed hook flags are not treated as path evidence.
`Evidence/overlay-apple-d3d11.json`
records actual game PID, hashes, phase snapshots, and prefix cleanup. This establishes
command-buffer/drawable integration for that synthetic Apple backend path. It does
**not** establish Apple end-to-end pixel output, arbitrary game compatibility,
fullscreen, or direct-to-display. The desktop was locked, and no UI control or screen
observation was performed. The six native Metal path tests separately retain their
actual pixel readback checks.

The D3D12 swapchain probe also passed with `D3DM_MTL4=1`: 600 submitted shader frames,
600 successful presentations, and zero occluded presents. The overlay's actual Metal 4
entry recorded 118 passes, all GPU-completed with zero failures; the Metal 3 entry
recorded zero. Counts stayed at 118 through a later hidden frame snapshot while the
texture allocation was zero. `Evidence/overlay-apple-d3d12.json` records this specific
local evaluation result. The per-path counters, rather than the requested environment
or hook-installation flags, establish the observed injection path. The same pixel,
fullscreen, direct-display, and arbitrary-game verification limits still apply.

For a framebuffer-only fullscreen probe, run
`Build/ReadyMetalProbe.app/Contents/MacOS/ReadyMetalProbe` with the injection environment
and `--metal4 --fullscreen --presentation-probe --session-probe`. The app bundle enables
native fullscreen and Game Mode; presentation-only draws at the view's backing-pixel
size, while readback tests retain their fixed diagnostic resolution. Optional Metal HUD
variables are `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1`.

On 2026-10-28, the actual Metal HUD on Apple M1/macOS 27.0 showed **Composited** for
both hidden and shown overlay states at 3360×2100, with Game Mode on and a full-screen,
opaque, framebuffer-only Metal layer. `Evidence/overlay-native-hud-observation.json`
records the observation and geometry. `Scripts/test_overlay_presentation.py` additionally
records actual AppKit activity, key/main window status, frontmost PID, occlusion
visibility, and all window/view/layer/display dimensions. In the follow-up observation
the probe was active, key, main, frontmost, and visible, with opaque view/window/layer
and `presentsWithTransaction=NO`; the shown HUD remained Composited. The baseline
was already composited; this test
neither proves direct presentation nor identifies why composition was active. A
PID-scoped `metalperftrace listen` trace provided timings but no composition-mode field
in its observed JSON output. No system-wide capture or security settings were changed.

## Remaining limits

- Direct-to-display with the overlay visible must be verified with the Metal HUD or
  Instruments for each real backend. A fullscreen probe passing is not sufficient.
- DXVK/MoltenVK and arbitrary GPTK/D3DMetal games still need end-to-end testing.
  Wine/KosmicKrisp Windows Vulkan and the local Apple D3D11/D3D12 swapchain evaluations
  establish specific backend integration paths, alongside the Metal contract tests.
  Apple end-to-end pixel output remains unverified.
- Hardened-runtime/library-validation restrictions may reject dynamic injection.
  Do not disable SIP or alter third-party code signatures to claim compatibility.
- Games acquiring drawables exclusively through other APIs such as an internal
  CAMetalDisplayLink path may not hit `nextDrawable` interception; verify actual
  frame counters before enabling the UI's overlay controls.
- A game must keep presenting frames for a drawable-injected overlay to appear.
- No compatibility with kernel anti-cheat is claimed.

## Frontend background failures

The launcher disables its interface menu actions while a game owns the session. Background store errors are deferred to Library → Notifications; they do not create an AppKit alert, re-show the launcher or restore its Metal canvas during play. The normal session-finish callback restores the UI and points to pending notifications.

`python3 Scripts/test_frontend_lifecycle.py` runs the actual AppDelegate, MetalCanvas, SessionManager and native keeper with a two-second synthetic native helper. Eleven checks verify initial allocation, teardown, no modal/window/texture on a background error, and restoration after exit. It creates only its own marked data root. This is logical resource/window-state evidence, not a visual test or direct-display proof.

## CPU heartbeat for paused presentation

After a process has rendered its first supported drawable, the overlay publishes a private atomic heartbeat four times per second and polls its existing raw GameController profile. A renderer that never draws does not start this heartbeat or overwrite the actual game status. The heartbeat allocates no Metal texture, creates no encoder/command buffer, and does not force a game frame. Status files are created at0600 before atomic rename, rather than chmod after publication.

The real Metal probe now pauses rendering for1.3seconds while visible and hidden. On all six native/Rosetta/Metal3/Metal4 paths, heartbeat sequences advance while frame counts and GPU submission counts remain unchanged; hidden texture memory stays zero. This supports scoped input liveness, not a claim that a stalled game can display a newly rendered panel without another drawable.
