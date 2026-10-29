#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real CoreGraphics/Metal byte roundtrip and own-window canvas event probes.

No global input events are injected. Actual app CUA verification is a separate
record; this does not claim a screenshot proves event delivery.
"""
import argparse,hashlib,json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--modules',type=Path,required=True);parser.add_argument('--archive',type=Path,required=True);parser.add_argument('--compile-only',action='store_true');args=parser.parse_args()
    work=Path('/Volumes/Dati APFS/Codex-ready-01a17e79');assert (work/'.ready-external-workspace').is_file();output=work/'build/canvas-feedback';output.mkdir(parents=True,exist_ok=True)
    cache=work/'cache/canvas-feedback-swift';cache.mkdir(exist_ok=True);env={**os.environ,'TMPDIR':str(work/'tmp')+'/','CLANG_MODULE_CACHE_PATH':str(cache)}
    commands=[];sources=[ROOT/'Sources/M1Launcher/CanvasDrawing.swift']
    for name,probe,extra in [('rendering','ReadyCanvasRenderingProbe.swift',[]),('interaction','ReadyCanvasInteractionProbe.swift',[ROOT/'Sources/M1Launcher/MetalCanvas.swift',ROOT/'Sources/M1Launcher/ArtworkCache.swift',ROOT/'Sources/M1Launcher/LibraryEntryPresentation.swift',ROOT/'Sources/M1Launcher/ArtworkIndexStore.swift',ROOT/'Sources/M1Launcher/CanvasShellRenderer.swift',ROOT/'Sources/M1Launcher/LibraryGridSurface.swift',ROOT/'Sources/M1Launcher/GameArtwork.swift',ROOT/'Sources/M1Launcher/ControllerNavigation.swift',args.archive])]:
        source=ROOT/'Synthetic'/probe;sources.append(source);command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(cache),'-I',str(args.modules),str(ROOT/'Sources/M1Launcher/CanvasDrawing.swift'),str(source),*map(str,extra),'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',str(output/name)]
        subprocess.run(command,cwd=ROOT,env=env,check=True);commands.append(command)
    if args.compile_only:return
    results={}
    for name in ['rendering','interaction']:
        run=subprocess.run([str(output/name)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=60);(output/(name+'.log')).write_text(run.stdout+'\n'+run.stderr);assert run.returncode==0,run.stderr;value=json.loads(run.stdout);assert value['passed'];results[name]=value
    results.update(sourceHashes={str(p.relative_to(ROOT)):sha(p) for p in sources+[ROOT/'Sources/M1Launcher/MetalCanvas.swift',ROOT/'Sources/M1Launcher/ArtworkCache.swift',ROOT/'Sources/M1Launcher/LibraryEntryPresentation.swift',ROOT/'Sources/M1Launcher/ArtworkIndexStore.swift',ROOT/'Sources/M1Launcher/CanvasShellRenderer.swift',ROOT/'Sources/M1Launcher/LibraryGridSurface.swift',ROOT/'Sources/M1Launcher/GameArtwork.swift',ROOT/'Sources/M1Launcher/ControllerNavigation.swift']},commands=commands,CUAInteractionVerified=False)
    (ROOT/'Evidence/canvas-feedback.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
if __name__=='__main__':main()
