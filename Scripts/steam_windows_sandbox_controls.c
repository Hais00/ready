/* SPDX-License-Identifier: GPL-3.0-only */
/* Independent host-side sandbox controls. Never loads any Valve code. */
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
extern char **environ;
static int denied(int code){return code==EPERM||code==EACCES;}
int main(int argc,char **argv){
    if(argc!=3)return 2;
    int fd=open(argv[1],O_RDONLY),read_error=fd<0?errno:0;if(fd>=0)close(fd);
    fd=open(argv[2],O_WRONLY|O_CREAT|O_EXCL,0600);int write_error=fd<0?errno:0;if(fd>=0)close(fd);
    int sock=socket(AF_INET,SOCK_STREAM,0),network_error=sock<0?errno:0;
    if(sock>=0){struct sockaddr_in peer={0};peer.sin_family=AF_INET;peer.sin_port=htons(9);peer.sin_addr.s_addr=htonl(INADDR_LOOPBACK);if(connect(sock,(struct sockaddr*)&peer,sizeof(peer))<0)network_error=errno;close(sock);}
    pid_t child=-1;char *args[]={(char*)"/usr/bin/true",NULL};int exec_error=posix_spawn(&child,args[0],NULL,NULL,args,environ);if(!exec_error)waitpid(child,NULL,0);
    int passed=denied(read_error)&&denied(write_error)&&denied(network_error)&&denied(exec_error);
    printf("{\"readErrno\":%d,\"writeErrno\":%d,\"directNetworkErrno\":%d,\"execErrno\":%d,\"allDenied\":%s}\n",read_error,write_error,network_error,exec_error,passed?"true":"false");return passed?0:1;
}
