# Prefix and profile architecture

The user's architecture correction replaces the initial shared-prefix design without replacing the project.

## Layout

Inside the launcher's application-support root:

```
Runtimes/                            # centrally installed engines/configuration
Games/<store>/<game>/<platform>/      # shared installation files
Prefixes/<profile>/<game-key>/        # Windows registry and per-game DLL COW projections
Profiles/<profile>/Documents/         # shared across that profile's Windows games
Profiles/<profile>/Saved Games/       # same profile, persistent
Profiles/<profile>/Games/<key>/AppData # persistent, isolated for that game/profile
Sessions/<session-uuid>/              # private0600 overlay control/status files
Locks/<profile>-<game-key>.lock       # lock just this pair
Backups/                             # old prefixes and redirect source data
Migration/plan.json                  # latest migration and validation state
Migration/Plans/<id>/                # plan history and pre-migration library snapshot
InstallLocks/                       # separate shared-read/exclusive-update protocol
```

Game keys include the full SHA256 of the source identifier; punctuation sanitization cannot collide two game IDs. Native macOS games never create a Wine prefix.

Documents/My Documents, Saved Games and AppData are symlinks in the Wine user directory, accompanied by a User Shell Folders registry import. Documents and Saved Games are profile-wide. AppData is per game/profile, as is the prefix registry. Old physical directories are copied conservatively and retained as backups; default Wine links into the real macOS home are removed as links only and never recursively imported.

## Session and engine rules

Each prefix has its own OS file lock. A running game's prefix cannot have its DLL selection or registry mutated by another ready session. Other prefix pairs are independent. Translator DLLs use per-prefix APFS copy-on-write projections of central versioned files, so installer writes cannot mutate another game or the central engine. Non-APFS volumes copy only the selected translator DLLs; the full Wine engine is not duplicated. `wineserver -k/-w` is always scoped with the exact session's WINEPREFIX. There is no global `killall`.

Automatic selection requires a runtime that exists and a path recorded as verified. Exact game/wine-version compatibility rules have priority; generic verified API paths can be candidates but are not described as per-game proof. Advanced overrides never cause simultaneous indiscriminate renderer loading. Selection and DLL changes occur before launch, not while a game is active. Runtime and game behavior must be validated beyond a synthetic file-existence check.

### Interrupted renderer DLL projection

Each architecture has an independent private intent (`managed-dlls.intent.json` / `managed-dlls32.intent.json`). Before changing any DLL, EngineInstaller retains COW/file snapshots of the affected system files, permanent originals and prior manifest, then records the complete old/new name union. Newly introduced DLLs therefore cannot escape tracking if copying finishes before the final manifest write.

On the next initialization, recovery runs **before** an unchanged-runtime-marker early return and before another renderer selection. Under the caller's same game/profile prefix lease it restores the exact pre-swap state; changed or newly written current DLLs are archived inside `.ready/EngineTransactions/<transaction>/recovery`, including custom post-interruption versions. Normal swaps retain the replaced versions and snapshot packet as well. Existing original-backup/provider-epoch rules and separate PE32/PE64 manifests remain in force. A corrupt manifest, intent or snapshot stops the operation without guessing an empty state or discarding the journal.

`EngineTransactionChecks` injects an exception through an explicitly marked fixture callback after a new DLL has actually been projected and before manifest commit, for both system32 and syswow64. It verifies unchanged-version recovery, absent-new-DLL cleanup, preservation of before/after custom versions, pure Wine restoration, corruption rejection and central-payload immutability. This is a process-interruption state/fixture test, **not a real SIGKILL or power-loss claim**. Production configuration has no environment-driven fault hook or sleeps.

## Recreation and migration

Prefix recreation acquires its lease, moves the old prefix into Backups, and prepares a new prefix pointing at the same persistent personal directories. On setup failure it restores the old prefix. This preserves saves in redirected locations; games saving elsewhere need explicit save rules and real verification.

`Game.saveRules` now applies additional **directory** mappings from verified per-game recipes, such as `drive_c/ProgramData/Game/Saves`. They point into that game/profile's persistent `ExtraSaveFolders` data. The prefix stores the recipe before importing data, merges it with later incoming recipes, and carries it across recreation. Existing physical save folders are imported with their original directory retained in Backups; name conflicts are retained separately. Standard Windows user folders remain handled by the profile redirections above. Rules cannot redirect Windows system folders, traverse outside the prefix, overlap one another, alias the same Windows path with different case, or import unverified internal links.

`Scripts/test_custom_saves.py` runs actual Windows CreateFileA/GetFileAttributesA through the real SessionManager: game A writes a normal C:\\ProgramData save, game B and a second profile cannot see it, and recreating A retains both its save and old prefix. The next launch omits the recipe intentionally and succeeds using the persisted one. Unknown save locations still need a verified recipe; this is not a claim that every game's storage convention has been discovered.

