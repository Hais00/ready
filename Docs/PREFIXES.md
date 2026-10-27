# Prefix and profile architecture

The user's architecture correction replaces the initial shared-prefix design without replacing the project.

## Layout

Inside the launcher's application-support root:

```
Runtimes/                            # centrally installed engines/configuration
Games/<store>/<game>/<platform>/      # shared installation files
Prefixes/<profile>/<game-key>/        # Windows registry and per-game DLL links
Profiles/<profile>/Documents/         # shared across that profile's Windows games
Profiles/<profile>/Saved Games/       # same profile, persistent
Profiles/<profile>/Games/<key>/AppData # persistent, isolated for that game/profile
Sessions/<session-uuid>/              # private0600 overlay control/status files
Locks/<profile>-<game-key>.lock       # lock just this pair
Backups/                             # old prefixes and redirect source data
Migration/plan.json                  # legacy migration and validation state
```

Game keys include the full SHA256 of the source identifier; punctuation sanitization cannot collide two game IDs. Native macOS games never create a Wine prefix.

Documents/My Documents, Saved Games and AppData are symlinks in the Wine user directory, accompanied by a User Shell Folders registry import. Documents and Saved Games are profile-wide. AppData is per game/profile, as is the prefix registry. Old physical directories are copied conservatively and retained as backups; default Wine links into the real macOS home are removed as links only and never recursively imported.

## Session and engine rules

Each prefix has its own OS file lock. A running game's prefix cannot have its DLL selection or registry mutated by another ready session. Other prefix pairs are independent. Translator DLLs link to central versioned engine files; the full engine is not copied into every prefix. `wineserver -k/-w` is always scoped with the exact session's WINEPREFIX. There is no global `killall`.

Automatic selection requires a runtime that exists and a path recorded as verified. Exact game/wine-version compatibility rules have priority; generic verified API paths can be candidates but are not described as per-game proof. Advanced overrides never cause simultaneous indiscriminate renderer loading. Selection and DLL changes occur before launch, not while a game is active. Runtime and game behavior must be validated beyond a synthetic file-existence check.

## Recreation and migration

Prefix recreation acquires its lease, moves the old prefix into Backups, and prepares a new prefix pointing at the same persistent personal directories. On setup failure it restores the old prefix. This preserves saves in redirected locations; games saving elsewhere need explicit save rules and real verification.

Legacy migration first writes a plan and leaves SharedPrefix untouched. Ownership of old mixed-account data cannot safely be inferred. Execution copies into independently writable per-game prefixes for the assigned owner profile and prepares redirects. The original remains the rollback source; no automatic deletion occurs. A copied prefix is marked **awaiting real validation**, not complete.

## Scope and unresolved limits

- Profiles are launcher profiles within one macOS account. This is logical data separation, not a sandbox against malicious same-user code.
- macOS-native apps can ignore HOME or share OS services. Their per-profile save/account isolation still needs game-specific handling; they are not forced into Wine.
- Synthetic checks cover independent registry/DLL files, profile-specific AppData, Documents links, recreation survival, lock concurrency, safe paths and original-preserving migration. Wine registry resolution, actual game save locations, complete migration recovery and end-to-end multi-session behavior remain integration gates.
- Prefix separation is not claimed to reduce VRAM. VRAM goals are handled by UI teardown and in-process rendering measurements.
