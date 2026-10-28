/* SPDX-License-Identifier: GPL-3.0-only */
/* Native preparation controls only. Never loads Valve or reads credentials. */
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <semaphore.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netdb.h>
#include <poll.h>
extern char **environ;
static int denied(int e){return e==EPERM||e==EACCES;}
static int unix_connect(const char *path){struct sockaddr_un address={0};address.sun_family=AF_UNIX;address.sun_len=sizeof address;if(!path||strlen(path)>=sizeof address.sun_path)return EINVAL;strcpy(address.sun_path,path);int s=socket(AF_UNIX,SOCK_STREAM,0),e=s<0?errno:0;if(s>=0){if(connect(s,(struct sockaddr*)&address,sizeof address))e=errno;close(s);}return e;}
static int public_smoke(void){struct addrinfo hint={0},*items=NULL;hint.ai_socktype=SOCK_STREAM;hint.ai_family=AF_UNSPEC;int dns=getaddrinfo("api.steampowered.com","443",&hint,&items),connected=0;if(!dns)for(struct addrinfo *a=items;a&&!connected;a=a->ai_next){int s=socket(a->ai_family,a->ai_socktype,a->ai_protocol);if(s<0)continue;fcntl(s,F_SETFL,O_NONBLOCK);int result=connect(s,a->ai_addr,a->ai_addrlen);if(!result)connected=1;else if(errno==EINPROGRESS){struct pollfd p={s,POLLOUT,0};if(poll(&p,1,4000)>0){int error=0;socklen_t n=sizeof error;if(!getsockopt(s,SOL_SOCKET,SO_ERROR,&error,&n)&&!error)connected=1;}}close(s);}if(items)freeaddrinfo(items);printf("{\"dnsResolved\":%s,\"publicTCPConnected\":%s,\"ValveLoaded\":false,\"credentialsRead\":false}\n",!dns?"true":"false",connected?"true":"false");return !dns&&connected?0:1;}
int main(int argc,char **argv){if(argc==2&&!strcmp(argv[1],"--public-smoke"))return public_smoke();
 if(argc!=5)return 64;int fd=open(argv[1],O_RDONLY),rd=fd<0&&denied(errno);if(fd>=0)close(fd);fd=open(argv[2],O_WRONLY|O_CREAT|O_EXCL,0600);int wr=fd<0&&denied(errno);if(fd>=0)close(fd);
 int s=socket(AF_INET,SOCK_STREAM,0),e=s<0?errno:0;struct sockaddr_in a={0};a.sin_family=AF_INET;a.sin_port=htons(9);a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);if(s>=0){if(connect(s,(struct sockaddr*)&a,sizeof a))e=errno;close(s);}int net=denied(e);
 s=socket(AF_INET6,SOCK_STREAM,0);e=s<0?errno:0;struct sockaddr_in6 a6={0};a6.sin6_family=AF_INET6;a6.sin6_port=htons(9);a6.sin6_addr=in6addr_loopback;if(s>=0){if(connect(s,(struct sockaddr*)&a6,sizeof a6))e=errno;close(s);}int net6=denied(e);
 pid_t child;char *args[]={"/usr/bin/true",NULL};e=posix_spawn(&child,args[0],NULL,NULL,args,environ);int ex=denied(e);if(!e)waitpid(child,NULL,0);
 char name[32];snprintf(name,sizeof name,"/ReadyWinControl%d",getpid());fd=shm_open(name,O_CREAT|O_EXCL|O_RDWR,0600);int shm=fd<0&&denied(errno);if(fd>=0){close(fd);shm_unlink(name);}sem_t *sem=sem_open(name,O_CREAT|O_EXCL,0600,1);int se=sem==SEM_FAILED&&denied(errno);if(sem!=SEM_FAILED){sem_close(sem);sem_unlink(name);}
 int un=denied(unix_connect(argv[3])),own=unix_connect(argv[4])==0;int all=rd&&wr&&net&&net6&&ex&&shm&&se&&un&&own;
 printf("{\"readDenied\":%s,\"writeDenied\":%s,\"otherIPv4LoopbackDenied\":%s,\"otherIPv6LoopbackDenied\":%s,\"otherExecDenied\":%s,\"unscopedSharedMemoryDenied\":%s,\"unscopedSemaphoreDenied\":%s,\"otherUnixDenied\":%s,\"ownWineUnixAllowed\":%s,\"allPassed\":%s,\"ValveLoaded\":false}\n",rd?"true":"false",wr?"true":"false",net?"true":"false",net6?"true":"false",ex?"true":"false",shm?"true":"false",se?"true":"false",un?"true":"false",own?"true":"false",all?"true":"false");return all?0:1;
}
