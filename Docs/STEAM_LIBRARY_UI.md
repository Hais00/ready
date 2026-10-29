# Steam library and game pages

Status, 2026-10-29: implemented with scoped tests and real cached-data rendering.
The genuine earlier same-account synchronization populated **495 unique cached
owned-membership records**. After actual application repair, 465 have Windows
availability, 190 macOS and one is installed. Platform counts overlap. This does not certify 495 playable base
games. The earlier 30-entry public probe had 27 unavailable responses; that is
not license denial. Current app persistence retains 26 numeric title placeholders
and 30 unverified artwork fallback records. The private-file app is offline with
no token file/new login. The final build passed in 32.19 seconds, Ready 25884 is
running, and interactive on-screen review is deferred by the user.

The user approved detail-page → play and asked work to continue while they check
later. The [persistent interface checkpoint](../Validation/steam-library-interface-checkpoint.json)
keeps the goal active pending Root's manual completion audit of the final build,
actual cached-data repairs and appropriately scoped evidence.
No new game, download, benchmark or input/performance proof is claimed.

## Library behavior

The profile's persistent Steam connection synchronizes its library when the
account becomes ready, without another QR login. Refresh uses the same service.
Remote membership is bound to the profile, account and connection generation.
Changing accounts removes the previous remote membership while retaining local
installations and preferences; stale callbacks cannot replace the current
profile's library. A failed synchronization preserves the previous cached list.

PICS package/app metadata supplies owned games and available Windows/macOS
variants. Entries remain visible when uninstalled. Platform metadata is the union
of the common, launch and depot records; unavailable PICS details retain an entry
without inventing a platform. Known DLC entries are not presented as base games.
Remote variants have no executable or installation path and retain architecture
`unknown`. A macOS flag or `osarch=64` does not prove Apple Silicon support:
only inspection of an actual installed Mach-O executable can establish that.
Locally verified installations and selected game settings survive a catalog merge.
Public detail availability can add a missing Windows/macOS variant with unknown
architecture, uninstalled state and no executable path; it cannot add ownership.
Existing cached availability is projected over at most 20,000 entries before any
credential or network request and saved only if changed. A completed public
metadata response and artwork survive later empty/incomplete PICS placeholders,
while launch, membership and other metadata continue to update. This is not a
freshness/TTL guarantee.

The game detail page exposes available variants, installed play actions,
installation/download actions and existing download controls. It shows the
available description, developer, publisher, genre, release date and store link.
Missing fields remain optional. These actions continue through the existing
installation and genuine Steam ownership gates; descriptive catalog data cannot
authorize a launch or mark a variant installed.

## Paged library protocol

The frontend requests `library` with strict boolean `options.paged: true`.
Each nonterminal `library_page` has `games` and a zero-based integer `pageIndex`.
The terminal `result` has integer `gameCount` and `pageCount`, without a duplicate
`games` array. Pages contain at most 50 entries and remain below 1 MiB including
reserved envelope space, below the client/service 4 MiB JSONL limit.

The coordinator accumulates contiguous pages, rejects duplicate app IDs and
invalid counts, and commits only after a successful matching terminal result.
Cancellation, an account/profile/generation change or an error cannot commit an
incomplete list. The backend retains its explicit 20,000-entry safety limit;
it does not claim an unlimited catalog. A duplicate entry or an oversized single
entry fails the request. Legacy callers without `paged: true` retain the previous
terminal `games[]` response.

## Public details and artwork

Opening a detail page or preparing its splash can request
`catalog_metadata` with `options.gameID` and `options.language`. The result has
`appID` and `metadata`. The operation reads the public Steam Store endpoint;
it does not connect or authenticate a Steam account. Library synchronization
itself performs no per-game HTTP detail requests. A separate startup path
prefetches public details for at most the first six currently visible Steam
entries after `network.start`. A bounded repair pass handles at most 64 incomplete
profile entries, sharing a global limit of two metadata requests; failed lookups
consume their attempt for the scope and do not auto-retry. Neither pass fetches
all 495 entries or establishes account ownership. Concurrent requests for the
same detail are shared. This current-source scheduler is separately fixture-tested;
the actual application has now applied and persisted repair results. Interactive
visual review and new authentication are separate scopes.

