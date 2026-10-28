#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Validate actual NoCopyProxy receipts; optional constructor-only fail control."""
import argparse,hashlib,json,os,subprocess
from pathlib import Path

def validate(report,require_baseline=False):
    checks={}
    assert report['renderPipelineSucceeded']and report['sameGuestBinary']
    host=report['host'];guest=report['guest']
    hd=next(x for x in host if x.get('type')=='host-done');gd=next(x for x in guest if x.get('type')=='guest-done');gw=next(x for x in guest if x.get('type')=='guest-window')
    assert hd['frames']==gd['frames']>0;checks['actualRenderAndPresentationCompleted']=True
    window=hd['window'];assert gw['reportedWindow']==window and gw['logicalClass']=='NCLogicalWindow'and gw['appWindowCount']==0;checks['logicalProxyUsesActualHostWindowNumber']=True
    assert not gw['windows']and not gd['windows']and all(not x['windows']for x in guest if x.get('type')=='guest-frame');checks['guestWindowServerCensusEmptyThroughout']=True
    census=report['independentCensus'];assert census['queryAvailable'];by_pid=census['windowsByPID'];host_windows=by_pid[str(report['ownHostPID'])];visible=[w for w in host_windows if w['onscreen']];assert by_pid[str(report['ownGuestPID'])]==[]and len(visible)==1 and visible[0]['id']==window and sum(w['id']==window for w in host_windows)==1;checks['independentCensusOneVisibleHostZeroGuest']=True
    assert all(hd[k]==0 for k in ('hostCommandBuffers','hostRenderEncoders','hostBlitEncoders','hostComputeEncoders','hostCopies','hostReadbacks'));checks['hostPresentsWithoutApplicationGPUCommandsOrCopies']=True
    proxy={x['frame']:x for x in guest if x.get('type')=='proxy-frame'}
    observed=0
    for x in host:
        if x.get('type')!='host-frame':continue
        p=proxy[x['frame']];assert x['drawableSurface']==x['guestSurface']==p['hostSurface']==p['importedSurface']and p['reportedWindow']==window;observed+=1
    assert observed>=1;checks['actualHostDrawableAndImportedSurfaceIDsMatch']=True
    assert gd['renderEncoders']==hd['frames']and gd['blitEncoders']==0 and gd['computeEncoders']==0;checks['guestOnlyOriginalSceneRenderEncoders']=True
    assert not any(x.get('type')=='shim-refused'for x in guest);checks['noFallbackPathTaken']=True
    if require_baseline:
        assert report['baselinePending']is False and report['baselineExit']==0
        bw=next(x for x in report['baseline']if x.get('type')=='guest-window')
        assert bw['windows']and bw['appWindowCount']>=1 and bw['logicalClass']!='NCLogicalWindow'
        assert report['baselineExecutableSHA256']==report['injectedExecutableSHA256']==report['guestExecutableSHA256'];checks['ordinaryWindowBaselineAndInjectedUseIdenticalSignedBinary']=True
    return checks

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('report',type=Path);p.add_argument('--require-baseline',action='store_true');p.add_argument('--constructor-negative',action='store_true');a=p.parse_args()
    raw=a.report.read_bytes();report=json.loads(raw);checks=validate(report,a.require_baseline)
    if a.constructor_negative:
        run=Path(report['runRoot']);guest=run/'ReadyNoCopyProxyGuest.app/Contents/MacOS/NoCopyProxyGuest';shim=run/'NoCopyProxyShim.dylib'
        assert hashlib.sha256(guest.read_bytes()).hexdigest()==report['guestExecutableSHA256']and hashlib.sha256(shim.read_bytes()).hexdigest()==report['shimSHA256']
        env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','M1L_'))};env['DYLD_INSERT_LIBRARIES']=str(shim)
        child=subprocess.run([str(guest),'1'],env=env,capture_output=True,text=True,timeout=5)
        events=[]
        for line in child.stderr.splitlines():
            try:events.append(json.loads(line))
            except ValueError:pass
        assert child.returncode==77 and any(x.get('type')=='shim-refused'and x.get('reason')=='explicit-service-required'and x.get('guestHiddenWindowFallback')is False and x.get('copyFallback')is False for x in events)
        checks['missingConfigurationStopsBeforeApplicationMain']=True
    receipt={'schema':1,'passed':all(checks.values()),'checks':checks,'count':len(checks),'sourceReportSHA256':hashlib.sha256(raw).hexdigest(),'visualProofImplied':False,'strictSingleHostWindowServerResource':len(report['independentCensus']['windowsByPID'][str(report['ownHostPID'])])==1,'auxiliaryHostResources':[w for w in report['independentCensus']['windowsByPID'][str(report['ownHostPID'])]if w['id']!=next(x for x in report['host']if x.get('type')=='host-done')['window']]}
    out=a.report.parent/'validation.json';out.write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'passed':True,'count':len(checks),'validation':str(out),'sha256':hashlib.sha256(out.read_bytes()).hexdigest()}))
if __name__=='__main__':main()
