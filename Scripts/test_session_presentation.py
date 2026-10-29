#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own finite-process presentation admission/lifecycle tests. No SwiftPM/CUA/game.
Builds an isolated actual Core module, manager and keeper; does not replace live helpers.
"""
import array,fcntl,hashlib,json,os,pathlib,socket,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
PROGRAM=r'''#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
int main(int n,char**a){if(n!=3)return 64;FILE*f=fopen(a[1],"w");if(!f)return 71;fprintf(f,"{\"presentation\":%s,\"overlay\":%s,\"adapters\":%s,\"hud\":\"%s\"}",dlsym(RTLD_DEFAULT,"presentation_fixture_marker")?"true":"false",dlsym(RTLD_DEFAULT,"overlay_fixture_marker")?"true":"false",dlsym(RTLD_DEFAULT,"adapter_a_fixture")&&dlsym(RTLD_DEFAULT,"adapter_b_fixture")&&dlsym(RTLD_DEFAULT,"adapter_c_fixture")?"true":"false",getenv("MTL_HUD_ENABLED")?:"");fclose(f);usleep((unsigned)atoi(a[2])*1000);char p[4096];snprintf(p,sizeof p,"%s.ended",a[1]);f=fopen(p,"w");if(f)fclose(f);return 0;}
'''
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    run=pathlib.Path(tempfile.mkdtemp(prefix='session-presentation-',dir=WORK/'tests'));run.chmod(0o700)
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','MTL_HUD_'))}
    env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/clang-session-presentation'))
    logs=[]
    def call(command,timeout=180):
        p=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout);logs.append(p.stdout+p.stderr)
        (run/'build.log').write_text('\n'.join(logs))
        if p.returncode:raise RuntimeError('Own presentation source build failed; private log retained')
        return p
    (run/'Build').mkdir();(run/'installation').mkdir()
    (run/'program.c').write_text(PROGRAM);(run/'shim.c').write_text('int presentation_fixture_marker=1;\n');(run/'overlay.c').write_text('int overlay_fixture_marker=1;\n')
    cc=['xcrun','clang','-arch','arm64','-mmacosx-version-min=14.0']
    call(cc+[run/'program.c','-o',run/'installation/program'])
    call(cc+['-dynamiclib',run/'shim.c','-o',run/'presentation.dylib'])
    call(cc+['-dynamiclib',run/'overlay.c','-o',run/'Build/libReadyOverlay.dylib'])
    call(cc+['-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror',ROOT/'SessionHost/ReadySessionHost.c',ROOT/'SessionHost/InstallationLease.c','-o',run/'Build/ReadySessionHost'])
    checks={}
    def keeper(name,options):
        report=run/(name+'.json');lock=run/(name+'.lock')
        with lock.open('a+b')as handle:
            os.fchmod(handle.fileno(),0o600);fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            p=subprocess.Popen([str(run/'Build/ReadySessionHost'),'--installation',str(run/'installation'),'--installation-lock-root',str(run/'locks'),*options,'--',str(run/'installation/program'),str(report),'1'],stdin=handle,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
        stdout,stderr=p.communicate(timeout=10);return p.returncode,report
    path=str(run/'presentation.dylib');digest=sha(run/'presentation.dylib')
    code,report=keeper('bad-digest',['--presentation-shim',path,'--presentation-shim-sha256','0'*64]);checks['wrong-shim-digest-rejected-before-child']=code==76 and not report.exists()
    code,report=keeper('partial',['--presentation-shim',path]);checks['partial-presentation-binding-rejected']=code==64 and not report.exists()
    alias=run/'shim-alias';alias.symlink_to(run/'presentation.dylib')
    code,report=keeper('alias',['--presentation-shim',str(alias),'--presentation-shim-sha256',digest]);checks['presentation-symlink-rejected-before-child']=code==76 and not report.exists()
    os.chmod(run/'presentation.dylib',0o666);code,report=keeper('writable',['--presentation-shim',path,'--presentation-shim-sha256',digest]);checks['writable-shim-rejected-before-child']=code==76 and not report.exists();os.chmod(run/'presentation.dylib',0o755)
    # Genuine descriptor protocol with deliberately synthetic health/lease FDs:
    # tests adapter preservation, not authentication or entitlement.
    adapters=[]
    for name in ['a','b','c']:
        source=run/('adapter-'+name+'.c');source.write_text('int adapter_'+name+'_fixture=1;\n')
        library=run/('adapter-'+name+'.dylib');call(cc+['-dynamiclib',source,'-o',library]);adapters.append(str(library))
    a,b=socket.socketpair();health_read,health_write=os.pipe();lock=run/'steam.lock'
    with lock.open('a+b')as handle:
        os.fchmod(handle.fileno(),0o600);fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
        childenv={**env,'READY_STEAM_ADAPTER_LIBRARIES':':'.join(adapters),'READY_OVERLAY_LIBRARY':str(run/'Build/libReadyOverlay.dylib'),'MTL_HUD_ENABLED':'0'}
        report=run/'steam-injection.json'
        p=subprocess.Popen([str(run/'Build/ReadySessionHost'),'--installation',str(run/'installation'),'--installation-lock-root',str(run/'locks'),'--steam-bootstrap','--presentation-shim',path,'--presentation-shim-sha256',digest,'--',str(run/'installation/program'),str(report),'1'],stdin=b,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=childenv)
        b.close();a.sendmsg([b'RDYSLF1\0'],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',[handle.fileno(),health_read]))]);a.shutdown(socket.SHUT_WR)
        reply=b''
        while True:
            part=a.recv(32)
            if not part:break
            reply+=part
        assert reply==b'RDYACK1\0'
    a.close();os.close(health_read)
    stdout,stderr=p.communicate(timeout=10);os.close(health_write)
    result=json.loads(report.read_text());checks['steam-bootstrap-preserves-adapters-and-presentation-without-overlay']=p.returncode==0 and result['presentation']and result['adapters']and not result['overlay']
    swift=['xcrun','swiftc','-swift-version','5','-module-cache-path',str(WORK/'cache/swift-session-presentation')]
    call(swift+['-emit-module','-emit-library','-module-name','LauncherCore',*sorted((ROOT/'Sources/LauncherCore').glob('*.swift')),'-emit-module-path',run/'LauncherCore.swiftmodule','-o',run/'libLauncherCore.dylib'])
    call(swift+['-parse-as-library','-I',run,ROOT/'Sources/M1Launcher/SessionManager.swift',ROOT/'Synthetic/ReadySessionPresentationProbe.swift','-L',run,'-lLauncherCore','-Xlinker','-rpath','-Xlinker',run,'-framework','AppKit','-o',run/'probe'])
    p=call([run/'probe',run,digest],timeout=30);report=json.loads(p.stdout)
    checks.update(report['checks']);assert all(checks.values())
    sources=[ROOT/'Sources/M1Launcher/SessionManager.swift',ROOT/'SessionHost/ReadySessionHost.c',ROOT/'Synthetic/ReadySessionPresentationProbe.swift',pathlib.Path(__file__)]
    final={'passed':True,'count':len(checks),'checks':checks,'sourceHashes':{str(p.relative_to(ROOT)):sha(p)for p in sources},'fixtureOnly':True,'actualGameAccountOrSDKUsed':False,'realWindowOrFullscreenUsed':False}
    retained=run/'report.json';retained.write_text(json.dumps(final,indent=2)+'\n');retained.chmod(0o600)
    pointer={'passed':True,'count':len(checks),'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':final['sourceHashes'],'fixtureOnly':True}
    (ROOT/'Evidence/session-presentation-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
