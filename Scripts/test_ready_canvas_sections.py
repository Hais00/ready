#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Reproduce real canvas raster/hit/keyboard/controller page-isolation checks.

Only an owned offscreen window is used. No global input, accounts or app build.
The explicit static Core product is built before standalone compilation to avoid
linking a fresh Swift value-type module against an older archive.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode=True
from swift_probe_support import prepare_core
ROOT=Path(__file__).resolve().parents[1]
DEFAULT_WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
SOURCES=['Sources/M1Launcher/MetalCanvas.swift','Sources/M1Launcher/ArtworkCache.swift','Sources/M1Launcher/LibraryEntryPresentation.swift','Sources/M1Launcher/ArtworkIndexStore.swift','Sources/M1Launcher/CanvasShellRenderer.swift','Sources/M1Launcher/LibraryGridSurface.swift','Sources/M1Launcher/GameArtwork.swift','Sources/M1Launcher/CanvasDrawing.swift','Sources/M1Launcher/ControllerNavigation.swift','Synthetic/ReadyCanvasSectionsProbe.swift']
def sha(path):
    with Path(path).open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--work-root',type=Path,default=DEFAULT_WORK);parser.add_argument('--core-root',type=Path);a=parser.parse_args()
    work=a.work_root
    if not work.is_absolute()or work.resolve(strict=True)!=work or work.stat().st_uid!=os.getuid()or work.stat().st_mode&0o077 or(work/'.ready-external-workspace').read_text().strip()!='ready project work for thread01a17e79':raise ValueError('Marked private canonical owned work root required')
    run=Path(tempfile.mkdtemp(prefix='canvas-sections-',dir=work/'tests'));run.chmod(0o700)
    source_hashes={name:sha(ROOT/name)for name in SOURCES}
    snapshots=run/'sources';snapshots.mkdir(mode=0o700)
    for name in SOURCES:(snapshots/Path(name).name).write_bytes((ROOT/name).read_bytes())
    cache=work/'cache/canvas-sections-swift';cache.mkdir(mode=0o700,exist_ok=True)
    os.environ.update(TMPDIR=str(work/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(cache),PYTHONDONTWRITEBYTECODE='1')
    if a.core_root:
        products=modules=a.core_root.resolve(strict=True);archive=products/'libLauncherCore.dylib'
        bound=json.loads((products/'core-build.json').read_text());assert all(sha(ROOT/name)==digest for name,digest in bound['sourceHashes'].items());assert sha(archive)==bound['librarySHA256']and sha(products/'LauncherCore.swiftmodule')==bound['moduleSHA256']
    else:products,modules,archive=prepare_core()
    archive_hash=sha(archive)
    module=modules/'LauncherCore.swiftmodule';importable=list(module.glob('*.swiftmodule'))if module.is_dir()else[module]
    module_hashes={str(path.relative_to(modules)):sha(path)for path in importable}
    command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(cache),'-I',str(modules),*map(str,[ROOT/name for name in SOURCES]),str(archive),'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',str(run/'ReadyCanvasSectionsProbe')]
    result=subprocess.run(command,cwd=ROOT,capture_output=True,text=True);(run/'compile.log').write_text(result.stdout+result.stderr)
    if result.returncode:raise RuntimeError('Canvas section probe compile failed: '+result.stderr[-5000:])
    if source_hashes!={name:sha(ROOT/name)for name in SOURCES}or archive_hash!=sha(archive)or module_hashes!={str(path.relative_to(modules)):sha(path)for path in importable}:raise RuntimeError('Source/Core product changed during standalone compilation')
    result=subprocess.run([str(run/'ReadyCanvasSectionsProbe'),str(run/'previews')],cwd=ROOT,capture_output=True,text=True,timeout=90)
    (run/'probe.log').write_text(result.stdout+'\n'+result.stderr)
    if result.returncode:raise RuntimeError('Canvas section probe failed: '+result.stderr[-5000:])
    report=json.loads(result.stdout)
    if report.get('passed')is not True or not all(report['checks'].values()):raise RuntimeError('Canvas section checks did not pass')
    report.update(sourceHashes=source_hashes,command=command,coreArchive=str(archive),coreArchiveSHA256=archive_hash,coreModuleSHA256=module_hashes,scriptSHA256=sha(Path(__file__)),binarySHA256=sha(run/'ReadyCanvasSectionsProbe'))
    path=run/'report.json';path.write_text(json.dumps(report,indent=2)+'\n');path.chmod(0o600)
    print(json.dumps({'passed':True,'count':report['count'],'report':str(path),'reportSHA256':sha(path),'canvasSHA256':source_hashes[SOURCES[0]]}))
if __name__=='__main__':main()
