#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise real frontend resource teardown and a deferred background failure.

Creates its own AppKit window and runs a two-second native helper. It does not
send mouse/keyboard/controller events, inspect other apps, or bypass screen lock.
"""
import fcntl,json,os,pathlib,shutil,subprocess,time,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]

def main():
    subprocess.run(['swift','build','--product','M1Launcher','--jobs','2'],cwd=ROOT,check=True,capture_output=True)
    subprocess.run(['sh',str(ROOT/'Scripts/build_session_host.sh')],cwd=ROOT,check=True,capture_output=True)
    products=pathlib.Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=ROOT,text=True).strip())
    scratch=ROOT/'Runtime/TestPrefixes'/('frontend-'+uuid.uuid4().hex)
    scratch.mkdir(parents=True,mode=0o700)
    (scratch/'.ready-frontend-probe').write_text('Synthetic frontend lifecycle data only\n')
    passed=False
    try:
        env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','M1L_','READY_'))}
        env['READY_PROJECT_ROOT']=str(ROOT)
        result=subprocess.run([str(products/'M1Launcher'),'--data-root',str(scratch),'--background-error-self-test'],cwd=ROOT,env=env,capture_output=True,text=True,timeout=25)
        (ROOT/'Evidence/frontend-lifecycle.log').write_text(result.stdout+'\n'+result.stderr)
        assert result.returncode==0,'Frontend lifecycle failed; inspect ignored local log'
        report=json.loads(result.stdout);assert report['passed']
        (ROOT/'Evidence/frontend-lifecycle.json').write_text(json.dumps(report,indent=2)+'\n')
        passed=True
        print(json.dumps(report,indent=2))
    finally:
        # The helper is finite. A surviving keeper prevents cleanup until its
        # child has exited, independently of the controlling frontend process.
        deadline=time.monotonic()+8
        while True:
            busy=False
            for file in (scratch/'Locks').glob('*.lock'):
                with file.open('a+b') as handle:
                    try:fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    except BlockingIOError:busy=True
            if not busy:break
            if time.monotonic()>deadline:raise RuntimeError('Retaining scratch while native keeper is live')
            time.sleep(.1)
        if passed:
            assert scratch.parent==ROOT/'Runtime/TestPrefixes' and (scratch/'.ready-frontend-probe').is_file()
            shutil.rmtree(scratch)

if __name__=='__main__':main()
