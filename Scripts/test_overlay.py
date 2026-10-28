#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Inject the real dylib into a Metal 3 and Metal 4 test host and inspect readbacks."""
import json, os, pathlib, subprocess, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
def write_control(path,**values):
    temp=path.with_suffix('.tmp');temp.write_text(json.dumps(values));temp.chmod(0o600);temp.replace(path)
def wait_status(path,predicate,timeout=8):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            state=json.loads(path.read_text())
            if predicate(state):return state
        except (FileNotFoundError,json.JSONDecodeError):pass
        time.sleep(.04)
    raise AssertionError(f'Overlay status did not reach expected state: {path}')
def isolation():
    with tempfile.TemporaryDirectory(prefix='ready-overlay-isolation-') as tmp:
        sessions=[]
        try:
            for label in ('a','b'):
                d=pathlib.Path(tmp)/label;d.mkdir(mode=0o700);c=d/'control.json';write_control(c,sequence=1,visible=False,selection=0)
                env={**os.environ,'DYLD_INSERT_LIBRARIES':str(ROOT/'Build/libReadyOverlay.dylib'),'M1L_CONTROL_FILE':str(c),'M1L_OVERLAY_STATUS':str(d/'status.json')}
                process=subprocess.Popen([str(ROOT/'Build/ReadyMetalProbe'),'--session-probe','--frames','3600','--output',str(d)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
                sessions.append((d,c,process))
            a,b=sessions
            for d,c,p in sessions:wait_status(d/'status.json',lambda s:s['injectionSupported'])
            write_control(a[1],sequence=2,visible=True,selection=1)
            a_shown=wait_status(a[0]/'status.json',lambda s:s['visible'] and s['overlayFrameCount']>0)
            b_untouched=json.loads((b[0]/'status.json').read_text());assert not b_untouched['visible']
            write_control(a[1],sequence=3,visible=True,selection=1,action='quit')
            a_quit=wait_status(a[0]/'status.json',lambda s:s['requestedAction']=='quit')
            assert a[2].poll() is None and b[2].poll() is None
            write_control(b[1],sequence=2,visible=True,selection=0)
            b_shown=wait_status(b[0]/'status.json',lambda s:s['visible'] and s['overlayFrameCount']>0)
            write_control(a[1],sequence=4,visible=False,selection=0,action='resume')
            a_hidden=wait_status(a[0]/'status.json',lambda s:not s['visible'] and s['requestedAction']=='resume' and s['trackedTextureBytes']==0)
            b_still_shown=json.loads((b[0]/'status.json').read_text());assert b_still_shown['visible'] and b_still_shown['requestedAction']==''
            write_control(b[1],sequence=3,visible=False,selection=0,action='resume')
            b_hidden=wait_status(b[0]/'status.json',lambda s:not s['visible'] and s['trackedTextureBytes']==0)
            result={'passed':True,'separatePIDs':a_shown['pid']!=b_shown['pid'],'quitIsRequestOnly':True,'aShown':a_shown,'bUntouched':b_untouched,'aQuit':a_quit,'bShown':b_shown,'aResumed':a_hidden,'bStillShown':b_still_shown,'bResumed':b_hidden}
            (ROOT/'Evidence/overlay-isolation.json').write_text(json.dumps(result,indent=2)+'\n')
            return {'sessionIsolation':True,'separatePIDs':result['separatePIDs'],'quitIsRequestOnly':True}
        finally:
            for d,c,p in sessions:
                if p.poll() is None:p.terminate()
                try:p.wait(timeout=5)
                except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)
def main():
    subprocess.run(["sh",str(ROOT/"Scripts/build_overlay.sh")],check=True)
    results=[]
    with tempfile.TemporaryDirectory(prefix="ready-overlay-") as temp:
        base=pathlib.Path(temp);control=base/"control.json"
        control.write_text(json.dumps(dict(visible=False,selection=0,sequence=1)));control.chmod(0o600)
        env={**os.environ,"DYLD_INSERT_LIBRARIES":str(ROOT/"Build/libReadyOverlay.dylib"),"M1L_CONTROL_FILE":str(control),"M1L_OVERLAY_STATUS":str(base/"status.json")}
        for architecture,version,scheduled in ((a,v,s) for a in ('arm64','x86_64') for v,s in ((3,False),(3,True),(4,False))):
            label=f"metal{version}"+("-scheduled" if scheduled else "")+('-x86_64' if architecture=='x86_64' else '')
            # /usr/bin/arch is an Apple system executable and does not inherit DYLD_*.
            # Its documented -e option passes the variable to OUR ad-hoc-signed test host.
            args=['/usr/bin/arch','-'+architecture,'-e','DYLD_INSERT_LIBRARIES='+str(ROOT/'Build/libReadyOverlay.dylib'),str(ROOT/"Build/ReadyMetalProbe"),"--output",str(ROOT/"Evidence"),"--frames","24"]
            if version==4:args.append("--metal4")
            if scheduled:args.append("--scheduled-present")
            run=subprocess.run(args,env=env,capture_output=True,text=True,timeout=90)
            (ROOT/f"Evidence/overlay-{label}.log").write_text(run.stdout+"\n"+run.stderr)
            assert run.returncode==0, f"Metal {version} failed ({run.returncode}): {run.stderr}\n{run.stdout}"
            data=json.loads((ROOT/f"Evidence/overlay-{label}.json").read_text())
            assert data["passed"] and not data["directToDisplayVerified"]
            before,shown,hidden=data["phases"]
            assert before["after"]["gpuOverlaySubmissions"]==0
            assert shown["after"]["trackedTextureBytes"]>0
            assert hidden["after"]["trackedTextureBytes"]==0
            assert hidden["after"]["gpuOverlaySubmissions"]==shown["after"]["gpuOverlaySubmissions"]
            expected_path='metal4OverlaySubmissions' if version==4 else 'metal3OverlaySubmissions'
            other_path='metal3OverlaySubmissions' if version==4 else 'metal4OverlaySubmissions'
            assert shown["after"][expected_path]>0 and hidden["after"][other_path]==0
            assert shown["after"]["completedGPUOverlaySubmissions"]>0
            assert hidden["after"]["completedGPUOverlaySubmissions"]==hidden["after"]["gpuOverlaySubmissions"]
            assert all(phase["after"]["failedGPUOverlaySubmissions"]==0 for phase in data["phases"])
            results.append({"architecture":architecture,"metal":version,"scheduledHandler":scheduled,"passed":True,"changedPixels":data["changedPixelsShown"],"hiddenTextureBytes":0,"completedGPUOverlaySubmissions":hidden["after"]["completedGPUOverlaySubmissions"],"failedGPUOverlaySubmissions":0,"actualOverlayPath":expected_path})
    results.append(isolation())
    (ROOT/"Evidence/overlay-summary.json").write_text(json.dumps(results,indent=2)+"\n")
    print(json.dumps(results,indent=2))
if __name__=="__main__":main()
