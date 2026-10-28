/* SPDX-License-Identifier: GPL-3.0-only */
/* Own-prefix Wine lifetime guardian. Never reads credential stdin, never kills
 * global Steam or a prefix lacking the exact private marker/device/inode. */
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <poll.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include <errno.h>
static volatile sig_atomic_t cancelled;
static void cancel(int signal){(void)signal;cancelled=1;}
static double monotonic(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int safe_prefix(const char *path,const char *nonce,dev_t *device,ino_t *inode){char canonical[PATH_MAX],marker[PATH_MAX],contents[129];struct stat info;if(!realpath(path,canonical)||strcmp(path,canonical)||lstat(path,&info)||!S_ISDIR(info.st_mode)||info.st_uid!=getuid()||(info.st_mode&077))return 0;if(*device&&(*device!=info.st_dev||*inode!=info.st_ino))return 0;*device=info.st_dev;*inode=info.st_ino;if(snprintf(marker,sizeof marker,"%s/.ready-windows-auth-prefix",path)>=(int)sizeof marker)return 0;int fd=open(marker,O_RDONLY|O_NOFOLLOW);if(fd<0)return 0;struct stat st;int ok=!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_uid==getuid()&&!(st.st_mode&077);ssize_t n=ok?read(fd,contents,sizeof contents-1):-1;close(fd);if(n<0)return 0;contents[n]=0;return !strcmp(contents,nonce);}
static int wait_bounded(pid_t pid,double seconds,int *status){double end=monotonic()+seconds;while(monotonic()<end){pid_t result=waitpid(pid,status,WNOHANG);if(result==pid)return 1;if(result<0&&errno==ECHILD)return 1;usleep(10000);}return 0;}
static int server_command(const char *server,const char *option){pid_t child=fork();if(child<0)return -1;if(!child){execl(server,server,option,(char*)NULL);_exit(127);}int status=0;if(!wait_bounded(child,6,&status)){kill(child,SIGKILL);wait_bounded(child,1,&status);return 124;}return WIFEXITED(status)?WEXITSTATUS(status):128;}
int main(int argc,char **argv){
 if(argc<6)return 64;const char *prefix=argv[1],*server=argv[2],*wine=argv[3],*nonce=getenv("READY_WINDOWS_PREFIX_NONCE"),*lifeline=getenv("READY_WINDOWS_GUARDIAN_FD"),*dependencies=getenv("READY_WINDOWS_DEPENDENCY_PATH");dev_t dev=0;ino_t ino=0;if(!nonce||!lifeline||!dependencies||!safe_prefix(prefix,nonce,&dev,&ino))return 65;char *tail;long descriptor=strtol(lifeline,&tail,10);if(*tail||descriptor<3||descriptor>INT_MAX)return 65;int control=(int)descriptor;struct stat fdinfo;if(fstat(control,&fdinfo)||!S_ISFIFO(fdinfo.st_mode))return 65;
 setenv("WINEPREFIX",prefix,1);setenv("DYLD_LIBRARY_PATH",dependencies,1);setenv("DYLD_FALLBACK_LIBRARY_PATH",dependencies,1);signal(SIGTERM,cancel);signal(SIGINT,cancel);signal(SIGHUP,cancel);
 pid_t child=fork();if(child<0)return 70;if(!child){setpgid(0,0);close(control);execv(wine,&argv[3]);_exit(127);}setpgid(child,child);close(STDIN_FILENO);int status=0,ended=0,lifetime_eof=0;
 while(!cancelled){pid_t result=waitpid(child,&status,WNOHANG);if(result==child){ended=1;break;}if(result<0&&errno==ECHILD){ended=1;break;}struct pollfd watch={control,POLLIN|POLLHUP,0};if(poll(&watch,1,100)>0&&(watch.revents&(POLLIN|POLLHUP|POLLERR|POLLNVAL))){char byte;ssize_t count=read(control,&byte,1);if(count<=0){lifetime_eof=1;break;}}}
 if(!ended){kill(-child,SIGTERM);if(!wait_bounded(child,2,&status)){kill(-child,SIGKILL);wait_bounded(child,1,&status);}}
 int killed=125,waited=125;if(safe_prefix(prefix,nonce,&dev,&ino)){killed=server_command(server,"-k");waited=server_command(server,"-w");}
 const char *event=getenv("READY_WINDOWS_GUARDIAN_EVENT");if(event){char expected[PATH_MAX];if(snprintf(expected,sizeof expected,"%s/.ready-windows-guardian.json",prefix)<(int)sizeof expected&&!strcmp(expected,event)){int fd=open(event,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd>=0){dprintf(fd,"{\"guardian\":true,\"childExit\":%d,\"childSignalled\":%s,\"parentLifetimeEOF\":%s,\"cancelled\":%s,\"serverKill\":%d,\"serverWait\":%d,\"exactPrefixValidated\":%s}\n",WIFEXITED(status)?WEXITSTATUS(status):128,WIFSIGNALED(status)?"true":"false",lifetime_eof?"true":"false",cancelled?"true":"false",killed,waited,waited!=125?"true":"false");close(fd);}}}
 close(control);if(waited||!(killed==0||killed==1))return 74;if(lifetime_eof||cancelled)return 130;return WIFEXITED(status)?WEXITSTATUS(status):128;
}
