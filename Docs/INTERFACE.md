<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Interface behavior and checks

The launcher uses a dark, event-driven Metal canvas with separate hover, pressed
and keyboard/controller focus states. Every interactive canvas region has its own ID,
including repeated import actions. Pointer tracking and cursor rectangles update
when layout changes; dragging outside a pressed target does not activate it.

Symbols fit their intrinsic aspect ratio. Artwork fills its card while retaining
its ratio and clipping the overflow. The CPU bitmap and Metal texture now share
an explicit sRGB BGRA8 contract. The prior NSBitmapImageRep path returned ARGB
bytes despite its requested flags, putting the alpha byte into the blue channel.
The real GPU roundtrip now returns the expected BGRA bytes [21,19,16,255].

Search, profiles, game options, runtime selection, import, notifications, errors,
authentication/QR, evaluation and migration/recovery are presented inside the
existing application window. No NSAlert, NSOpenPanel, NSPanel or nested runModal
call remains in the frontend. Panels are asynchronous and block input to the
underlying canvas. Tab/Shift-Tab stay inside the panel; Escape selects the explicit
cancel action. Destructive confirmation does not receive initial focus. The authentication
request is invalidated and cancellation requested before its view is removed.

The internal browser reads directories off the main thread and ignores stale
responses. It hides dotfiles by default, supports explicit paths and disables
confirmation while the directory is unreadable. A native-app reimport preserves
its game ID, per-profile preferences and save rules, and does not duplicate the
entry. A successful import clears an incompatible library filter and selects
the imported game.

Checks on the M1 host include actual Cua mouse/keyboard/AX interactions with
search Return/Escape, profile creation and errors, options, runtime selection,
invalid/valid paths and restoration, native import/reimport, hover changes on
the canvas and primary panel button, and closing a panel without closing the
launcher. Screenshots and hashes are retained privately. Other rendering checks
verify five symbol aspect ratios, twelve hit targets and actual Metal byte
readback. The native-session lifecycle probe passes thirteen checks, including
removal of active/queued internal panels and zero canvas texture allocation
during the game. These checks do not certify real account authentication,
physical controllers, commercial games or direct display.

Backups use a non-launchable `.ready-backup` directory with a private inventory.
Only the current published bundle is registered with Launch Services, preventing
an older backup from appearing when the app is opened by name. See
[frontend packaging](FRONTEND_PACKAGING.md) for exact restoration steps.
