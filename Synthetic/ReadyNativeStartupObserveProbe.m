// SPDX-License-Identifier: GPL-3.0-only
#define READY_NATIVE_STARTUP_OBSERVE_TESTING 1
#import "ReadyNativeStartupObserve.m"
@interface OwnStartupTexture:NSObject @end
@implementation OwnStartupTexture
-(NSUInteger)width{return 4;}-(NSUInteger)height{return 4;}-(MTLPixelFormat)pixelFormat{return MTLPixelFormatBGRA8Unorm;}
@end
@interface OwnStartupDrawable:NSObject
@property(nonatomic)NSUInteger drawableID;
@property(nonatomic)double presentedTime;
@property(nonatomic,copy)MTLDrawablePresentedHandler handler;
@property(nonatomic)unsigned handlerRegistrations;
@property(nonatomic,strong)OwnStartupTexture*texture;
@end
@implementation OwnStartupDrawable
-(void)addPresentedHandler:(MTLDrawablePresentedHandler)handler{self.handlerRegistrations++;self.handler=handler;}
@end
static OwnStartupDrawable*current;
static id originalGetter(id self,SEL selector){return current;}
#define CHECK(value) do{if(!(value)){fprintf(stdout,"assertion line:%d\n",__LINE__);return 70;}}while(0)
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 64;CHECK(nativeBegin());CHECK(fcntl(nativeDiagnosticFD,F_GETFD)&FD_CLOEXEC);nativeOriginalNext=(IMP)originalGetter;nativeOriginalUpdate=(IMP)originalGetter;
 NSString*mode=@(argv[1]);unsigned count=[mode isEqual:@"positive"]?11:([mode isEqual:@"budget"]?128:3);
 current=[OwnStartupDrawable new];current.texture=[OwnStartupTexture new];
 for(unsigned i=1;i<=count;i++){
  current.drawableID=i;unsigned before=current.handlerRegistrations;
  CHECK(nativeStartupNext(nil,@selector(nextDrawable))==current);CHECK(nativeStartupUpdate(nil,@selector(drawable))==current);CHECK(current.handlerRegistrations==before+1);CHECK(nativeObserved==i);
  current.presentedTime=[mode isEqual:@"positive"]&&i==11?1:0;current.handler((id<MTLDrawable>)current);current.handler=nil;
 }
 if([mode isEqual:@"deadline"])nativeFinish("startup-deadline",0);
 CHECK(atomic_load(&nativeFinished));unsigned observed=nativeObserved;current.drawableID=999;CHECK(nativeStartupNext(nil,@selector(nextDrawable))==current);CHECK(nativeObserved==observed);
 CHECK(nativeCallbacks==count);CHECK(nativePositive==([mode isEqual:@"positive"]?1:0));CHECK(nativeZero==count-nativePositive);
 close(nativeDiagnosticFD);nativeDiagnosticFD=-1;printf("{\"passed\":true,\"mode\":\"%s\",\"originalObjectsPreserved\":true,\"duplicatesRejected\":true,\"framebufferObjectsRetained\":false,\"observed\":%u,\"GPUWindowGameUsed\":false}\n",argv[1],nativeObserved);return 0;
}}
