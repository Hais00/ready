#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual SessionManager/Wine sessions with fresh isolated prefixes and real store locks.

Compiles our Windows WinAPI heartbeat helper locally; no game, account, downloaded
fixture, external template, or user data is used. Runtime configuration is read by
SessionManager from this project's existing Runtime/runtime.json and never modified.
"""
import fcntl,hashlib,json,os,pathlib,shutil,subprocess,time,uuid,sys
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
HEARTBEAT_SOURCE=r'''
/* SPDX-License-Identifier: GPL-3.0-only */
typedef unsigned long DWORD;typedef void *HANDLE;
#define API __declspec(dllimport)
#define CALL __stdcall
API DWORD CALL GetEnvironmentVariableA(const char*,char*,DWORD);
API HANDLE CALL CreateFileA(const char*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
API int CALL WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
API int CALL FlushFileBuffers(HANDLE);
API DWORD CALL SetFilePointer(HANDLE,long,long*,DWORD);
API DWORD CALL GetCurrentProcessId(void);
API int CALL CloseHandle(HANDLE);
API void CALL Sleep(DWORD);
API void CALL ExitProcess(DWORD);
void mainCRTStartup(void){
 static char path[2048];DWORD length=GetEnvironmentVariableA("SESSION_PROBE_HEARTBEAT",path,2048);
 if(!length||length>=2048)ExitProcess(2);
 HANDLE file=CreateFileA(path,0x40000000,3,0,2,0x80,0);
 if(file==(HANDLE)-1)ExitProcess(3);
 DWORD data[2]={0,GetCurrentProcessId()};
 /* Self-limited test lifetime, even if the controlling launcher disappears. */
 for(unsigned i=0;i<1200;i++){
  DWORD count=0;data[0]++;SetFilePointer(file,0,0,0);
  if(!WriteFile(file,data,8,&count,0)||count!=8)ExitProcess(4);
  FlushFileBuffers(file);Sleep(100);
 }
 CloseHandle(file);ExitProcess(0);
}
'''
def run(arguments,**kwargs):
    return subprocess.run(list(map(str,arguments)),cwd=ROOT,check=True,**kwargs)
def build():
    out=ROOT/'Build/WineSessionProbe';out.mkdir(parents=True,exist_ok=True)
    source=out/'heartbeat.c';source.write_text(HEARTBEAT_SOURCE)
    exports=['GetEnvironmentVariableA','CreateFileA','WriteFile','FlushFileBuffers','SetFilePointer','GetCurrentProcessId','CloseHandle','Sleep','ExitProcess']
    definition=out/'kernel32.def';definition.write_text('LIBRARY KERNEL32.dll\nEXPORTS\n'+'\n'.join(exports)+'\n')
    run(['/opt/homebrew/opt/llvm/bin/llvm-dlltool','-m','i386:x86-64','-d',definition,'-l',out/'kernel32.lib'])
    run(['/opt/homebrew/opt/llvm/bin/clang','--target=x86_64-windows','--no-default-config','-ffreestanding','-fno-builtin','-fno-stack-protector','-O2','-c',source,'-o',out/'heartbeat.obj'])
    executable=out/'heartbeat.exe'
    run(['/opt/homebrew/opt/lld/bin/lld-link','/entry:mainCRTStartup','/subsystem:console','/machine:x64','/nodefaultlib',out/'heartbeat.obj',out/'kernel32.lib','/out:'+str(executable)])
    products,modules,archive=prepare_core()
    run(['sh',ROOT/'Scripts/build_session_host.sh'])
    command=['swiftc','-swift-version','5','-parse-as-library','-I',modules,ROOT/'Sources/M1Launcher/SessionManager.swift',ROOT/'Synthetic/ReadyWineSessionProbe.swift']
    command += [archive]
    command+=['-framework','AppKit','-o',ROOT/'Build/ReadyWineSessionProbe']
    run(command)
    return executable

def cleanup(scratch):
    manifest=scratch/'cleanup.json'
    if manifest.exists():
        data=json.loads(manifest.read_text());server=pathlib.Path(data['server'])
        assert server.is_absolute() and server.is_file()
        for item in data['prefixes']:
            prefix=pathlib.Path(item);assert prefix.is_relative_to(scratch)
            env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','M1L_','READY_'))}
            env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all')
            subprocess.run([str(server),'-k'],env=env,capture_output=True,timeout=10)
            subprocess.run([str(server),'-w'],env=env,capture_output=True,timeout=15,check=True)
    # Do not delete a prefix whose keeper is still using its lock, even on a failed test.
    deadline=time.monotonic()+5
    while True:
        busy=False
        for file in scratch.rglob('*.lock'):
            with file.open('a+b') as handle:
                try:fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:busy=True
        if not busy:break
        if time.monotonic()>deadline:raise RuntimeError('Preserving scratch: native keeper still holds a session lock')
        time.sleep(.1)
    shutil.rmtree(scratch)

def main():
    executable=build()
    scratch=ROOT/'Runtime/TestPrefixes'/('sessions-'+str(uuid.uuid4()));scratch.mkdir(parents=True,mode=0o700)
    result=None;process=None;writer=None
    sys.path.insert(0,str(ROOT/'StoreBridge'))
    import install_lock
    from bridge import BridgeError
    install_lock.LOCK_ROOT=scratch/'data/InstallLocks'
    try:
        env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','M1L_','READY_'))}
        process=subprocess.Popen([str(ROOT/'Build/ReadyWineSessionProbe'),str(scratch),str(ROOT),str(executable)],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        deadline=time.monotonic()+150;handled=0
        while process.poll() is None:
            if time.monotonic()>deadline:raise TimeoutError('Real Wine session integration exceeded 150 seconds')
            request=scratch/'writer-request.json'
            if request.exists():
                data=json.loads(request.read_text());sequence=data['sequence']
                if sequence>handled:
                    target=install_lock.canonical_installation(data['installation'])
                    assert target==executable.parent.resolve()
                    if data['phase']=='read-check':
                        busy=False
                        try:
                            with install_lock.installation_lease(target):pass
                        except BridgeError as error:
                            assert error.code=='installation_busy';busy=True
                        response={'busy':busy}
                    elif data['phase']=='hold-writer':
                        writer=install_lock.installation_lease(target);writer.__enter__();response={'held':True}
                    elif data['phase']=='release-writer':
                        assert writer is not None;writer.__exit__(None,None,None);writer=None;response={'released':True}
                    else:raise AssertionError('Unknown fixture coordination phase')
                    output=scratch/('writer-response-'+str(sequence)+'.json');temporary=output.with_suffix('.tmp');temporary.write_text(json.dumps(response));temporary.chmod(0o600);temporary.replace(output);handled=sequence
            time.sleep(.02)
        stdout,stderr=process.communicate(timeout=5)
        result=subprocess.CompletedProcess(process.args,process.returncode,stdout,stderr)
        (ROOT/'Evidence/session-host-wine-real.log').write_text(result.stdout+'\n'+result.stderr)
        assert result.returncode==0,result.stderr+'\n'+result.stdout
        report=json.loads(result.stdout);assert report['passed']
        report['helperSHA256']=hashlib.sha256(executable.read_bytes()).hexdigest()
        report['helperSource']='Scripts/test_wine_sessions.py::HEARTBEAT_SOURCE'
        (ROOT/'Evidence/session-host-wine-real.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,indent=2))
    finally:
        if writer is not None:writer.__exit__(None,None,None)
        if process is not None and process.poll() is None:process.kill();process.wait(timeout=5)
        try:cleanup(scratch)
        except Exception:
            print('Scratch preserved for its exact session:',scratch)
            raise
if __name__=='__main__':main()