The backend limits HTTP concurrency to two, the request budget to 12 seconds,
the response to 4 MiB and its six-hour memory cache to 256 app/language entries.
Failures produce bounded `metadata_timeout` or `metadata_unavailable` errors;
cancelled requests cannot publish a late successful result. An unavailable store
page leaves the PICS/local record usable.

No new `Game` model fields are required. `Game.metadata` preserves `launch` and
uses these optional keys:

| Keys | JSON type |
| --- | --- |
| `title`, `contentType`, `shortDescription`, `description`, `releaseDate`, `storeURL` | string |
| `developers`, `publishers`, `genres`, `downloadableVariants` | string array |
| `iconURL`, `capsuleURL`, `heroURL`, `bannerURL` | HTTPS URL string |
| `metadataComplete`, `artworkFallbacksUnverified` | boolean |

Descriptions are plain text after HTML cleanup. A page containing only images
uses its short description as the text fallback. Image URLs are limited to Steam
CDN hosts. PICS supplies the actual icon hash and offered library images; public
Store details supply header/capsule images and an offered background for the
hero. Missing optional fields do not erase existing PICS artwork. Official `title` repairs only an empty title or the exact AppID placeholder;
custom titles are preserved. `contentType` is descriptive and does not hide an
owned entry. Missing PICS artwork can use the standard Steam library capsule
and header URLs as **unverified candidates**: they may return 404, and normal
image/icon placeholders remain. These URLs do not prove an asset exists.

The detail and launch UI use hero/banner artwork first, then icon/artwork fallbacks. The
selected artwork cache directory is `/Volumes/Dati APFS/Ready Cache/Artwork`;
user-default/environment overrides and normalized-root rejection are covered by
the current fixture source. The running binary predates this latest cache refinement.

