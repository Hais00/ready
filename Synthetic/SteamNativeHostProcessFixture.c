// SPDX-License-Identifier: GPL-3.0-only
// Independent host-protocol fixture. No Valve library or Steam SDK is loaded.
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <libgen.h>
static volatile sig_atomic_t stopped;
static void stop_handler(int value){(void)value;stopped=1;}
static const char* arg(int count,char**values,const char*name){for(int i=1;i+1<count;i++)if(!strcmp(values[i],name))return values[i+1];return NULL;}
int main(int argc,char**argv){
 char cwd[PATH_MAX];const char *temporary=getenv("TMPDIR");
 if(!temporary||!getcwd(cwd,sizeof cwd)||strlen(temporary)!=strlen(cwd)+1||strncmp(cwd,temporary,strlen(cwd))||temporary[strlen(cwd)]!='/')return 79;
 if(!arg(argc,argv,"--library")||!arg(argc,argv,"--sdk")||!arg(argc,argv,"--discovery-library")||
    !arg(argc,argv,"--lifeline-fd")||strcmp(arg(argc,argv,"--lifeline-fd"),"3")||
    !arg(argc,argv,"--events-fd")||strcmp(arg(argc,argv,"--events-fd"),"1"))return 80;
 if(!arg(argc,argv,"--game-health-fd")||strcmp(arg(argc,argv,"--game-health-fd"),"4"))return 80;
 struct stat info;if(fstat(3,&info)||!S_ISFIFO(info.st_mode)||(fcntl(3,F_GETFL)&O_ACCMODE)!=O_RDONLY)return 81;
 if(fstat(4,&info)||!S_ISFIFO(info.st_mode)||(fcntl(4,F_GETFL)&O_ACCMODE)!=O_WRONLY)return 81;
 for(int fd=5;fd<128;fd++)if(fcntl(fd,F_GETFD)>=0)return 82;
 if(getenv("READY_FIXTURE_SECRET")||getenv("DYLD_INSERT_LIBRARIES"))return 83;
 char input[9000];size_t used=0;ssize_t count;
 while((count=read(0,input+used,sizeof(input)-used))>0){used+=(size_t)count;if(used==sizeof(input))return 84;}
 if(used<30||memcmp(input,"RDYAUTH1",8))return 85;
 memset(input,0,sizeof(input));close(0);
 char code[PATH_MAX],denied[PATH_MAX],write_path[PATH_MAX];snprintf(code,sizeof(code),"%s",argv[0]);char*directory=dirname(code);
 snprintf(denied,sizeof(denied),"%s/deny-read",directory);
 int fd=open(denied,O_RDONLY);if(fd>=0){close(fd);return 86;}if(errno!=EPERM&&errno!=EACCES)return 87;
 snprintf(write_path,sizeof(write_path),"%s/deny-write",directory);
 fd=open(write_path,O_WRONLY|O_CREAT|O_EXCL,0600);if(fd>=0){close(fd);return 88;}if(errno!=EPERM&&errno!=EACCES)return 89;
 char private_path[PATH_MAX];snprintf(private_path,sizeof(private_path),"%s/own-fixture-%s",getenv("READY_STEAM_PRIVATE_STATE_ROOT"),getenv("READY_STEAM_IPC_NAMESPACE"));
 fd=open(private_path,O_WRONLY|O_CREAT|O_EXCL,0600);if(fd<0)return 90;write(fd,"fixture",7);close(fd);unlink(private_path);
 fd=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons(1),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
 int connected=connect(fd,(struct sockaddr*)&address,sizeof(address)),error=errno;close(fd);
 if(connected==0||(error!=EPERM&&error!=EACCES))return 91;
 pid_t child=fork();if(child<0)return 92;if(child==0){execl("/usr/bin/true","true",NULL);_exit(errno==EPERM||errno==EACCES?77:78);}
 int status=0;while(waitpid(child,&status,0)<0&&errno==EINTR){}if(!WIFEXITED(status)||WEXITSTATUS(status)!=77)return 93;
 puts("{\"type\":\"starting\",\"gameID\":0,\"rawCredential\":\"fixture_private_not_forwarded\"}");fflush(stdout);
#ifdef BAD_EVENT
 puts("{invalid fixture event}");fflush(stdout);
#else
 printf("{\"type\":\"ready\",\"authenticated\":true,\"identityMatches\":true,\"ownedSubscription\":true,\"gameID\":480,\"fixtureOnly\":true,\"namespace\":\"%s\",\"privateName\":\"%s\",\"masterEndpoint\":\"%s\",\"serviceEndpoint\":\"%s\"}\n",
 getenv("READY_STEAM_IPC_NAMESPACE"),getenv("READY_STEAM_DISCOVERY_SERVICE"),getenv("steam_master_ipc_name_override"),getenv("SteamClientService"));fflush(stdout);
#endif
#ifdef DROP_EVENTS
 close(1);
#endif
#ifdef REVOKE_HEALTH
 close(4);
 puts("{\"type\":\"state\",\"revoked\":true,\"authenticated\":false,\"identityMatches\":false,\"ownedSubscription\":false,\"gameID\":480,\"fixtureOnly\":true,\"network\":\"unknown\",\"reason\":43}");fflush(stdout);
 usleep(500000); /* Simulated cleanup after the health lease was already revoked. */
 puts("{\"type\":\"stopped\",\"reason\":43,\"userReleased\":true,\"pipeReleased\":true}");fflush(stdout);return 43;
#endif
#ifdef IGNORE_LIFELINE
 signal(SIGTERM,SIG_IGN);for(;;)pause();
#else
 signal(SIGTERM,stop_handler);signal(SIGINT,stop_handler);char byte;
 while(!stopped){count=read(3,&byte,1);if(count==0)break;if(count<0&&errno==EINTR)continue;if(count<0)return 94;}
 close(4); /* No bytes: EOF revokes the health lease before remaining cleanup. */
 printf("{\"type\":\"stopped\",\"reason\":%d,\"userReleased\":true,\"pipeReleased\":true}\n",stopped?44:42);fflush(stdout);return stopped?44:42;
#endif
}
