// SPDX-License-Identifier: GPL-3.0-only
// Test-process-only public-method observation. No timing changes or other app.
#import "ReadySplashAnimationObserver.h"
#import <objc/runtime.h>
static IMP originalAdd,originalRemove;
static NSMutableDictionary *records,*removals,*additions;
static NSMutableSet *observedLayers;
static NSLock *observedLock;
static NSString *layerKey(CALayer *layer){return [NSString stringWithFormat:@"%p",layer];}
static void observeAdd(CALayer *layer,SEL selector,CAAnimation *animation,NSString *key){
 if(key&&[@[@"loading.rotation",@"loading.pulse",@"artwork.motion"]containsObject:key]){
  NSString *identity=[layerKey(layer) stringByAppendingFormat:@":%@",key];CAAnimation *copy=[animation copy];
  [observedLock lock];records[identity]=copy;additions[identity]=@([additions[identity]unsignedIntValue]+1);[observedLayers addObject:layerKey(layer)];[observedLock unlock];
 }
 ((void(*)(id,SEL,CAAnimation*,NSString*))originalAdd)(layer,selector,animation,key);
}
static void observeRemove(CALayer *layer,SEL selector){NSString *key=layerKey(layer);[observedLock lock];if([observedLayers containsObject:key])removals[key]=@([removals[key]unsignedIntValue]+1);[observedLock unlock];((void(*)(id,SEL))originalRemove)(layer,selector);}
void ReadySplashAnimationObserverStart(void){
 observedLock=[NSLock new];records=[NSMutableDictionary new];removals=[NSMutableDictionary new];additions=[NSMutableDictionary new];observedLayers=[NSMutableSet new];
 originalAdd=method_setImplementation(class_getInstanceMethod(CALayer.class,@selector(addAnimation:forKey:)),(IMP)observeAdd);
 originalRemove=method_setImplementation(class_getInstanceMethod(CALayer.class,@selector(removeAllAnimations)),(IMP)observeRemove);
}
void ReadySplashAnimationObserverStop(void){
 if(originalAdd)method_setImplementation(class_getInstanceMethod(CALayer.class,@selector(addAnimation:forKey:)),originalAdd);
 if(originalRemove)method_setImplementation(class_getInstanceMethod(CALayer.class,@selector(removeAllAnimations)),originalRemove);
 [observedLock lock];[records removeAllObjects];[removals removeAllObjects];[additions removeAllObjects];[observedLayers removeAllObjects];[observedLock unlock];
}
CAAnimation *ReadySplashRecordedAnimation(CALayer *layer,const char *key){[observedLock lock];CAAnimation *result=records[[layerKey(layer) stringByAppendingFormat:@":%s",key]];[observedLock unlock];return result;}
unsigned ReadySplashRemovalCount(CALayer *layer){[observedLock lock];unsigned result=[removals[layerKey(layer)]unsignedIntValue];[observedLock unlock];return result;}
unsigned ReadySplashAdditionCount(CALayer *layer,const char *key){[observedLock lock];unsigned result=[additions[[layerKey(layer) stringByAppendingFormat:@":%s",key]]unsignedIntValue];[observedLock unlock];return result;}
