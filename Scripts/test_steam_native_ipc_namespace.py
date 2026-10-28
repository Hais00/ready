#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Benign, random POSIX IPC objects only. Never runs or cleans Valve IPC.

Universal worker-local shim and separate ARM64/x86_64 fixture processes, all
build/output on the marked work volume. Sandbox restrictions are tested too.
"""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
WORK = Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
SOURCE = ROOT / 'Scripts/steam_native_ipc_namespace.c'
FIXTURE = r'''
#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#define CHECK(name,x) do{if(!(x)){fprintf(stderr,"fixture failed: %s errno=%d\n",name,errno);return 1;}}while(0)
int main(int argc,char **argv){
 CHECK("arguments",argc==4);const char *op=argv[1],*name=argv[2];int expected=atoi(argv[3]);
 if(!strcmp(op,"mutate")){CHECK("mutate env",setenv("READY_STEAM_IPC_NAMESPACE",getenv("READY_IPC_FIXTURE_OTHER_NAMESPACE"),1)==0);op="create";}
 if(!strcmp(op,"raw-denial")){
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wdeprecated-declarations"
  errno=0;long fd=syscall(SYS_shm_open,name,O_CREAT|O_EXCL|O_RDWR,0600);CHECK("raw shm independently denied",fd<0&&(errno==EPERM||errno==EACCES));
  errno=0;long sem=syscall(SYS_sem_open,name,O_CREAT|O_EXCL,0600,1u);CHECK("raw sem independently denied",sem<0&&(errno==EPERM||errno==EACCES));
  #pragma clang diagnostic pop
 }else if(!strcmp(op,"absent")){
  errno=0;int fd=shm_open(name,O_RDONLY,0);CHECK("shm absent",fd<0&&errno==ENOENT);
  errno=0;sem_t *sem=sem_open(name,0);CHECK("sem absent",sem==SEM_FAILED&&errno==ENOENT);
 }else if(!strcmp(op,"unlink")){
  CHECK("unlink own shm",shm_unlink(name)==0);CHECK("unlink own semaphore",sem_unlink(name)==0);
 }else{
  int creating=!strcmp(op,"create");CHECK("operation",creating||!strcmp(op,"read"));
  int fd=shm_open(name,creating?O_CREAT|O_EXCL|O_RDWR:O_RDONLY,0600);CHECK("shm open",fd>=0);
  if(creating)CHECK("shm length",ftruncate(fd,sizeof(int))==0);
  int *value=mmap(NULL,sizeof(int),creating?PROT_READ|PROT_WRITE:PROT_READ,MAP_SHARED,fd,0);CHECK("mmap",value!=MAP_FAILED);
  if(creating)*value=expected;CHECK("sentinel",*value==expected);CHECK("unmap",munmap(value,sizeof(int))==0);close(fd);
  sem_t *sem=creating?sem_open(name,O_CREAT|O_EXCL,0600,1u):sem_open(name,0);CHECK("sem open",sem!=SEM_FAILED);
  CHECK("shared semaphore wait",sem_trywait(sem)==0);CHECK("shared semaphore post",sem_post(sem)==0);CHECK("sem close",sem_close(sem)==0);
 }
 printf("{\"passed\":true,\"operation\":\"%s\",\"fixtureOnly\":true}\n",op);return 0;
}
'''


def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def mapped(namespace, original, kind):
    domain = b'shm' if kind == 'shm' else b'sem'
    digest = hashlib.sha256(b'ready-steam-ipc-v1\0' + domain + b'\0' + namespace.lower().encode() + b'\0' + original.encode()).hexdigest()[:10]
    return ('/RS' if kind == 'shm' else '/RE') + namespace.lower()[:16] + '_' + digest


def main():
    assert (WORK / '.ready-external-workspace').read_text().strip() == 'ready project work for thread01a17e79'
    if shutil.disk_usage(WORK).free < 512*1024*1024: raise OSError('External reserve unavailable')
    work = Path(tempfile.mkdtemp(prefix='steam-ipc-namespace-fixture-', dir=WORK / 'tests')); work.chmod(0o700)
    (work / '.ready-steam-ipc-fixture').write_text('own random POSIX objects only\n')
    build = work / 'build'; build.mkdir(mode=0o700); fixture = build / 'fixture.c'; fixture.write_text(FIXTURE)
    cache = WORK / 'cache/steam-ipc-clang'; cache.mkdir(mode=0o700, exist_ok=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('DYLD_', 'READY_', 'Steam', 'STEAM', 'SB_'))}
    env['TMPDIR'] = str(WORK / 'tmp') + '/'
    common = ['xcrun','clang','-mmacosx-version-min=14.0','-O2','-Wall','-Wextra','-Werror','-fmodules-cache-path='+str(cache)]
    library = build / 'libReadySteamIPCNamespace.dylib'
    commands = [[*common,'-arch','arm64','-arch','x86_64','-dynamiclib',str(SOURCE),'-o',str(library)]]
    subprocess.run(commands[0],env=env,check=True,capture_output=True)
    executables={}
    for arch in ['arm64','x86_64']:
        exe=build/('fixture-'+arch);command=[*common,'-arch',arch,str(fixture),'-o',str(exe)]
        subprocess.run(command,env=env,check=True,capture_output=True);commands.append(command);executables[arch]=exe
    namespace_a=uuid.uuid4().hex;namespace_b=uuid.uuid4().hex
    assert namespace_a[:16]!=namespace_b[:16]
    checks={};operations=[];owned_names=set();active=[]
    # The noninjected controller only checks/cleans these fresh random names.
    # It never enumerates objects or touches an existing Valve name.
    libc=ctypes.CDLL(None,use_errno=True)
    libc.shm_open.restype=ctypes.c_int;libc.shm_unlink.argtypes=[ctypes.c_char_p]
    libc.sem_open.restype=ctypes.c_void_p;libc.sem_unlink.argtypes=[ctypes.c_char_p]
    libc.sem_close.argtypes=[ctypes.c_void_p]
    sem_failed=ctypes.c_void_p(-1).value
    def absent(name):
        fd=libc.shm_open(name.encode(),os.O_RDONLY,0)
        if fd>=0:os.close(fd);return False
        if ctypes.get_errno()!=errno.ENOENT:return False
        sem=libc.sem_open(name.encode(),0)
        if sem!=sem_failed:libc.sem_close(sem);return False
        return ctypes.get_errno()==errno.ENOENT
    def invoke(arch, namespace, op, name, value=0, mutate=None):
        profile=work/(namespace[:16]+'.sb')
        if not profile.exists():
            profile.write_text('(version 1)\n(allow default)\n(deny ipc-posix-shm ipc-posix-sem)\n'
                '(allow ipc-posix-shm (ipc-posix-name-regex #"^/RS'+namespace[:16]+'_'+('[a-f0-9]'*10)+'$"))\n'
                '(allow ipc-posix-sem (ipc-posix-name-regex #"^/RE'+namespace[:16]+'_'+('[a-f0-9]'*10)+'$"))\n')
        additions=['DYLD_INSERT_LIBRARIES='+str(library),'READY_STEAM_IPC_NAMESPACE='+namespace]
        if mutate:additions.append('READY_IPC_FIXTURE_OTHER_NAMESPACE='+mutate)
        command=['/usr/bin/sandbox-exec','-f',str(profile),'/usr/bin/env',*additions,str(executables[arch]),op,name,str(value)]
        process=subprocess.run(command,env=env,text=True,capture_output=True,timeout=20)
        if process.returncode:raise RuntimeError('Own IPC fixture failed: '+process.stderr)
        result=json.loads(process.stdout);assert result['passed'] and result['fixtureOnly']
        operations.append({'arch':arch,'namespacePrefix':namespace[:16],'operation':op,'passed':True})
    try:
        for arch, opposite in [('arm64','x86_64'),('x86_64','arm64')]:
            name='/RO'+uuid.uuid4().hex[:20] # valid short benign original, never a Valve name
            assert absent(name);owned_names.add(name)
            for ns in [namespace_a,namespace_b]:
                for kind in ['shm','sem']:
                    physical=mapped(ns,name,kind);assert len(physical)==30 and absent(physical);owned_names.add(physical)
            invoke(arch,namespace_a,'create',name,111);active.append((namespace_a,name))
            invoke(opposite,namespace_a,'read',name,111);checks[arch+'-same-namespace-cross-process-cross-arch']=True
            invoke(opposite,namespace_b,'absent',name)
            invoke(opposite,namespace_b,'create',name,222);active.append((namespace_b,name))
            invoke(arch,namespace_a,'read',name,111);invoke(arch,namespace_b,'read',name,222)
            checks[arch+'-different-namespace-distinct-state']=True
            invoke(arch,namespace_b,'unlink',name);active.remove((namespace_b,name))
            invoke(opposite,namespace_b,'absent',name);invoke(opposite,namespace_a,'read',name,111)
            invoke(opposite,namespace_a,'unlink',name);active.remove((namespace_a,name))
            invoke(arch,namespace_a,'absent',name);checks[arch+'-unlink-affects-only-own-namespace']=True
            invoke(arch,namespace_a,'mutate',name,333,namespace_b);active.append((namespace_a,name))
            invoke(opposite,namespace_a,'read',name,333);invoke(opposite,namespace_b,'absent',name)
            checks[arch+'-constructor-namespace-frozen']=True
            invoke(arch,namespace_a,'unlink',name);active.remove((namespace_a,name))
            invoke(arch,namespace_a,'raw-denial',name);checks[arch+'-sandbox-denies-uninterposed-original-names']=True
            assert absent(name);checks[arch+'-original-name-never-created']=True
            for ns in [namespace_a,namespace_b]:
                assert absent(mapped(ns,name,'shm')) and absent(mapped(ns,name,'sem'))
            checks[arch+'-only-owned-mapped-objects-cleaned']=True
            for invalid in ['', '0'*31, 'g'*32, '0'*33]:
                process=subprocess.run([str(executables[arch]),'absent',name,'0'],env={**env,'DYLD_INSERT_LIBRARIES':str(library),'READY_STEAM_IPC_NAMESPACE':invalid},capture_output=True,text=True,timeout=10)
                assert process.returncode==78
            checks[arch+'-invalid-namespace-fails-before-IPC']=True
    finally:
        # Only names proved absent before this run and derived from our random
        # namespace+nonce are eligible. No global or normal Steam cleanup.
        for name in owned_names:
            libc.shm_unlink(name.encode());libc.sem_unlink(name.encode())
    report={'schema':1,'fixtureOnly':True,'passed':all(checks.values()),'checks':checks,'checkCount':len(checks),'operations':operations,
            'sourceSHA256':sha(SOURCE),'testSHA256':sha(Path(__file__)),'fixtureCSHA256':sha(fixture),'dylibPath':str(library),'dylibSHA256':sha(library),
            'commands':commands,'fixtureRoot':str(work),'hostOS':platform.mac_ver()[0],'hostArchitecture':platform.machine(),
            'minimumBuildTarget':'14.0','olderMacOSRuntimeVerified':False,'valveExecuted':False,'normalValveObjectsReadOrCleaned':False,
            'mapping':'/R[S|E]<namespace16>_<10hexSHA256(version,domain,fullNamespace,original)>;30characters',
            'limitations':['lookup namespacing only; 64-bit prefix is not authentication','namespace prefix uniqueness requires coordinator enforcement','uninterposed syscalls require independent sandbox','Mach IPC/sockets/inherited handles outside scope','child/game participants must explicitly share namespace and shim; not game compatibility proof']}
    (ROOT/'Evidence/steam-native-ipc-namespace-fixtures.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['schema','fixtureOnly','passed','checkCount','dylibPath','dylibSHA256','sourceSHA256','hostOS','valveExecuted','normalValveObjectsReadOrCleaned']},indent=2))


if __name__=='__main__':main()
