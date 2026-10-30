// SPDX-License-Identifier: GPL-3.0-only
// Diagnostic-only native startup observer. Original objects and rendering are unchanged.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <pthread.h>
#import <mach/mach_time.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#define NATIVE_STARTUP_LIMIT 128
static IMP nativeOriginalNext,nativeOriginalUpdate,nativeOriginalInit;
static Method nativeNextMethod,nativeUpdateMethod,nativeInitMethod;
static int nativeDiagnosticFD=-1;
static uint64_t nativeBegan;
static mach_timebase_info_data_t nativeTimebase;
static pthread_mutex_t nativeStateLock=PTHREAD_MUTEX_INITIALIZER,nativeLogLock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic bool nativeFinished;
static _Atomic unsigned nativeLinkInitializers;
typedef struct{uintptr_t object;uint64_t drawableID;}NativeStartupKey;
static NativeStartupKey nativeKeys[NATIVE_STARTUP_LIMIT];
static unsigned nativeObserved,nativeCallbacks,nativeZero,nativePositive,nativeInvalid;
static id nativeStartupNext(CAMetalLayer*,SEL);
static id nativeStartupUpdate(CAMetalDisplayLinkUpdate*,SEL);
static id nativeStartupInit(id __attribute__((ns_consumed)),SEL,CAMetalLayer*) __attribute__((ns_returns_retained));
static double nativeElapsed(void){return (double)((long double)(mach_continuous_time()-nativeBegan)*nativeTimebase.numer/nativeTimebase.denom/1e6L);}
static void nativeLog(const char*line){if(nativeDiagnosticFD<0)return;pthread_mutex_lock(&nativeLogLock);size_t length=strlen(line),offset=0;while(offset<length){ssize_t count=write(nativeDiagnosticFD,line+offset,length-offset);if(count<0&&errno==EINTR)continue;if(count<=0)break;offset+=(size_t)count;}pthread_mutex_unlock(&nativeLogLock);}
static unsigned nativeRestore(void){unsigned count=0;Method methods[]={nativeNextMethod,nativeUpdateMethod,nativeInitMethod};IMP ours[]={(IMP)nativeStartupNext,(IMP)nativeStartupUpdate,(IMP)nativeStartupInit};IMP originals[]={nativeOriginalNext,nativeOriginalUpdate,nativeOriginalInit};for(unsigned i=0;i<3;i++)if(methods[i]&&originals[i]&&method_getImplementation(methods[i])==ours[i]){method_setImplementation(methods[i],originals[i]);count++;}return count;}
static void nativeFinish(const char*reason,unsigned firstPositiveIndex){
 if(atomic_exchange(&nativeFinished,true))return;unsigned restored=nativeRestore();
 pthread_mutex_lock(&nativeStateLock);unsigned observed=nativeObserved,callbacks=nativeCallbacks,zero=nativeZero,positive=nativePositive,invalid=nativeInvalid;pthread_mutex_unlock(&nativeStateLock);
 char line[640];snprintf(line,sizeof line,"{\"schema\":1,\"type\":\"native-startup-observe\",\"phase\":\"final\",\"reason\":\"%s\",\"elapsedMilliseconds\":%.3f,\"observed\":%u,\"callbacks\":%u,\"zero\":%u,\"positive\":%u,\"invalid\":%u,\"firstPositiveObservation\":%u,\"ownedMethodsRestored\":%u}\n",reason,nativeElapsed(),observed,callbacks,zero,positive,invalid,firstPositiveIndex,restored);nativeLog(line);
}
static void nativePresented(unsigned index,id<MTLDrawable>drawable){
 if(atomic_load(&nativeFinished))return;double stamp=drawable.presentedTime;BOOL valid=isfinite(stamp)&&stamp>=0,positive=valid&&stamp>0;
 pthread_mutex_lock(&nativeStateLock);nativeCallbacks++;if(!valid)nativeInvalid++;else if(positive)nativePositive++;else nativeZero++;unsigned callbacks=nativeCallbacks,observed=nativeObserved;pthread_mutex_unlock(&nativeStateLock);
 char line[360];snprintf(line,sizeof line,"{\"schema\":1,\"type\":\"native-startup-observe\",\"phase\":\"presented\",\"observation\":%u,\"elapsedMilliseconds\":%.3f,\"valid\":%s,\"positive\":%s,\"zero\":%s}\n",index,nativeElapsed(),valid?"true":"false",positive?"true":"false",valid&&!positive?"true":"false");nativeLog(line);
 if(positive)nativeFinish("first-positive",index);else if(observed==NATIVE_STARTUP_LIMIT&&callbacks==NATIVE_STARTUP_LIMIT)nativeFinish("nonpositive-frame-budget",0);
}
static void nativeObserve(id<CAMetalDrawable>drawable,const char*source){
 if(!drawable||atomic_load(&nativeFinished))return;
 @try{
  NativeStartupKey key={(uintptr_t)(__bridge void*)drawable,drawable.drawableID};unsigned index=0;
  pthread_mutex_lock(&nativeStateLock);
  if(!atomic_load(&nativeFinished)&&nativeObserved<NATIVE_STARTUP_LIMIT){BOOL duplicate=NO;for(unsigned i=0;i<nativeObserved;i++)if(nativeKeys[i].object==key.object&&nativeKeys[i].drawableID==key.drawableID){duplicate=YES;break;}if(!duplicate){index=++nativeObserved;nativeKeys[index-1]=key;}}
  pthread_mutex_unlock(&nativeStateLock);if(!index)return;
  id<MTLTexture>texture=drawable.texture;
  // Runtime class names are reduced to ASCII identifier characters; no object descriptions.
  const char*raw=class_getName(object_getClass(drawable));char safeClass[96];unsigned n=0;for(;raw&&raw[n]&&n<sizeof safeClass-1;n++){char c=raw[n];safeClass[n]=((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_')?c:'_';}safeClass[n]=0;
  char line[480];snprintf(line,sizeof line,"{\"schema\":1,\"type\":\"native-startup-observe\",\"phase\":\"observed\",\"observation\":%u,\"elapsedMilliseconds\":%.3f,\"source\":\"%s\",\"drawableClass\":\"%s\",\"width\":%llu,\"height\":%llu,\"pixelFormat\":%llu}\n",index,nativeElapsed(),source,safeClass,(unsigned long long)texture.width,(unsigned long long)texture.height,(unsigned long long)texture.pixelFormat);nativeLog(line);
  // Capture the scalar observation only; never retain a drawable or texture in our state.
  [drawable addPresentedHandler:^(id<MTLDrawable>shown){nativePresented(index,shown);}];
  if(index==NATIVE_STARTUP_LIMIT){nativeRestore();nativeLog("{\"schema\":1,\"type\":\"native-startup-observe\",\"phase\":\"observation-budget-reached\"}\n");}
 }@catch(NSException*exception){(void)exception;nativeFinish("observation-unavailable",0);}
}
static id nativeStartupNext(CAMetalLayer*layer,SEL selector){id drawable=((id(*)(id,SEL))nativeOriginalNext)(layer,selector);nativeObserve(drawable,"nextDrawable");return drawable;}
static id nativeStartupUpdate(CAMetalDisplayLinkUpdate*update,SEL selector){id drawable=((id(*)(id,SEL))nativeOriginalUpdate)(update,selector);nativeObserve(drawable,"displayLinkUpdate");return drawable;}
typedef id(*NativeStartupInit)(id __attribute__((ns_consumed)),SEL,CAMetalLayer*) __attribute__((ns_returns_retained));
static id nativeStartupInit(id self __attribute__((ns_consumed)),SEL selector,CAMetalLayer*layer){
 id link=((NativeStartupInit)nativeOriginalInit)(self,selector,layer);
 if(!atomic_load(&nativeFinished)&&atomic_fetch_add(&nativeLinkInitializers,1)<8){CGSize size=layer.drawableSize;char line[320];snprintf(line,sizeof line,"{\"schema\":1,\"type\":\"native-startup-observe\",\"phase\":\"display-link-init\",\"elapsedMilliseconds\":%.3f,\"width\":%.0f,\"height\":%.0f}\n",nativeElapsed(),isfinite(size.width)?size.width:0,isfinite(size.height)?size.height:0);nativeLog(line);}return link;
}
static BOOL nativeBegin(void){nativeDiagnosticFD=fcntl(STDERR_FILENO,F_DUPFD_CLOEXEC,3);if(nativeDiagnosticFD<0)return NO;mach_timebase_info(&nativeTimebase);nativeBegan=mach_continuous_time();atomic_init(&nativeFinished,false);atomic_init(&nativeLinkInitializers,0);return YES;}
#ifndef READY_NATIVE_STARTUP_OBSERVE_TESTING
__attribute__((constructor))static void nativeInstall(void){@autoreleasepool{
 if(!nativeBegin())return;
 nativeNextMethod=class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable));nativeUpdateMethod=class_getInstanceMethod(CAMetalDisplayLinkUpdate.class,@selector(drawable));nativeInitMethod=class_getInstanceMethod(CAMetalDisplayLink.class,@selector(initWithMetalLayer:));
 if(!nativeNextMethod||!nativeUpdateMethod||!nativeInitMethod){nativeFinish("native-getters-unavailable",0);return;}
 nativeOriginalNext=method_setImplementation(nativeNextMethod,(IMP)nativeStartupNext);nativeOriginalUpdate=method_setImplementation(nativeUpdateMethod,(IMP)nativeStartupUpdate);nativeOriginalInit=method_setImplementation(nativeInitMethod,(IMP)nativeStartupInit);
 nativeLog("{\"schema\":1,\"type\":\"native-startup-observe\",\"phase\":\"installed\",\"maximumDistinctDrawables\":128,\"deadlineSeconds\":15,\"originalObjectsPreserved\":true}\n");
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{nativeFinish("startup-deadline",0);});
}}
#endif
