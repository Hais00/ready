# Steam library, metadata and artwork

Updated 2026-10-29. Ready keeps the library on disk and opens a game detail page
before Play. Remote metadata describes content and platform availability; it
never grants ownership, invents executable paths or marks a game installed.
Hosted-game input and benchmark testing remains suspended during this UI work.

## Scrolling

The library uses a native `NSScrollView` with a sparse Core Animation document.
Only viewport cards and one preheat row have layers. Scrolling moves the clip
view rather than rasterizing/uploading the whole window for every wheel event.
Configured/filter/sorted records are cached until the model or filter changes.
Hover, selection and keyboard focus use separate layers. Immutable card tiles
are cached by title, platform, installation state, dimensions and artwork
revision, bounded to 96 tiles/64 MiB. At most two missing tiles are built per
display tick; the display link pauses when idle.

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
hash. Directory/index permissions are 0700/0600; cache files contain public
artwork, not Steam authentication credentials. Cache data and publisher images
are excluded from source distributions.

Startup prepares every profile-visible owned entry, prioritizing the visible
cards. It fetches missing assets in the background with two concurrent image
requests, so banners and icons can be ready before the first detail click.
Existing positive disk entries have no TTL and are not evicted by scrolling,
restart or RAM cleanup. A persistent 404/410 is not repeatedly retried during
scrolling. Standard Steam CDN URLs are candidates, never proof an image exists.

Opening a detail shows the cached image first. It requests fresh public detail
metadata and explicitly revalidates both icon and banner (plus the card) using
conditional HTTP requests where validators exist. HTTP 304 and identical
content hashes preserve the existing artwork revision. Only a successfully
decoded replacement updates the binding; failed requests preserve the old good
image. No image refresh timer invalidates this persistent cache. The first
population still requires network transfer; prefetch cannot guarantee that every
asset has finished before an immediate click or that unpublished content has
publisher artwork.

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
