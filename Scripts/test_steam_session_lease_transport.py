#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Swift Foundation Process -> own C keeper descriptor handoff; no Steam SDK/account."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
KEEPER=WORK/'tests/steam-session-lease-cp_1rtua/ReadySessionHost'
KEEPER_SHA='88012067ae57e82fcf51487c2338a11e82312dcd60356213e06a3c04e45d7b6c'
GAME=r'''
// SPDX-License-Identifier: GPL-3.0-only
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
int main(int argc,char **argv) {
 if(argc!=2)return 64;
 if(!strncmp(argv[1],"--",2)) {
  char frame[8];size_t used=0;while(used<8){ssize_t n=read(0,frame+used,8-used);if(n<=0)return 65;used+=(size_t)n;}
  if(!strcmp(argv[1],"--ACKWithoutEOF")){if(write(0,"RDYACK1\0",8)!=8)return 66;}
  else if(!strcmp(argv[1],"--badACK")){if(write(0,"BADACK1\0",8)!=8)return 66;shutdown(0,SHUT_WR);}
  for(;;)pause();
 }
 signal(SIGTERM,SIG_IGN);
 char target[4096],temp[4096];snprintf(target,sizeof target,"%s/state.json",argv[1]);snprintf(temp,sizeof temp,"%s/state.tmp",argv[1]);
 FILE *file=fopen(temp,"w");if(!file)return 71;
 fprintf(file,"{\"pid\":%d,\"ignoredTERM\":true,\"extraFDs\":[",getpid());int count=0;
 for(int fd=3;fd<1024;fd++)if(fd!=fileno(file)&&fcntl(fd,F_GETFD)>=0)fprintf(file,"%s%d",count++?",":"",fd);
 const char *adapters=getenv("DYLD_INSERT_LIBRARIES");if(!adapters)return 72;
 fprintf(file,"],\"adapters\":\"%s\"}",adapters);if(fclose(file)||rename(temp,target))return 71;
 for(;;)pause();
}
'''
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--keeper',type=pathlib.Path,default=KEEPER);parser.add_argument('--keeper-sha256',default=KEEPER_SHA);args=parser.parse_args()
 keeper=args.keeper.resolve()
 if hashlib.sha256(keeper.read_bytes()).hexdigest()!=args.keeper_sha256:raise RuntimeError('Own keeper digest does not match selected build')
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-session-lease-transport-',dir=WORK/'tests'));run.chmod(0o700)
 env=dict(os.environ,TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/clang-host-session'))
 source=run/'game.c';source.write_text('#include <sys/socket.h>\n'+GAME);game=run/'own-game'
 adapter_source=run/'adapter.c';adapter_source.write_text('// SPDX-License-Identifier: GPL-3.0-only\nint ready_own_lease_transport_fixture(void){return 1;}\n')
 subprocess.run(['/usr/bin/clang','-std=c11','-O1','-Wall','-Wextra','-Werror',str(source),'-o',str(game)],env=env,capture_output=True,check=True)
 adapters=[]
 for index in range(3):
  target=run/f'own-adapter-{index}.dylib'
  subprocess.run(['/usr/bin/clang','-dynamiclib',str(adapter_source),'-o',str(target)],env=env,capture_output=True,check=True)
  adapters.append(str(target.resolve()))
 binary=run/'probe'
 compiled=subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(ROOT/'Sources/M1Launcher/SteamSessionLeaseTransport.swift'),str(ROOT/'Synthetic/ReadySteamSessionLeaseTransportProbe.swift'),'-o',str(binary)],env=env,capture_output=True,text=True)
 if compiled.returncode:raise RuntimeError(compiled.stderr[-6000:])
 result=subprocess.run([str(binary),str(keeper),str(game),str(run),':'.join(adapters)],env=env,capture_output=True,text=True,timeout=30)
 if result.returncode:raise RuntimeError('Own lease transport fixture failed: '+result.stderr[-4500:])
 report=json.loads(result.stdout);assert report['allPassed']
 print(json.dumps(dict(passed=True,fixtureOnly=True,keeperSHA256=args.keeper_sha256,retainedRoot=str(run),checks=report),sort_keys=True))
if __name__=='__main__':main()
