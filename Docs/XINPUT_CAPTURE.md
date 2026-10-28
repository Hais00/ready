<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Session-scoped overlay input capture

The diagnostic Wine 11.20 provider implements capture in Wine's builtin XInput
DLLs. It returns neutral controller input to the Windows game while its injected
Metal overlay is visible. GameController continues reading the original controller
state. The currently selected runtime is unchanged; the candidate configuration is
`Runtime/candidate-xinput-v2.json`. The earlier protocol1/E5 provider and its
candidate remain unchanged.

The production implementation adapts the shared Wine `xinput1_3/main.c` source and
adds a small native Unix library. It does not intercept arbitrary executable code,
install a system input filter, or modify an Apple binary. `xinput1_1`, `xinput1_2`,
`xinput1_3`, and `xinput1_4` use that shared implementation. Wine's unchanged
`xinput9_1_0` delegates its state and vibration calls to `xinput1_4`. Both PE32 and
PE64 use the x86_64 Wine host, with a pointer-free Unix-call protocol.

| API | During capture |
| --- | --- |
| `XInputGetState` | Connected device remains connected; buttons, triggers, and axes are zero |
| `XInputGetStateEx` / ordinal 100, where exported | Same neutral state, including Guide |
| `XInputGetKeystroke`, where exported | Empty result; internal physical state advances so captured presses are not replayed |
| `XInputSetState` | Sends zero vibration; the first API observation of capture also stops previously requested game vibration |
| Capabilities, battery, audio, enable | Wine behavior retained |

While a supported overlay is active but hidden, Start is reserved for opening it.
All other input passes normally. Closing the overlay keeps input neutral until
that controller returns to its XInput deadzones and releases its buttons/triggers.
A fresh press then reaches the game. Existing rumble is stopped when a game XInput
call first observes capture; no independent global HID timer is installed. The
native overlay increments
`inputCaptureEpoch` each time it opens; this also disarms held resume input when
the game made no XInput call during the entire open/close interval. Packet numbers
change with capture transitions, including synthetic neutral state.

## Activation and failure behavior

Protocol2 requires the exact native environment value `M1L_XINPUT_CAPTURE=1`.
Absent, `0`, `true`, `01`, or any other value leaves ordinary input and rumble
untouched, even with otherwise valid visible overlay state or changing capture
epochs. The native reader performs no control/status file reads while opted out.
The PE exports and pointer-free Unix-call ABI are unchanged.

The native reader uses the current process's `M1L_CONTROL_FILE` and
`M1L_OVERLAY_STATUS` (or the sibling `overlay-status.json`). It requires private,
regular files owned by the current user, rejects symlinks, bounds JSON to 16 KiB,
and validates the status belongs to the same Darwin process ID. Wine's Windows
process ID is a different namespace and is not used for this check.

Capture requires an actual first presented frame, supported Metal injection, a
Metal hook, and an active heartbeat. The native overlay polls raw GameController
input and updates its status four times per second after its first valid frame,
even while game presentation pauses. The reader allows at most three seconds of
status age; missing, unsupported, stale, malformed, public-mode, foreign-process,
or otherwise invalid state leaves ordinary Windows input available, including
Start. `heartbeatActive` accepts JSON booleans and the older NSNumber `0`/`1`
encoding; other numeric values are rejected.

A newer control command overrides an older acknowledged status immediately.
Otherwise the native status's visibility wins, because the controller can open
or close the overlay inside the game process. Merely setting an environment
variable does not activate capture. Start can reach the game before the first
supported overlay frame; that initial interval remains a documented limit.

## Reproduction and source provenance

```sh
python3 Scripts/runtime_build_xinput.py
python3 Scripts/runtime_xinput_test.py
python3 Scripts/runtime_xinput_overlay_test.py
python3 Scripts/runtime_freeze_xinput.py
```

