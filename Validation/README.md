# Verification checkpoint

`checkpoint.json` is a sanitized summary of local measurements, not a compatibility certification. Generate it with `python3 Scripts/checkpoint_report.py` after the corresponding probes have produced their files in ignored `Evidence/`.

Raw logs, local paths, account material, proprietary libraries and downloaded binaries are excluded. Source and reproduction scripts remain in the repository. CI checks the portable source/domain/protocol paths; local Wine/GPU measurements require an Apple Silicon Mac, a display and provisioned runtimes. A successful synthetic probe does not verify store accounts, commercial games, direct display or migration of real user data.