The public catalog response for app 1091500 was checked independently of an
account: Windows/macOS, description, developer/publisher, genre, release date and
Store artwork were returned. Public library capsule/hero/header HEAD requests
returned image responses. No artwork bytes or game binaries were added to the
repository. See [Steam's library asset documentation](https://partner.steamgames.com/doc/store/assets/libraryassets)
and [the public catalog response](https://store.steampowered.com/api/appdetails?appids=1091500&l=english).
These checks establish public metadata availability, not ownership or installability.

At the earlier b83 selection, one request exercised the actual selected `dotnet` and
`ReadySteamBridge --service` with app 1091500 and `language: italian`. It returned
nonempty description/short description/banner, three HTTPS artwork URLs on the
Steam allowlist, one developer, one publisher, one genre and two downloadable
platform variants. The request and orderly shutdown completed in 0.727 seconds,
with shutdown acknowledgement, exit zero and no stderr. The isolated service
profile/generation were fresh UUIDs; no credentials, `connect`, authentication,
game or download operations were supplied. This verifies the selected .NET
HTTPS/certificate/runtime path, not the user's owned library or frontend rendering.

The later 888ea component was tested with exactly the **30 cached entries missing
all artwork URLs**, with two concurrent public metadata requests and no auth.
Three returned titles/artwork/variants (two demos and one DLC); 27 returned
`metadata_unavailable`. This is not license denial and does not remove membership.
The run completed in 5.298 seconds with orderly shutdown and no library, credential
or selector writes. The unavailable subset prevents claiming every entry now has
real publisher artwork or a resolved title.

## Launch splash and responsiveness

The launch splash is an ordinary view inside Ready's existing window. It uses
Core Animation for its loading indicator and artwork motion, offers cancel and
failure/retry actions, and suspends for account authorization pages. Launch IDs,
profile guards and view identity reject stale completion/cancel callbacks.
Successful hosted first-frame handoff removes the splash; teardown removes its
animations and pending artwork callbacks. This is not an on-glass timing claim.

Credential access and native admission hashing use asynchronous work so the
main UI can continue responding. Fixture coverage of this work does not certify
continuous visible animation during a genuine account/game flow.

## Current live gate and credential choice

The cache now contains the 495 unique records described above, populated by a
genuine same-account synchronization before/at old Ready 19397 shutdown, without
manual user-data writes. A rendering probe uses a **copy** of those real records:
actual MetalCanvas reports 495 visible entries both for the active profile and
Steam filter; the detail target exposes macOS/Windows and preserved installation.
Its private captures and raw report stay outside the repository. This is a real
model/canvas rendering check, not CUA interaction with the running user app.

The final quality run extends that copy-render proof to 18 checks with exactly
two fresh public detail assets in its own private cache copy. The decoded poster
is **300×450 pixels**, and the hero **1024×331 pixels**; a `600x900` URL filename
does not establish a 600-pixel image. The fixture verifies the intended image
proportions/display rule, without a manual visual-acceptance claim. It neither
writes the original artwork cache/library nor activates a window, invokes
play/install callbacks or uses account, Keychain, game/SDK or performance probes.
Private preview images and title lists remain outside the repository.

Root reports final Ready 25884 in private-file mode, `offline/not_connected`,
with no token file and no new Steam login. The actual application persisted all
495 owner records and repaired catalog fields: every record has a cover/icon URL
candidate, 30 retain an unverified-fallback marker, 16 have an official content
type, and numeric title placeholders decreased from 27 to 26. These are actual
application callbacks/persistence, not manual library-file edits. A candidate URL
is not proof of a downloaded publisher image. Cached membership is not attributed
to a new file-mode login. The older locked-Keychain observation (main thread idle in NSApplication,
credential worker waiting in `SecItemCopyMatching`) remains historical. The final
image-quality helper, public repair scheduler and cancellation graph are now
included in the successful build; no new on-screen review is invented.

The user explicitly chose “Sì usa il file privato” after the storage tradeoff
was explained. Root selected `readySteamCredentialStorage=privateFile` in the
normal `app.ready.launcher` preferences for **Steam only**. The policy-aware
source routes reads/saves/removal through the selected backend dynamically.
Keychain remains the default for other stores and new users without that
explicit preference. Ready 25884 reports that selected policy, but no real file-backed login
or saved token has been verified.

The private file is scoped to the selected private state root and profile:
`Credentials/<lowercase-profile-UUID>-steam.json`, with a 0700 directory and 0600
regular file. It stores the refresh credential, never a Steam password. These
permissions do not provide Keychain encryption or exclude same-user processes;
the user accepted that tradeoff. Existing Keychain entries remain untouched.
Selection performs no automatic Keychain read or migration, and a missing or
unsafe private file never falls back to Keychain. A first Steam sign-in may be
needed when the user is ready; no automatic QR is requested before then.

Policy routing passes 18 checks with verified mocked SecItem bindings, including
zero SecItem calls in file mode and no fallback on missing/unsafe files. The
filesystem suite passes 51 checks with fake credentials and own files. Its
`backendActivated: false` describes the fixture's lack of actual preference
writes; it does not mean the now-consented production policy is inactive.
No real credential-file write, migration or saved-token verification is claimed.

The final current-source build and 14 headless relocation checks pass. The
relocation report verifies the frontend closure/signature and runtime-location
behavior, without certifying a real game/account or full runtime. Root's manual
completion audit remains pending. Library28 and Repair12 match the current public metadata paths. Earlier
policy-aware StoreClient16, account coordinator13, Session20 and authorization103
results are separately scoped: their later Session scheduler dependency changed,
so they are not retroactively reported as a fresh whole-dependency run.

## Scoped evidence

| Evidence | Result and limit |
| --- | --- |
| `steam-catalog-checks-6z6vi9up/report.json`, SHA256 `29f0e5401e6de2802c2e1f2a5b04a90a33d6e1c44f810f69e2e9fe88095feb2f` | 28 historical catalog/paging checks and 176 persistent-service checks; fake transports run with network denied. The separate public catalog request uses no account. |
| `steam-catalog-component-runtime.json`, SHA256 `4a430dea6e8a64f1bbddf698503c130d3f928821c80c0a55564f5e53a2e86f76` | Actual built component's offline snapshot/shutdown and `catalog_metadata` capability pass with network and source/SDK reads denied. |
| `steam-public-catalog-live-zyj68h0_/receipt.json`, SHA256 `7840bdd201f8d4be8c3b251972959e6d3e3f3dc4b9e8b1ff3090a7f568463339` | One actual selected-component public metadata request in Italian; genuine .NET HTTPS, returned fields/Steam image hosts and orderly shutdown verified. Raw response SHA256 `ae2d18e9eda085923550c68e0bf6f87865a69f812a27016e7032ef87484e277d` stays private. No account login or user-library writes. |
| `steam-catalog-checks-paj7mnvb/report.json`, SHA256 `7bf7398fbf5eb3933f111c60e966d5ba0b4c206aa7b75a1e14edc3c33628cafe` | Current 32 catalog/paging/optional-title-type checks plus 176 persistent service checks: 208 total. |
| `steam-missing-public-repair-qja3jltt/receipt.json`, SHA256 `e323e1256d63f5730f2849b836f862f0fa718518f5c286355e8ee27f1597bea2` | Actual 888ea .NET service, 30 missing-art entries, three public resolutions and 27 unavailable; no auth or user-data writes. |
| [Public repair coordination](../Evidence/steam-public-metadata-repair-handoff.json) | 12 scheduler/repair checks plus Library28; maximum 64 incomplete entries, global concurrency two, coalescing and no automatic retry. |
| `ready-final-library-package.json`, SHA256 `e04a77deaab12cab2f03bc433defaaa3ad09c8fde0a68a34c587ffb5f06247bf` | 14 headless relocated-frontend checks; no real GPU/game/account or full-runtime certification. Root separately reports build PASS and current Ready25884. |
| [Actual-model copy rendering](../Evidence/library-copy-render.json) | 18 final checks on the real-data copy, including exactly two fresh public detail assets in the cache copy: poster300×450 and hero1024×331. No original-cache/library writes, account/Keychain/game or window activation. Raw SHA256 `f1f962781f9aeb16e98256c5b34b6f2902ceeee5b554fdad28df133a340d69da`; private captures are not on-screen user-app proof. |
| [Library detail UI](../Evidence/library-detail-ui-tests.json) | 45 current-source fixture checks, including cache-directory overrides, normalized roots, picker deduplication and image candidate quality; no account, Keychain, external network, game or activated window. |
| [Launch splash](../Evidence/launch-splash-ui-tests.json) | 34 fixture checks using an own hidden window; no activation or account/game. Continuous on-screen animation remains unverified. |
| [Library coordination](../Evidence/steam-library-tests.json) | 28 current-source coordinator checks for membership, ordered pages, callback lifetime, public platform variants, cached projection, rich metadata preservation and native-platform deduplication. |
| [Credential file filesystem](../Evidence/private-steam-credential-file-tests.json) | 51 current-source checks with own fake payloads/files; the fixture does not change real application preferences or use real credentials/Keychain/account. |
| [Storage policy](../Evidence/credential-storage-policy-tests.json) | 18 routing checks with mocked SecItem bindings; Steam file mode uses zero SecItem calls, with no missing/unsafe-file fallback or automatic migration. |
| [Policy-aware async regressions](../Evidence/steam-credential-async-tests.json) | Policy-aware StoreClient16, account coordinator13, Session20 and authorization103; the later Session public-repair dependency differs and remains explicit. No real credentials/account/game. |
| [Older library/async aggregate](../Evidence/steam-library-async-handoff.json) | Retained scoped results, including Library28's coordinator. Its earlier credential-policy dependency hashes and authorization dependency caveat are historical; current policy-aware regressions are recorded above. |

The private backend reports above live under the owned external workspace's
`tests/` directory. They contain public catalog data and fixture evidence, not
real account credentials. The source-built local component is
`steambridge-888ea8c3a140626c7d4c95ec`, manifest SHA256
`db48c4562e02ffe2b760561a396b51c922fe2dc4d5bfc194bd6767de4c6457f9`,
helper SHA256 `f7214e986c8535549c1982da0bd86781cf5ff07a216818bde93b0ab8adab47c9`.
The preceding b83 version remains preserved with selector history.
Its payload and external read-only dependency inventories were verified. Root
selected this component for the normal state directory with the previous
selector retained in history. Selection alone is not owned-library verification.

Cached membership counts and actual-model copy rendering are verified within
the scopes above. Actual application repair persistence and final build/relocation now pass within
the scopes above. New private-file authentication/saved-token persistence and the
deferred on-screen review remain distinct unverified scopes; Root controls the
manual goal-completion audit. Hosted game input/performance testing remains suspended;
[its separate checkpoint](HOSTED_PERFORMANCE_AUDIT.md) is not marked resolved by
this catalog/UI work.