Build prerequisites are the pinned Wine 11.20 source, the configured Wine build
cache produced by `Scripts/runtime_build.py`, GNU make, the Apple command-line
SDK and LLVM's Windows PE toolchain. The build copies and adapts Wine source;
`Vendor/wine` and existing providers remain unchanged. It compiles separate
production and deterministic test variants. Production export names/ordinals are
compared to all ten original PE DLLs, and production binaries are scanned for the
test interface and backend environment variable. The test-only variant exports
an observation function and loads a deterministic RAW device provider; production
contains neither facility.

`Evidence/runtime-xinput-build.json` binds source and payload hashes.
`Evidence/runtime-xinput-capture.json` records all five DLL versions on PE32 and
PE64, independent keystroke calls, release latches, vibration, invalid status
cases, newer commands, and concurrent sessions with separate control files
and native PIDs. Protocol2 adds30 opt-out cases (absent/0/true across all ten
DLL/architecture combinations), while the original ten opted-in cases retain
rumble, epoch/release-latch and24 invalid-state/command checks. Four simultaneous
session-pair cases cover PE32 and PE64 with both sessions enabled and with the
second session opted out. A five-case native-only reader unit also checks `01`. Per-case DLL/Unix-module load traces are preserved with hashes.

`Evidence/runtime-xinput-real-overlay.json` adds an actual Windows Vulkan window
presenting through Wine, KosmicKrisp, and Metal. The real injected overlay writes
its own status inside that same process: hidden input passes, visible input and
rumble are zero, held input stays suppressed after hiding, and a new press passes
after neutral. The test's raw controller device remains a declared synthetic
provider. The overlay allocates 835,584 tracked texture bytes while shown and
returns to zero when hidden in this run. This is an input/overlay integration
proof, not a direct-display or physical-controller result.

The freeze script makes a new protocol2 provider identity with versioned base and DXMT Wine copies with production
capture modules, a separate `test-only/` payload, complete pristine Wine source,
adapted source, build configuration, recipes, patches, notices, and hash-bound
evidence. It creates a diagnostic candidate configuration without selecting it. A separate
immutable `controller-capability.json` binds each exact Wine root, raw Wine
binary and selected launcher hashes,11 regular production modules,4 Unix
symlink targets and10 original/current builtin hash lists. The candidate binds
that capability manifest by path and hash; the full provider manifest then binds
both the capability and candidate configuration hashes, avoiding a cycle.
It does not swap DLLs in an active prefix. A game must load these builtin XInput
DLLs; an application-supplied native XInput DLL is outside this proof. The
candidate records the builtin override needed for testing but does not force it
in the launcher. Future integration must select the provider and initialize each
owned game/profile prefix before launch, under its normal session lease.

Wine's original copyright headers remain intact. The Wine adaptation, native
reader and ABI header use LGPL-2.1-or-later. Ready's original test programs and
freeze orchestration use GPL-3.0-only. No Apple proprietary component is added.

## Remaining scope

Physical controller behavior is unverified. WineCX/Apple-evaluation providers,
`xinputuap`, DirectInput, Raw Input, HID access, native SDL input, and games using
their own native XInput implementation are not covered. No claim is made that
controller input is exclusively captured across every game/input API. The active
runtime generation and its existing prefixes remain unchanged. This diagnostic
provider's evidence does not establish distribution readiness for the whole app
or all inherited runtime components.


## Protocol2 checkpoint

The new frozen provider is
`ready-xinput-v2-wine1120-5847cc7c9432529e98b9`. The capability manifest SHA256 is
`e78fc7c412e1d1e00760cf500862222f3ddb0044e17ffd02aec6513a7e918662`;
`Evidence/runtime-xinput-e6-provider.json` binds the full manifest and candidate.
The source snapshot includes the native opt-in unit, production/test build
recipes, all API/overlay evidence, complete Wine source and original notices.
No frozen E5 file, active default configuration or evaluation configuration was
changed. All synthetic Wine prefixes were stopped and removed before freeze.

The observed actual-overlay result uses explicit flag1 and the earlier compiled
Metal overlay library; it proves the new reader with actual same-process status.
The caller's new controller policy and rebuilt overlay still require their own
Core/Session end-to-end gate before any activation. Physical controllers remain
unverified. The deterministic backend and observation export exist only in the
separate test variant; production uses Wine's original physical input path.
