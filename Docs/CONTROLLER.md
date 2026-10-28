# Controller navigation

`ControllerNavigation.swift` and the launcher handlers are original GPL-3.0-only code.
They use public GameController and typed AppKit control APIs, with no synthetic
keyboard/mouse events, accessibility permission changes, or unconditional modal abort.

| Context | Input | Behavior |
| --- | --- | --- |
| Library | Dpad / left stick | Previous/next game; dominant vertical direction also moves one game |
| Library | A | Activate selected game |
| Library | B | Home: clear store filter and search, select first game |
| Library | Menu | Profiles |
| Library | L1 / R1 | Cycle all stores and Home |
| Modal dialog | Left / right | Previous/next AppKit key view |
| Modal dialog | Up / down | Change a focused popup's selected item, skipping disabled/hidden/separator items; otherwise move focus |
| Modal dialog | A | Click the focused enabled button, or the dialog default button; a focused popup confirms the default without opening menu tracking |
| Modal dialog | B | Click an enabled Escape button or exact Annulla/Chiudi/Cancel/Close button |
| Steam QR login | B | Cancel this authentication request and close its QR panel |
| Steam QR login | Other inputs | Consumed, without actions behind the panel |

Routing priority is: running/initializing/stopping session, maintenance, modal dialog,
QR authentication, then library. An inactive launcher ignores controller actions.
Menu and shoulders are consumed inside a modal instead of opening another library
screen. A modal opened while authentication is active takes precedence over the QR
panel. Cancel matches whole button titles, so B does not choose a destructive
“Chiudi sessione” button by substring. Buttons complete the original AppKit modal
response, preserving the caller's `NSAlert` result handling.

Every parent handler rejects input while `SessionManager.running` both when receiving
an input callback and when delivering an action. The injected overlay remains the
single game-session controller authority; see [overlay limitations](OVERLAY.md).

Input actions are scheduled in the main run loop's default, modal-panel, and event-
tracking modes. This allows controller work inside `runModal` without placing an
entire modal session inside a serial GCD main-queue callback. AppKit control access
occurs only on the main thread.

The stick/dpad policy engages at magnitude 0.55 and returns to neutral below 0.30,
with an 80 ms debounce. Updates from a held direction can repeat after 400 ms, at
most every 180 ms. Repetition depends on controller value updates; no continuous
polling timer is added. Separate dpad/stick state is maintained per controller.

## Verification and limits

```sh
python3 Scripts/test_controller_navigation.py
swift build
```

The pure probe checks axis thresholds, hysteresis, timing, invalid input, library/
store boundaries, popup index selection, safe cancel-title matching, and routing
priority. It compiles the real AppKit helper but creates no `NSApplication`, window,
or fake input. Evidence is `Evidence/controller-navigation.json`.

Physical controller behavior and actual AppKit focus/modal interactions remain
manual verification gates. They were not exercised while the Mac was locked; both
`physicalControllerVerified` and `modalAppKitInteractionVerified` remain false.
AppKit owns the key-view order and focus behavior. Text entry still uses normal
text input; this feature does not provide a controller keyboard. Support here is
for controllers exposing a public `GCExtendedGamepad` profile.
