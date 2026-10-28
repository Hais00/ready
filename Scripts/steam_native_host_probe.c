/* SPDX-License-Identifier: GPL-3.0-only */
/* Independent offline loader/client probe. No Valve/GameNative headers or code,
 * real credentials, Internet access, game launch or Steam UI entrypoint.
 * Indexed methods are guarded against offsets in one inspected ARM64 image. */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <netinet/in.h>
#include <netdb.h>
#include <spawn.h>
#include <stdio.h>
#include <stdint.h>
#include <semaphore.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "steam_host_credential.h"
extern char **environ;
static FILE *events;
typedef struct {int32_t user,id;void *payload;int32_t size;} callback_message;
_Static_assert(sizeof(callback_message)==24 && offsetof(callback_message,payload)==8 && offsetof(callback_message,size)==16,"Measured ARM64 callback layout");
static void pump_callbacks(void *library,int pipe,unsigned long milliseconds) {
    typedef _Bool (*get_fn)(int,callback_message *);
    typedef void (*free_fn)(int);
    get_fn get=(get_fn)dlsym(library,"Steam_BGetCallback");
    free_fn release=(free_fn)dlsym(library,"Steam_FreeLastCallback");
    if(!get||!release)return;
    unsigned count=0;_Bool malformed=0;
    fprintf(events,"{\"callbackPump\":true,\"pipe\":%d,\"observations\":[",pipe);
    unsigned long ticks=milliseconds/50+1;
    for(unsigned long tick=0;tick<ticks;tick++) {
        callback_message message={0};
        for(unsigned batch=0;batch<128 && get(pipe,&message);batch++) {
            if(count<128)fprintf(events,"%s{\"id\":%d,\"size\":%d}",count?",":"",message.id,message.size);
            count++;
            malformed=message.size<0||message.size>1024*1024||(message.size>0&&!message.payload);
            /* Opaque payloads never enter diagnostics. Release on this thread
             * before the next get, including malformed-message handling. */
            release(pipe);
            if(malformed)break;
        }
        if(malformed)break;
        if(milliseconds)usleep(50000);
    }
    fprintf(events,"],\"count\":%u,\"malformed\":%s}\n",count,malformed?"true":"false");fflush(events);
}
static void *checked_method(void *object,size_t slot,uintptr_t offset,void *image) {
    if(!object)return NULL;
    void *function=(*(void ***)object)[slot];Dl_info info={0};
    if(!dladdr(function,&info)||info.dli_fbase!=image || (uintptr_t)function-(uintptr_t)image!=offset)return NULL;
    return function;
}

