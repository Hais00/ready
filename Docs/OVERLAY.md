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

- Ctrl+Shift+Space toggles the overlay inside the game process.
- Up/Down, Enter, and Escape navigate/resume; mouse can select either button.
- Key/button releases are matched to consumed presses, so a key held before opening
  the overlay is still released to the game.
- Menu, D-pad, A, and B are sampled through GameController without replacing the
  game's installed controller handlers.

**Not yet proved:** a physical controller was not available in the synthetic suite.
Polling does not suppress a game's independent Wine XInput/SDL/RawInput path, so
game input may also react to controller buttons. A Wine-side input arbitration hook
remains necessary for a fully exclusive console-menu experience.

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
- Two simultaneous injected processes have independent controls and status. Sending
  quit/resume to one does not hide, quit, or modify the other's action state.

Evidence lives in `Evidence/overlay-*.json` and PNGs. Timings are diagnostics of a
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
- DXVK/MoltenVK and GPTK/D3DMetal game processes still need end-to-end testing.
  The successful Wine/KosmicKrisp Windows Vulkan probe establishes one real backend
  path, alongside the synthetic Metal contract tests.
- Hardened-runtime/library-validation restrictions may reject dynamic injection.
  Do not disable SIP or alter third-party code signatures to claim compatibility.
- Games acquiring drawables exclusively through other APIs such as an internal
  CAMetalDisplayLink path may not hit `nextDrawable` interception; verify actual
  frame counters before enabling the UI's overlay controls.
- A game must keep presenting frames for a drawable-injected overlay to appear.
- No compatibility with kernel anti-cheat is claimed.
