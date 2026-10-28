# Reversible project .NET SDK cache

Only the four project build-tool trees `sdk`, `packs`, `templates` and
`sdk-manifests` may be compacted by `Scripts/store_sdk_cache.py`. The .NET host,
shared runtimes, compiled store helpers, source pin, licenses and notices remain
in place. Store authentication/download execution does not require restoring the
SDK.

```sh
python3 Scripts/store_sdk_cache.py compact
python3 Scripts/store_sdk_cache.py verify
python3 Scripts/store_sdk_cache.py restore
python3 Scripts/test_store_sdk_cache.py
```

Compaction snapshots file bytes, modes and links; creates and verifies the
complete compressed archive; rechecks the originals; then moves only those four
roots into an owned removal stage before deletion. Archive and manifest hashes
remain under `Runtime/Tools/StoreBridge/sdk-cache`. A failed verification leaves
the original SDK intact. Interrupted removal is retryable and unknown staged
data is preserved.

`store_bootstrap.dotnet()` restores this exact cache when a later **build** needs
the SDK. It does not silently fetch a different version. Restore verifies the
archive before materialization, uses a private staging directory, rejects
conflicting destinations and preserves a 512 MiB free-space reserve. Already
restored exact roots are accepted on retry. The runtime-only helpers do not run
the bootstrap or compiler.

The actual four-tree snapshot contained 4,569 regular files and no links,
552,951,856 bytes. Its verified archive is 180,854,138 bytes, SHA256
`325e13620679049de7ad0adb71d1116ca801f9fd3aaec8916ef34fe941a58723`.
Host/shared, licenses and `source.json` remained byte/mode identical. Runtime
enumeration, the existing Steam bridge self-test and DepotDownloader's no-account
usage path still pass. The real full SDK restore was not performed under current
space pressure; miniature round-trip/conflict/tamper/crash-state/space tests pass.
No provider, game prefix, personal data or operating-system installation is
changed by this project cache operation.
