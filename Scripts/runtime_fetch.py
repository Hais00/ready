#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fetch upstream runtime artifacts into this project only; retain provenance.

Apple's optional evaluation runtime is deliberately not a distribution input.
"""
import concurrent.futures
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "Runtime"
ARTIFACTS = {
    "vulkan-loader-1.4.366": "https://codeload.github.com/KhronosGroup/Vulkan-Loader/tar.gz/v1.4.366",
    "vulkan-headers-1.4.366": "https://codeload.github.com/KhronosGroup/Vulkan-Headers/tar.gz/v1.4.366",
    "spirv-tools-1.4.363.0": "https://codeload.github.com/KhronosGroup/SPIRV-Tools/tar.gz/vulkan-sdk-1.4.363.0",
    "spirv-headers-1.4.363.0": "https://codeload.github.com/KhronosGroup/SPIRV-Headers/tar.gz/vulkan-sdk-1.4.363.0",
    "moltenvk-1.4.2": "https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar",
    "dxvk-3.1.1": "https://github.com/doitsujin/dxvk/releases/download/v3.1.1/dxvk-3.1.1.tar.gz",
    "vkd3d-proton-3.0.1": "https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v3.0.1/vkd3d-proton-3.0.1.tar.zst",
}

APPLE_COMPAT_ARTIFACT = ("gptk-wine-base-3.0-3", "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")

def fetch_open_wine_dependencies():
    """Use only the open-source dylib dependencies from the community Wine bundle.

    This is a local build bootstrap, not a claim that LGPL corresponding-source
    obligations for a public binary release have already been satisfied.
    """
    dest=RUNTIME/"wine-deps/lib"
    record_path=RUNTIME/"wine-deps.artifact.json"
    if record_path.exists():return json.loads(record_path.read_text())
    url="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-devel-11.18-osx64.tar.xz"
    partial=RUNTIME/"wine-deps.partial";h=hashlib.sha256()
    with urllib.request.urlopen(url,timeout=120) as src,partial.open('wb') as out:
        while data:=src.read(1<<20):out.write(data);h.update(data)
    dest.mkdir(parents=True,exist_ok=True);files=[]
    with tarfile.open(partial) as tf:
        for member in tf:
            if "/Contents/Resources/wine/lib/" not in member.name:continue
            relative=member.name.split("/Contents/Resources/wine/lib/",1)[1]
            if '/' in relative or not relative.endswith('.dylib'):continue
            target=dest/relative
            if member.isfile():
                with tf.extractfile(member) as src,target.open('wb') as out:shutil.copyfileobj(src,out)
                target.chmod(0o644);files.append(relative)
            elif member.issym() and '/' not in member.linkname:
                target.symlink_to(member.linkname);files.append(relative)
    partial.unlink()
    if not (dest/'libfreetype.dylib').exists() or not (dest/'libgnutls.dylib').exists():raise RuntimeError('Wine dependency bundle layout changed')
    record={'url':url,'sha256':h.hexdigest(),'extracted':files,'excluded':'Wine binaries and all non-dylib top-level files','distribution_reviewed':False}
    record_path.write_text(json.dumps(record,indent=2)+'\n');return record

def fetch_dependency_headers():
    import os
    cache=RUNTIME/"Tools/runtime-brew-cache"
    env=dict(os.environ,HOMEBREW_CACHE=str(cache),HOMEBREW_NO_AUTO_UPDATE="1")
    subprocess.run(["brew","fetch","--force-bottle","freetype","gnutls"],env=env,check=True)
    dest=RUNTIME/"dependency-headers";dest.mkdir(exist_ok=True)
    records=[]
    for archive in (cache/"downloads").glob('*.tar.gz'):
        with tarfile.open(archive) as tf:
            selected=[m for m in tf.getmembers() if '/include/' in m.name and not m.isdir()]
            tf.extractall(dest,members=selected,filter='data')
            records.append({'archive':archive.name,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'headerCount':len(selected)})
    (RUNTIME/'dependency-headers.artifact.json').write_text(json.dumps(records,indent=2)+'\n')
    return records

def fetch(name_url):
    name, url = name_url
    dest = RUNTIME / name
    provenance = RUNTIME / (name + ".artifact.json")
    if dest.exists() and provenance.exists():
        return json.loads(provenance.read_text())
    partial = RUNTIME / (name + ".partial")
    h = hashlib.sha256()
    print("Downloading", name, flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "ready-runtime-fetcher"})
    with urllib.request.urlopen(req, timeout=120) as src, partial.open("wb") as out:
        while data := src.read(1 << 20):
            out.write(data)
            h.update(data)
    staging = RUNTIME / (name + ".extracting")
    staging.mkdir(exist_ok=True)
    # Python 3.15 supports zstd tar archives. External tar is a fallback for older Python.
    try:
        with tarfile.open(partial) as tf:
            tf.extractall(staging, filter="data")
    except tarfile.ReadError:
        subprocess.run(["/usr/bin/tar", "-xf", str(partial), "-C", str(staging)], check=True)
    entries = list(staging.iterdir())
    if len(entries) == 1 and entries[0].is_dir():
        entries[0].rename(dest)
        staging.rmdir()
    else:
        staging.rename(dest)
    partial.unlink()
    item = {"name": name, "url": url, "sha256": h.hexdigest(), "local_only": True,
            "redistribution_reviewed": False}
    provenance.write_text(json.dumps(item, indent=2) + "\n")
    print("Ready", name, flush=True)
    return item

if __name__ == "__main__":
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--include-apple-compat',action='store_true',help='Optional local compatibility baseline; not part of the open distribution')
    parser.add_argument('--wine-deps-only',action='store_true')
    parser.add_argument('--dependency-headers',action='store_true')
    args=parser.parse_args()
    RUNTIME.mkdir(exist_ok=True)
    if args.dependency_headers:
        print(json.dumps(fetch_dependency_headers(),indent=2));raise SystemExit(0)
    if args.wine_deps_only:
        print(json.dumps(fetch_open_wine_dependencies(),indent=2));raise SystemExit(0)
    artifacts=dict(ARTIFACTS)
    if args.include_apple_compat:artifacts[APPLE_COMPAT_ARTIFACT[0]]=APPLE_COMPAT_ARTIFACT[1]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for result in pool.map(fetch, artifacts.items()):
            print(json.dumps(result), flush=True)
