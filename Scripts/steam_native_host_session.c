/* SPDX-License-Identifier: GPL-3.0-only */
/* Persistent OWN host. Reuses the measured bootstrap, never a Steam UI entry.
 * The launcher must supply private per-profile filesystem/IPC sandboxing and
 * read-only pinned images. This worker does not grant game authorization. */
#define READY_STEAM_HOST_SESSION 1
#define main ready_steam_native_bootstrap
#include "steam_native_host_probe.c"
#undef main
#include <CommonCrypto/CommonDigest.h>
static int ready_session_number(const char *s) {
    if(!s||!*s)return -1;char *end;errno=0;long n=strtol(s,&end,10);
    return errno||*end||n<1||n>INT_MAX?-1:(int)n;
}
static int ready_session_image(const char *path) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);struct stat st;
    if(fd<0)return 0;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)){close(fd);return 0;}
#ifdef READY_STEAM_HOST_SESSION_FIXTURE
    close(fd);return 1;
#else
#if !defined(__arm64__)
    close(fd);return 0; /* These ABI offsets are proved only for ARM64 b9. */
#endif
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char bytes[65536],digest[32];ssize_t n;
    while((n=read(fd,bytes,sizeof bytes))>0)CC_SHA256_Update(&ctx,bytes,(CC_LONG)n);
    close(fd);if(n<0)return 0;CC_SHA256_Final(digest,&ctx);char hex[65];
    for(unsigned i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return !strcmp(hex,"b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd");
#endif
}
static int ready_session_endpoint(const char *value) {
    if(!value||strncmp(value,"127.0.0.1:",10)||!value[10])return 0;
    unsigned port=0;for(const unsigned char *p=(const unsigned char *)value+10;*p;p++){if(*p<'0'||*p>'9')return 0;port=port*10+*p-'0';if(port>65535)return 0;}return port>0;
}
static int ready_session_environment(const char *private_name) {
    const char *ns=getenv("READY_STEAM_IPC_NAMESPACE"),*master=getenv("steam_master_ipc_name_override"),*service=getenv("SteamClientService");
    if(!ns||strlen(ns)!=32||!ready_session_endpoint(master)||!ready_session_endpoint(service)||!strcmp(master,service))return 0;
    for(unsigned i=0;i<32;i++)if(!((ns[i]>='0'&&ns[i]<='9')||(ns[i]>='a'&&ns[i]<='f')))return 0;
    snprintf(ready_session_private_name,sizeof ready_session_private_name,"app.ready.steam.ipctool.%s",ns);
    if(strcmp(private_name,ready_session_private_name))return 0;
    strcpy(ready_session_namespace,ns);snprintf(ready_session_master_endpoint,sizeof ready_session_master_endpoint,"%s",master);snprintf(ready_session_service_endpoint,sizeof ready_session_service_endpoint,"%s",service);
#ifndef READY_STEAM_HOST_SESSION_FIXTURE
    const char *keys[]={"READY_STEAM_STATE_FS_LIBRARY","READY_STEAM_IPC_LIBRARY","READY_STEAM_ORIGINAL_STATE_ROOT","READY_STEAM_PRIVATE_STATE_ROOT",NULL};
    for(unsigned i=0;keys[i];i++){const char *p=getenv(keys[i]);if(!p||p[0]!='/')return 0;}
#endif
    return 1;
}
int main(int argc,char **argv) {
    const char *library=NULL,*mode=NULL,*discovery=NULL,*service=NULL,*sdk=NULL;int life=-1,event=-1,health=-1;
    if((argc!=16&&argc!=18)||strcmp(argv[1],"--host-session"))return 64;
    for(int i=2;i+1<argc;i+=2) {
        const char *key=argv[i],*value=argv[i+1];
        if(!strcmp(key,"--library")&&!library)library=value;
        else if(!strcmp(key,"--mode")&&!mode)mode=value;
        else if(!strcmp(key,"--lifeline-fd")&&life<0)life=ready_session_number(value);
        else if(!strcmp(key,"--events-fd")&&event<0)event=ready_session_number(value);
        else if(!strcmp(key,"--game-health-fd")&&health<0)health=ready_session_number(value);
        else if(!strcmp(key,"--discovery-library")&&!discovery)discovery=value;
        else if(!strcmp(key,"--discovery-service")&&!service)service=value;
        else if(!strcmp(key,"--sdk")&&!sdk)sdk=value;
        else return 64;
    }
    if(!library||!mode||!discovery||!service||!sdk||life<3||event<1||life==event||(!strcmp(mode,"cached")?0:strcmp(mode,"credentials")))return 64;
    if(!ready_session_environment(service))return 64;
    /* No arbitrary library can opt itself into the measured production ABI. */
    if(!ready_session_image(library))return 67;
    if(!getenv("READY_STEAM_NATIVE_REEXEC")) {
        char directory[PATH_MAX],injected[PATH_MAX*2+2];
        if(strlen(library)>=sizeof directory)return 64;strcpy(directory,library);
        char *slash=strrchr(directory,'/');if(!slash)return 64;*slash=0;
        setenv("DYLD_LIBRARY_PATH",directory,1);
        const char *fs=getenv("READY_STEAM_STATE_FS_LIBRARY"),*ipc=getenv("READY_STEAM_IPC_LIBRARY");
        if(fs&&*fs) {
            if(snprintf(injected,sizeof injected,"%s%s%s",fs,ipc&&*ipc?":":"",ipc?ipc:"")>=(int)sizeof injected)return 64;
            setenv("DYLD_INSERT_LIBRARIES",injected,1);
        }
        setenv("READY_STEAM_NATIVE_REEXEC","1",1);execv(argv[0],argv);return 74;
    }
    if(argc==18&&health<3)return 64;
    if(health>=0){
        struct stat info;int flags=fcntl(health,F_GETFL);
        if(health==life||health==event||flags<0||fstat(health,&info)||!S_ISFIFO(info.st_mode)||info.st_uid!=geteuid()||(flags&O_ACCMODE)!=O_WRONLY||fcntl(health,F_SETFD,FD_CLOEXEC))return 65;
        atomic_store(&ready_session_health,health);
    }
    event=fcntl(event,F_DUPFD_CLOEXEC,5);if(event<0)return 65;
    int null=open("/dev/null",O_WRONLY);if(null<0)return 73;
    if(dup2(null,STDOUT_FILENO)<0||dup2(null,STDERR_FILENO)<0)return 73;if(null>2)close(null);
    if(ready_session_begin(life,event))return 65;
    if(setenv("READY_STEAM_DISCOVERY_LIBRARY",discovery,1)||setenv("READY_STEAM_DISCOVERY_SERVICE",service,1)||setenv("READY_STEAM_DISCOVERY_SDK",sdk,1))return 73;
    char *bootstrap[]={argv[0],(char *)library,"CLIENTENGINE_INTERFACE_VERSION005","--create-user",!strcmp(mode,"cached")?"--cached-login":"--authenticate",NULL};
    return ready_steam_native_bootstrap(5,bootstrap);
}
