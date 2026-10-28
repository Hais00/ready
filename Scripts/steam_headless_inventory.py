#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read code images only; never load a Valve/GameNative image or read account data.

The selected directory must be Steam.app/Contents/MacOS (including the updated
Steam.AppBundle layout). Output is research metadata, not redistribution approval.
No process discovery, signalling, login, configuration or credential access.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess


EXPORTS = {
    "CreateInterface", "Steam_CreateSteamPipe", "Steam_BReleaseSteamPipe",
    "Steam_CreateGlobalUser", "Steam_CreateLocalUser", "Steam_ConnectToGlobalUser",
    "Steam_ReleaseUser", "Steam_LogOn", "Steam_LogOff", "Steam_BLoggedOn",
    "Steam_BGetCallback", "Steam_FreeLastCallback", "Steam_ReleaseThreadLocalMemory",
}
CODE_FILES = (
    "steam_osx", "steamclient.dylib", "libtier0_s.dylib", "libvstdlib_s.dylib",
    "libaudio.dylib", "libsteam.dylib", "libsteaminput.dylib", "libsteamwebrtc.dylib",
    "Frameworks/SteamHelper.app/Contents/MacOS/libsteam_api.dylib",
)


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def tool(argv):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    if p.returncode:
        raise RuntimeError("code inspection tool failed: " + argv[0])
    return p.stdout


def inventory(code_dir, android_helper, llvm):
    code_dir = code_dir.resolve(strict=True)
    if code_dir.name != "MacOS" or code_dir.parent.name != "Contents":
        raise ValueError("expected explicit Steam bundle Contents/MacOS code directory")
    if not (code_dir / "steamclient.dylib").is_file():
        raise ValueError("Steam client code image missing")
    records = []
    for relative in CODE_FILES:
        path = code_dir / relative
        if not path.is_file():
            continue
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(code_dir):
            raise ValueError("code image escapes selected code directory")
        before = sha(path)
        architectures = tool(["/usr/bin/lipo", "-archs", str(path)]).strip().split()
        exports = {}
        for arch in architectures:
            lines = tool([str(llvm / "llvm-nm"), "--arch=" + arch,
                          "--defined-only", "--extern-only", str(path)]).splitlines()
            exports[arch] = [line.strip() for line in lines
                             if line.split() and line.split()[-1].lstrip("_") in EXPORTS]
        records.append({"relativePath": relative, "path": str(path),
                        "bytes": path.stat().st_size, "sha256": before,
                        "architectures": architectures, "selectedExports": exports,
                        "loadCommands": tool(["/usr/bin/otool", "-L", str(path)]),
                        "uuid": tool(["/usr/bin/dwarfdump", "--uuid", str(path)]),
                        "unchangedAfterInspection": sha(path) == before})
    # Info.plist is executable-bundle metadata, not Steam account configuration.
    info = plistlib.loads((code_dir.parent / "Info.plist").read_bytes())
    version = {key: info.get(key) for key in ("CFBundleIdentifier", "CFBundleVersion",
               "CFBundleShortVersionString", "CFBundleExecutable", "LSMinimumSystemVersion")}
    helper_before = sha(android_helper)
    android = {"path": str(android_helper), "sha256": helper_before,
               "bytes": android_helper.stat().st_size,
               "elf": tool([str(llvm / "llvm-readelf"), "-h", "-l", "-n", str(android_helper)]),
               "dynamicSymbols": tool([str(llvm / "llvm-nm"), "--dynamic", str(android_helper)]),
               "unchangedAfterInspection": sha(android_helper) == helper_before,
               "proprietarySourceWithheld": True}
    return {"schemaVersion": 1, "scope": "static code-only interoperability research",
            "executedClientImages": False, "accountDataRead": False,
            "processesSignalled": False, "abiVerifiedByExecution": False,
            "distributionApproved": False, "steamBundleMetadata": version,
            "steamClientBuildRevision": None,
            "steamClientBuildRevisionNote": "Bundle version is not a verified client build revision",
            "macCode": records, "androidBootstrap": android}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--steam-code-dir", type=Path, required=True)
    p.add_argument("--android-helper", type=Path, required=True)
    p.add_argument("--llvm", type=Path, default=Path("/opt/homebrew/opt/llvm/bin"))
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    report = inventory(args.steam_code_dir, args.android_helper, args.llvm)
    # Refuse overwriting an existing receipt or following an output symlink.
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
