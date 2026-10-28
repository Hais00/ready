# Portable runtime configuration paths

Existing absolute `runtime.json` files keep their behavior. A runtime assembled
to be relocatable may declare its path format explicitly:

```json
{
  "pathFormat": "runtime-relative-v1",
  "runtimeID": "example-component-generation",
  "wine": "launchers/base/ready-wine",
  "wineServer": "components/base/wine/bin/wineserver",
  "kosmicICD": "icd/kosmic-x64.json",
  "builtin32Directory": "components/base/wine/lib/wine/i386-windows",
  "engineDLLs": {}
}
```

Paths resolve relative to the actual configuration file, independently of the
working directory, frontend bundle and application-data root.
`RuntimeConfiguration.read` validates and returns absolute in-memory paths;
`load` retains its unavailable-configuration fallback on error. The central
location selector uses the same reader. Reading never modifies a configuration
or executes an engine.

| Kind | Resolved fields |
| --- | --- |
| Scalar | wine, wineServer, wineBoot, kosmicICD, moltenICD, vulkanLibrary, builtin32Directory |
| Operational metadata scalar | wineBinary, kosmicNativeICD, immutableRuntimeSet, sourceDependencyPrefix |
| Engine maps | engineDLLs, engineDLLs32, engineSearchPaths, engineWineBinaries, engineWineServers, engineBootstrap32Dirs, engineBuiltin32Dirs |

Optional missing/null fields remain unchanged. Provided paths must be nonempty
and relative, without dot/parent/empty components, backslashes or NUL. Internal
aliases are allowed; escaping symlinks and unknown formats are rejected. Missing
targets remain unavailable under the existing renderer/executable checks. The
reader accepts bounded regular files (4 MiB), and cannot block on a FIFO.

Version identities, API names, DLL overrides and historical source/build paths
are not remapped. Source receipts are never rewritten into new test results.
Explicit evaluation activation resolves its fragment against the original
directory before saving an absolute configuration under user data, removing the
relative-format tag to prevent a second rebase. Source bytes, license policy and
exact restoration of the prior configuration retain their existing behavior.

The shared Core check moves synthetic fixtures to a path with spaces and removes
the old location, then checks PE32/PE64 paths, central selection, aliases, rejected
formats, size/FIFO limits, immutable provenance and evaluation restoration. The
frontend relocation suite also selects the moved relative runtime without
executing its synthetic Wine file. These checks establish the path contract,
not Wine/GPU compatibility.

## Actual local runtime projection proof

`runtime_portable_projection.py` creates only an owned diagnostic COW projection
under `Runtime/TestProjections`. Base/DXMT component bytes, original wrappers,
ICDs and source-generation receipts remain unchanged. New launchers and relative
ICDs live outside the component trees; launchers call the relocated canonical
Wine executable directly. The original configuration is retained as provenance,
with a distinct projection manifest. Neither a user location pointer nor an
evaluation configuration is activated.

`test_runtime_projection.py` passes 14 baseline checks using real Wine before
and after moving the whole runtime directory. They include WinAPI PE64/PE32
file writes/reads through one persistent game/profile save binding, Vulkan
Kosmic/Molten buffer readback and DXMT buffer readback on PE64/PE32. Each Wine
process is denied access to the original component/developer/Homebrew roots and
audited for every loaded native image. No unexpected non-system image is loaded.

Thirteen additional checks pass from the moved root: DXMT PE64 shader/readback;
600 DXMT presentations on PE64/PE32 with fullscreen requested and no windowed
fallback; 600 Vulkan presentations through each ICD; and real HTTPS, untrusted
certificate rejection, GDI and DirectWrite on both PE architectures. Negative
certificate checks require the actual verification diagnostic and no bypass.
The Vulkan probe uses its original 960×600 window and makes no fullscreen claim.
PE32 shader rasterization, gaming performance and direct display are not claimed.

The resource run first stopped at its 512 MiB disk reserve after initializing
two prefixes. After project-only Swift cache cleanup, a bounded resume reused
those exact owned prefixes and existing adapter without redoing boot/baseline
tests. It binds the retained stop-report bytes, projection manifest and original
configuration hashes. The original 14-check report remains byte-identical; the
13-check resume has a separate report. All fixture prefixes were removed only
after their exact wineserver waits; source, projection, receipts and configuration
hashes remain unchanged. This is local synthetic integration evidence on macOS
27.0.1, not validation of store accounts or commercial games.

```sh
python3 Scripts/runtime_portable_projection.py
python3 Scripts/test_runtime_projection.py --projection /absolute/owned/TestProjections/root --output Evidence/runtime-projection-full-tests.json
```

An assembled projection remains diagnostic. The source/notice gate for the
complete runtime, an installer and the ARM64 external-library closure are still
unfinished. The 25-dependency evidence transport in [DISTRIBUTION.md](DISTRIBUTION.md)
preserves the narrower scope of that existing gate.

Relative JSON alone does not relocate shell constants, ICD paths, Mach-O loads
or compiled-in fallbacks. Generation 68 still has such issues: its Wine/Vulkan
binaries declare macOS 27 minimum; Kosmic ARM64 references Homebrew libraries.
The separate diagnostic local projection retains immutable component bytes and
generates new entrypoints/ICDs outside those trees. Actual load/presentation tests
and complete distribution inventory are separate gates. See
[core provenance](RUNTIME_CORE_PROVENANCE.md) and
[renderer provenance](RENDERER_PROVENANCE.md). No user configuration is activated,
proprietary component bundled, or consumer archive approved by this path feature.
