/* SPDX-License-Identifier: GPL-3.0-only */
/* Worker-local discovery routing ONLY; no SDK/game patches, return spoofing,
 * authentication or global Steam service lookup. Other lookups are unchanged. */
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <stdio.h>
static _Atomic unsigned long long loaded,fixed,redirected,forwarded,missing,invalid,succeeded,failed;static _Atomic int last_status;
__attribute__((constructor)) static void loaded_image(void){atomic_store(&loaded,1);}
static int valid_name(const char *s){const char *p="app.ready.steam.ipctool.";size_t n=strlen(p);if(!s||strncmp(s,p,n)||strlen(s)!=n+32)return 0;for(s+=n;*s;s++)if(!(*s>='0'&&*s<='9')&&!(*s>='a'&&*s<='f'))return 0;return 1;}
/* dyld leaves references to the replacee inside this interposer bound to the
 * original, as with the project's tested POSIX namespace adapters. */
static kern_return_t redirected_lookup(mach_port_t bootstrap,const char *name,mach_port_t *service){if(name&&!strcmp(name,"com.valvesoftware.steam.ipctool")){atomic_fetch_add(&fixed,1);const char *private_name=getenv("READY_STEAM_DISCOVERY_SERVICE");if(!private_name||!*private_name)atomic_fetch_add(&missing,1);if(!valid_name(private_name)){atomic_fetch_add(&invalid,1);atomic_store(&last_status,BOOTSTRAP_UNKNOWN_SERVICE);if(service)*service=MACH_PORT_NULL;return BOOTSTRAP_UNKNOWN_SERVICE;}atomic_fetch_add(&redirected,1);kern_return_t status=bootstrap_look_up(bootstrap,private_name,service);atomic_store(&last_status,status);if(status==KERN_SUCCESS)atomic_fetch_add(&succeeded,1);else atomic_fetch_add(&failed,1);return status;}atomic_fetch_add(&forwarded,1);return bootstrap_look_up(bootstrap,name,service);}
__attribute__((used)) static const struct {const void *replacement,*replacee;} interpose __attribute__((section("__DATA,__interpose")))={(const void*)redirected_lookup,(const void*)bootstrap_look_up};

size_t ready_steam_discovery_redirect_stats_json(char *out,size_t capacity){if(!out||!capacity)return 0;int n=snprintf(out,capacity,"{\"redirectLoaded\":%s,\"fixedLookups\":%llu,\"privateRedirects\":%llu,\"otherLookupsForwarded\":%llu,\"missingConfiguration\":%llu,\"invalidConfiguration\":%llu,\"privateLookupSucceeded\":%llu,\"privateLookupFailed\":%llu,\"lastLookupStatus\":%d}",atomic_load(&loaded)?"true":"false",(unsigned long long)atomic_load(&fixed),(unsigned long long)atomic_load(&redirected),(unsigned long long)atomic_load(&forwarded),(unsigned long long)atomic_load(&missing),(unsigned long long)atomic_load(&invalid),(unsigned long long)atomic_load(&succeeded),(unsigned long long)atomic_load(&failed),atomic_load(&last_status));return n>0&&(size_t)n<capacity?(size_t)n:0;}
