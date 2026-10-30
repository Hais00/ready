# Steam library, metadata and artwork

Updated 2026-10-30. Ready keeps the library on disk and opens a game detail page
before Play. Remote metadata describes content and platform availability; it
never grants ownership, invents executable paths or marks a game installed.
Hosted-game input and benchmark testing remains suspended during this UI work.

## Current cards, details and return from gameplay

Library cards show the title and upper-right Apple/Windows availability icons.
Portrait artwork keeps its aspect ratio; selection and hover have dedicated
viewport/document padding. The detail body inherits the launcher background and
uses a larger hero. Controller navigation reaches the version picker, primary
action, options, transfer control, long description and Back, skipping disabled
actions. Installation has its own controller-aware page with library selection.
See [game libraries and space](GAME_STORAGE.md) for size semantics and storage
configuration.

Before gameplay, Ready retains the already decoded thumbnails of the last
viewport, bounded to 24 cards/16 MiB of CPU image memory. It releases its grid
layers, tiles and Metal resources; the retained thumbnails are not GPU textures.
Catalog models and titles remain cached. On return, those thumbnails are restored
before rebuilding the grid. Missing cached thumbnails get priority indexed disk
reads; background artwork and metadata warming resume afterwards. A cache miss
does not hold restoration waiting for a network download. Both gameplay and
maintenance pause states are cleared on return, including failed launches.

Controlled hidden-window checks verify actual artwork restoration and release
of owned canvas GPU storage. They do not establish zero system-wide GPU memory,
immediate display scan-out, game FPS, or physical controller acceptance. The
[storage/interface checkpoint](../Validation/storage-interface-checkpoint.json)
records the current verification scope.

## Scrolling

The library uses a native `NSScrollView` with a sparse Core Animation document.
Only viewport cards and one preheat row have layers. Scrolling moves the clip
view rather than rasterizing/uploading the whole window for every wheel event.
Configured/filter/sorted records are cached until the model or filter changes.
Hover, selection and keyboard focus use separate layers. Immutable card tiles
are cached by title, platform, installation state, dimensions and artwork
revision, bounded to 96 tiles/64 MiB. A tick builds at most six missing tiles, with a soft 4 ms precheck between
non-preemptible Core Graphics draws; the display link pauses when idle. Existing
artwork remains visible until a replacement tile is ready.

Rare shell updates use a bounded asynchronous Metal queue with immutable texture
uploads. The main thread no longer waits for GPU command completion. Session
resource release drops the grid, tile memory and owned requests; command
completion retains resources that are still in flight. These changes address
library work only and make no claim about hosted-game FPS.

The controlled 495-record copy test measured Main CPU p95 of 55.33 ms for
the previous full-raster reference and 0.52 ms for cached scroll ticks, with
zero shell rasters during the sampled scrolling. It retained 468 Games and 27
Other records, with no deletion. This is CPU fixture evidence, not an on-screen
FPS or smoothness measurement; see [the sanitized validation summary](../Validation/steam-library-cache-checkpoint.json).

## Persistent artwork

The selected cache directory is `/Volumes/Dati APFS/Ready Cache/Artwork`.
`ArtworkIndexStore` maintains a keyed durable index for game ID and image role
(card, icon, banner), URL candidates, selected URL, content hash, ETag and
Last-Modified. Originals and size-specific decoded thumbnails are stored by
hash. Card thumbnails are capped at 512 pixels, sufficient for the current grid
size; existing 1024-pixel thumbnails are decoded locally without a download.
Cards have their own bounded RAM cache, separate from detail banners/icons.
Directory/index permissions are 0700/0600; cache files contain public
artwork, not Steam authentication credentials. Cache data and publisher images
are excluded from source distributions.

Startup prepares every profile-visible owned entry, prioritizing the visible
cards. It fetches missing assets in the background, so banners and icons can be ready
before the first detail click. Interactive work has two reserved request slots,
look-ahead one, and background warming at most two (five total). A FIFO priority
scheduler prevents newer background work from overtaking visible cards. Requests
for obsolete visible rows are demoted or cancelled with generation tokens.
Existing positive disk entries have no TTL and are not evicted by scrolling,
restart or RAM cleanup. A persistent 404/410 is not repeatedly retried during
scrolling. Standard Steam CDN URLs are candidates, never proof an image exists.

Opening a detail shows the cached image first. It requests fresh public detail
metadata and explicitly revalidates both icon and banner (plus the card) using
conditional HTTP requests where validators exist. HTTP 304 and identical
content hashes preserve the existing artwork revision. Revalidation pins the
selected URL while it remains among the candidates: a reordered Store background
cannot replace a selected library hero, and a failure at that URL does not trigger
a switch to another image. New selections prefer the canonical Steam library hero
before Store/background fallbacks. Only a successfully
decoded replacement updates the binding; failed requests preserve the old good
image. No image refresh timer invalidates this persistent cache. The first
population still requires network transfer; prefetch cannot guarantee that every
asset has finished before an immediate click or that unpublished content has
publisher artwork.

