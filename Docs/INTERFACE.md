<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Interface behavior and checks

The launcher uses a dark, event-driven Metal canvas with separate hover, pressed
and keyboard/controller focus states. Every interactive canvas region has its own ID,
including repeated import actions. Pointer tracking and cursor rectangles update
when layout changes; dragging outside a pressed target does not activate it.

The library combines games from all enabled stores. Non-game content and the
Games/Other selector are excluded. The header names the current section, and
the footer appears only for errors. Header/footer text uses soft gradient strips
and shadows rather than hard glass panels. The dock has a Library icon and
icons for actual running sessions instead of separate store libraries.

During hosted native play, Ctrl+Shift+Space mounts this same canvas and the same
navigation pages in the existing game window, at its actual backing scale. The
initial game page leaves its center clear; library, friends and settings remain
navigable. Selecting the running-game icon or pressing Escape returns to play.
Runtime/profile/storage/authentication changes are guarded while playing. See
[hosted overlay behavior](OVERLAY.md#hosted-native-games) for the static blurred
background, fallback and resource cleanup.

Entering Library while a hosted game remains open explicitly restores the
visible viewport's indexed card images from disk. Repeated entry does not
invalidate pending reads. The interface skips whole-catalog artwork preparation
during play, and clears decoded artwork and card layers when returning to the
game. The owned cache/canvas fixture checks three repeated open/load/close cycles.
Hosted chrome also skips software filtering of its transparent background; the
game supplies the actual GPU blur. This avoids redundant first-frame CPU work.

Symbols fit their intrinsic aspect ratio. Artwork fills its card while retaining
its ratio and clipping the overflow. The CPU bitmap and Metal texture now share
an explicit sRGB BGRA8 contract. The prior NSBitmapImageRep path returned ARGB
bytes despite its requested flags, putting the alpha byte into the blue channel.
The real GPU roundtrip now returns the expected BGRA bytes [21,19,16,255].

Settings, account/friends, downloads and profiles are nonmodal navigation pages
inside the main content area. Settings has persistent Generali, Account, Motori,
Dati e ripristino and Toolkit Apple tabs. The sidebar and toolbar remain visible
and usable; entering a page removes library cards and their game-launch hit
regions. Search, import, game options, authentication, migration and notices use
the same page surface rather than a floating card over a dimmed library.

Only the critical quit confirmation while a game is running retains the transient
internal presenter. The frontend does not use NSAlert, NSOpenPanel, NSPanel or
nested runModal. Ordinary pages have no modal keyboard monitor or closed Tab loop.
Validation errors appear inline and preserve the form. Navigation cancels an
unfinished authentication flow; internal progress/QR transitions preserve the
same request. Leaving the page does not stop a persistent Steam connection or
its download queue. The page, its observers and canvas graphics are detached
before a game session takes ownership of the window.

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

The navigation-page checkpoint adds 80 AppKit lifecycle/geometry checks at two
window sizes, 18 production canvas raster/hit/key/controller groups, 24 account
layout checks and 15 delayed OAuth transition checks with network access denied.
The frontend teardown passes 13 checks and the relocated package passes 14.
Actual Cua verified all five settings sections, return to Steam through the
sidebar, the empty downloads page, and final full tab labels/single focus ring.
These UI changes did not run a new real account login, CDN download or game.
See [the scoped checkpoint](../Validation/navigation-pages-checkpoint.json).

Reproduce the page checks with `Scripts/test_ready_page_presenter.py`,
`Scripts/test_ready_canvas_sections.py`, `Scripts/test_store_authentication_pages.py`
and `Scripts/test_steam_account_layout.py`. Their offscreen fixtures are distinct
from real user interaction and physical-controller coverage.
