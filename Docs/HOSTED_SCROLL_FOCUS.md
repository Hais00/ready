<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Hosted native scroll and cursor ownership

The hosted input protocol preserves precise scroll deltas, line/point/fixed
representations, phase, momentum, modifiers and timestamps. Wheel events target
the actual consumer under the logical pointer and remain latched during a
gesture. Keyboard first-responder routing remains independent.

The installed native Cyberpunk consumer was inspected statically, without
executing or loading the game. `GameView.scrollWheel:` checks its option-mode
state, which reads `GameWindowController.m_windowFocus`. That controller sets
the flag from standard key-window callbacks. Merely setting the logical window's
`m_isActive` and delivering keys directly does not provide those callbacks.

The logical window now posts its own key-window focus edges and registers its
delegate for the corresponding standard notifications. Repeated authenticated
focus values do not repeat callbacks. Focus loss still releases held inputs and
cancels an active scroll before notifying the controller. Main-window
notifications follow visibility, consistent with the logical main-window getter;
key status follows authenticated host focus. No game binary or game state flag
is patched.

Ready owns one balanced AppKit `NSCursor.hide` / `unhide` pair per physical
capture. The earlier post-scroll repair explicitly showed then hid the cursor
for gesture packets, exposing the anchored system pointer and adding run-loop
work. That repair and the periodic visibility-based rehide are removed. Focus,
Space, overlay and shutdown still use the existing capture/release gates.

Controlled own-process checks cover fractional scroll reconstruction, input
gating, a wheel consumer gated by a native-style controller focus flag, duplicate
focus edges, delegate replacement and exact mock cursor balance across 100
gesture packets. The mock cursor fixture makes no physical cursor mutation.
These checks do not establish physical two-finger trackpad behavior in
Cyberpunk. That acceptance check remains with the user; no commercial game
benchmark or screen recording is performed by the agent.

The real-event regression on 30 October found an earlier boundary failure:
AppKit throws `NSInternalInconsistencyException` for `clickCount` on a real
scroll event. The host now reads click fields only for mouse down/up and preserves
wheel fields separately. Actual unposted AppKit event tests cover this path;
the user then confirmed two-finger scrolling works. These input hooks are shared
by both transports. Later CLI-only native performance checks are documented in
the [current audit](HOSTED_PERFORMANCE_AUDIT.md); they supersede the earlier
benchmark restriction above.