## Visible artwork latency and disk recovery

Cached reads/decode run on two user-initiated workers, independently of the
serial index/blob writer. A visible row prepares cards only, with directional
look-ahead; scrolling no longer loads full-size banners/icons into the same RAM
working set. Publication is scheduled in normal, event-tracking and modal run-loop
modes. A newly decoded image can reach the view before thumbnail encoding/fsync.
Downloaded bytes waiting for persistence are bounded; background transfer pauses
before it can grow the staged-data budget indefinitely.

URL-to-content receipts are committed with downloaded blobs. A dirty marker and
an atomic recovery snapshot protect mappings if index publication fails or the
app exits mid-write. A missing, corrupt or marked-dirty index triggers one bounded
recovery pass, then the writer repairs the index. Healthy startup and scrolling
do not enumerate the cache directory. Exact URL receipt lookup can recover a
mapping missing from an older index. RAM cleanup never deletes these files.

The earlier CPU-only scrolling measurement does not measure image arrival.
Current validation records viewport entry, decoded card availability and assignment
of a tile containing actual artwork separately, including blocked background
writes and event-tracking operation. First network downloads are reported
separately from cached reads. These timings are not display scan-out measurements. The final controlled steady run
measured predictive cached artwork tile p95 of 17 ms in normal mode and 64 ms
during event tracking, with the index writer deliberately blocked. Sudden jumps
to unprepared rows took 291–439 ms. A prior run under concurrent compilation
missed the soft 100 ms target at 112 ms; that failed performance result is retained.
One uncached entrant remained an honest placeholder and is excluded from cached
image timing. Three live scroll captures showed images in their first captured
post-scroll frames, without establishing a frame-pacing or display-latency bound.

## Names, descriptions and classification

Authenticated library synchronization unions PICS package-license membership
with Steam's self-scoped `Player.GetOwnedGames` response, including its app info.
CM names/icons can fill missing PICS fields. Explicit PICS content types take
precedence. Games, demos and applications are listed under Games; DLC, tools,
runtimes, support and unresolved license records remain accessible under Other
content. Search includes both categories and supports AppID. Unresolved titles
use a textual placeholder instead of showing a numeric ID as a game title.
Records, installations and user preferences are retained. Named legacy entries
without a classification stay in Games until authoritative data arrives; a
missing field alone does not move an existing named library to Other content.

Public Store metadata warms all incomplete records once per service generation,
with a global limit of two requests. Rate limiting pauses the queue according to
the server's bounded Retry-After. A confirmed unavailable Store page is persisted
and is checked again on detail opening rather than on every startup. Temporary
network failures do not erase old details. Details always request a forced
refresh; superseded responses cannot overwrite a newer result. Metadata saves
are coalesced and serialization/fsync runs on a serial background queue shared
with synchronous user-action saves.

Some owned license records have no public Store page or description. Ready
states that limitation instead of inventing descriptions or treating missing
metadata as denial of ownership. The old cache contained 495 membership records;
this is not a claim of 495 playable base games. Fresh authenticated CM enrichment
requires a connected account and remains separate from fixture validation.

## Membership and download safety

Pages contain at most 50 records. The frontend accumulates contiguous pages and
commits only a validated terminal response with matching counts. Account,
profile and generation guards reject stale callbacks. A failed synchronization
preserves the old library. If only CM membership is available because package
enumeration failed, `licenseMembershipComplete: false` prevents removal of
previous cached membership. Public metadata cannot add ownership.

Installed variants and launch settings survive catalog merges. Platform flags
alone do not prove Apple Silicon support; an installed Mach-O must be inspected.
The detail exposes installed launch choices and the existing durable download
queue, pause/resume/cancel and verified installation path.

## Credentials and verification limits

Following explicit user consent, this installation uses a profile-scoped private
Steam refresh-token file. Passwords are never saved. Other stores/new users keep
the Keychain default. Existing Keychain entries are untouched; missing private
files never trigger a Keychain fallback. File permissions do not exclude other
programs running as the same user. A new file-mode login remains unverified.

The [sanitized validation summary](../Validation/steam-library-cache-checkpoint.json)
records cache, scrolling, classification and coordinator checks. Raw `Evidence/`
reports stay local and are excluded from Git. The summary distinguishes
controlled transports/hidden render fixtures from
actual UI review. No fixture proves on-screen frame pacing, authenticated CM
success for the user's account, or that every public description/artwork exists.
Build and relocation checks verify the frontend package separately. See also
[the earlier launch/UI checkpoint](../Validation/steam-library-interface-checkpoint.json)
and [the paused hosted performance work](HOSTED_PERFORMANCE_AUDIT.md).
