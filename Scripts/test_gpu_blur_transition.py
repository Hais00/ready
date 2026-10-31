#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exact injected renderer, procedural pixels, real offscreen MPS/Metal work."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='gpu-blur-transition-',dir=WORK/'tests'));run.chmod(0o700)
 shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';fixture=ROOT/'Synthetic/ReadyGPUBlurTransitionProbe.m';header=ROOT/'Sources/ReadyHostedView/include/RHGOverlayTransition.h';files=[shim,fixture,header,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 text=shim.read_text();start=text.index('@interface RHGOverlayBlurAcknowledgement:');end=text.index('static BOOL rhgOverlayBlurEpochIsCurrent',start)
 source=run/'probe.m';source.write_text('#import <Cocoa/Cocoa.h>\n#import <Metal/Metal.h>\n#import <MetalPerformanceShaders/MetalPerformanceShaders.h>\n#import <QuartzCore/QuartzCore.h>\n#import <stdatomic.h>\n#import "RHGOverlayTransition.h"\n'+text[start:end]+fixture.read_text())
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','MTL_','READY_','Steam','STEAM'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/gpu-blur-transition'))
 command=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(header.parent),str(source),'-framework','Cocoa','-framework','Metal','-framework','MetalPerformanceShaders','-framework','QuartzCore','-o',str(run/'probe')]
 p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=90);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+'\n'+p.stderr[-2500:])
 p=subprocess.run([str(run/'probe')],env=env,capture_output=True,text=True,timeout=30);(run/'output.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+'\n'+p.stderr[-2500:])
 report=json.loads(p.stdout);assert report['passed']and before=={str(p.relative_to(ROOT)):sha(p)for p in files};report['sourceSHA256']=before
 out=run/'report.json';out.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'passed':True,'checks':report['checks'],'report':str(out),'reportSHA256':sha(out),'blendSamples':report['blendSamples']}))
if __name__=='__main__':main()
