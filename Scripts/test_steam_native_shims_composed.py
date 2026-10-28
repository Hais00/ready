#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compose the two worker shims on benign files/SHM, never a Valve process.

The SHM mutation fallback must use current kernel object metadata, not failed
F_GETPATH alone and not cached descriptor numbers. Independent sandbox controls
continue to reject raw IPC names outside the current random namespace.
"""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile
import uuid

from test_steam_native_ipc_namespace import mapped
ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
FIXTURE=r'''
#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#if defined(__x86_64__)
#define READY_FIXTURE_CPU "x86_64"
#else
#define READY_FIXTURE_CPU "arm64"
#endif
#define CHECK(name,x) do{if(!(x)){fprintf(stderr,"fixture failed: %s errno=%d\n",name,errno);return 1;}checks++;}while(0)
int main(int argc,char **argv){
 int checks=0;CHECK("arguments",argc==4);const char *op=argv[1],*name=argv[2];int expected=atoi(argv[3]);
 if(!strcmp(op,"unlink")){CHECK("unlink namespace object",shm_unlink(name)==0);printf("{\"passed\":true,\"checks\":%d,\"machine\":\"%s\"}\n",checks,READY_FIXTURE_CPU);return 0;}
 int creating=!strcmp(op,"create");CHECK("operation",creating||!strcmp(op,"read"));
 int fd=shm_open(name,creating?O_CREAT|O_EXCL|O_RDWR:O_RDONLY,0600);CHECK("namespaced SHM opened",fd>=0);
 char filename[4096];CHECK("SHM has no filesystem pathname",fcntl(fd,F_GETPATH,filename)<0);
 struct pshm_fdinfo info;memset(&info,0,sizeof info);
 CHECK("kernel confirms SHM flavor",proc_pidfdinfo(getpid(),fd,PROC_PIDFDPSHMINFO,&info,sizeof info)==sizeof info);
 CHECK("kernel confirms current uid",info.pshminfo.pshm_stat.vst_uid==getuid());
 if(creating){
  int duplicated=dup(fd);CHECK("duplicate descriptor",duplicated>=0);
  CHECK("owned kernel SHM duplicate can ftruncate",ftruncate(duplicated,4096)==0);close(duplicated);
 }
 struct stat st;CHECK("physical SHM size",fstat(fd,&st)==0&&st.st_size>=4096);
 int *data=mmap(NULL,4096,creating?PROT_READ|PROT_WRITE:PROT_READ,MAP_SHARED,fd,0);CHECK("shared mmap",data!=MAP_FAILED);
 if(creating)*data=expected;CHECK("private sentinel",*data==expected);CHECK("unmap",munmap(data,4096)==0);
 if(creating){
  int slot=dup(fd);CHECK("reserve old SHM descriptor",slot>=0);close(slot);
  int pipes[2];CHECK("pipe",pipe(pipes)==0);if(pipes[0]!=slot)CHECK("reuse number for pipe",dup2(pipes[0],slot)==slot);
  errno=0;CHECK("old number now pipe is denied",ftruncate(slot,0)<0&&errno==EPERM);
  close(slot);if(pipes[0]!=slot)close(pipes[0]);close(pipes[1]);
  int other=atoi(getenv("READY_COMPOSED_OTHER_SHM_FD"));
  CHECK("reuse number for foreign SHM",dup2(other,slot)==slot);
  errno=0;CHECK("other namespace kernel SHM denied",ftruncate(slot,0)<0&&errno==EPERM);
  CHECK("foreign SHM size unchanged",fstat(slot,&st)==0&&st.st_size==atoll(getenv("READY_COMPOSED_OTHER_SIZE")));close(slot);
  int original=atoi(getenv("READY_COMPOSED_ORIGINAL_FD"));
  CHECK("reuse number for original state",dup2(original,slot)==slot);
  errno=0;CHECK("original state fd still denied",ftruncate(slot,0)<0);close(slot);
  char code[4096];snprintf(code,sizeof code,"%s/Steam.AppBundle/code.bin",getenv("READY_STEAM_ORIGINAL_STATE_ROOT"));
  int codefd=open(code,O_RDONLY);CHECK("original code read",codefd>=0);CHECK("reuse number for readonly code",dup2(codefd,slot)==slot);
  errno=0;CHECK("readonly code mutation denied",ftruncate(slot,0)<0&&errno==EROFS);close(slot);if(codefd!=slot)close(codefd);
  CHECK("original owned SHM fd still valid",fstat(fd,&st)==0&&st.st_size>=4096);
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wdeprecated-declarations"
  errno=0;long raw=syscall(SYS_shm_open,getenv("READY_COMPOSED_OTHER_NAME"),O_RDWR,0);
  CHECK("sandbox denies foreign raw IPC bypass",raw<0&&(errno==EPERM||errno==EACCES));
  #pragma clang diagnostic pop
 }
 close(fd);printf("{\"passed\":true,\"checks\":%d,\"kernelSHMValidated\":true,\"machine\":\"%s\"}\n",checks,READY_FIXTURE_CPU);return 0;
}
'''


def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def inventory(root):
    return {str(p.relative_to(root)):{'sha256':sha(p),'mode':p.stat().st_mode&0o777} for p in root.rglob('*') if p.is_file()}


def main():
    assert (WORK/'.ready-external-workspace').read_text().strip()=='ready project work for thread01a17e79'
    work=Path(tempfile.mkdtemp(prefix='steam-composed-shims-',dir=WORK/'tests'));work.chmod(0o700)
    (work/'.ready-steam-composed-fixture').write_text('own benign objects and files only\n')
    originals={name:ROOT/'Scripts'/name for name in ['steam_native_state_fs.c','steam_native_ipc_namespace.c']}
    snapshots={}
    for name,path in originals.items():
        target=work/name;target.write_bytes(path.read_bytes());snapshots[name]=target
    c=work/'fixture.c';c.write_text(FIXTURE)
    env={k:v for k,v in os.environ.items() if not k.startswith(('READY_','DYLD_','Steam','STEAM','SB_'))};env['TMPDIR']=str(WORK/'tmp')+'/'
    cache=WORK/'cache/steam-composed-clang';cache.mkdir(mode=0o700,exist_ok=True)
    base=['xcrun','clang','-mmacosx-version-min=14.0','-O2','-Wall','-Wextra','-Werror','-fmodules-cache-path='+str(cache),'-arch','arm64','-arch','x86_64']
    commands=[];libraries={}
    for name,path in snapshots.items():
        library=work/(path.stem+'.dylib');command=[*base,'-dynamiclib',str(path),'-o',str(library)];subprocess.run(command,env=env,check=True,capture_output=True);commands.append(command);libraries[name]=library
    exe=work/'composed-fixture-universal';command=[*base,str(c),'-o',str(exe)];subprocess.run(command,env=env,check=True,capture_output=True);commands.append(command)
    original=work/'original normal Steam';original.mkdir(mode=0o700);(original/'state.bin').write_bytes(b'original account bytes remain unchanged');(original/'Steam.AppBundle').mkdir();(original/'Steam.AppBundle/code.bin').write_bytes(b'original code immutable')
    before=inventory(original);libc=ctypes.CDLL(None,use_errno=True);libc.shm_open.restype=ctypes.c_int;libc.shm_open.argtypes=[ctypes.c_char_p,ctypes.c_int];libc.shm_unlink.argtypes=[ctypes.c_char_p]
    owned=[];checks={};records=[]
    try:
      for arch,otherarch in [('arm64','x86_64'),('x86_64','arm64')]:
       for order in ['fs-ipc','ipc-fs']:
        namespace=uuid.uuid4().hex;otherns=uuid.uuid4().hex;assert namespace[:16]!=otherns[:16]
        logical='/RO'+uuid.uuid4().hex[:20];physical=mapped(namespace,logical,'shm');foreign=mapped(otherns,logical,'shm')
        private=work/(arch+'-'+order+'-private');private.mkdir(mode=0o700)
        for name in [physical,foreign]:
            test=libc.shm_open(name.encode(),os.O_RDONLY)
            assert test<0 and ctypes.get_errno()==errno.ENOENT
            owned.append(name)
        (work/(arch+'-'+order+'-owned-names.json')).write_text(json.dumps({'names':[physical,foreign],'fixtureOnly':True}))
        foreignfd=libc.shm_open(foreign.encode(),os.O_CREAT|os.O_EXCL|os.O_RDWR,ctypes.c_int(0o600));assert foreignfd>=0
        os.ftruncate(foreignfd,64);foreign_size=os.fstat(foreignfd).st_size
        # mmap is the portable Darwin POSIX SHM data interface.
        import mmap
        memory=mmap.mmap(foreignfd,64);memory[:25]=b'foreign profile unchanged';memory.close()
        originalfd=os.open(original/'state.bin',os.O_RDWR)
        suffix='[a-f0-9]'*10
        sb=work/(arch+'-'+order+'.sb');sb.write_text('(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write* (subpath '+json.dumps(str(private))+'))\n'
            '(deny file-read* (subpath '+json.dumps(str(original))+'))\n(allow file-read-metadata (literal '+json.dumps(str(original))+'))\n(allow file-read* (subpath '+json.dumps(str(original/'Steam.AppBundle'))+'))\n'
            '(deny ipc-posix-shm ipc-posix-sem)\n(allow ipc-posix-shm (ipc-posix-name-regex #"^/RS'+namespace[:16]+'_'+suffix+'$"))\n'
            '(allow ipc-posix-sem (ipc-posix-name-regex #"^/RE'+namespace[:16]+'_'+suffix+'$"))\n')
        fslib=libraries['steam_native_state_fs.c'];ipclib=libraries['steam_native_ipc_namespace.c']
        sequence=[fslib,ipclib] if order=='fs-ipc' else [ipclib,fslib]
        additions={'DYLD_INSERT_LIBRARIES':':'.join(map(str,sequence)),'READY_STEAM_ORIGINAL_STATE_ROOT':str(original),'READY_STEAM_PRIVATE_STATE_ROOT':str(private),
                   'READY_STEAM_IPC_NAMESPACE':namespace,'READY_COMPOSED_OTHER_SHM_FD':str(foreignfd),'READY_COMPOSED_ORIGINAL_FD':str(originalfd),'READY_COMPOSED_OTHER_NAME':foreign,'READY_COMPOSED_OTHER_SIZE':str(os.fstat(foreignfd).st_size)}
        def invoke(cpu,op,value):
            # arch is a platform binary: set DYLD after it, not before it.
            args=['/usr/bin/sandbox-exec','-f',str(sb),'/usr/bin/arch','-'+cpu,'/usr/bin/env',*[key+'='+value for key,value in additions.items()],str(exe),op,logical,str(value)]
            result=subprocess.run(args,env=env,pass_fds=(foreignfd,originalfd),capture_output=True,text=True,timeout=20)
            if result.returncode:raise RuntimeError('Own composed fixture failed: '+result.stderr)
            record=json.loads(result.stdout);assert record['passed'] and record['machine']==cpu;records.append({'architecture':cpu,'order':order,'operation':op,**record})
        try:
            invoke(arch,'create',111);invoke(otherarch,'read',111);invoke(otherarch,'unlink',111)
            assert inventory(original)==before;assert os.fstat(foreignfd).st_size==foreign_size
            memory=mmap.mmap(foreignfd,64);assert memory[:25]==b'foreign profile unchanged';memory.close()
            checks[arch+'-'+order+'-kernel-validated-shm-ftruncate-and-cross-process-mmap']=True
            checks[arch+'-'+order+'-descriptor-dup-reuse-other-namespace-and-originals-safe']=True
        finally:os.close(foreignfd);os.close(originalfd)
    finally:
        for name in owned:libc.shm_unlink(name.encode())
    assert inventory(original)==before
    for name,path in originals.items():assert path.read_bytes()==snapshots[name].read_bytes()
    report={'schema':1,'fixtureOnly':True,'passed':all(checks.values()),'checks':checks,'checkCount':len(checks),'records':records,
            'sourceSHA256':{name:sha(path) for name,path in originals.items()},'testSHA256':sha(Path(__file__)),'fixtureCSHA256':sha(c),'libraries':{name:{'path':str(path),'sha256':sha(path)} for name,path in libraries.items()},
            'universalPath':str(exe),'universalSHA256':sha(exe),'commands':commands,'fixtureRoot':str(work),'credentialHeaderUsed':False,'hostOS':platform.mac_ver()[0],
            'valveExecuted':False,'realUserStateChanged':False,'normalValveIPCReadOrCleaned':False,
            'limits':['self kernel POSIX SHM flavor/owner/current-prefix proof only; not all unknown FDs','no registry; kernel metadata rechecked after dup/reuse','independent sandbox and unique active namespace prefixes required','actual Valve controller/game compatibility not claimed']}
    (ROOT/'Evidence/steam-native-shims-composed-fixtures.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['passed','checkCount','libraries','sourceSHA256','fixtureRoot','hostOS','valveExecuted']},indent=2))


if __name__=='__main__':main()