Legacy migration first writes a plan and leaves SharedPrefix untouched. Ownership of old mixed-account data cannot safely be inferred. Execution copies into independently writable per-game prefixes for the assigned owner profile and prepares redirects. The original remains the rollback source; no automatic deletion occurs. A copied prefix is marked **awaiting real validation**, not complete.

`LegacyMigration.rollback` acquires all affected prefix leases and archives the migrated copies with their modified data instead of deleting them. It leaves the original legacy prefix and the persistent profile folders intact. Rollback refuses a running destination or an invalid/replaced source. The GUI exposes Dati e ripristino from the Library menu and settings. It requires an explicit owner selection, reviews the candidate games, runs copying off the UI thread, and offers archival rollback. Per-profile variant bindings prevent a migrated executable from becoming another profile's launch target. Original legacy executables are blocked from direct launch until migrated, so an uncommitted operation cannot silently write into its rollback source.

Copying writes a private journal before touching each destination. Interrupted or failed copies block affected game/profile sessions and can be archived through the GUI before retrying. `Scripts/test_migration_crash.py` kills an actual LauncherCore copy during file creation, recovers it, retries both games and verifies the original content hash is unchanged. This uses synthetic data; rollback now has a durable move journal, inode/device reconciliation and idempotent recovery. Six real SIGKILL checkpoints verify crash boundaries, conflicting replacement preservation, stale library reconciliation and retry. Migrations of real user games still require verification. Original files and partial copies are retained rather than deleted.

Wine PE32 builtins are projected separately into each prefix's `syswow64` using APFS copy-on-write (file copies on other volumes); executable Wine/Unix engines remain central. Pure Wine files for the selected provider are bootstrapped before wineboot, while 32-bit and 64-bit renderer DLLs have separate selection/backup manifests. Updating an unmodified core projection cannot write through to another prefix; custom modified core files are preserved. Actual installed payload availability is checked for the requested executable architecture. Initialization identity includes the selected Wine executable and pure PE32 directory; switching providers cannot reuse a marker from another Wine build. A real provider-version migration still needs its own compatibility proof.

## Scope and unresolved limits

The architecture correction is checked at the following boundaries. These are
repeatable probes of synthetic games and data, not certification of arbitrary
commercial games or ownership of mixed legacy accounts.

| Requested verification | Concrete evidence |
| --- | --- |
| A dependency change in A leaves B unchanged | Shared `LauncherChecks` domain suite plus `Scripts/runtime_prefix_proof.py`; Core provider round-trip also compares the other game's DLL and registry bytes |
| Profiles do not share personal account markers, registry or saves | `Scripts/runtime_prefix_proof.py` uses actual Windows registry/folder APIs; `Scripts/test_custom_saves.py` checks another game and another profile |
| Documents are normal Windows paths | Wine canonical-folder and CreateFile probes in `Scripts/runtime_prefix_proof.py` |
| Automatic rendering uses available engines | Domain renderer-policy checks reject unavailable or unverified paths; wrapper E2E and Core provider probes test the specific locally installed runtime generation |
| Recreating a prefix retains saves | Windows API prefix probe and five `Scripts/test_custom_saves.py` checks, including a later launch with no incoming recipe |
| Terminating A leaves B active | `Scripts/test_wine_sessions.py` runs two actual Windows sessions; keeper and SessionManager tests check leases and exact-prefix shutdown |
| Migration preserves originals and can recover | `Scripts/test_migration_crash.py` and `Scripts/test_rollback_crash.py`, including real process kills at copy/rollback boundaries |

Run the domain suite with `swift run --jobs 2 ReadyCoreProbe`. Runtime probes need
the separately provisioned central engines; their raw local evidence is ignored
by Git. The sanitized [checkpoint](../Validation/checkpoint.json) reports their
scope and the remaining verification gates.

- Profiles are launcher profiles within one macOS account. This is logical data separation, not a sandbox against malicious same-user code.
- macOS-native apps can ignore HOME or share OS services. Their per-profile save/account isolation still needs game-specific handling; they are not forced into Wine.
- Launched games now hold a shared installation lease in the native keeper. Store downloads hold an exclusive writer lease; overlapping target/ancestor/descendant paths conflict while distinct games and multiple readers stay independent. Protocol v2 is tested across native C and Python plus real SessionManager/Wine sessions. All participants must be upgraded together; old v1 download processes must finish before switching. External store clients/updaters that do not participate cannot be coordinated automatically.
- Domain checks cover independent registry/DLL files, profile-specific AppData, Documents links, recreation survival, lock concurrency, safe paths and original-preserving migration. Separate Windows executables running under Wine also verify registry/folder APIs, private account markers, cross-profile separation and saved-data survival after recreation. Native keeper tests verify independent process termination and retained locks after launcher crashes. Actual game save locations, real-game migration and multi-session behavior remain integration gates.
- Prefix separation is not claimed to reduce VRAM. VRAM goals are handled by UI teardown and in-process rendering measurements.
