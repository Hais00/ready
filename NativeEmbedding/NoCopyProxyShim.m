// SPDX-License-Identifier: GPL-3.0-only
// Narrow logical window/drawable proxy for OUR unchanged synthetic executable.
// Unsupported paths fail closed. No real guest NSWindow initializer is called.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <servers/bootstrap.h>
#import <unistd.h>
#import "NoCopyProxyProtocol.h"
static mach_port_t peer,receive;static NCReply metadata;static dispatch_semaphore_t available;
static unsigned logicalWindows,imports,presentRequests,completions,renders,blits,computes,shimQueues;
static double IPCSeconds,GPUSeconds;static IMP queueOriginal,presentOriginal,renderOriginal,blitOriginal,computeOriginal;
static Class bufferClass;static id logicalWindow;
static void emit(NSDictionary*v){NSData*d=[NSJSONSerialization dataWithJSONObject:v options:0 error:nil];fwrite(d.bytes,1,d.length,stderr);fputc('\n',stderr);fflush(stderr);}
static void fail(NSString*why){emit(@{@"type":@"shim-refused",@"reason":why?:@"unknown",@"logicalWindows":@(logicalWindows),@"imports":@(imports),@"guestHiddenWindowFallback":@NO,@"copyFallback":@NO});_exit(77);}
static NCReply transact(uint32_t op,uint32_t frame,uint32_t surface,double gpu){
 double at=CACurrentMediaTime();NCRequest request={0};request.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE);request.h.msgh_remote_port=peer;request.h.msgh_local_port=receive;request.h.msgh_size=sizeof request;request.op=op;request.frame=frame;request.surface=surface;request.gpu=gpu;
 kern_return_t k=mach_msg(&request.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,request.h.msgh_size,0,MACH_PORT_NULL,5000,MACH_PORT_NULL);if(k)fail(@"mach-send");NCReplyReceive r={0};k=mach_msg(&r.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof r,receive,5000,MACH_PORT_NULL);if(k)fail(@"mach-receive");if(r.message.h.msgh_size!=sizeof(NCReply)||r.message.status)fail(@"invalid-reply");IPCSeconds+=CACurrentMediaTime()-at;return r.message;
}
static void connectHost(void){static dispatch_once_t once;dispatch_once(&once,^{const char*s=getenv("READY_NO_COPY_PROXY_SERVICE");if(!s||strncmp(s,"local.ready.nocopyproxy.",strlen("local.ready.nocopyproxy.")))fail(@"missing-owned-service");if(bootstrap_look_up(bootstrap_port,s,&peer))fail(@"host-lookup");if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&receive))fail(@"private-receive");available=dispatch_semaphore_create(1);metadata=transact(NC_HELLO,0,0,0);if(!metadata.window||!metadata.width||!metadata.height)fail(@"host-metadata");});}
@interface NCLogicalWindow:NSObject
@property(copy)NSString*title;
@property(strong)NSView*contentView;
@property NSRect frame;
@property NSWindowStyleMask styleMask;
@property BOOL releasedWhenClosed;
@property BOOL visible;
@end
@implementation NCLogicalWindow
-(instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer{(void)backing;(void)defer;self=[super init];if(self){connectHost();self.frame=rect;self.styleMask=style;logicalWindow=self;emit(@{@"type":@"logical-window",@"reportedWindow":@(metadata.window),@"hostResourceOnly":@YES,@"realNSWindowInitCalls":@0,@"sameObjCObjectAcrossProcesses":@NO});}return self;}
-(NSInteger)windowNumber{return metadata.window;}
-(NSScreen*)screen{return NSScreen.mainScreen;}
-(CGFloat)backingScaleFactor{return 1;}
-(NSRect)contentLayoutRect{return NSMakeRect(0,0,metadata.width,metadata.height);}
-(BOOL)isVisible{return self.visible;}
-(BOOL)isKeyWindow{return self.visible;}
-(BOOL)isMainWindow{return self.visible;}
-(BOOL)canBecomeKeyWindow{return YES;}
-(BOOL)canBecomeMainWindow{return YES;}
-(BOOL)isMiniaturized{return NO;}
-(void)makeKeyAndOrderFront:(id)sender{(void)sender;self.visible=YES;}
-(void)orderFront:(id)sender{(void)sender;self.visible=YES;}
-(void)orderOut:(id)sender{(void)sender;self.visible=NO;}
-(void)makeKeyWindow{self.visible=YES;}
-(void)setFrame:(NSRect)frame display:(BOOL)display{(void)display;self.frame=frame;}
-(NSRect)contentRectForFrameRect:(NSRect)rect{return rect;}
-(NSRect)frameRectForContentRect:(NSRect)rect{return rect;}
-(void)doesNotRecognizeSelector:(SEL)selector{fail([@"unsupported-window-selector:"stringByAppendingString:NSStringFromSelector(selector)]);}
@end
static id windowAlloc(id self,SEL cmd,NSZone*zone)__attribute__((ns_returns_retained));
static id windowAlloc(id self,SEL cmd,NSZone*zone){(void)cmd;if(self!=NSWindow.class)fail(@"unsupported-window-subclass");if(++logicalWindows!=1)fail(@"multiple-window-request");return [NCLogicalWindow allocWithZone:zone];}
static id windowAllocSimple(id self,SEL cmd)__attribute__((ns_returns_retained));
static id windowAllocSimple(id self,SEL cmd){return windowAlloc(self,cmd,NULL);}
@interface NCDrawable:NSObject<CAMetalDrawable>
@property(strong)id<MTLTexture>texture;
@property uint32_t frame,surface;
@property IOSurfaceRef importedSurface;
@end
@implementation NCDrawable
-(void)dealloc{if(_importedSurface)CFRelease(_importedSurface);}
-(NSUInteger)drawableID{return self.frame;}
-(CFTimeInterval)presentedTime{return 0;}
-(void)present{fail(@"direct-present-without-command-buffer-fence");}
-(void)presentAtTime:(CFTimeInterval)t{(void)t;fail(@"timed-present-unsupported");}
-(void)presentAfterMinimumDuration:(CFTimeInterval)t{(void)t;fail(@"duration-present-unsupported");}
-(void)addPresentedHandler:(MTLDrawablePresentedHandler)block{(void)block;fail(@"presented-handler-unsupported");}
@end
static id renderHook(id self,SEL cmd,id descriptor){renders++;return ((id(*)(id,SEL,id))renderOriginal)(self,cmd,descriptor);}
static id blitHook(id self,SEL cmd){blits++;return ((id(*)(id,SEL))blitOriginal)(self,cmd);}
static id computeHook(id self,SEL cmd){computes++;return ((id(*)(id,SEL))computeOriginal)(self,cmd);}
static void presentHook(id<MTLCommandBuffer>self,SEL cmd,id drawable){(void)cmd;if(![drawable isKindOfClass:NCDrawable.class])fail(@"non-proxy-drawable");NCDrawable*proxy=drawable;presentRequests++;
 [self addCompletedHandler:^(id<MTLCommandBuffer>done){if(done.status!=MTLCommandBufferStatusCompleted)fail(@"guest-GPU-failure");double gpu=done.GPUEndTime-done.GPUStartTime;GPUSeconds+=gpu;NCReply r=transact(NC_PRESENT,proxy.frame,proxy.surface,gpu);if(r.frame!=proxy.frame||r.surface!=proxy.surface)fail(@"present-identity");completions++;if(completions==1||completions%30==0)emit(@{@"type":@"proxy-frame",@"frame":@(proxy.frame),@"hostSurface":@(proxy.surface),@"importedSurface":@(IOSurfaceGetID(proxy.texture.iosurface)),@"reportedWindow":@(metadata.window),@"renderEncoders":@(renders),@"blitEncoders":@(blits),@"computeEncoders":@(computes),@"IPCSeconds":@(IPCSeconds),@"GPUSeconds":@(GPUSeconds),@"shimCreatedQueues":@(shimQueues),@"shimCreatedCommandBuffers":@0,@"surfaceCopyOperations":@0,@"pixelReadbacks":@0});dispatch_semaphore_signal(available);}];
}
static id commandBufferHook(id self,SEL cmd){id cb=((id(*)(id,SEL))queueOriginal)(self,cmd);if(!cb)fail(@"no-original-command-buffer");if(bufferClass&&bufferClass!=[cb class])fail(@"multiple-command-buffer-classes");if(!bufferClass){bufferClass=[cb class];Method p=class_getInstanceMethod(bufferClass,@selector(presentDrawable:));Method r=class_getInstanceMethod(bufferClass,@selector(renderCommandEncoderWithDescriptor:));Method b=class_getInstanceMethod(bufferClass,@selector(blitCommandEncoder));Method c=class_getInstanceMethod(bufferClass,@selector(computeCommandEncoder));if(!p||!r||!b||!c)fail(@"missing-public-buffer-selector");presentOriginal=method_setImplementation(p,(IMP)presentHook);renderOriginal=method_setImplementation(r,(IMP)renderHook);blitOriginal=method_setImplementation(b,(IMP)blitHook);computeOriginal=method_setImplementation(c,(IMP)computeHook);}(void)presentOriginal;return cb;}
static id nextHook(CAMetalLayer*self,SEL cmd){(void)cmd;connectHost();if(self.pixelFormat!=MTLPixelFormatBGRA8Unorm)fail(@"unsupported-pixel-format");if(dispatch_semaphore_wait(available,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)))fail(@"previous-frame-incomplete");static dispatch_once_t once;dispatch_once(&once,^{id<MTLCommandQueue>q=[self.device newCommandQueue];shimQueues++;Method m=class_getInstanceMethod([q class],@selector(commandBuffer));if(!m)fail(@"missing-command-buffer-selector");queueOriginal=method_setImplementation(m,(IMP)commandBufferHook);});
 NCReply r=transact(NC_ACQUIRE,0,0,0);if(!(r.h.msgh_bits&MACH_MSGH_BITS_COMPLEX)||r.body.msgh_descriptor_count!=1||r.port.type!=MACH_MSG_PORT_DESCRIPTOR||r.window!=metadata.window)fail(@"invalid-surface-reply");IOSurfaceRef surface=IOSurfaceLookupFromMachPort(r.port.name);mach_port_deallocate(mach_task_self(),r.port.name);if(!surface||IOSurfaceGetID(surface)!=r.surface)fail(@"surface-port-identity");
 MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:r.width height:r.height mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;id<MTLTexture>texture=[self.device newTextureWithDescriptor:td iosurface:surface plane:0];if(!texture||!texture.iosurface||IOSurfaceGetID(texture.iosurface)!=r.surface)fail(@"same-surface-import-rejected");NCDrawable*drawable=[NCDrawable new];drawable.texture=texture;drawable.frame=r.frame;drawable.surface=r.surface;drawable.importedSurface=surface;imports++;return drawable;
}
__attribute__((constructor))static void install(void){@autoreleasepool{
 if(!getenv("READY_NO_COPY_PROXY_SERVICE"))fail(@"explicit-service-required");Class meta=object_getClass(NSWindow.class);Method awz=class_getClassMethod(NSWindow.class,@selector(allocWithZone:));Method alloc=class_getClassMethod(NSWindow.class,@selector(alloc));if(!awz||!alloc)fail(@"missing-window-allocation-selector");if(!class_addMethod(meta,@selector(allocWithZone:),(IMP)windowAlloc,method_getTypeEncoding(awz)))class_replaceMethod(meta,@selector(allocWithZone:),(IMP)windowAlloc,method_getTypeEncoding(awz));if(!class_addMethod(meta,@selector(alloc),(IMP)windowAllocSimple,method_getTypeEncoding(alloc)))class_replaceMethod(meta,@selector(alloc),(IMP)windowAllocSimple,method_getTypeEncoding(alloc));Method next=class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable));if(!next)fail(@"missing-nextDrawable-selector");method_setImplementation(next,(IMP)nextHook);emit(@{@"type":@"shim-installed",@"realNSWindowInitCalls":@0,@"originalNextDrawableCalls":@0,@"copyFallback":@NO});
}}
