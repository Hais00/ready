<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Experimental presentation in the Ready window

This opt-in experiment keeps Ready's existing NSWindow, fills its current
display and exchanges the library canvas for a CAMetalLayer. It does not move
another application's actual NSView/NSWindow objects into Ready. The guest uses
local logical AppKit objects whose windowNumber identifies the host resource.
The display-fill mode does not create a native fullscreen Space. Ready keeps
this placement when the game exits, so the same fullscreen library returns.
The Dock/menu are hidden rather than configured to reappear on edge hover.
An explicit fullscreen exit restores the original placement.

The loading canvas stays above the target layer until a validated GPU-complete
first PRESENT. A Core Animation transaction exchanges the UI for that surface;
blocking UI-resource cleanup runs only after the transaction commits. Input to
the loading canvas is disabled. A presented-handler timestamp is separate
telemetry; enqueueing a present is not called an on-glass observation.

`--exclusive-hosted-view` additionally requests exclusive display ownership via
Core Graphics, with the existing window above the shielding level. This opt-in
path records API results/shielding metadata and must be validated on the actual
OS/display; it is not inferred from display-fill geometry. Switching away or
locking releases capture without terminating the game, and an eligible return
to foreground can reacquire it. Stop/exit always release ownership and restore
window level. Capture success alone does not prove Metal direct scanout.

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

Mouse/key events originate in the host view and travel over the same authenticated
session to the guest's local responder. Physical cursor warping/capture is not
implemented: guest CGWarpMouseCursorPosition/CGAssociateMouseAndMouseCursorPosition
return an explicit unsupported result. Cocoa gesture semantics, multiple displays,
arbitrary dialogs, controllers and accessibility require their own validation.
The guest Ready overlay is omitted in this experiment so only one transport owns
the presentation hooks; ordinary launches retain their existing overlay path.

The actual host layer can show Metal HUD. Its FPS/frame interval/presentation mode
belong to that layer. Host GPU timing cannot be presented as total guest frame GPU
time: the host itself encodes no game command buffers, and an optional guest
presenting-buffer interval would not account for every queue in a commercial game.
HUD instrumentation itself is additional diagnostic work.

Developer entry points:

```sh
Build/ready.app/Contents/MacOS/ready --host-game-view 1091500 --metal-hud \
  --exclusive-hosted-view
# Optional explicit local development override; each launch pins its bytes:
Build/ready.app/Contents/MacOS/ready --host-game-view 1091500 --metal-hud \
  --host-game-shim /absolute/owned/libReadyHostedGame.dylib
```

The default path remains unchanged without the explicit experiment. A successful
synthetic-app run is not a commercial-game compatibility certificate. Exact live
checkpoints and remaining limits must accompany any claim of game support.
