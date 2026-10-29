#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own offscreen actual Root-host-C transport test; no CUA/game/Steam/account."""
import argparse,hashlib,json,os
from pathlib import Path
import shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
GUEST=WORK/'tests/native-no-copy-proxy-beqwzggl/ReadyNoCopyProxyGuest.app/Contents/MacOS/NoCopyProxyGuest'
GUEST_SHA='a614b2e149c9929ee87a7ff933e5333bc110a67b5259aaad73789de96e6c5ce3'

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def rows(path):
    out=[]
    for line in path.read_text().splitlines():
        try:out.append(json.loads(line))
        except ValueError:pass
    return out

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--shim',type=Path,default=ROOT/'Build/libReadyHostedGame.dylib');parser.add_argument('--expected-shim-sha256',required=True);parser.add_argument('--frames',type=int,default=120);parser.add_argument('--hud-on-second',action='store_true');parser.add_argument('--compile-only',action='store_true');a=parser.parse_args()
    assert 1<=a.frames<=600 and WORK.stat().st_uid==os.getuid()and(WORK/'.ready-external-workspace').is_file()
    assert GUEST.resolve(strict=True)==GUEST and sha(GUEST)==GUEST_SHA
    shim=a.shim.resolve(strict=True);assert shim==a.shim and sha(shim)==a.expected_shim_sha256
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(shim)],check=True,capture_output=True)
    run=Path(tempfile.mkdtemp(prefix='ready-hosted-transport-',dir=WORK/'tests'));run.chmod(0o700)
    source_paths=[ROOT/'Sources/ReadyHostedView/ReadyHostedView.m',*sorted((ROOT/'Sources/ReadyHostedView/include').glob('*.h')),ROOT/'NativeEmbedding/ReadyHostedTransportHostHarness.m',Path(__file__)]
    before={str(p.relative_to(ROOT)):sha(p)for p in source_paths}
    snapshots=run/'sources';snapshots.mkdir(mode=0o700)
    for p in source_paths:(snapshots/p.name).write_bytes(p.read_bytes())
    cache=WORK/'cache/ready-hosted-transport-clang';cache.mkdir(mode=0o700,exist_ok=True)
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','MTL_HUD_','M1L_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(cache),PYTHONDONTWRITEBYTECODE='1')
    executable=run/'ReadyHostedTransportHarness';command=['/usr/bin/clang','-arch','arm64','-fobjc-arc','-fblocks','-std=gnu11','-O2','-mmacosx-version-min=14.0','-Wno-deprecated-declarations','-I',str(ROOT/'Sources/ReadyHostedView/include'),'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','Security','-lbsm',str(source_paths[0]),str(ROOT/'NativeEmbedding/ReadyHostedTransportHostHarness.m'),'-o',str(executable)]
    built=subprocess.run(command,env=env,capture_output=True,text=True);(run/'build.log').write_text(built.stdout+built.stderr)
    if built.returncode:raise RuntimeError('Own harness compile failed; '+str(run/'build.log'))
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(executable)],check=True,capture_output=True)
    assert before=={str(p.relative_to(ROOT)):sha(p)for p in source_paths}
    report={'schema':1,'fixtureOnly':True,'runRoot':str(run),'sourceHashes':before,'guestSHA256':GUEST_SHA,'shimSHA256':sha(shim),'harnessSHA256':sha(executable),'command':command,'gameOrAccountExecuted':False,'HUDVisualVerified':False,'tests':[]}
    if not a.compile_only:
        for hud in ([False,True]if a.hud_on_second else[False]):
            case=run/('hud-on'if hud else'hud-off');case.mkdir(mode=0o700)
            child=subprocess.run([str(executable),str(GUEST),str(shim),str(case),str(int(hud)),str(a.frames)],env=env,capture_output=True,text=True,timeout=55)
            (case/'stdout.log').write_text(child.stdout);(case/'stderr.log').write_text(child.stderr)
            if not(case/'harness-report.json').exists():raise RuntimeError('Owned harness ended before report; '+str(case))
            result=json.loads((case/'harness-report.json').read_text());diagnostic=rows(case/'host-diagnostic.jsonl');guest=rows(case/'guest-stdout.jsonl');errors=rows(case/'guest-stderr.jsonl');checks={}
            checks['guestExitedZeroUnder40Seconds']=result['guestExit']==0 and result['elapsedSeconds']<40 and child.returncode==0
            checks['neverActivatedOrKey']=not result['focusViolation']and all(not c['hostIsActive']for c in result['censuses'])
            checks['guestWindowServerCensusEmpty']=bool(result['censuses'])and all(c['queryAvailable']and not c['guestWindows']for c in result['censuses'])
            checks['allFramesAcquiredAndPresented']=len(result['acquisitions'])==len(result['presentations'])==a.frames
            checks['rootCNoHostCommandQueuesBuffersEncodersOrCopies']=bool(diagnostic)and all(all(d.get(k)==0 for k in ('hostCommandQueues','hostCommandBuffers','hostEncoders','applicationSurfaceCopies','pixelReadbacks'))for d in diagnostic)
            checks['firstPresentUsesTransactionThenNormalFramesDoNot']=bool(result['presentations'])and result['presentations'][0].get('presentsWithTransaction')is True and all(p.get('presentsWithTransaction')is False for p in result['presentations'][1:])and all(d.get('presentsWithTransaction')is False for d in diagnostic)
            callbacks=result.get('firstFrameCallbacks',[]);first_callback=callbacks[0]if callbacks else{}
            checks['plainLoadingOverlayStartsAboveAndIsRemovedExactlyOnce']=result.get('loadingInitiallyAbove')is True and result.get('firstFrameCallbackCount')==len(callbacks)==1 and not result.get('loadingStillAttached')and callbacks[0].get('loadingHadSuperview')is True and callbacks[0].get('loadingLayerIsMetal')is False and callbacks[0].get('loadingRemoved')is True
            checks['firstCallbackFollowsActualFirstPresentCallAndSurface']=len(callbacks)==1 and callbacks[0].get('mainThread')is True and callbacks[0].get('acquisitionsAlreadyObserved')==callbacks[0].get('presentCallsAlreadyObserved')==1 and callbacks[0].get('frame')==0 and callbacks[0].get('surfaceID')==result['presentations'][0]['surfaceID'] and callbacks[0].get('layerPresentsWithTransaction')is True
            transitions=[d for d in diagnostic if d.get('phase')=='first-gpu-complete-transition']
            checks['rootFirstTransitionDiagnosticOnce']=len(transitions)==1 and transitions[0].get('acquires')==1 and transitions[0].get('surfaceID')==first_callback.get('surfaceID') and transitions[0].get('presentsWithTransaction')is False
            presentation_outcomes=[d.get('reason')for d in diagnostic if d.get('phase')=='first-presentation-result']
            checks['guestReportsRequestedFrames']=any(d.get('type')=='guest-done'and d.get('frames')==a.frames and d.get('windows')==[]for d in guest)
            checks['noShimRefusal']=not any(d.get('type')=='hosted-shim-refused'for d in errors)
            acquire={d['frame']:d for d in result['acquisitions']};present={d['frame']:d for d in result['presentations']}
            checks['hostAcquirePresentSurfaceIdentity']=bool(acquire)and set(acquire)==set(present)and all(acquire[n]['surfaceID']>0 and acquire[n]['surfaceID']==present[n]['surfaceID']and acquire[n]['window']==result['hostWindow']for n in acquire)
            samples=[d for d in guest if d.get('type')=='guest-frame'];checks['sampledGuestTextureEqualsActualHostDrawableSurface']=bool(samples)and all(d['frame']in acquire and d['surface']==acquire[d['frame']]['surfaceID']for d in samples)
            checks['guestWindowProxyTargetsExistingHost']=any(d.get('type')=='guest-window'and d.get('reportedWindow')==result['hostWindow']and d.get('windows')==[]for d in guest)
            checks['rootHostDiagnosticMatchesCompletion']=any(d.get('phase')=='stopped'and d.get('frames')==a.frames for d in diagnostic)
            report['tests'].append({'hudRequested':hud,'passed':all(checks.values()),'checks':checks,'elapsedSeconds':result['elapsedSeconds'],'CPUSeconds':result['CPUSeconds'],'guestExit':result['guestExit'],'acquires':len(acquire),'presents':len(present),'caseRoot':str(case),'hostDiagnosticSHA256':sha(case/'host-diagnostic.jsonl'),'firstFrameCallbackCount':result.get('firstFrameCallbackCount'),'firstPresentationDiagnosticOutcomes':presentation_outcomes,'onGlassVerified':False})
            if not all(checks.values()):break
    assert sha(GUEST)==GUEST_SHA and sha(shim)==a.expected_shim_sha256 and before=={str(p.relative_to(ROOT)):sha(p)for p in source_paths}
    report['passed']=a.compile_only or(bool(report['tests'])and all(t['passed']for t in report['tests']));report['compileOnly']=a.compile_only
    path=run/'report.json';path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'passed':report['passed'],'tests':report['tests'],'report':str(path),'reportSHA256':sha(path),'compileOnly':a.compile_only}),flush=True)
    if not report['passed']:raise SystemExit(1)
if __name__=='__main__':main()
