# Portable frontend, external runtimes

`sh Scripts/build_app.sh` stages and signs `Build/ready.app` before atomically
publishing it. Previous apps remain in `Build/AppBackups`; a failed staging or
signature check leaves the published app intact. The app does not contain or read
`development-root.txt`.

`Contents/Resources/ReadySupport` contains our built overlay, native session host,
Python StoreBridge source, original Swift/C/Objective-C sources and frontend build
recipes, GPL license, notices, and documentation. `frontend-package.json` records
SHA256 and size for every support file. The main executable is in
`Contents/MacOS/ready`. System macOS frameworks and the Python 3 interpreter remain
external requirements. StoreBridge requires an available `python3` on `PATH`;
this package does not claim to install Python or the independent store engines.

No runtime, Vendor tree, third-party store dependency checkout, compiled .NET
helper, downloaded game, account token, user library, evidence log, or proprietary
Apple SDK/runtime is copied into the app. The package inventory is a frontend
scope statement, **not approval of a whole application/runtime distribution**.
The existing source dependency gate still applies only to its approved 25 shared
libraries/modules. Wine, renderers, tools and their provenance must pass their own
applicable checks before anyone distributes them. Apple's optional proprietary
files remain external local evaluation inputs with their separate license; they
are never classified as GPL or bundled here.

## Selecting the central installation

Open **Libreria → Motori…** (also available from **Account e runtime… → Motori…**)
and choose **Scegli cartella…**. Select the existing central directory containing
`runtime.json`, with independent store tools under `Tools/StoreBridge` when
installed. The picker starts at the current runtime location. The selection is
validated by decoding the real ready runtime configuration and checking that any
declared Wine executable is available; it does not run Wine or any helper. A
configuration without Wine is accepted for native macOS games, and the dialog
states that Windows support is unavailable. Missing store tools are shown
separately.

The app remembers only a private location pointer at
`dataRoot/Runtimes/external-runtime-location.json`. It creates no runtime.json and
copies no engine, DLL, SDK, account, or game files. **Usa posizione predefinita**
removes the pointer; **Ripristina posizione precedente** restores the preceding
selection. Changes retain private UUID history plus a previous-location snapshot
under the same Runtimes directory. An invalid owned pointer can be reset through
the interface, with its original bytes retained in history. A saved root whose
installation later goes missing remains selected and is reported unavailable.

The data root and location/history directories must be canonical, owned by the
current user, and private. Directory traversal and pointer updates use file
descriptors without following symlinks; updates are locked, written as mode 0600,
and published atomically. Selection errors never change an external runtime or
the user's runtime.json. Location changes are blocked while a session, store
request, authentication, launch preparation or data-maintenance operation is
active. Idle session/store clients receive the new location together.

## Path contract

- Packaged code resolves relative to the running app's `ReadySupport` resource.
- `READY_PROJECT_ROOT` explicitly selects a source checkout for development.
  Direct `.build` executables also locate their checkout; source execution keeps
  the historical read-only `checkout/Runtime` fallback.
- `READY_RUNTIME_ROOT=/absolute/external/runtime` selects an external engine/tool
  installation and has priority over the saved location. The saved location is
  next. With neither set, a packaged app uses the selected application's data
  directory plus `Runtimes`; source execution keeps `checkout/Runtime`. The dialog
  identifies when an environment override remains active.
- An existing `dataRoot/Runtimes/runtime.json` always takes priority over
  `READY_RUNTIME_ROOT/runtime.json`. Evaluation fragments come from the selected
  external runtime root, and enabling evaluation writes only the existing owned
  application configuration/history through `EvaluationMode`.
- `--data-root /absolute/private/directory` selects application data for normal
  execution and diagnostics. It isolates library, profiles, prefixes, logs and
  Keychain scope. In source mode the trusted checkout runtime is still readable;
  a packaged app has no implicit checkout fallback.
- StoreBridge receives the same `READY_RUNTIME_ROOT` and `READY_DATA_ROOT` as the
  frontend and never needs to write Python bytecode in signed app resources.

Central store tools live under `runtimeRoot/Tools/StoreBridge`: `venv`, `dotnet`,
`SteamBridge/ReadySteamBridge.dll` and `DepotDownloader/DepotDownloader.dll` (with
all sibling dependencies required by each helper). A source checkout retains its
old `.NET bin/Release` fallback only when using that checkout's `Runtime` root.
A packaged app or an explicit external root never falls back to development
helper binaries. Existing `Scripts/store_bootstrap.py` remains a source-development
bootstrap; it is not run automatically by the app, and it does not grant release
permission. This packaging change neither seeds nor overwrites any user runtime
configuration or engine tree. Provision an external runtime separately, then select
its location through Motori….

## Verification

```sh
sh Scripts/build_app.sh
python3 Scripts/test_frontend_package.py --output Evidence/frontend-package-tests.json
Build/ready.app/Contents/MacOS/ready --frontend-self-test --data-root /tmp/ready-owned-test-data
READY_RUNTIME_ROOT=/absolute/external/runtime Build/ready.app/Contents/MacOS/ready --diagnostics --data-root /tmp/ready-owned-test-data
```

The relocation test copies the app into a temporary path containing spaces and
runs it from an unrelated working directory, without `READY_PROJECT_ROOT` or a
runtime installation. It verifies support hashes, the exact three native payload
files, signature validity, missing-runtime reporting without data writes, external
runtime selection, saved-location persistence, environment and user-configuration
precedence, private history and previous-location restore, invalid/symlink/unowned
path rejection, corrupt-pointer reset recovery, and the relocated Python bridge
through its process supervisor using only the local `capabilities` operation.
`--frontend-self-test` does no Metal/UI initialization, account/network access,
Keychain access, game execution, or data creation. `--diagnostics` additionally
queries Metal. These probes do not certify games, store authentication, GPU
presentation, an external runtime, or distribution of external dependencies.

Explicit scoped location commands are available for automation/testing. They require
`--data-root` with a canonical, owned private directory; there is no implicit write
to the normal user's data root:

```sh
Build/ready.app/Contents/MacOS/ready --set-runtime-root /absolute/central/runtime --data-root /absolute/private/test-data
Build/ready.app/Contents/MacOS/ready --reset-runtime-root --data-root /absolute/private/test-data
Build/ready.app/Contents/MacOS/ready --restore-runtime-root --data-root /absolute/private/test-data
python3 Scripts/test_frontend_package.py --external-runtime Runtime --output Evidence/frontend-package-tests.json
```

The optional `--external-runtime` test selects that existing installation using an
isolated temporary pointer and verifies the original configuration hash is
unchanged. It never executes that runtime. These commands and the GUI selector do
not accept vendor terms or change evaluation/consumer policy flags.
