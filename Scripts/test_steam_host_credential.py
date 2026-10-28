#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic anonymous-pipe framing tests. Never reads an account or a token.

pack_credentials validates structure only. SteamID/AppID must be explicit input
from the future genuine authorization path, never inferred from token contents.
Closing the writer after the returned bytes supplies the required EOF.
"""
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
HEADER = ROOT / 'Scripts/steam_host_credential.h'
PUBLIC_INDIVIDUAL = (1 << 56) | (1 << 52) | (1 << 32)
SYNTHETIC_ID = PUBLIC_INDIVIDUAL | 12345


from steam_host_credential import pack_credentials


FIXTURE = r'''
#define _DARWIN_C_SOURCE 1
#include "steam_host_credential.h"
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
static volatile sig_atomic_t signals;
static void interrupt_read(int sig){(void)sig;signals++;}
static int zeros(const void *v,size_t n){const unsigned char *p=v;for(size_t i=0;i<n;i++)if(p[i])return 0;return 1;}
int main(int argc,char **argv){
 if(argc!=3)return 64;int fd=atoi(argv[1]),ack=atoi(argv[2]);
 struct sigaction action={0};action.sa_handler=interrupt_read;sigemptyset(&action.sa_mask);sigaction(SIGUSR1,&action,NULL);
 ready_steam_credential value;memset(&value,0xa5,sizeof value);
 int before=fcntl(fd,F_GETFL);struct timespec a,b;clock_gettime(CLOCK_MONOTONIC,&a);
 if(write(ack,"R",1)!=1)return 65;close(ack);
 int rc=ready_steam_credential_read(fd,&value),error=errno;clock_gettime(CLOCK_MONOTONIC,&b);
 int rejected_zero=rc!=0&&zeros(&value,sizeof value);size_t account=rc==0?strlen(value.account):0,token=rc==0?strlen(value.token):0;
 int exact=rc==0&&value.steam_id==(((uint64_t)1<<56)|((uint64_t)1<<52)|((uint64_t)1<<32)|12345)&&value.app_id==123&&
  !strcmp(value.account,"fixture_user")&&!strcmp(value.token,"opaque.fixture-only.not-a-jwt");
 int flags=fcntl(fd,F_GETFL)==before;ready_steam_credential_clear(&value);int cleared=zeros(&value,sizeof value);
 double elapsed=(b.tv_sec-a.tv_sec)*1000.0+(b.tv_nsec-a.tv_nsec)/1000000.0;
 printf("{\"accepted\":%s,\"zeroOnReject\":%s,\"clearedAfterUse\":%s,\"flagsRestored\":%s,\"exactSyntheticPayload\":%s,\"accountLength\":%zu,\"tokenLength\":%zu,\"errno\":%d,\"elapsedMs\":%.3f,\"signals\":%d}\n",rc==0?"true":"false",rejected_zero?"true":"false",cleared?"true":"false",flags?"true":"false",exact?"true":"false",account,token,error,elapsed,(int)signals);
 close(fd);return 0;
}
'''


def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    assert (WORK / '.ready-external-workspace').read_text().strip() == 'ready project work for thread01a17e79'
    work = Path(tempfile.mkdtemp(prefix='steam-credential-fixture-', dir=WORK / 'tests')); work.chmod(0o700)
    (work / '.ready-steam-credential-fixture').write_text('synthetic framing only\n')
    snapshot = work / 'steam_host_credential.h'; snapshot.write_bytes(HEADER.read_bytes())
    source = work / 'fixture.c'; source.write_text(FIXTURE)
    cache = WORK / 'cache/steam-credential-clang'; cache.mkdir(exist_ok=True, mode=0o700)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('READY_', 'STEAM', 'Steam', 'DYLD_', 'SB_'))}
    env['TMPDIR'] = str(WORK / 'tmp') + '/'
    common = ['xcrun','clang','-mmacosx-version-min=14.0','-O2','-Wall','-Wextra','-Werror','-fmodules-cache-path='+str(cache),str(source)]
    universal = work / 'credential-fixture-universal'; command = [*common,'-arch','arm64','-arch','x86_64','-o',str(universal)]
    subprocess.run(command,env=env,check=True,capture_output=True)
    synthetic = {'username':'fixture_user','refresh_token':'opaque.fixture-only.not-a-jwt','steamID':SYNTHETIC_ID,'appID':123}
    valid = pack_credentials(synthetic)
    records=[];checks={}
    def execute(arch, label, chunks, accept=False, *, close_writer=True, signals=False, nonblocking=False, descriptor='pipe', timeout=6):
        if descriptor=='pipe': r,w=os.pipe(); closer=lambda: os.close(w)
        elif descriptor=='file':
            path=work/'own-fixture-file';path.write_bytes(valid);r=os.open(path,os.O_RDONLY);w=None;closer=lambda: None
        else:
            reader,writer=socket.socketpair();r=reader.detach();w=writer.detach();closer=lambda: os.close(w)
        if nonblocking:fcntl.fcntl(r,fcntl.F_SETFL,fcntl.fcntl(r,fcntl.F_GETFL)|os.O_NONBLOCK)
        ack_r,ack_w=os.pipe(); stop=threading.Event()
        process=subprocess.Popen(['/usr/bin/arch','-'+arch,str(universal),str(r),str(ack_w)],env=env,pass_fds=(r,ack_w),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        os.close(r);os.close(ack_w)
        ready,_,_=select.select([ack_r],[],[],5)
        if not ready or os.read(ack_r,1)!=b'R':process.kill();raise AssertionError('Own fixture did not become ready')
        os.close(ack_r)
        def writer_job():
            try:
                started=time.monotonic()
                for offset,data in chunks:
                    if stop.wait(max(0,started+offset-time.monotonic())):return
                    if signals:
                        try:os.kill(process.pid,signal.SIGUSR1)
                        except ProcessLookupError:return
                    if w is not None:
                        try:os.write(w,data)
                        except (BrokenPipeError,OSError):return
                if not close_writer:stop.wait(5)
            finally:closer()
        thread=threading.Thread(target=writer_job,daemon=True);thread.start()
        try:out,error=process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:process.kill();process.communicate();raise AssertionError('Reader exceeded total deadline')
        finally:stop.set();thread.join(timeout=2)
        assert process.returncode==0 and not error
        # Only safe structural metadata is emitted by the C fixture.
        assert synthetic['username'].encode() not in out and synthetic['refresh_token'].encode() not in out
        result=json.loads(out);assert result['accepted'] is accept and result['clearedAfterUse'] and result['flagsRestored']
        if not accept:assert result['zeroOnReject']
        checks[arch+'-'+label]=True;records.append({'arch':arch,'case':label,**result})
        return result
    for arch in ['arm64','x86_64']:
        result=execute(arch,'valid-opaque-synthetic',[(0,valid)],True);assert result['exactSyntheticPayload']
        execute(arch,'valid-short-reads-EINTR',[(i*.004,valid[i:i+1]) for i in range(len(valid))],True,signals=True)
        execute(arch,'valid-already-nonblocking',[(.05,valid)],True,nonblocking=True)
        largest=pack_credentials({**synthetic,'username':'A'*64,'refresh_token':'T'*8192})
        result=execute(arch,'valid-maximum-bounds',[(0,largest)],True);assert result['accountLength']==64 and result['tokenLength']==8192
        malformed=[('truncated-header',valid[:12]),('truncated-account',valid[:30]),('truncated-token',valid[:-1]),('wrong-magic',b'BADMAGIC'+valid[8:]),
                   ('extra-byte',valid+b'!'),('second-frame',valid+valid),('empty',b'')]
        for label,data in malformed:execute(arch,label,[(0,data)])
        for label,account,token,steam,app in [('account-oversize',65,1,SYNTHETIC_ID,123),('token-oversize',1,8193,SYNTHETIC_ID,123),
                 ('account-zero',0,1,SYNTHETIC_ID,123),('token-zero',1,0,SYNTHETIC_ID,123),('appID-zero',1,1,SYNTHETIC_ID,0),
                 ('steamID-zero',1,1,0,123),('steamID-type',1,1,(1<<56)|(2<<52)|(1<<32)|12345,123),
                 ('steamID-universe',1,1,(2<<56)|(1<<52)|(1<<32)|12345,123),('steamID-instance',1,1,(1<<56)|(1<<52)|(2<<32)|12345,123),
                 ('steamID-account-zero',1,1,PUBLIC_INDIVIDUAL,123)]:
            execute(arch,label,[(0,b'RDYAUTH1'+struct.pack('>IIQI',account,token,steam,app))])
        for label,data in [('account-NUL',b'fi\0ture_user'),('account-hyphen',b'fixture-user'),('account-nonascii',b'fixture_\xff')]:
            frame=b'RDYAUTH1'+struct.pack('>IIQI',len(data),1,SYNTHETIC_ID,123)+data+b'T';execute(arch,label,[(0,frame)])
        for label,data in [('token-NUL',b'a\0b'),('token-whitespace',b'a b'),('token-control',b'a\nb'),('token-nonascii',b'a\xffb')]:
            frame=b'RDYAUTH1'+struct.pack('>IIQI',1,len(data),SYNTHETIC_ID,123)+b'A'+data;execute(arch,label,[(0,frame)])
        execute(arch,'reject-regular-file',[],descriptor='file')
        execute(arch,'reject-socket',[(0,valid)],descriptor='socket')
        result=execute(arch,'EOF-hang-total-budget',[(0,valid[:28]),(1,valid[28:40]),(2,valid[40:])],close_writer=False)
        assert result['errno']==errno.ETIMEDOUT and 2500<=result['elapsedMs']<4500
        result=execute(arch,'drip-header-total-budget',[(i*.8,valid[i:i+1]) for i in range(7)],close_writer=False)
        assert result['errno']==errno.ETIMEDOUT and 2500<=result['elapsedMs']<4500
        result=execute(arch,'EINTR-does-not-reset-budget',[(i*.3,b'') for i in range(14)],close_writer=False,signals=True)
        assert result['errno']==errno.ETIMEDOUT and result['signals']>0 and 2500<=result['elapsedMs']<4500
    for key,value in [('steamID',True),('steamID',None),('steamID',str(SYNTHETIC_ID)+' '),('appID',0),('appID',1<<32),('username','bad account'),('refresh_token','contains\nnewline')]:
        try:pack_credentials({**synthetic,key:value})
        except ValueError:pass
        else:raise AssertionError('Encoder accepted invalid structure')
    checks['python-encoder-rejects-invalid-structure']=True
    assert snapshot.read_bytes()==HEADER.read_bytes()
    report={'schema':1,'fixtureOnly':True,'passed':all(checks.values()),'checks':checks,'checkCount':len(checks),'records':records,
            'headerSHA256':sha(HEADER),'testSHA256':sha(Path(__file__)),'fixtureCSHA256':sha(source),'universalPath':str(universal),'universalSHA256':sha(universal),
            'commands':[command],'sourceSnapshot':str(snapshot),'fixtureRoot':str(work),'hostOS':platform.mac_ver()[0],
            'realCredentialsRead':False,'valveExecuted':False,'credentialsInArgvOrEnvironment':False,'authenticationVerified':False}
    (ROOT/'Evidence/steam-host-credential-fixtures.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['schema','fixtureOnly','passed','checkCount','headerSHA256','universalPath','universalSHA256','hostOS','realCredentialsRead','authenticationVerified']},indent=2))


if __name__=='__main__':main()
