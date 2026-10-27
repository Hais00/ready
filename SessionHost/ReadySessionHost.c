// SPDX-License-Identifier: GPL-3.0-only
// A minimal native lock keeper. It never parses a shell command string or kills globally.
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

static volatile sig_atomic_t child_group=0;
static volatile sig_atomic_t pending_signal=0;
static int spawn_error=0;
extern char **environ;

static void forward_signal(int signal_number) {
    int saved=errno;
    pending_signal=signal_number;
    sig_atomic_t group=child_group;
    if(group>0)kill(-(pid_t)group,signal_number);
    errno=saved;
}
static int usage(const char *message) {
    if(message)fprintf(stderr,"ReadySessionHost: %s\n",message);
    fprintf(stderr,"usage: ReadySessionHost [--wine-server /path/wineserver --prefix /path/prefix] -- /path/program [args...]\n");
    return 64;
}
static int normal_status(int status) {
    if(WIFEXITED(status))return WEXITSTATUS(status);
    if(WIFSIGNALED(status))return 128+WTERMSIG(status);
    return 70;
}
static int wait_for(pid_t pid) {
    int status=0;pid_t result;
    do{result=waitpid(pid,&status,0);}while(result<0 && errno==EINTR);
    if(result<0){perror("ReadySessionHost: waitpid");return 71;}
    return normal_status(status);
}
static pid_t spawn_program(char *const argv[],int game,const sigset_t *original_mask) {
    posix_spawnattr_t attr;posix_spawn_file_actions_t actions;pid_t pid=-1;
    int error=posix_spawnattr_init(&attr);if(error){spawn_error=error;return -1;}
    error=posix_spawn_file_actions_init(&actions);if(error){posix_spawnattr_destroy(&attr);spawn_error=error;return -1;}
    sigset_t defaults;sigemptyset(&defaults);sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT);sigaddset(&defaults,SIGHUP);
    short flags=POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_CLOEXEC_DEFAULT;
    if((error=posix_spawnattr_setflags(&attr,flags)) || (error=posix_spawnattr_setpgroup(&attr,0)) ||
       (error=posix_spawnattr_setsigmask(&attr,original_mask)) || (error=posix_spawnattr_setsigdefault(&attr,&defaults)) ||
       (error=posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0)))goto finish;
    // CLOEXEC_DEFAULT drops EVERY unrelated descriptor. Only logging descriptors survive.
    for(int fd=STDOUT_FILENO;fd<=STDERR_FILENO;fd++){
        error=fcntl(fd,F_GETFD)>=0 ? posix_spawn_file_actions_addinherit_np(&actions,fd):posix_spawn_file_actions_addopen(&actions,fd,"/dev/null",O_WRONLY,0);
        if(error)goto finish;
    }
    size_t count=0;while(environ[count])count++;
    char **environment=calloc(count+2,sizeof(char *));if(!environment){error=ENOMEM;goto finish;}
    size_t used=0;
    for(size_t i=0;i<count;i++)if(strncmp(environ[i],"DYLD_INSERT_LIBRARIES=",22))environment[used++]=environ[i];
    char *injection=NULL;const char *overlay=getenv("READY_OVERLAY_LIBRARY");struct stat st;
    if(game && overlay && *overlay && stat(overlay,&st)==0 && S_ISREG(st.st_mode)){
        if(asprintf(&injection,"DYLD_INSERT_LIBRARIES=%s",overlay)<0){free(environment);error=ENOMEM;goto finish;}
        environment[used++]=injection;
    }
    environment[used]=NULL;
    // posix_spawn is literal argv execution, not execvp's ENOEXEC shell fallback.
    error=posix_spawn(&pid,argv[0],&actions,&attr,argv,environment);
    free(injection);free(environment);
finish:
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);
    if(error){spawn_error=error;errno=error;perror(game ? "ReadySessionHost: spawn game":"ReadySessionHost: spawn wineserver");return -1;}
    return pid;
}
int main(int argc,char **argv) {
    const char *server=NULL,*prefix=NULL;int command=0;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--")){command=i+1;break;}
        if(!strcmp(argv[i],"--wine-server") && i+1<argc)server=argv[++i];
        else if(!strcmp(argv[i],"--prefix") && i+1<argc)prefix=argv[++i];
        else return usage("unknown or incomplete option");
    }
    if(command==0 || command>=argc || argv[command][0]!='/')return usage("program must be an absolute executable path after --");
    if(server && (server[0]!='/' || !prefix || prefix[0]!='/'))return usage("wine-server requires an absolute server path and explicit absolute prefix");
    if(prefix && prefix[0]!='/')return usage("prefix must be absolute");
    struct stat lease;
    if(fstat(STDIN_FILENO,&lease)!=0 || !S_ISREG(lease.st_mode) || lease.st_uid!=geteuid())return usage("stdin must be a regular lock file owned by this user");
    if(flock(STDIN_FILENO,LOCK_EX|LOCK_NB)!=0){perror("ReadySessionHost: prefix lease");return 73;}
    // The parent must close its handed-off descriptor WITHOUT explicit LOCK_UN.
    // This process owns fd0 until game plus exact-prefix wineserver have finished.
    if(prefix && setenv("WINEPREFIX",prefix,1)!=0){perror("ReadySessionHost: prefix environment");return 71;}
    struct sigaction action;memset(&action,0,sizeof(action));action.sa_handler=forward_signal;action.sa_flags=SA_RESTART;sigemptyset(&action.sa_mask);
    if(sigaction(SIGTERM,&action,NULL)!=0 || sigaction(SIGINT,&action,NULL)!=0){perror("ReadySessionHost: signal handlers");return 71;}
    struct sigaction ignore;memset(&ignore,0,sizeof(ignore));ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);sigaction(SIGHUP,&ignore,NULL);
    sigset_t blocked,oldmask;sigemptyset(&blocked);sigaddset(&blocked,SIGTERM);sigaddset(&blocked,SIGINT);sigprocmask(SIG_BLOCK,&blocked,&oldmask);
    pid_t child=spawn_program(&argv[command],1,&oldmask);
    if(child<0){sigprocmask(SIG_SETMASK,&oldmask,NULL);return spawn_error==ENOENT?127:spawn_error==EACCES?126:71;}
    child_group=(sig_atomic_t)child;
    sigprocmask(SIG_SETMASK,&oldmask,NULL);
    if(pending_signal)kill(-child,(int)pending_signal);
    int result=wait_for(child);
    // Do not risk signalling an unrelated future process group after the original leader is reaped.
    child_group=0;
    if(server){
        char *server_args[]={(char *)server,"-w",NULL};
        sigprocmask(SIG_BLOCK,&blocked,&oldmask);
        pid_t waiter=spawn_program(server_args,0,&oldmask);
        sigprocmask(SIG_SETMASK,&oldmask,NULL);
        if(waiter<0)return 71;
        int server_result=wait_for(waiter);
        if(result==0 && server_result!=0)result=server_result;
    }
    // No LOCK_UN: closing the last inherited reference releases the flock.
    close(STDIN_FILENO);
    return result;
}
