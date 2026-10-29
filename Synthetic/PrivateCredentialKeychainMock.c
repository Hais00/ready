// SPDX-License-Identifier: GPL-3.0-only
// Interposes only in the independently built policy fixture process. Never
// forwards to Security.framework or accesses any actual Keychain contents.
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdint.h>
#include <pthread.h>
#ifdef READY_CREDENTIAL_BINDING_CHECK
extern OSStatus ready_mock_copy(CFDictionaryRef,CFTypeRef *);
extern OSStatus ready_mock_update(CFDictionaryRef,CFDictionaryRef);
extern OSStatus ready_mock_add(CFDictionaryRef,CFTypeRef *);
extern OSStatus ready_mock_delete(CFDictionaryRef);
int ready_credential_binding_is_mocked(void){
 const void * volatile actual[4]={(const void *)&SecItemCopyMatching,(const void *)&SecItemUpdate,(const void *)&SecItemAdd,(const void *)&SecItemDelete};
 const void * volatile expected[4]={(const void *)&ready_mock_copy,(const void *)&ready_mock_update,(const void *)&ready_mock_add,(const void *)&ready_mock_delete};
 for(int i=0;i<4;i++)if(actual[i]!=expected[i])return 0;return 1;
}
#else
static _Atomic uint32_t counts[4];
static _Atomic uint32_t main_calls;
static void hit(unsigned index){atomic_fetch_add(&counts[index],1);if(pthread_main_np())atomic_fetch_add(&main_calls,1);}
OSStatus ready_mock_copy(CFDictionaryRef query,CFTypeRef *result){
 (void)query;hit(0);
 static const UInt8 value[]="{\"username\":\"mock_keychain_account\",\"refresh_token\":\"mock_keychain_refresh\"}";
 if(result)*result=CFDataCreate(kCFAllocatorDefault,value,sizeof(value)-1);
 return errSecSuccess;
}
OSStatus ready_mock_update(CFDictionaryRef query,CFDictionaryRef attributes){(void)query;(void)attributes;hit(1);return errSecSuccess;}
OSStatus ready_mock_add(CFDictionaryRef query,CFTypeRef *result){(void)query;if(result)*result=NULL;hit(2);return errSecSuccess;}
OSStatus ready_mock_delete(CFDictionaryRef query){(void)query;hit(3);return errSecSuccess;}
uint32_t ready_credential_mock_count(int index){if(index==4){uint32_t sum=0;for(int i=0;i<4;i++)sum+=atomic_load(&counts[i]);return sum;}if(index==5)return atomic_load(&main_calls);return index>=0&&index<4?atomic_load(&counts[index]):0;}
void ready_credential_mock_reset(void){for(int i=0;i<4;i++)atomic_store(&counts[i],0);atomic_store(&main_calls,0);}
#define INTERPOSE(replacement,original) __attribute__((used,section("__DATA,__interpose"))) static const struct{const void *new_function,*old_function;} ready_interpose_##replacement={(const void *)&replacement,(const void *)&original};
INTERPOSE(ready_mock_copy,SecItemCopyMatching)
INTERPOSE(ready_mock_update,SecItemUpdate)
INTERPOSE(ready_mock_add,SecItemAdd)
INTERPOSE(ready_mock_delete,SecItemDelete)

#endif
