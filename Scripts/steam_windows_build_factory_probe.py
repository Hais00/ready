#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build independent Windows interoperability probes. This script never executes them."""
import hashlib,json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    work=Path('/Volumes/Dati APFS/Codex-ready-01a17e79');assert (work/'.ready-external-workspace').is_file();research=work/'retained/research-steam-windows';build_id=hashlib.sha256(b''.join(x.read_bytes() for x in [Path(__file__),ROOT/'Scripts/steam_windows_factory_probe.c',ROOT/'Scripts/steam_windows_sandbox_controls.c',ROOT/'Scripts/steam_windows_login_abi.h',ROOT/'Scripts/steam_windows_credential.h'])).hexdigest()[:20];output=research/('free-probe-build-'+build_id);output.mkdir(parents=True,exist_ok=True)
    cc='/opt/homebrew/opt/llvm/bin/clang';dt='/opt/homebrew/opt/llvm/bin/llvm-dlltool';link='/opt/homebrew/opt/lld/bin/lld-link';commands=[];artifacts={};env={**os.environ,'TMPDIR':str(work/'tmp')+'/'}
    imports={'CreateThread':24,'WaitForSingleObject':8,'CancelSynchronousIo':4,'GetCurrentProcess':0,'TerminateProcess':8,'SetStdHandle':8,'ReadFile':20,'PeekNamedPipe':24,'GetFileType':4,'GetTickCount64':0,'GetEnvironmentVariableW':12,'GetCommandLineW':0,'GetFileAttributesW':4,'CreateFileW':28,'CloseHandle':4,'GetStdHandle':4,'WriteFile':20,'LoadLibraryExW':12,'GetProcAddress':8,'FreeLibrary':4,'GetLastError':0,'ExitProcess':4,'GetModuleHandleW':4,'GetModuleFileNameW':12,'GetCurrentProcessId':0,'Sleep':4}
    for bits,target,machine,dllmachine in [(64,'x86_64-windows','x64','i386:x86-64'),(32,'i686-windows','x86','i386')]:
        spec=output/('kernel-'+str(bits)+'.def');spec.write_text('LIBRARY KERNEL32.dll\nEXPORTS\n'+'\n'.join(name+('@'+str(size) if bits==32 else '') for name,size in imports.items())+'\n');lib=output/('kernel-'+str(bits)+'.lib');obj=output/('probe-'+str(bits)+'.obj');exe=output/('ready-steam-factory'+str(bits)+'.exe')
        queue=[[dt,'-m',dllmachine,*(['--kill-at'] if bits==32 else []),'-d',str(spec),'-l',str(lib)],
          [cc,'--target='+target,'--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2','-I'+str(ROOT/'Runtime/wine-11.20/include/wine/windows'),'-I'+str(ROOT/'Vendor/wine/include/msvcrt'),'-c',str(ROOT/'Scripts/steam_windows_factory_probe.c'),'-o',str(obj)],
          [link,'/timestamp:0','/entry:mainCRTStartup','/subsystem:console','/machine:'+machine,'/safeseh:no','/nodefaultlib',str(obj),str(lib),'/out:'+str(exe)]]
        user=output/('user-'+str(bits)+'.def');user.write_text('LIBRARY USER32.dll\nEXPORTS\n'+'\n'.join(name+('@'+str(size) if bits==32 else '') for name,size in {'EnumWindows':8,'GetWindowThreadProcessId':8,'IsWindowVisible':4}.items())+'\n');userlib=output/('user-'+str(bits)+'.lib');command=[dt,'-m',dllmachine,*(['--kill-at'] if bits==32 else []),'-d',str(user),'-l',str(userlib)];subprocess.run(command,cwd=ROOT,env=env,check=True);commands.append(command);queue[-1].insert(-1,str(userlib))
        for command in queue:subprocess.run(command,cwd=ROOT,env=env,check=True);commands.append(command)
        artifacts[str(exe)]=sha(exe)
    native=output/'ready-steam-sandbox-controls';command=['/usr/bin/clang','-arch','arm64','-O2',str(ROOT/'Scripts/steam_windows_sandbox_controls.c'),'-o',str(native)];subprocess.run(command,cwd=ROOT,env=env,check=True);commands.append(command);artifacts[str(native)]=sha(native)
    report={'schema':1,'commands':commands,'sources':{str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__),ROOT/'Scripts/steam_windows_factory_probe.c',ROOT/'Scripts/steam_windows_sandbox_controls.c',ROOT/'Scripts/steam_windows_login_abi.h',ROOT/'Scripts/steam_windows_credential.h']},'artifacts':artifacts,'compiled':True,'executed':False,'credentialsRead':False,'authenticationImplemented':False,'closedHelperUsed':False,'proprietaryImplementationCopied':False,'license':'GPL-3.0-only'}
    (output/'build-receipt.json').write_text(json.dumps(report,indent=2)+'\n');(research/'current-factory-build.json').write_text(json.dumps({'buildReceipt':str(output/'build-receipt.json'),'buildReceiptSHA256':sha(output/'build-receipt.json')},indent=2)+'\n');print(json.dumps({'compiled':True,'executed':False,'receipt':str(output/'build-receipt.json'),'artifacts':artifacts},indent=2))
if __name__=='__main__':main()
