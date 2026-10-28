# Logical window and direct drawable experiment

This is a separate GPL synthetic-app experiment, not integration with Ready,
Steam, a game or another user's window. Only `NoCopyProxy*` sources are involved.

The guest is an ordinary independent Cocoa/Metal program: it constructs an
`NSWindow`, `NSView`, `CAMetalLayer`, obtains `nextDrawable`, encodes its own render
pass and calls `presentDrawable:` on its command buffer. It contains no host IPC,
shim detection or cooperative export path. Each comparison uses the exact same
signed guest executable before and after injecting our own dylib.

The shim overrides allocation for this process's `NSWindow` class. It returns an
`NSObject` logical proxy implementing the measured public selectors, without
calling a real guest `NSWindow` initializer. `windowNumber` returns the actual
host WindowServer ID. This is explicitly **not** an identical Objective-C object
shared between address spaces. `NSApp.windows` remains empty in the injected
process. Unsupported selectors/window subclasses fail with a bounded error,
rather than create a hidden guest window.

The host owns one actual `NSWindow` and `CAMetalLayer`. On acquisition it retains
its actual `CAMetalDrawable` and exports that drawable texture's IOSurface via a
Mach port. The shim imports the same surface into a render-target texture and
returns its own `CAMetalDrawable` protocol object to the unchanged guest.
The guest's original encoder renders into that allocation. The shim intercepts
`presentDrawable:` and waits for that actual command buffer's GPU completion;
then the host calls only `[drawable present]` and acknowledges the frame.
No application-side full-frame copy, blit, compute pass, host command buffer or
pixel readback is implemented. The host never creates a command queue.
An extra empty guest queue is used only to identify the public runtime command
buffer class for interception; it produces no command buffer or GPU work.

This does not prove that WindowServer composition, display scanout or the Metal
driver performs no internal work. It also does not prove zero CPU/IPC overhead,
production input handling, resize/fullscreen semantics, arbitrary AppKit object
layout compatibility, arbitrary Metal selectors or commercial application
compatibility. GPU completion and Mach exchanges deliberately serialize frames.
The shim currently supports only the measured single-window BGRA8 render path;
timed presentation, direct drawable presentation without a command-buffer fence,
multiple windows and unsupported selectors fail closed.

## Running

All builds, source snapshots and reports go into a fresh private Dati fixture.
No existing app is re-signed, opened, closed or registered with LaunchServices.
The driver owns every process it stops and enforces bounded lifetimes.

```sh
python3 NativeEmbedding/NoCopyProxyLab.py --build-only
python3 NativeEmbedding/NoCopyProxyLab.py --offscreen --frames 90 --linger 1
# Only when foreground/UI ownership has been released:
python3 NativeEmbedding/NoCopyProxyLab.py --visual --frames 90 --linger 20
```

`--offscreen` requests a host window outside display bounds and never activates
it. Reports retain the actual WindowServer bounds/onscreen flag; the requested
mode alone is not proof of visibility. Visual mode additionally runs the ordinary
baseline guest, then the exact same binary with the injected shim. A CUA visual
inspection must be recorded separately; a successful API run is not a screenshot.
The host has no fullscreen/Space switching path. No window is kept for more than
65 seconds, and none should be left open while the real Ready authentication UI
has foreground ownership.

## Initial observed result

The first actual API run rendered and presented 90 frames, with both processes
exiting zero. Independent WindowServer census reported one host window (ID 6097)
and zero guest windows. The guest's logical `windowNumber` was 6097; all reported
host/imported IOSurface IDs matched. Counters observed 90 original guest render
encoders, zero guest blit/compute encoders, zero host command buffers/encoders,
zero application-side copies/readbacks and 181 Mach requests. Total guest GPU
work reported about 5.12 ms over those 90 frames; this is not a performance claim.

