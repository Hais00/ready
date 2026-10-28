# Durable Steam downloads

The Steam adapter exposes a persisted queue to the native frontend. It does not
launch a daemon or save credentials to disk: `download_run` is the long-lived
supervised request, and independent short requests inspect/control the same job.
Other stores retain their existing adapters.

| Operation | Options | Result |
|---|---|---|
| `download_prepare` | `gameID`, `platform`, `installDir`, public `metadata.launch` | `job` with durable `jobID`; matching unfinished work is reused |
| `download_run` | `jobID`; fresh credentials in private request stdin | numeric `progress.job`, then `result.job` |
| `download_status` | `jobID` | current `job`; interrupted-owner recovery/finalization when safe |
| `download_list` | none | profile-scoped `jobs` |
| `download_control` | `jobID`, `action`: `pause`, `resume`, `cancel`, `retry` | updated `job`; resume/retry queues work, frontend starts `download_run` |

All requests are Steam-only and carry the same canonical profile UUID. Platforms
are exactly `windows` or `macOS`. The job DTO contains `jobID`, `profileID`,
`gameID`, `platform`, canonical `installDir`, `state`, `phase`, monotonic persisted
`sequence`, timestamps, attempts, optional `errorCode`, and `retryable`.
`bytesCompleted` is verified uncompressed content, `bytesTotal` is the selected
manifest total, and `networkBytesReceived` is compressed chunk traffic for the
current attempt. These values and `fraction` remain null until the engine knows
them. Percentage text, preallocated file length and arbitrary engine logs are not
used as invented byte progress. Authentication/license/local-I/O failures are
not marked as automatic network retries.

Queue records are mode 0600 below the profile's
`Stores/steam/DownloadQueue`, with owned private directories and separate state
and runner locks. They contain no username, refresh/access token or auth state.
Credentials are supplied again from the frontend's profile account boundary on
each run. The downloader receives them over private stdin only; a non-secret
`READY_TOKEN_STDIN` flag activates that transport. Its durable nonzero LoginID
uses the reserved `0xD0000000..0xDfffffff` range, unique among jobs in this
application-data root and disjoint from the persistent service's lower range.

## Pause, cancellation and cold restart

Pinned DepotDownloader 3.4.0 has no native pause API or graceful pause handler.
Pause stops only the currently owned engine and retains the game directory and
`.DepotDownloader` cache. Resume starts the same destination with `-validate`.
The upstream implementation checks existing chunk checksums and skips valid
chunks; a restart is not treated as a fresh empty download. Verification can take
local disk time, and partial/mismatched chunks must be downloaded again.

A pinned separate GPL-2 source patch adds numeric-only `READY_DOWNLOAD_V1`
telemetry and a selected-manifest completion event. It bounds internal network
attempts, refuses interactive password/2FA fallback for private-token jobs, and
writes `depot.config` through a flushed temporary file and atomic replacement.
Interrupted staging files are restored or their valid chunks merged, with the
remaining original staging bytes archived instead of deleted. Legacy corrupt
owned `depot.config` metadata is archived before the engine revalidates content.

Cancellation never deletes content, cache or profile saves. It records the desired
state and stops the active owned process; metadata is never used as a PID/PGID
signal target. Engine and supervised descendants inherit the installation and
job leases. If the bridge dies, the existing supervisor reserves its process
group and cleans only that job. The next status operation marks abandoned work
interrupted after its runner lease has actually released. A live unrelated game
or overlapping downloader prevents writer admission.

Completed state requires a successful engine exit and structured completion for
the selected depots. After releasing the writer lease, the adapter acquires a
reader lease before rechecking cache manifest hashes/IDs and resolving declared
launch metadata against the actual PE/Mach-O executable. A descendant still
holding the inherited writer lease keeps the job in `verifying`; it cannot
publish an installed variant early. Ambiguous launch candidates remain an
explicit selection, not an arbitrary executable guess. Binary inspection does
not prove that a commercial game runs.

## Local build and evidence

The normal offline recipe is:

```sh
python3 Scripts/store_bootstrap.py --steam-downloader-only \
  --work-root /absolute/owned/work/build \
  --sdk-root /absolute/verified/dotnet-sdk-copy \
  --tools-store /absolute/owned/work/retained/store-downloaders
```

It copies pinned upstream/private-stdin sources, applies the recorded GPL-2
progress/recovery patch, retargets the owned build copy to the available pinned
.NET 10 framework, and compiles without network fetches. Corresponding modified
source, patch/lock, original license, NuGet input hashes and commands remain in
the version. Existing source/bin files are not overwritten. The project selects
an immutable version at the existing `Runtime/Tools/StoreBridge/DepotDownloader`
path; selection history and the old development fallback remain available.
`build_steam_downloader.py --rollback-project <history-record>` only restores that
reviewed selector and retains all code. A newly built complete central tools view
pins the resolved downloader version. Older immutable tools views are not
silently modified; an incompatible old engine is rejected before login.

`Scripts/test_steam_download_queue.py` uses real supervised cold processes and a
benign chunk-verifying engine. It covers pause/resume, cancel, network versus
auth failure, SIGKILL/lease recovery, profile conflicts, delayed descendant
release, both executable platforms, safe paths and credential/log hygiene.
Separate C# source fixtures cover the actual staging-recovery and numeric-byte
code. No genuine account, CDN or large commercial game is used by these tests.
Real entitled downloads, CDN behavior and commercial launch still need their own
validation. Complete .NET/NuGet source/notices and binary distribution approval
are separate gates. This adapter protects profile paths and rejects escaping
links/hardlinked mutable game files; normal game updates may replace or remove
the engine's manifest-managed game files, so it does not claim to discover and
protect arbitrary undocumented saves placed in those paths.
