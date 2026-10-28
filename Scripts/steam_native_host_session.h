/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef READY_STEAM_NATIVE_HOST_SESSION_H
#define READY_STEAM_NATIVE_HOST_SESSION_H
/* Worker-local lifetime support. The parent owns the sole lifeline writer.
 * EOF revokes discovery immediately; the callback thread releases only its
 * own user/pipe. A stuck vendor call gets a two-second process-exit fallback.
 * No account identifiers, callback payloads or credentials enter these events. */
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/stat.h>
static int ready_session_lifeline=-1,ready_session_event=-1;
static _Atomic int ready_session_health=-1;
static _Atomic int ready_session_reason,ready_session_active;
static _Atomic(ReadySteamAuthenticatedHostRecord *) ready_session_record;
static volatile sig_atomic_t ready_session_signal;
static double ready_session_started;
static uint32_t ready_session_game_id;
static _Bool ready_session_user_released,ready_session_pipe_released;
static char ready_session_namespace[33],ready_session_private_name[96],ready_session_master_endpoint[32],ready_session_service_endpoint[32];
static double ready_session_now(void) {
    struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))_exit(70);
    return (double)t.tv_sec+(double)t.tv_nsec/1000000000.0;
}
static void ready_session_stop(int reason);
static void ready_session_emit(const char *phase,int reason) {
    /* phase is always a literal chosen below, never library/server text. */
    _Bool ready=!strcmp(phase,"ready"),heartbeat=!strcmp(phase,"heartbeat"),revoked=!strcmp(phase,"revoked");
    const char *type=revoked||heartbeat?"state":phase;
    _Bool authorized=ready||heartbeat;char hints[384]={0};
    if(ready)snprintf(hints,sizeof hints,",\"privateName\":\"%s\",\"namespace\":\"%s\",\"masterEndpoint\":\"%s\",\"serviceEndpoint\":\"%s\"",ready_session_private_name,ready_session_namespace,ready_session_master_endpoint,ready_session_service_endpoint);
    char out[1024];int n=snprintf(out,sizeof out,
        "{\"schema\":1,\"type\":\"%s\",\"reason\":%d,\"authenticated\":%s,\"identityMatches\":%s,\"ownedSubscription\":%s,\"gameID\":%u,\"revoked\":%s,\"network\":\"unknown\",\"userReleased\":%s,\"pipeReleased\":%s,\"fixtureOnly\":%s%s}\n",type,reason,authorized?"true":"false",authorized?"true":"false",authorized?"true":"false",ready_session_game_id,revoked?"true":"false",ready_session_user_released?"true":"false",ready_session_pipe_released?"true":"false",
#ifdef READY_STEAM_HOST_SESSION_FIXTURE
        "true"
#else
        "false"
#endif
    ,hints);
    if(n>0&&(size_t)n<sizeof out) {
        ssize_t written;do{written=write(ready_session_event,out,(size_t)n);}while(written<0&&errno==EINTR);
        /* An undrained/broken diagnostic pipe cannot strand this session. */
        if(written!=n)ready_session_stop(46);
    }
}
static void ready_session_stop(int reason) {
    int expected=0;atomic_compare_exchange_strong(&ready_session_reason,&expected,reason);
    ReadySteamAuthenticatedHostRecord *r=atomic_load(&ready_session_record);
    if(r)atomic_store(&r->authenticated,0);
    /* Publish revocation BEFORE another process can observe health EOF. */
    int health=atomic_exchange(&ready_session_health,-1);if(health>=0)close(health);
}
static void ready_session_signalled(int signal_number) {(void)signal_number;ready_session_signal=1;}
static void *ready_session_watch(void *unused) {
    (void)unused;double stopping=0;
    for(;;) {
        if(ready_session_signal)ready_session_stop(44);
        struct pollfd p={ready_session_lifeline,POLLIN,0};int result=poll(&p,1,50);
        if(result<0&&errno!=EINTR)ready_session_stop(41);
        if(result>0) {
            if(p.revents&POLLNVAL)ready_session_stop(41);
            if(p.revents&(POLLIN|POLLHUP|POLLERR)) {
                char byte;ssize_t n=read(ready_session_lifeline,&byte,1);
                if(n==0)ready_session_stop(42);
                else if(n>0||(errno!=EINTR&&errno!=EAGAIN))ready_session_stop(41);
            }
        }
        if(!atomic_load(&ready_session_active)&&ready_session_now()-ready_session_started>=45)ready_session_stop(70);
        int reason=atomic_load(&ready_session_reason);
        if(reason) {
            if(!stopping)stopping=ready_session_now();
            if(ready_session_now()-stopping>=2)_exit(reason);
        }
    }
    return NULL;
}
typedef struct {
    void *user,*apps;
    _Bool (*logged_on)(void *);
    uint64_t (*identity)(void *);
    _Bool (*subscribed)(void *,uint32_t);
    uint64_t expected_identity;
    uint32_t app_id;
} ReadySteamSessionContext;
static ReadySteamSessionContext ready_session_context;
static int ready_session_begin(int lifeline,int event) {
    struct stat a,b;int af=fcntl(lifeline,F_GETFL),bf=fcntl(event,F_GETFL);
    if(lifeline<3||event<3||lifeline==event||af<0||bf<0||fstat(lifeline,&a)||fstat(event,&b))return -1;
    if(!S_ISFIFO(a.st_mode)||a.st_uid!=getuid()||(af&O_ACCMODE)!=O_RDONLY)return -1;
    if(b.st_uid!=getuid()||(!S_ISFIFO(b.st_mode)&&!(S_ISREG(b.st_mode)&&(b.st_mode&0777)==0600&&b.st_nlink==1))||(bf&O_ACCMODE)==O_RDONLY)return -1;
    if(fcntl(lifeline,F_SETFL,af|O_NONBLOCK)||fcntl(event,F_SETFL,bf|O_NONBLOCK))return -1;
    ready_session_lifeline=lifeline;ready_session_event=event;
    atomic_init(&ready_session_reason,0);atomic_init(&ready_session_active,0);atomic_init(&ready_session_record,NULL);
    ready_session_started=ready_session_now();
    struct sigaction action={0};action.sa_handler=ready_session_signalled;sigemptyset(&action.sa_mask);
    sigaction(SIGTERM,&action,NULL);sigaction(SIGINT,&action,NULL);signal(SIGPIPE,SIG_IGN);
    pthread_t watcher;if(pthread_create(&watcher,NULL,ready_session_watch,NULL))return -1;pthread_detach(watcher);
    ready_session_emit("starting",0);return 0;
}
static void ready_session_lifetime(void *library,int pipe,ReadySteamAuthenticatedHostRecord *record,_Bool discovery_started) {
    typedef _Bool (*get_fn)(int,callback_message *);typedef void (*release_fn)(int);
    get_fn get=(get_fn)dlsym(library,"Steam_BGetCallback");release_fn release=(release_fn)dlsym(library,"Steam_FreeLastCallback");
    ReadySteamSessionContext *c=&ready_session_context;
    if(!discovery_started||!get||!release||!c->user||!c->apps||!c->logged_on||!c->identity||!c->subscribed) {ready_session_stop(67);return;}
    atomic_store(&ready_session_record,record);
    /* Recheck after publication, including parent EOF during startup. */
    if(atomic_load(&ready_session_reason)||!c->logged_on(c->user)||c->identity(c->user)!=c->expected_identity||!c->subscribed(c->apps,c->app_id)){ready_session_stop(43);return;}
    ready_session_game_id=c->app_id;atomic_store(&ready_session_active,1);ready_session_emit("ready",0);
    double heartbeat=0,notification=ready_session_now()+1;
    while(!atomic_load(&ready_session_reason)) {
        for(unsigned batch=0;batch<128;batch++) {
            callback_message message={0};if(!get(pipe,&message))break;
            _Bool malformed=message.size<0||message.size>1024*1024||(message.size>0&&!message.payload);
            _Bool disconnected=message.id==103;
            release(pipe);
            if(malformed||disconnected){ready_session_stop(malformed?45:43);break;}
        }
        double now=ready_session_now();
        if(now>=heartbeat) {
            heartbeat=now+.25;
            if(!c->logged_on(c->user)||c->identity(c->user)!=c->expected_identity||!c->subscribed(c->apps,c->app_id))ready_session_stop(43);
        }
        if(now>=notification&&!atomic_load(&ready_session_reason)){ready_session_emit("heartbeat",0);notification=now+1;}
        struct timespec delay={0,25000000};nanosleep(&delay,NULL);
    }
    atomic_store(&record->authenticated,0);ready_session_emit("revoked",atomic_load(&ready_session_reason));
}
#endif