static int denied(int error) { return error==EPERM || error==EACCES; }
static int public_network_probe(void) {
    alarm(10);
    struct addrinfo hints={0},*addresses=NULL;
    hints.ai_family=AF_INET;hints.ai_socktype=SOCK_STREAM;
    int resolution=getaddrinfo("api.steampowered.com","443",&hints,&addresses),connected=0;
    for(struct addrinfo *item=addresses;!resolution&&item&&!connected;item=item->ai_next) {
        int fd=socket(item->ai_family,item->ai_socktype,item->ai_protocol);if(fd<0)continue;
        fcntl(fd,F_SETFL,O_NONBLOCK);
        int rc=connect(fd,item->ai_addr,item->ai_addrlen);
        if(rc==0)connected=1;
        else if(errno==EINPROGRESS) {
            struct pollfd wait={fd,POLLOUT,0};int error=0;socklen_t length=sizeof error;
            if(poll(&wait,1,2000)>0&&getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length)==0&&!error)connected=1;
        }
        close(fd);
    }
    if(addresses)freeaddrinfo(addresses);
    printf("{\"publicDNSResolved\":%s,\"publicTCPConnected\":%s,\"accountAuthenticated\":false,\"ValveClientLoaded\":false}\n",resolution==0?"true":"false",connected?"true":"false");
    return connected?0:4;
}
static int controls(const char *read_path,const char *write_path) {
    int fd=open(read_path,O_RDONLY);int read_denied=fd<0&&denied(errno);if(fd>=0)close(fd);
    fd=open(write_path,O_WRONLY|O_CREAT|O_EXCL,0600);int write_denied=fd<0&&denied(errno);if(fd>=0)close(fd);
    int socket_fd=socket(AF_INET,SOCK_STREAM,0);int socket_error=socket_fd<0?errno:0;struct sockaddr_in address={0};
    address.sin_family=AF_INET;address.sin_port=htons(9);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    int connected=socket_fd<0?-1:connect(socket_fd,(struct sockaddr *)&address,sizeof(address));
    int network_denied=socket_fd<0?denied(socket_error):(connected<0&&denied(errno));if(socket_fd>=0)close(socket_fd);
    pid_t child=0;char *args[]={"/usr/bin/true",NULL};
    int error=posix_spawn(&child,args[0],NULL,NULL,args,environ);int exec_denied=denied(error);
    if(!error)waitpid(child,NULL,0);
    char name[32];snprintf(name,sizeof name,"/ReadyControl%d",getpid());
    fd=shm_open(name,O_RDWR|O_CREAT|O_EXCL,0600);int shm_denied=fd<0&&denied(errno);
    if(fd>=0){close(fd);shm_unlink(name);}
    sem_t *sem=sem_open(name,O_CREAT|O_EXCL,0600,1);int sem_denied=sem==SEM_FAILED&&denied(errno);
    if(sem!=SEM_FAILED){sem_close(sem);sem_unlink(name);}
    const char *unix_path=getenv("READY_STEAM_CONTROL_UNIX");int unix_denied=0;
    if(unix_path) {
        struct sockaddr_un unix_address={0};unix_address.sun_family=AF_UNIX;unix_address.sun_len=sizeof unix_address;
        if(strlen(unix_path)<sizeof unix_address.sun_path) {
            strcpy(unix_address.sun_path,unix_path);fd=socket(AF_UNIX,SOCK_STREAM,0);
            if(fd<0)unix_denied=denied(errno);
            else {int rc=connect(fd,(struct sockaddr *)&unix_address,sizeof unix_address);unix_denied=rc<0&&denied(errno);close(fd);}
        }
    }
    printf("{\"sandboxControls\":true,\"readDenied\":%s,\"writeDenied\":%s,\"networkDenied\":%s,\"otherExecDenied\":%s,\"unscopedSharedMemoryDenied\":%s,\"unscopedSemaphoreDenied\":%s,\"unapprovedUnixSocketDenied\":%s}\n",
        read_denied?"true":"false",write_denied?"true":"false",network_denied?"true":"false",exec_denied?"true":"false",shm_denied?"true":"false",sem_denied?"true":"false",unix_denied?"true":"false");
    return read_denied&&write_denied&&network_denied&&exec_denied&&shm_denied&&sem_denied&&unix_denied?0:3;
}

static void string_json(const char *s) {
    fputc('"',events);
    for (const unsigned char *p=(const unsigned char *)s; *p; ++p) {
        if (*p=='"' || *p=='\\') fputc('\\',events);
        if (*p<32) fprintf(events,"\\u%04x",*p); else fputc(*p,events);
    }
    fputc('"',events);
}

