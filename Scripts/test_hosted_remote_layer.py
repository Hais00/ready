#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Research-only private CAContext/CALayerHost, real two-process Metal presentation.
Own brief window and guest with zero NSWindows. No capture/readback/input/game.
Run only in a quiet unlocked graphical session, outside benchmarks.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-remote-layer-',dir=WORK/'tests'));run.chmod(0o700)
 source=ROOT/'Synthetic/ReadyHostedRemoteLayerProbe.m';paths=[source,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','READY_','MTL_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-remote-layer'))
 cmd=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1',str(source),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-o',str(run/'probe')]
 p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+' compile '+p.stderr[-2500:])
 cases={}
 for case,mode in [('native-manual','host'),('displaylink-opaque-cover','host-link-opaque'),('displaylink-almost-opaque-cover','host-link-almost'),('displaylink-positive-almost-cover','host-link-positive-almost'),('displaylink-positive-translucent-cover','host-link-positive-translucent')]:
  case_root=run/case;case_root.mkdir(mode=0o700)
  p=subprocess.run([str(run/'probe'),mode,str(case_root),str(run/'probe')],env=env,capture_output=True,text=True,timeout=18);(case_root/'stdout.json').write_text(p.stdout);(case_root/'stderr.log').write_text(p.stderr)
  if p.returncode:raise RuntimeError(str(run)+' '+case+' probe '+p.stdout[-4000:]+p.stderr[-1000:])
  result=json.loads(p.stdout);assert result['passed'];cases[case]=result
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 result={'passed':True,'cases':cases}
 report={**result,'sourceHashes':before,'limitations':['Private system API: availability, support, policy and future OS compatibility are unverified.','No application-level image copy or per-frame IPC; internal compositor work and direct scanout are not measured.','Own synthetic Metal producer, not a game or performance benchmark.'],'primarySources':['https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Platform/cocoa/LayerHostingContext.mm','https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/VideoPresentationManagerProxy.mm','https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/cocoa/QuartzCoreSPI.h']};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-remote-layer-tests.json').write_text(json.dumps(out,indent=2)+'\n');compact={**out,'cases':{case:{**data,'guest':{k:v for k,v in data['guest'].items()if k not in ('presentedTimes','surfaceIDs')}}for case,data in cases.items()}};print(json.dumps(compact,indent=2))
if __name__=='__main__':main()
