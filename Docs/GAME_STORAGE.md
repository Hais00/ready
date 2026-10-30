# Game libraries and installation space

Ready stores game-library configuration separately from the game catalog, under
its private state directory in `Storage/libraries.json`. A library is a user-chosen
folder, identified by its persistent ID, volume UUID/device and directory inode.
Settings → Archiviazione adds folders, renames their display name, chooses a
default and removes entries. Removing an entry never deletes game files. Roots
that overlap another library, change identity or become unavailable/read-only
cannot silently receive a new installation.

The installation page lists the configured libraries, their usable free space
and the selected version's installation/download size. Its Manage action opens
Archiviazione and returns to the same installation page afterwards. There is no
fixed Dati-only installation path: Dati APFS remains the initial preference for
this installation, while the user can select other folders and volumes.
Recognized existing Steam installations can be adopted into the registry without
moving files or changing their ownership. Windows game files remain shared;
Wine prefixes, profile configuration and personal saves retain their existing
separate locations. Native macOS games require no Wine prefix.

## Reservations and jobs

Before starting a managed installation, the storage engine creates a persistent
reservation. It aggregates reservations from every configured library on the
same device/volume; two folders do not each promise the same free bytes. The
reservation is associated with the downloader's durable job before the worker
starts. Profile-scoped queue reconciliation preserves other profiles' paused
work. Progress reduces remaining reserved bytes so written data is not counted
twice. Completion releases the reservation and registers the installation;
cancellation/interruption retains existing files for recovery.

A reservation with unknown bytes is explicitly unplanned and cannot create an
installation. The user-facing install flow requests a usable manifest/depot plan;
unknown/partial results are displayed honestly rather than turned into zero.
Removal is refused while a library still has active reservations.

For Steam, the verified plan fixes the selected depot/manifest identities. The
Python queue persists them, checks the private storage registry/path/profile and
free space before launch, and supplies the exact depot/manifest arguments to the
existing downloader. Completion must report the same manifest set. Credentials
still travel privately through the existing mechanism; a size plan does not
replace Steam's license/depot-key checks. Paused jobs retain their pinned plan.
Legacy queue files remain supported without being relabelled as managed plans.

## What a size means

- Installation payload: the selected uncompressed depot/manifest files. PICS
  estimates are labelled; authenticated plans verify selection and access.
- Download payload: the selected compressed content when the source supplies it.
  This does not promise the exact network traffic of a resumed or cached job.
- Installed folder size: a background measurement of known installation roots,
  with symlinks skipped and hard links deduplicated. Results are indexed and
  invalidated by completion and recognized executable/build-manifest changes.
- Store minimum requirement: separately identified descriptive data, never used
  as a fabricated download size.

Physical APFS allocation, shared clone extents, temporary workspace, existing
files and patch strategy can differ from payload totals. Volume free space is
queried independently. No source is presented as an exact peak-disk guarantee
when it does not provide one.

Steam catalog records expose per-platform PICS estimates and public Store
requirements. The authenticated installation planner uses public/English/64-bit
selection consistent with the current downloader. Epic and GOG use their open
manifest/info engines. Amazon does not provide compressed network bytes through
its current manifest schema; multi-package content is marked partial because the
current Nile installation path does not implement all packages. Missing sizes
stay visible as unavailable, with recalculation/authentication actions.

## Verification

The [current validation summary](../Validation/storage-interface-checkpoint.json)
separates own-directory storage/queue tests, fake or offline SDK plans, actual
hidden UI/controller checks and live application inspection. No game install,
uninstall or move is performed merely by configuring a library. Actual store/CDN
installations, external-volume hot unplug and physical controller acceptance are
separate from the controlled fixtures. Existing installs and saves are preserved.