int main(int argc,char **argv) {
    if(argc==4 && !strcmp(argv[1],"--controls"))return controls(argv[2],argv[3]);
    if(argc==2 && !strcmp(argv[1],"--public-network-probe"))return public_network_probe();
    if(argc==2 && !strcmp(argv[1],"--validate-auth-frame")) {
        ready_steam_credential credential;
        int valid=ready_steam_credential_read(STDIN_FILENO,&credential)==0;
        ready_steam_credential_clear(&credential);
        printf("{\"frameStructurallyValid\":%s,\"authenticated\":false}\n",valid?"true":"false");
        return valid?0:65;
    }
    if (argc<2 || argc>5) return 64;
    if(argc>=4 && strcmp(argv[3],"--create-user") && strcmp(argv[3],"--connect-user"))return 64;
    if(argc==5 && strcmp(argv[4],"--invalid-login") && strcmp(argv[4],"--authenticate") && strcmp(argv[4],"--cached-login"))return 64;
    _Bool cached_login=argc==5&&!strcmp(argv[4],"--cached-login");
    _Bool real_auth=argc==5&&(!strcmp(argv[4],"--authenticate")||cached_login);
    _Bool authenticated=0,ownership=0;
    if(!getenv("READY_STEAM_NATIVE_REEXEC")) {
        /* sandbox-exec strips inherited DYLD settings. Re-enter only this
         * exact allowed worker, so optional Valve code dependencies and our
         * worker-local state adapter resolve without changing any system app. */
        char directory[PATH_MAX];
        if(strlen(argv[1])>=sizeof directory)return 64;
        strcpy(directory,argv[1]);char *slash=strrchr(directory,'/');if(!slash)return 64;*slash=0;
        setenv("DYLD_LIBRARY_PATH",directory,1);
        const char *shim=getenv("READY_STEAM_STATE_FS_LIBRARY");
        const char *ipc=getenv("READY_STEAM_IPC_LIBRARY");
        char injected[PATH_MAX*2+2];
        if(shim && *shim) {
            if(snprintf(injected,sizeof injected,"%s%s%s",shim,ipc&&*ipc?":":"",ipc?ipc:"")>=(int)sizeof injected)return 64;
            setenv("DYLD_INSERT_LIBRARIES",injected,1);
        }
        setenv("READY_STEAM_NATIVE_REEXEC","1",1);
        execv(argv[0],argv);return 74;
    }
    const char *event_path=getenv("READY_STEAM_EVENT_FILE");
    if(!event_path || event_path[0]!='/')return 64;
    int event_fd=open(event_path,O_WRONLY|O_APPEND|O_NOFOLLOW|O_CLOEXEC);
    if(event_fd<0 || !(events=fdopen(event_fd,"a")))return 73;
    alarm(40);
    ready_steam_credential credential={0};
    if(real_auth && ready_steam_credential_read(STDIN_FILENO,&credential)) {
        fputs("{\"error\":\"invalid_private_credential_frame\",\"authenticated\":false}\n",events);fflush(events);return 65;
    }
    if(cached_login && strcmp(credential.token,"READY_USE_GENUINE_CACHED_LOGIN")) {
        ready_steam_credential_clear(&credential);return 65;
    }
    fprintf(events,"{\"readySteamProbeStage\":\"before-dlopen\",\"pid\":%d}\n",getpid()); fflush(events);
    void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!library) {
        fprintf(events,"{\"readySteamProbe\":true,\"loaded\":false,\"error\":");
        string_json(dlerror()); fputs("}\n",events); return 2;
    }
    const char *names[]={"CreateInterface","Steam_CreateSteamPipe","Steam_BReleaseSteamPipe",
        "Steam_CreateGlobalUser","Steam_CreateLocalUser","Steam_ConnectToGlobalUser",
        "Steam_ReleaseUser","Steam_LogOn","Steam_LogOff","Steam_BLoggedOn",
        "SteamAPI_RunCallbacks","Steam_BGetCallback","Steam_FreeLastCallback",NULL};
    fprintf(events,"{\"readySteamProbe\":true,\"loaded\":true,\"architecture\":\"%s\",\"exports\":{",
#if defined(__arm64__)
        "arm64"
#else
        "x86_64"
#endif
    );
    for (int i=0;names[i];i++) {
        if(i)fputc(',',events); string_json(names[i]); fprintf(events,":%s",dlsym(library,names[i])?"true":"false");
    }
    fprintf(events,"},\"factoryRequested\":%s",argc>=3?"true":"false"); fflush(events);
    if (argc>=3) {
        /* Public CreateInterface C factory convention. The requested string is
         * recorded verbatim; methods below require the pinned image layout. */
        typedef void *(*factory_fn)(const char *,int *);
        factory_fn factory=(factory_fn)dlsym(library,"CreateInterface");
        int result=-1;void *object=factory?factory(argv[2],&result):NULL;
        fprintf(events,",\"interface\":");string_json(argv[2]);
        fprintf(events,",\"factoryReturnCode\":%d,\"factoryReturnedObject\":%s",result,object?"true":"false");
    }
    fputs("}\n",events);fflush(events);
    if(argc>=4) {
        /* Only enabled by the driver for the measured ARM64 image/hash. The
         * one-pointer/32-bit-handle shape was recovered from that image's own
         * exported wrapper, not inferred from the Android binary's vtable. */
        typedef int (*create_user_fn)(int *);
        create_user_fn create_user=(create_user_fn)dlsym(library,"Steam_CreateGlobalUser");
        fprintf(stderr,"{\"readySteamProbeStage\":\"before-create-global-user\",\"loaded\":true}\n");fflush(stderr);
        int pipe=0,user=0;_Bool connecting=!strcmp(argv[3],"--connect-user");
        if(connecting) {
            typedef int (*create_pipe_fn)(void);
            typedef int (*connect_user_fn)(int);
            create_pipe_fn create_pipe=(create_pipe_fn)dlsym(library,"Steam_CreateSteamPipe");
            connect_user_fn connect_user=(connect_user_fn)dlsym(library,"Steam_ConnectToGlobalUser");
            pipe=create_pipe?create_pipe():0;
            if(pipe>0&&connect_user)user=connect_user(pipe);
        } else user=create_user?create_user(&pipe):0;
        fprintf(events,"{\"globalUserAttempted\":%s,\"connectUserAttempted\":%s,\"globalUserHandle\":%d,\"pipeHandle\":%d",connecting?"false":"true",connecting?"true":"false",user,pipe);
        if(user>0 && pipe>0) {
            typedef _Bool (*logged_on_fn)(int,int);
            logged_on_fn logged_on=(logged_on_fn)dlsym(library,"Steam_BLoggedOn");
            int status=logged_on?logged_on(user,pipe):-1;
            fprintf(events,",\"loggedOnStatus\":%d",status);
            /* Public interface route, measured on this exact image. Primitive
             * ABI facts only; no Valve headers, implementation or licence
             * decisions are reproduced. Offline results are not ownership. */
            typedef void *(*factory_fn)(const char *,int *);
            typedef void *(*get_fn)(void *,int,int,const char *);
            typedef _Bool (*user_bool_fn)(void *);
            typedef uint64_t (*identity_fn)(void *);
            typedef _Bool (*subscribed_fn)(void *,uint32_t);
            factory_fn factory=(factory_fn)dlsym(library,"CreateInterface");
            Dl_info module={0};dladdr((void *)factory,&module);int rc=-1;
            void *client=factory?factory("SteamClient023",&rc):NULL;
            get_fn get_user=(get_fn)checked_method(client,5,0x7d9f18,module.dli_fbase);
            get_fn get_apps=(get_fn)checked_method(client,15,0x7da034,module.dli_fbase);
            void *public_user=get_user?get_user(client,user,pipe,"SteamUser023"):NULL;
            void *public_apps=get_apps?get_apps(client,user,pipe,"STEAMAPPS_INTERFACE_VERSION008"):NULL;
            user_bool_fn user_status=(user_bool_fn)checked_method(public_user,1,0x806114,module.dli_fbase);
            identity_fn identity=(identity_fn)checked_method(public_user,2,0x806124,module.dli_fbase);
            subscribed_fn subscription=(subscribed_fn)checked_method(public_apps,6,0x7d3bd4,module.dli_fbase);
            fprintf(events,",\"publicUserInterface\":%s,\"publicAppsInterface\":%s,\"publicMethodsMatchExactImage\":%s",
                public_user?"true":"false",public_apps?"true":"false",user_status&&identity&&subscription?"true":"false");
            if(user_status&&identity&&subscription) {
                fprintf(events,",\"publicLoggedOn\":%s,\"publicSteamID\":%llu,\"offlineAppProbeID\":480,\"offlineSubscriptionObservation\":%s",
                    user_status(public_user)?"true":"false",(unsigned long long)identity(public_user),subscription(public_apps,480)?"true":"false");
            }
            if(argc==5) {
                /* Synthetic mode only uses deliberate invalid public values.
                 * Online mode accepts a bounded private stdin frame, never
                 * an argument/environment credential or decoded JWT identity. */
                typedef void *(*internal_user_fn)(void *,int,int);
                typedef void (*set_info_fn)(void *,const char *,const char *,_Bool);
                typedef void (*set_token_fn)(void *,const char *,const char *);
                typedef uint32_t (*log_on_fn)(void *,uint64_t);
                void *engine=factory("CLIENTENGINE_INTERFACE_VERSION005",&rc);
                internal_user_fn get_internal=(internal_user_fn)checked_method(engine,8,0xa0fd38,module.dli_fbase);
                void *internal=get_internal?get_internal(engine,user,pipe):NULL;
                set_info_fn set_info=(set_info_fn)checked_method(internal,54,0x8a69ec,module.dli_fbase);
                set_token_fn set_token=(set_token_fn)checked_method(internal,56,0x8a6ccc,module.dli_fbase);
                log_on_fn log_on=(log_on_fn)checked_method(internal,1,0x8a15cc,module.dli_fbase);
                _Bool methods=set_info&&set_token&&log_on&&user_status&&identity;
                fprintf(events,",\"loginMethodsMatchExactImage\":%s",methods?"true":"false");fflush(events);
                if(methods) {
                    uint64_t expected_id=real_auth?credential.steam_id:UINT64_C(76561197960265728);
                    uint32_t app_id=real_auth?credential.app_id:480;
                    uint32_t result=0;_Bool logon_attempted=0;
                    if(cached_login) {
                        typedef _Bool (*has_cached_fn)(void *,const char *);
                        typedef _Bool (*select_cached_fn)(void *,const char *,_Bool);
                        has_cached_fn has_cached=(has_cached_fn)checked_method(internal,49,0x8a623c,module.dli_fbase);
                        select_cached_fn select_cached=(select_cached_fn)checked_method(internal,50,0x8a63b8,module.dli_fbase);
                        _Bool available=has_cached&&has_cached(internal,credential.account);
                        _Bool selected=available&&select_cached&&select_cached(internal,credential.account,1);
                        fprintf(events,",\"cachedLoginMethodsMatchExactImage\":%s,\"genuinePrivateCachedCredentialsAvailable\":%s,\"genuineCachedAccountSelected\":%s",has_cached&&select_cached?"true":"false",available?"true":"false",selected?"true":"false");
                        /* The structural sentinel is NEVER a login token. Only
                         * Valve's actual cached-credential path is invoked. */
                        if(selected){result=log_on(internal,expected_id);logon_attempted=1;}
                    } else {
                        /* The inspected token-seeding caller passes true here;
                         * real credentials remain in this owned private state. */
                        set_info(internal,real_auth?credential.account:"ready_offline_invalid_account","",real_auth);
                        set_token(internal,real_auth?credential.token:"ready.invalid.synthetic.token",real_auth?credential.account:"ready_offline_invalid_account");
                        result=log_on(internal,expected_id);logon_attempted=1;
                    }
                    ready_steam_credential_clear(&credential);
                    /* A successful dispatch is not a successful login. */
                    fprintf(events,",\"logOnAttempted\":%s,\"logOnDispatchResult\":%u",logon_attempted?"true":"false",result);
                    if(real_auth) {
                        typedef _Bool (*get_callback_fn)(int,callback_message *);
                        typedef void (*free_callback_fn)(int);
                        get_callback_fn get=(get_callback_fn)dlsym(library,"Steam_BGetCallback");
                        free_callback_fn release=(free_callback_fn)dlsym(library,"Steam_FreeLastCallback");
                        unsigned callbacks=0;_Bool malformed=0;
                        for(unsigned tick=0;logon_attempted&&get&&release&&tick<500;tick++) {
                            callback_message message={0};
                            for(unsigned batch=0;batch<128&&get(pipe,&message);batch++) {
                                callbacks++;malformed=message.size<0||message.size>1024*1024||(message.size>0&&!message.payload);
                                release(pipe);if(malformed)break;
                            }
                            authenticated=user_status(public_user)&&identity(public_user)==expected_id;
                            ownership=authenticated&&subscription&&subscription(public_apps,app_id);
                            if(malformed||(authenticated&&ownership))break;
                            usleep(50000);
                        }
                        fprintf(events,",\"onlineCallbackCount\":%u,\"callbackMalformed\":%s,\"authenticatedIdentityMatches\":%s,\"genuineSubscriptionObserved\":%s,\"appID\":%u",
                            callbacks,malformed?"true":"false",authenticated?"true":"false",ownership?"true":"false",app_id);
                        if(malformed){authenticated=0;ownership=0;}
                    } else fprintf(events,",\"afterInvalidLoginLoggedOn\":%s,\"afterInvalidLoginSteamID\":%llu",
                        user_status(public_user)?"true":"false",(unsigned long long)identity(public_user));
                }
            }
        }
        fputs("}\n",events);fflush(events);
        const char *hold=getenv("READY_STEAM_PROBE_HOLD_MS");
        unsigned long milliseconds=0;
        if(hold) {
            char *end=NULL;unsigned long candidate=strtoul(hold,&end,10);
            if(end&&!*end&&candidate<=30000)milliseconds=candidate;
        }
        if(pipe>0)pump_callbacks(library,pipe,milliseconds);
        if(user>0 && pipe>0) {
            typedef void (*release_user_fn)(int,int);
            typedef _Bool (*release_pipe_fn)(int);
            release_user_fn release_user=(release_user_fn)dlsym(library,"Steam_ReleaseUser");
            release_pipe_fn release_pipe=(release_pipe_fn)dlsym(library,"Steam_BReleaseSteamPipe");
            /* Export wrapper and engine call chain independently establish
             * (pipe,user), then the single-pipe release; no guessed destructor. */
            if(release_user&&release_pipe) {
                release_user(pipe,user);
                _Bool released=release_pipe(pipe);
                fprintf(events,"{\"releasedUser\":true,\"releasedPipe\":%s}\n",released?"true":"false");fflush(events);
            }
        }
    }
    fprintf(events,"{\"loadedImages\":[");
    for(uint32_t i=0;i<_dyld_image_count();i++){if(i)fputc(',',events);string_json(_dyld_get_image_name(i));}
    fprintf(events,"],\"authenticated\":%s,\"genuineSubscriptionObserved\":%s,\"gameCompatibilityVerified\":false}\n",authenticated?"true":"false",ownership?"true":"false");fflush(events);
    ready_steam_credential_clear(&credential);
    /* Exiting the owned worker is the lifetime boundary. Avoid pretending an
     * unknown private singleton has a public destruction ABI. */
    _exit(real_auth&&!(authenticated&&ownership)?5:0);
}
