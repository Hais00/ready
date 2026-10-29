#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real Wine Windows save-folder isolation and recreation, using only UUID fixtures."""
import fcntl,json,os,pathlib,shutil,subprocess,time,uuid
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]

def run(args,**kwargs):
    return subprocess.run(list(map(str,args)),cwd=ROOT,check=True,**kwargs)

def main():
    products,modules,archive=prepare_core()
    run(['sh',ROOT/'Scripts/build_session_host.sh'],capture_output=True)
    build=ROOT/'Build/CustomSaveProbe';build.mkdir(parents=True,exist_ok=True)
    definition=build/'kernel32.def'
    exports=['GetStdHandle','WriteFile','CloseHandle','CreateFileA','GetFileAttributesA','GetCommandLineA','ExitProcess']
    definition.write_text('LIBRARY KERNEL32.dll\nEXPORTS\n'+'\n'.join(exports)+'\n')
    run(['/opt/homebrew/opt/llvm/bin/llvm-dlltool','-m','i386:x86-64','-d',definition,'-l',build/'kernel32.lib'],capture_output=True)
    run(['/opt/homebrew/opt/llvm/bin/clang','--target=x86_64-windows','--no-default-config','-ffreestanding','-fno-builtin','-fno-stack-protector','-O2','-c',ROOT/'Scripts/custom_save_windows_probe.c','-o',build/'probe.obj'],capture_output=True)
    helper=build/'custom-save.exe'
    run(['/opt/homebrew/opt/lld/bin/lld-link','/entry:mainCRTStartup','/subsystem:console','/machine:x64','/nodefaultlib',build/'probe.obj',build/'kernel32.lib','/out:'+str(helper)],capture_output=True)
    executable=build/'ReadyCustomSaveProbe'
    run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',modules,ROOT/'Sources/M1Launcher/SessionScratchDirectory.swift',ROOT/'Sources/M1Launcher/SessionManager.swift',ROOT/'Synthetic/ReadyCustomSaveProbe.swift',archive,'-framework','AppKit','-o',executable],capture_output=True)
    scratch=ROOT/'Runtime/TestPrefixes'/('custom-saves-'+uuid.uuid4().hex)
    scratch.mkdir(parents=True,mode=0o700)
    (scratch/'.ready-custom-save-fixture').write_text('Synthetic saves only\n')
    passed=False
    try:
        env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))}
        result=subprocess.run([str(executable),str(ROOT),str(scratch),str(helper)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=300)
        (ROOT/'Evidence/custom-saves.log').write_text(result.stdout+'\n'+result.stderr)
        assert result.returncode==0,'Save integration failed; private log retained'
        report=json.loads(result.stdout);assert report['passed']
        (ROOT/'Evidence/custom-saves.json').write_text(json.dumps(report,indent=2)+'\n')
        passed=True;print(json.dumps(report,indent=2))
    finally:
        file=scratch/'cleanup.json'
        if file.exists():
            data=json.loads(file.read_text());server=pathlib.Path(data['server'])
            assert server.is_relative_to(ROOT/'Runtime') and server.is_file()
            for value in data['prefixes']:
                prefix=pathlib.Path(value);assert prefix.is_relative_to(scratch/'data/Prefixes')
                env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','READY_','M1L_'))}
                env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all')
                subprocess.run([str(server),'-k'],env=env,capture_output=True,timeout=10)
                subprocess.run([str(server),'-w'],env=env,capture_output=True,timeout=15,check=True)
        deadline=time.monotonic()+8
        while True:
            busy=False
            for lock in (scratch/'data/Locks').glob('*.lock'):
                with lock.open('a+b') as fd:
                    try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    except BlockingIOError:busy=True
            if not busy:break
            if time.monotonic()>deadline:raise RuntimeError('Retaining fixture while its keeper is still live')
            time.sleep(.1)
        if passed:
            assert scratch.parent==ROOT/'Runtime/TestPrefixes' and (scratch/'.ready-custom-save-fixture').is_file()
            shutil.rmtree(scratch)

if __name__=='__main__':main()
