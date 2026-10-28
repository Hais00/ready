// SPDX-License-Identifier: GPL-3.0-only
/* Independent game-API loader preparation. No Steamworks SDK header/code copied.
 * NEVER call this against a genuine library before an explicitly authorized,
 * isolated authenticated host context and independent child sandbox are ready.
 * dlopen itself executes external library initializers, even in exports mode.
 *
 * No game launch, Steam launch, account login, ownership replacement or file
 * creation is implemented. RestartAppIfNecessary is looked up, NEVER called.
 * SteamAppId/SteamGameId are supplied by the caller; HOME is never changed.
 * Root/parent must supervise this own child and audit actual loaded images/IPC.
 */
#define _DARWIN_C_SOURCE 1
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

typedef int32_t (*init_flat_fn)(char *); /* optional fixed-size diagnostic buffer; not emitted */
typedef bool (*init_fn)(void);
typedef bool (*running_fn)(void);
typedef void (*void_fn)(void);
typedef void *(*interface_fn)(void);
typedef bool (*logged_on_fn)(void *);
typedef uint64_t (*steam_id_fn)(void *);
typedef bool (*subscribed_fn)(void *,uint32_t);
static int report_fd=STDOUT_FILENO;
static void timed_out(int sig) {
    (void)sig;
    static const char message[]="{\"probeTimedOut\":true,\"restartCalled\":false,\"gameLaunchRequested\":false}\n";
    (void)write(report_fd,message,sizeof message-1);_exit(124);
}
static int refused(const char *code) {
    dprintf(report_fd,"{\"refused\":true,\"code\":\"%s\",\"restartCalled\":false,\"gameLaunchRequested\":false}\n",code);
    return 65;
}
static int hex(const char *s,size_t length) {
    if(!s||strlen(s)!=length)return 0;
    for(size_t i=0;i<length;i++)if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;
    return 1;
}
static uint64_t expected_identity(void) {
    const char *text=getenv("STEAMID");if(!text||!*text)return 0;
    for(const char *p=text;*p;p++)if(*p<'0'||*p>'9')return 0;
    errno=0;char *end=NULL;unsigned long long value=strtoull(text,&end,10);
    return errno||!end||*end?0:(uint64_t)value;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int file_hash(const char *path,char result[65]) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
    struct stat before,after;
    if(fstat(fd,&before)||!S_ISREG(before.st_mode)){close(fd);return -1;}
    CC_SHA256_CTX context;CC_SHA256_Init(&context);unsigned char buffer[8192],digest[32];ssize_t n;
    while((n=read(fd,buffer,sizeof buffer))!=0){if(n<0&&errno==EINTR)continue;if(n<0){close(fd);return -1;}CC_SHA256_Update(&context,buffer,(CC_LONG)n);}
    if(fstat(fd,&after)||before.st_size!=after.st_size||before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec||before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec){close(fd);return -1;}
    close(fd);CC_SHA256_Final(digest,&context);
    for(size_t i=0;i<sizeof digest;i++)snprintf(result+i*2,3,"%02x",digest[i]);return 0;
}
#pragma clang diagnostic pop
static int from_image(void *pointer,const char *expected) {
    if(!pointer)return 1;Dl_info info;char canonical[PATH_MAX];
    return dladdr(pointer,&info)&&info.dli_fname&&realpath(info.dli_fname,canonical)&&!strcmp(canonical,expected);
}
static double monotonic(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;return t.tv_sec+t.tv_nsec/1e9;}
static int quiet_library_console(void) {
    int saved=dup(STDOUT_FILENO);if(saved<0)return -1;
    report_fd=saved;(void)fcntl(saved,F_SETFD,FD_CLOEXEC);
    int sink=open("/dev/null",O_WRONLY|O_CLOEXEC);if(sink<0)return -1;
    int ok=dup2(sink,STDOUT_FILENO)>=0&&dup2(sink,STDERR_FILENO)>=0;
    close(sink);return ok?0:-1;
}
int main(int argc,char **argv) {
    const char *library=NULL,*code_root=NULL,*expected=NULL,*mode="exports";unsigned callback_ms=250;bool allowed=false,fixture=false;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--allow-sdk-execution"))allowed=true;
        else if(!strcmp(argv[i],"--fixture-only"))fixture=true;
        else if(i+1<argc&&!strcmp(argv[i],"--library"))library=argv[++i];
        else if(i+1<argc&&!strcmp(argv[i],"--code-root"))code_root=argv[++i];
        else if(i+1<argc&&!strcmp(argv[i],"--expected-sha256"))expected=argv[++i];
        else if(i+1<argc&&!strcmp(argv[i],"--mode"))mode=argv[++i];
        else if(i+1<argc&&!strcmp(argv[i],"--callback-ms")){char *end=NULL;unsigned long value=strtoul(argv[++i],&end,10);if(!end||*end||value>3000)return refused("invalid_callback_budget");callback_ms=(unsigned)value;}
        else return refused("invalid_arguments");
    }
    if(!allowed||!library||!code_root||!hex(expected,64))return refused("explicit_execution_scope_required");
    if(strcmp(mode,"exports")&&strcmp(mode,"init-flat")&&strcmp(mode,"init-legacy"))return refused("invalid_mode");
    const char *app=getenv("SteamAppId"),*game=getenv("SteamGameId"),*scope=getenv("READY_STEAM_GAME_API_PROBE");
    if(!scope||strcmp(scope,"1")||!app||!game||strcmp(app,"1091500")||strcmp(game,"1091500"))return refused("explicit_app_context_required");
    if(!hex(getenv("READY_STEAM_IPC_NAMESPACE"),32))return refused("explicit_namespace_required");
    char image[PATH_MAX],root[PATH_MAX],before_hash[65];
    if(library[0]!='/'||code_root[0]!='/'||!realpath(library,image)||!realpath(code_root,root))return refused("canonical_code_path_required");
    size_t size=strlen(root);
    if(size<=1||strncmp(image,root,size)||image[size]!='/')return refused("library_outside_code_root");
    if(file_hash(image,before_hash)||strcmp(before_hash,expected))return refused("sdk_hash_mismatch");
    /* The external SDK's own stdout/stderr may contain private diagnostics.
     * Keep only our bounded structured output on a separate inherited pipe. */
    if(quiet_library_console())return refused("console_guard_failed");
    struct sigaction action={0};action.sa_handler=timed_out;sigemptyset(&action.sa_mask);sigaction(SIGALRM,&action,NULL);alarm(10);
    void *handle=dlopen(image,RTLD_NOW|RTLD_LOCAL);if(!handle)return refused("sdk_load_failed");
    void *flat=dlsym(handle,"SteamAPI_InitFlat"),*legacy=dlsym(handle,"SteamAPI_Init"),*running=dlsym(handle,"SteamAPI_IsSteamRunning");
    void *restart=dlsym(handle,"SteamAPI_RestartAppIfNecessary"),*callbacks=dlsym(handle,"SteamAPI_RunCallbacks"),*shutdown=dlsym(handle,"SteamAPI_Shutdown");
    void *get_user=dlsym(handle,"SteamAPI_SteamUser_v023"),*logged_on=dlsym(handle,"SteamAPI_ISteamUser_BLoggedOn"),*get_id=dlsym(handle,"SteamAPI_ISteamUser_GetSteamID");
    void *get_apps=dlsym(handle,"SteamAPI_SteamApps_v008"),*subscribed=dlsym(handle,"SteamAPI_ISteamApps_BIsSubscribedApp");
    if(!from_image(flat,image)||!from_image(legacy,image)||!from_image(running,image)||!from_image(restart,image)||!from_image(callbacks,image)||!from_image(shutdown,image))return refused("export_image_binding_failed");
    if(!from_image(get_user,image)||!from_image(logged_on,image)||!from_image(get_id,image)||!from_image(get_apps,image)||!from_image(subscribed,image))return refused("flat_query_image_binding_failed");
    bool attempted=strcmp(mode,"exports")!=0,initialized=false,before=false,after=false,shutdown_called=false;
    bool queries_available=get_user&&logged_on&&get_id&&get_apps&&subscribed;
    bool queried=false,user_logged_on=false,identity_matches=false,owned_subscription=false;
    uint64_t expected_id=expected_identity();
    int result=-1;unsigned pumped=0;char error_buffer[1024]={0};
    if(attempted){
        if(!running||!callbacks||!shutdown||(!strcmp(mode,"init-flat")&&!flat)||(!strcmp(mode,"init-legacy")&&!legacy))return refused("required_api_missing");
        before=((running_fn)running)();
        if(!strcmp(mode,"init-flat")){result=((init_flat_fn)flat)(error_buffer);initialized=result==0;}
        else{initialized=((init_fn)legacy)();result=initialized?0:1;}
        /* Do not expose the SDK's free-form error buffer: it can contain private
         * paths/account information. Volatile stores retain the clear. */
        volatile unsigned char *clear=(volatile unsigned char *)error_buffer;for(size_t i=0;i<sizeof error_buffer;i++)clear[i]=0;
        if(initialized){double end=monotonic()+callback_ms/1000.0;do{((void_fn)callbacks)();pumped++;usleep(10000);}while(monotonic()<end&&callback_ms);}
        after=((running_fn)running)();
        if(initialized&&queries_available){
            void *user=((interface_fn)get_user)(),*apps=((interface_fn)get_apps)();
            queried=true;user_logged_on=user&&((logged_on_fn)logged_on)(user);
            identity_matches=user_logged_on&&expected_id&&((steam_id_fn)get_id)(user)==expected_id;
            owned_subscription=apps&&((subscribed_fn)subscribed)(apps,1091500);
        }
        if(initialized){((void_fn)shutdown)();shutdown_called=true;}
    }
    char after_hash[65];bool unchanged=!file_hash(image,after_hash)&&!strcmp(before_hash,after_hash);
    /* dlclose is intentionally omitted: the library may have asynchronous work.
     * This bounded, own probe exits instead of unloading live library code. */
    alarm(0);
    bool authenticated=queried&&user_logged_on&&identity_matches&&owned_subscription;
    dprintf(report_fd,"{\"schema\":1,\"fixtureOnly\":%s,\"sdkSHA256\":\"%s\",\"sdkUnchanged\":%s,\"exports\":{\"SteamAPI_InitFlat\":%s,\"SteamAPI_Init\":%s,\"SteamAPI_IsSteamRunning\":%s,\"SteamAPI_RestartAppIfNecessary\":%s,\"SteamAPI_RunCallbacks\":%s,\"SteamAPI_Shutdown\":%s},\"initializationAttempted\":%s,\"apiInitialized\":%s,\"initResult\":%d,\"steamRunningBefore\":%s,\"steamRunningAfter\":%s,\"callbackCalls\":%u,\"shutdownCalled\":%s,\"externalLibraryConsoleSuppressed\":true,\"restartCalled\":false,\"gameLaunchRequested\":false}\n",fixture?"true":"false",before_hash,unchanged?"true":"false",flat?"true":"false",legacy?"true":"false",running?"true":"false",restart?"true":"false",callbacks?"true":"false",shutdown?"true":"false",attempted?"true":"false",initialized?"true":"false",result>=0&&result<=3?result:-1,before?"true":"false",after?"true":"false",pumped,shutdown_called?"true":"false");
    dprintf(report_fd,"{\"flatQueriesAvailable\":%s,\"flatQueriesPerformed\":%s,\"identityExpectationProvided\":%s,\"genuineUserLoggedOn\":%s,\"identityMatches\":%s,\"ownedSubscriptionObserved\":%s,\"gameAPIContextAuthenticated\":%s,\"fixtureOnly\":%s,\"gameLaunchRequested\":false}\n",queries_available?"true":"false",queried?"true":"false",expected_id?"true":"false",user_logged_on?"true":"false",identity_matches?"true":"false",owned_subscription?"true":"false",authenticated?"true":"false",fixture?"true":"false");
    return !unchanged?66:attempted&&!initialized?3:queried&&expected_id&&!authenticated?4:0;
}
