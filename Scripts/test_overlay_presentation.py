#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Observe an owned fullscreen Metal probe, with explicit focus/geometry diagnostics.

The Metal HUD must be observed separately. This script never infers direct display
from fullscreen, timing, or overlay counters. Its private control protocol changes
only the probe it starts, and termination targets only that child.
"""
import json,os,pathlib,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
def atomic(path,value):
    temp=path.with_suffix('.tmp');temp.write_text(json.dumps(value));temp.chmod(0o600);temp.replace(path)
def read(path):
    try:return json.loads(path.read_text())
    except (FileNotFoundError,json.JSONDecodeError):return {}
def main():
    work=pathlib.Path(tempfile.mkdtemp(prefix='ready-presentation-',dir=ROOT/'Build'));control=work/'control.json';status=work/'status.json';process=None;records=[]
    try:
        atomic(control,{'sequence':1,'visible':True,'selection':0})
        env={**os.environ,'DYLD_INSERT_LIBRARIES':str(ROOT/'Build/libReadyOverlay.dylib'),'M1L_CONTROL_FILE':str(control),'M1L_OVERLAY_STATUS':str(status),'MTL_HUD_ENABLED':'1'}
        with (ROOT/'Evidence/overlay-presentation-focus.log').open('w') as log:
            process=subprocess.Popen([str(ROOT/'Build/ReadyMetalProbe.app/Contents/MacOS/ReadyMetalProbe'),'--metal4','--fullscreen','--session-probe','--presentation-probe','--frames','7200','--output',str(work)],env=env,stdout=log,stderr=subprocess.STDOUT)
            (ROOT/'Evidence/overlay-direct-session-context.json').write_text(json.dumps({'pid':process.pid,'control':str(control),'status':str(status),'directory':str(work)}))
            began=time.monotonic();hidden=False;last_frame=-1
            while process.poll() is None and time.monotonic()-began<55:
                elapsed=time.monotonic()-began
                if elapsed>28 and not hidden:atomic(control,{'sequence':2,'visible':False,'selection':0});hidden=True
                geometry=read(work/'overlay-probe-window.json');state=read(status)
                if geometry and geometry.get('frame')!=last_frame:
                    records.append({'elapsedSeconds':elapsed,'geometry':geometry,'status':state});last_frame=geometry.get('frame')
                time.sleep(.2)
        result={'directToDisplayVerified':False,'note':'Focus/geometry diagnostics only. The actual Metal HUD must establish composition mode; activity and fullscreen do not prove it.','pid':process.pid,'samples':records}
        (ROOT/'Evidence/overlay-presentation-focus.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({'pid':process.pid,'samples':len(records),'last':records[-1] if records else None},indent=2))
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
        shutil.rmtree(work)
if __name__=='__main__':main()
