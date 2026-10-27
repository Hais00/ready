#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual Wine -> Vulkan/Metal -> injected overlay path; requires an owned Windows present probe.

The fixture executable must keep presenting long enough for show/hide commands. Its arguments
are passed literally after --. No store account, downloaded game, or global Wine prefix is used.
"""
import argparse,fcntl,json,os,pathlib,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
def atomic(path,value):
    temp=path.with_suffix('.tmp');temp.write_text(json.dumps(value));temp.chmod(0o600);temp.replace(path)
def status_until(path,predicate,process,timeout=15):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            state=json.loads(path.read_text())
            if predicate(state):return state
        except (FileNotFoundError,json.JSONDecodeError):pass
        if process.poll() is not None:raise AssertionError(f'Probe exited ({process.returncode}) before expected Metal state')
        time.sleep(.025)
    raise AssertionError('Timed out waiting for actual Wine game Metal frames')
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=pathlib.Path,required=True)
    parser.add_argument('--runtime',type=pathlib.Path,default=ROOT/'Runtime/runtime.json')
    parser.add_argument('arguments',nargs=argparse.REMAINDER)
    args=parser.parse_args();exe=args.exe.resolve();assert exe.is_file()
    runtime=json.loads(args.runtime.read_text());wine=pathlib.Path(runtime['wine']);server=pathlib.Path(runtime['wineServer']);host=ROOT/'Build/ReadySessionHost';overlay=ROOT/'Build/libReadyOverlay.dylib'
    for file in (wine,server,host,overlay):assert file.is_file(),str(file)
    records={};process=None
    work=pathlib.Path(tempfile.mkdtemp(prefix='ready-wine-overlay-',dir=ROOT/'Build'))
    try:
        prefix=work/'prefix';prefix.mkdir(parents=True,exist_ok=True)
        control=work/'control.json';state_file=work/'overlay-status.json';lock=work/'prefix.lock'
        with lock.open('a+b') as lease, (ROOT/'Evidence/overlay-wine-present.log').open('wb') as log:
            os.fchmod(lease.fileno(),0o600);fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            base_env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','M1L_','READY_'))}
            base_env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all')
            def run_host(command,env):
                return subprocess.Popen([str(host),'--wine-server',str(server),'--prefix',str(prefix),'--',*map(str,command)],stdin=lease,stdout=log,stderr=log,env=env)
            def stop():
                if process is not None and process.poll() is None:process.terminate()
                subprocess.run([str(server),'-k'],env=base_env,stdout=log,stderr=log,timeout=10)
                if process is not None:
                    try:process.wait(timeout=15)
                    except subprocess.TimeoutExpired:raise AssertionError('Dedicated test prefix did not shut down; its native keeper remains locked')
            try:
                if not (prefix/'system.reg').exists():
                    init_env={**base_env,'WINEDLLOVERRIDES':'mscoree,mshtml=d'}
                    process=run_host([wine,'wineboot','-u'],init_env)
                    try:code=process.wait(timeout=120)
                    except subprocess.TimeoutExpired:stop();raise
                    assert code==0,f'Wine initialization failed ({code})'
                atomic(control,{'sequence':1,'visible':False,'selection':0})
                env={**base_env,'READY_OVERLAY_LIBRARY':str(overlay),'M1L_CONTROL_FILE':str(control),'M1L_OVERLAY_STATUS':str(state_file)}
                if runtime.get('kosmicICD'):env.update(VK_DRIVER_FILES=runtime['kosmicICD'],VK_ICD_FILENAMES=runtime['kosmicICD'])
                literal_args=args.arguments[1:] if args.arguments[:1]==['--'] else args.arguments
                process=run_host([wine,exe,*literal_args],env)
                idle=status_until(state_file,lambda s:s.get('frameCount',0)>0 and s.get('injectionSupported') and not s.get('visible'),process)
                assert idle['trackedTextureBytes']==0
                atomic(control,{'sequence':2,'visible':True,'selection':0})
                shown=status_until(state_file,lambda s:s.get('controlSequence')==2 and s.get('visible') and s.get('overlayFrameCount',0)>0 and s.get('trackedTextureBytes',0)>0,process)
                atomic(control,{'sequence':3,'visible':False,'selection':0})
                hidden=status_until(state_file,lambda s:s.get('controlSequence')==3 and not s.get('visible') and s.get('trackedTextureBytes')==0,process)
                assert shown['pid']!=process.pid
                records={'passed':True,'runtimeID':runtime.get('runtimeID',runtime.get('wineVersion')),'devicePath':'Windows Vulkan -> Wine Vulkan -> KosmicKrisp -> Metal -> same-drawable overlay','idle':idle,'shown':shown,'hidden':hidden,'directToDisplayVerified':False,'note':'Actual Wine presentation and encoder counters; direct mode and arbitrary game compatibility are not inferred.'}
                stop();process=None
            finally:
                if process is not None:stop()
                # CLOSE only: never LOCK_UN an open description still owned by a keeper.
    finally:
        if process is None or process.poll() is not None:shutil.rmtree(work)
        else:print('Preserved active test session directory:',work)
    (ROOT/'Evidence/overlay-wine-present.json').write_text(json.dumps(records,indent=2)+'\n');print(json.dumps(records,indent=2))
if __name__=='__main__':main()