The run requested offscreen placement, but WindowServer reported `onscreen=true`.
It did not activate the host, and all owned windows were closed promptly. Bounds
were added to subsequent instrumentation to distinguish placement from that flag.
Baseline comparison and CUA visual confirmation were still pending at this point.
The private immutable report is
`WORK/tests/native-no-copy-proxy-8za0zjwn/report.json`, SHA256
`433182cc77793c44c53e65914e2cea5d485eefd665e401fec88913b42dd272b4`.
Historical reports are never rewritten when instrumentation changes.

## Foreground baseline and CUA result

A later foreground run compared the same signed guest executable in both modes
(SHA256 `a614b2e149c9929ee87a7ff933e5333bc110a67b5259aaad73789de96e6c5ce3`).
The ordinary baseline created a real `NSWindow`, reported one AppKit window and
rendered 30 frames. With only DYLD injection changed, it rendered 90 frames:

- Guest WindowServer census stayed empty, including an independent process's
  query during rendering. `NSApp.windows.count` was measured as zero.
- The logical guest window returned the actual host target ID 6117. The guest
  object class was `NCLogicalWindow`, not a real `NSWindow` object.
- All sampled actual host-drawable/imported IOSurface IDs matched. The guest
  encoded 90 original scene render passes and no blit/compute encoder.
- The host's application code created no Metal queue, command buffer or encoder;
  it acquired real drawables and presented them. These are application-level
  counters/source paths, not a capture proving absence of private framework,
  WindowServer compositor or driver-internal work.
- The shim created one empty queue for public runtime-method interception and
  zero command buffers. It recorded zero surface-copy operations/readbacks.
- There were 181 Mach requests, about 62.27 ms of guest IPC call time and
  6.29 ms of guest GPU timestamps over 90 trivial triangle frames. Host CPU time
  was about 244 ms and guest CPU time about 141 ms, including their setup work.
  These measurements do not establish real-game performance or a speedup.

CUA selected the exact dedicated host app path, captured its green triangle and
saved `cua-host.png`. Both owned processes exited zero and their windows were
closed before the foreground slot was returned. No other app/window was clicked,
closed, re-signed or captured.

The final census also found **one non-onscreen auxiliary host resource**, ID 6118,
with bounds 1004×30 at (0,0). It is consistent with an AppKit menu-related resource,
but its class/cause was not verified. It is retained in the raw report and
validator; it is not filtered away. Thus the foreground run proves one visible
host target and zero guest windows, **not exactly one total WindowServer resource
for the host process**. No hidden guest-window fallback was used.

The proxy was not registered into `NSApp.windows`. `NSApp.mainWindow` and
`NSApp.keyWindow` were neither queried in this run nor virtualized by the shim.
Their compatibility must not be inferred from a successful render loop. The
experiment also does not establish an `NSView.window` relationship, native event
routing, AppKit responder chains, fullscreen/Spaces behavior or private window
selectors. Those need a new independently baselined iteration. The unsupported
window-selector exit path exists, but only the missing-configuration constructor
refusal was exercised as a negative control in this iteration.

The CPU validator passed ten checks, including identical baseline/injected binary,
actual presentation, surface identity, live zero-guest census and configuration
refusal before application main. It records
`strictSingleHostWindowServerResource:false` explicitly.

Private evidence under `WORK/tests/native-no-copy-proxy-beqwzggl/`:

| File | SHA256 |
| --- | --- |
| `report.json` | `87c2ed07f0571b1fe9e65369768ba3f60e864c0247a99bf27caeefcb80871dd9` |
| `validation.json` | `0bab82d256de055ff8725c5872cb4af88167951d2291f3bc268418ab3b6db110` |
| `visual.json` | `e1a8ddfa8d4062e08c3ee40d35d54c33207de2f787d81ae63d83b5c000104e05` |

`visual.json` binds the CUA image hash to the original immutable report. The raw
report's earlier `visualVerified:false` is retained; the later CUA observation is
a separate receipt, not a retroactive edit to that report. The report validator
can be repeated without opening a window:

```sh
python3 NativeEmbedding/NoCopyProxyTests.py \
  '/absolute/retained/run/report.json' --require-baseline --constructor-negative
```
