// SPDX-License-Identifier: GPL-3.0-only
// A minimal native lock keeper. It never parses a shell command string or kills globally.
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <sys/proc.h>
#include <libproc.h>
#include <limits.h>
#include <time.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include "InstallationLease.h"
#include "SteamSessionLease.h"

static volatile sig_atomic_t child_group=0;
static volatile sig_atomic_t pending_signal=0;
static int spawn_error=0;
static int steam_bootstrap=0;
static const char *presentation_shim=NULL;
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
    fprintf(stderr,"usage: ReadySessionHost [--wine-server /path/wineserver --prefix /path/prefix] [--installation /absolute/root] [--steam-bootstrap] [--presentation-shim /path/library --presentation-shim-sha256 digest] -- /path/program [args...]\n");
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
// proc_listpids includes zombies. Request BSD info with arg=1 as required by
// Darwin to inspect them too; arg=0 returns ESRCH for a waitable zombie.
static int group_snapshot(pid_t group,pid_t **pids,size_t *count) {
    errno=0;
    int bytes=proc_listpids(PROC_PGRP_ONLY,(uint32_t)group,NULL,0);
    if(bytes<=0)return -1;
    int capacity=bytes>128?bytes:128;
    for(;;){
        pid_t *list=malloc((size_t)capacity);if(!list){errno=ENOMEM;return -1;}
        errno=0;
        int used=proc_listpids(PROC_PGRP_ONLY,(uint32_t)group,list,capacity);
        if(used<0 || (used==0 && errno) || used%(int)sizeof(pid_t)){
            free(list);if(!errno)errno=EIO;return -1;
        }
        // An exact fit may be truncated. Never infer completion from it.
        if(used>=capacity){free(list);if(capacity>INT_MAX/2){errno=ENOMEM;return -1;}capacity*=2;continue;}
        *pids=list;*count=(size_t)used/sizeof(pid_t);return 0;
    }
}
static int group_has_only_zombies(pid_t group) {
    pid_t *first=NULL,*second=NULL;size_t count=0,again=0;int result=0;
    struct proc_bsdinfo *identities=NULL;
    if(group_snapshot(group,&first,&count)<0)return -1;
    if(count==0){errno=EAGAIN;result=-1;goto finish;}
    identities=calloc(count,sizeof(*identities));
    if(!identities){errno=ENOMEM;result=-1;goto finish;}
    int anchored=0;
    for(size_t i=0;i<count;i++){
        struct proc_bsdinfo *info=&identities[i];
        errno=0;
        if(proc_pidinfo(first[i],PROC_PIDTBSDINFO,1,info,sizeof(*info))!=(int)sizeof(*info)){
            result=errno==ESRCH?0:-1;goto finish;
        }
        if(info->pbi_pid!=(uint32_t)first[i] || info->pbi_pgid!=(uint32_t)group || info->pbi_status!=SZOMB)goto finish;
        if(first[i]==group && info->pbi_ppid==(uint32_t)getpid())anchored=1;
    }
    if(!anchored){errno=EAGAIN;result=-1;goto finish;}
    if(group_snapshot(group,&second,&again)<0){result=-1;goto finish;}
    // A member may fork between list and BSD-info queries, then become a zombie.
    // Every member in this second snapshot must be the SAME zombie observed
    // before it: a zombie cannot fork or become live again. Start times prevent
    // a reaped descendant's PID reuse from satisfying this comparison.
    anchored=0;
    for(size_t i=0;i<again;i++){
        size_t j=0;while(j<count && first[j]!=second[i])j++;
        if(j==count)goto finish;
        struct proc_bsdinfo info;errno=0;
        if(proc_pidinfo(second[i],PROC_PIDTBSDINFO,1,&info,sizeof(info))!=(int)sizeof(info)){
            result=errno==ESRCH?0:-1;goto finish;
        }
        if(info.pbi_pid!=(uint32_t)second[i] || info.pbi_pgid!=(uint32_t)group || info.pbi_status!=SZOMB ||
           info.pbi_start_tvsec!=identities[j].pbi_start_tvsec || info.pbi_start_tvusec!=identities[j].pbi_start_tvusec)goto finish;
        if(second[i]==group && info.pbi_ppid==(uint32_t)getpid())anchored=1;
    }
    if(!anchored){errno=EAGAIN;result=-1;goto finish;}
    result=1;
finish:
    free(identities);free(first);free(second);return result;
}
static void group_retry_pause(void) {
    struct timespec remaining={0,50000000};
    while(nanosleep(&remaining,&remaining)<0 && errno==EINTR){}
}
static int wait_for_game(pid_t child,int native,const sigset_t *blocked) {
    siginfo_t exited;memset(&exited,0,sizeof(exited));int waited;
    do{waited=waitid(P_PID,(id_t)child,&exited,WEXITED|WNOWAIT);}while(waited<0 && errno==EINTR);
    if(waited<0 || exited.si_pid!=child){
        // An unavailable anchor cannot safely be used for group signals. Keep
        // the leases indefinitely rather than assert that a game has finished.
        perror("ReadySessionHost: waitable game identity unavailable; retaining leases");
        sigset_t mask;sigprocmask(SIG_BLOCK,blocked,&mask);child_group=0;sigprocmask(SIG_SETMASK,&mask,NULL);
        for(;;)group_retry_pause();
    }
    // WNOWAIT pins the leader PID/PGID until all native group members are dead.
    // Voluntary setpgid/setsid escape and LaunchServices-owned processes are not
    // containment guarantees; this keeper supervises the original group only.
    if(native){
        int warned=0;
        for(;;){
            int state=group_has_only_zombies(child);if(state==1)break;
            if(state<0 && !warned){perror("ReadySessionHost: native group uncertain; retaining leases");warned=1;}
            group_retry_pause();
        }
    }
    // Clear the signal target BEFORE reaping the reserved leader. A signal must
    // never reach a later, unrelated group which reused this numeric identity.
    sigset_t mask;sigprocmask(SIG_BLOCK,blocked,&mask);child_group=0;
    int result=wait_for(child);
    sigprocmask(SIG_SETMASK,&mask,NULL);
    return result;
}
// Steam-only cancellation never abandons a live native group or its leases.
// Both direct-child lifetime and WNOWAIT pin the identity before any signal.
static double monotonic_seconds(void) {
    struct timespec now;if(clock_gettime(CLOCK_MONOTONIC,&now))return -1;
    return (double)now.tv_sec+(double)now.tv_nsec/1000000000.0;
}
static int wait_for_steam_game(pid_t child,int health,const sigset_t *blocked) {
    int leader_exited=0,stopping=0,killed=0,dependency_failed=0,warned=0;double deadline=0;
    for(;;){
        if(!leader_exited){
            siginfo_t status;memset(&status,0,sizeof status);
            int rc=waitid(P_PID,(id_t)child,&status,WEXITED|WNOWAIT|WNOHANG);
            if(rc<0&&errno!=EINTR){
                perror("ReadySessionHost: Steam game identity uncertain; retaining leases");
                sigset_t mask;sigprocmask(SIG_BLOCK,blocked,&mask);child_group=0;sigprocmask(SIG_SETMASK,&mask,NULL);
                for(;;)group_retry_pause();
            }
            if(rc==0&&status.si_pid==child)leader_exited=1;
        }
        if(leader_exited){
            int state=group_has_only_zombies(child);if(state==1)break;
            if(state<0&&!warned){perror("ReadySessionHost: Steam native group uncertain; retaining leases");warned=1;}
        }
        if(ready_steam_health_alive(health)!=1&&!stopping){
            dependency_failed=1;stopping=1;deadline=monotonic_seconds()+2;kill(-child,SIGTERM);
        }
        if(pending_signal&&!stopping){stopping=1;deadline=monotonic_seconds()+2;}
        if(stopping&&!killed){
            double now=monotonic_seconds();
            if(now<0||now>=deadline){kill(-child,SIGKILL);killed=1;}
        }
        group_retry_pause();
    }
    sigset_t mask;sigprocmask(SIG_BLOCK,blocked,&mask);child_group=0;
    int result=wait_for(child);sigprocmask(SIG_SETMASK,&mask,NULL);
    return dependency_failed?75:result;
}
static int steam_adapter_file(const char *path) {
    if(!path||path[0]!='/')return 0;char resolved[PATH_MAX];struct stat st;
    return realpath(path,resolved)&&!strcmp(path,resolved)&&lstat(path,&st)==0&&S_ISREG(st.st_mode)&&st.st_uid==geteuid()&&!(st.st_mode&0022);
}
static int steam_adapters_valid(const char *list) {
    if(!list||!*list)return 0;char *copy=strdup(list);if(!copy)return 0;
    unsigned count=0;int valid=1;char *part=copy;
    for(;;){char *colon=strchr(part,':');if(colon)*colon=0;
        if(!steam_adapter_file(part)){valid=0;break;}count++;
        if(!colon)break;part=colon+1;
    }
    free(copy);return valid&&count==3;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int presentation_file_valid(const char *path,const char *expected) {
    char canonical[PATH_MAX];struct stat before,after,named;
    if(!path||path[0]!='/'||!ready_steam_digest_valid(expected)||!realpath(path,canonical)||strcmp(path,canonical))return 0;
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return 0;int valid=0;
    if(fstat(fd,&before)||!S_ISREG(before.st_mode)||before.st_uid!=geteuid()||(before.st_mode&0022))goto finish;
    CC_SHA256_CTX context;CC_SHA256_Init(&context);unsigned char bytes[65536],digest[CC_SHA256_DIGEST_LENGTH];
    for(;;){ssize_t count=read(fd,bytes,sizeof bytes);if(count<0&&errno==EINTR)continue;if(count<0)goto finish;if(!count)break;CC_SHA256_Update(&context,bytes,(CC_LONG)count);}
    CC_SHA256_Final(digest,&context);char actual[65];for(unsigned i=0;i<sizeof digest;i++)snprintf(actual+i*2,3,"%02x",digest[i]);
    if(strcmp(actual,expected)||fstat(fd,&after)||lstat(path,&named))goto finish;
    valid=before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&before.st_size==after.st_size&&before.st_mode==after.st_mode&&before.st_uid==after.st_uid&&
        before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&
        before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec&&named.st_dev==after.st_dev&&named.st_ino==after.st_ino&&S_ISREG(named.st_mode);
finish:
    close(fd);return valid;
}
#pragma clang diagnostic pop
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
    if(game&&presentation_shim){
        const char *adapters=steam_bootstrap?getenv("READY_STEAM_ADAPTER_LIBRARIES"):NULL;
        if(steam_bootstrap&&!steam_adapters_valid(adapters)){free(environment);error=EINVAL;goto finish;}
        // The no-copy experiment must not create a separate guest overlay/HUD.
        if(asprintf(&injection,"DYLD_INSERT_LIBRARIES=%s%s%s",adapters?adapters:"",adapters?":":"",presentation_shim)<0){free(environment);error=ENOMEM;goto finish;}
        environment[used++]=injection;
    } else if(game&&steam_bootstrap){
        const char *adapters=getenv("READY_STEAM_ADAPTER_LIBRARIES");
        if(!steam_adapters_valid(adapters)||(overlay&&*overlay&&!steam_adapter_file(overlay))){free(environment);error=EINVAL;goto finish;}
        if(asprintf(&injection,"DYLD_INSERT_LIBRARIES=%s%s%s",adapters,overlay&&*overlay?":":"",overlay&&*overlay?overlay:"")<0){free(environment);error=ENOMEM;goto finish;}
        environment[used++]=injection;
    } else if(game && overlay && *overlay && stat(overlay,&st)==0 && S_ISREG(st.st_mode)){
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
    const char *server=NULL,*prefix=NULL,*installation=NULL,*installation_root=NULL;int command=0;
    const char *steam_executable_sha=NULL,*steam_sdk=NULL,*steam_sdk_sha=NULL;
    const char *presentation_sha=NULL;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--")){command=i+1;break;}
        if(!strcmp(argv[i],"--wine-server") && i+1<argc)server=argv[++i];
        else if(!strcmp(argv[i],"--prefix") && i+1<argc)prefix=argv[++i];
        else if(!strcmp(argv[i],"--installation") && i+1<argc)installation=argv[++i];
        else if(!strcmp(argv[i],"--installation-lock-root") && i+1<argc)installation_root=argv[++i];
        else if(!strcmp(argv[i],"--steam-bootstrap")&&!steam_bootstrap)steam_bootstrap=1;
        else if(!strcmp(argv[i],"--steam-executable-sha256")&&i+1<argc&&!steam_executable_sha)steam_executable_sha=argv[++i];
        else if(!strcmp(argv[i],"--steam-sdk")&&i+1<argc&&!steam_sdk)steam_sdk=argv[++i];
        else if(!strcmp(argv[i],"--steam-sdk-sha256")&&i+1<argc&&!steam_sdk_sha)steam_sdk_sha=argv[++i];
        else if(!strcmp(argv[i],"--presentation-shim")&&i+1<argc&&!presentation_shim)presentation_shim=argv[++i];
        else if(!strcmp(argv[i],"--presentation-shim-sha256")&&i+1<argc&&!presentation_sha)presentation_sha=argv[++i];
        else return usage("unknown or incomplete option");
    }
    if(command==0 || command>=argc || argv[command][0]!='/')return usage("program must be an absolute executable path after --");
    if(server && (server[0]!='/' || !prefix || prefix[0]!='/'))return usage("wine-server requires an absolute server path and explicit absolute prefix");
    if(prefix && prefix[0]!='/')return usage("prefix must be absolute");
    if(installation_root && !installation)return usage("installation-lock-root requires installation");
    if((presentation_shim!=NULL)!=(presentation_sha!=NULL)||
       (presentation_shim&&(!installation||server||presentation_shim[0]!='/'||!ready_steam_digest_valid(presentation_sha))))
        return usage("presentation requires native installation and both pinned shim fields");
    int image_arguments=(steam_executable_sha!=NULL)+(steam_sdk!=NULL)+(steam_sdk_sha!=NULL);
    if(image_arguments&&(!steam_bootstrap||image_arguments!=3||!installation||!ready_steam_digest_valid(steam_executable_sha)||!ready_steam_digest_valid(steam_sdk_sha)||steam_sdk[0]!='/'))return usage("Steam image bindings require native bootstrap, installation and all three canonical bindings");
    int steam_health=-1,steam_control=-1;
    if(steam_bootstrap){
        if(server)return usage("Steam bootstrap is native-only; Wine is not verified");
        if(ready_steam_receive_leases(&steam_health,&steam_control)){fprintf(stderr,"ReadySessionHost: invalid Steam lease bootstrap\n");return 65;}
    }
    struct stat lease;
    if(fstat(STDIN_FILENO,&lease)!=0 || !S_ISREG(lease.st_mode) || lease.st_uid!=geteuid())return usage("stdin must be a regular lock file owned by this user");
    if(flock(STDIN_FILENO,LOCK_EX|LOCK_NB)!=0){perror("ReadySessionHost: prefix lease");return 73;}
    // The parent must close its handed-off descriptor WITHOUT explicit LOCK_UN.
    // This process owns fd0 until game plus exact-prefix wineserver have finished.
    if(prefix && setenv("WINEPREFIX",prefix,1)!=0){perror("ReadySessionHost: prefix environment");return 71;}
    struct sigaction action;memset(&action,0,sizeof(action));action.sa_handler=forward_signal;action.sa_flags=SA_RESTART;sigemptyset(&action.sa_mask);
    if(sigaction(SIGTERM,&action,NULL)!=0 || sigaction(SIGINT,&action,NULL)!=0){perror("ReadySessionHost: signal handlers");return 71;}
    // An inherited SIG_IGN/SA_NOCLDWAIT would discard the leader's zombie and
    // destroy the identity reservation required by WNOWAIT.
    struct sigaction child_action;memset(&child_action,0,sizeof(child_action));child_action.sa_handler=SIG_DFL;sigemptyset(&child_action.sa_mask);
    if(sigaction(SIGCHLD,&child_action,NULL)!=0){perror("ReadySessionHost: child status disposition");return 71;}
    struct sigaction ignore;memset(&ignore,0,sizeof(ignore));ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);sigaction(SIGHUP,&ignore,NULL);
    sigset_t blocked,oldmask;sigemptyset(&blocked);sigaddset(&blocked,SIGTERM);sigaddset(&blocked,SIGINT);sigprocmask(SIG_BLOCK,&blocked,&oldmask);
    int *installation_fds=NULL;size_t installation_fd_count=0;
    if(installation){
        int lease_result=ready_installation_read_lease(installation,installation_root,&installation_fds,&installation_fd_count);
        if(lease_result){fprintf(stderr,"ReadySessionHost: installation lease %s\n",lease_result==73?"busy (download/update active)":"invalid or unsafe");return lease_result;}
    }
    // Only trusted CLI fields can select this library. Rehash AFTER admitting
    // the installation read lease and BEFORE Steam ACK or any child spawn.
    if(presentation_shim&&!presentation_file_valid(presentation_shim,presentation_sha)){
        fprintf(stderr,"ReadySessionHost: presentation shim binding invalid or changed\n");return 76;
    }
    if(steam_bootstrap){
        // Re-hash only AFTER the actual installation read lease is admitted.
        // This closes a cooperating downloader's selection/admission window.
        if(image_arguments&&!ready_steam_validate_game_images(installation,argv[command],steam_executable_sha,steam_sdk,steam_sdk_sha)){
            fprintf(stderr,"ReadySessionHost: Steam game image binding changed before admission\n");return 76;
        }
        if(!steam_adapters_valid(getenv("READY_STEAM_ADAPTER_LIBRARIES"))||ready_steam_health_alive(steam_health)!=1||ready_steam_acknowledge(steam_control)){
            fprintf(stderr,"ReadySessionHost: Steam dependency unavailable before launch\n");return 75;
        }
        close(steam_control);steam_control=-1;
        // An EOF racing this check is handled by the anchored post-spawn loop.
        if(ready_steam_health_alive(steam_health)!=1)return 75;
    }
    pid_t child=spawn_program(&argv[command],1,&oldmask);
    if(child<0){sigprocmask(SIG_SETMASK,&oldmask,NULL);return spawn_error==ENOENT?127:spawn_error==EACCES?126:71;}
    child_group=(sig_atomic_t)child;
    sigprocmask(SIG_SETMASK,&oldmask,NULL);
    if(pending_signal)kill(-child,(int)pending_signal);
    int result=steam_bootstrap?wait_for_steam_game(child,steam_health,&blocked):wait_for_game(child,server==NULL,&blocked);
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
    for(size_t i=0;i<installation_fd_count;i++)close(installation_fds[i]);
    free(installation_fds);
    if(steam_health>=0)close(steam_health);
    close(STDIN_FILENO);
    return result;
}
