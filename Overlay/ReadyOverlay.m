// SPDX-License-Identifier: GPL-3.0-only
// Original Ready implementation. Hooks only documented Objective-C Metal/AppKit methods.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include "ReadyOverlay.h"

static NSRecursiveLock *RDLock;
static NSString *RDControlPath, *RDStatusPath;
static BOOL RDEnabled, RDVisible, RDInjectionSupported, RDMetal3Hooked, RDMetal4Hooked;
static NSInteger RDSelection;
static int64_t RDControlSequence = INT64_MIN;
static uint64_t RDFrameCount, RDOverlayFrameCount, RDActionSequence, RDGPUWorkCount;
static uint64_t RDControlReadCount, RDGPUCompletedCount, RDGPUFailureCount, RDMetal3GPUWorkCount, RDMetal4GPUWorkCount;
static NSString *RDRequestedAction = @"", *RDError = @"";
static NSMutableDictionary<NSString *, NSValue *> *RDOriginals;
static NSMapTable<id<MTLTexture>,id<CAMetalDrawable>> *RDLiveDrawables;
static _Thread_local BOOL RDEmitting;
static dispatch_source_t RDControlWatch;
static __weak CAMetalLayer *RDLastLayer;
static unsigned char RDDrawablesKey;
static void RDWriteStatus(void);
static void RDReadControl(void);
static void RDPrepareHooks(id<MTLDevice> device);

@interface RDRenderer : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) id<MTLSharedEvent> event;
@property(nonatomic,strong) id<MTLTexture> panel;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,id<MTLRenderPipelineState>> *pipelines;
@property(nonatomic) uint64_t eventValue;
@property(nonatomic) NSInteger panelSelection;
- (BOOL)encodeOn:(id<MTLCommandBuffer>)command texture:(id<MTLTexture>)texture layer:(CAMetalLayer *)layer;
@end
static RDRenderer *RDResources;

static NSString *RDMethodKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%p:%s", cls, sel_getName(selector)];
}
static IMP RDOriginal(id obj, SEL selector) {
    for (Class cls=object_getClass(obj);cls;cls=class_getSuperclass(cls)) {
        NSValue *v=RDOriginals[RDMethodKey(cls,selector)];if(v)return [v pointerValue];
    }
    return NULL;
}
static BOOL RDHook(Class cls, SEL selector, IMP replacement) {
    if(!cls || RDOriginals[RDMethodKey(cls,selector)])return NO;
    Method method=class_getInstanceMethod(cls,selector);if(!method)return NO;
    IMP original=method_getImplementation(method);
    if(original==replacement)return NO;
    RDOriginals[RDMethodKey(cls,selector)]=[NSValue valueWithPointer:original];
    class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));return YES;
}

static NSDictionary *RDStatus(void) {
    NSUInteger bytes=RDResources.panel ? RDResources.panel.allocatedSize : 0;
    return @{@"schema":@1,@"pid":@(getpid()),@"visible":@(RDVisible),@"selection":@(RDSelection),
        @"frameCount":@(RDFrameCount),@"overlayFrameCount":@(RDOverlayFrameCount),
        @"metalAllocatedBytes":@(bytes),@"trackedTextureBytes":@(bytes),
        @"gpuOverlaySubmissions":@(RDGPUWorkCount),
        @"metal3OverlaySubmissions":@(RDMetal3GPUWorkCount),@"metal4OverlaySubmissions":@(RDMetal4GPUWorkCount),
        @"completedGPUOverlaySubmissions":@(RDGPUCompletedCount),@"failedGPUOverlaySubmissions":@(RDGPUFailureCount),@"injectionSupported":@(RDInjectionSupported),
        @"metal3Hooked":@(RDMetal3Hooked),@"metal4Hooked":@(RDMetal4Hooked),
        @"requestedAction":RDRequestedAction ?: @"",@"actionSequence":@(RDActionSequence),
        @"controlSequence":@(RDControlSequence),@"error":RDError ?: @"",
        @"controlWatchActive":@(RDControlWatch!=nil),@"controlReadCount":@(RDControlReadCount),
        @"separateWindowCount":@0,@"separateLayerCount":@0,
        @"directToDisplayVerified":@NO};
}
static void RDWriteStatus(void) {
    // Wine services and wineserver inherit the injection environment too. A process
    // that never renders must not overwrite the actual game's session status.
    if(!RDStatusPath.length || RDFrameCount==0)return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:RDStatus() options:NSJSONWritingSortedKeys error:nil];
    if(data){[data writeToFile:RDStatusPath options:NSDataWritingAtomic error:nil];chmod(RDStatusPath.fileSystemRepresentation,0600);}
}
char *ReadyOverlayCopyStatusJSON(void) {
    [RDLock lock];NSData *d=[NSJSONSerialization dataWithJSONObject:RDStatus() options:0 error:nil];
    NSString *s=[[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding];char *result=strdup((s ?: @"{}").UTF8String);[RDLock unlock];return result;
}
static void RDSetVisible(BOOL visible, NSInteger selection) {
    RDVisible=visible;RDSelection=MAX(0,MIN(selection,1));
    // In-flight Metal commands retain their own resource references in completion handlers.
    // Drop ALL persistent overlay GPU resources immediately on hide; no hidden render loop.
    if(!visible)RDResources=nil;
    RDWriteStatus();
}
void ReadyOverlaySetStateForTesting(int visible,int selection){[RDLock lock];RDSetVisible(visible!=0,selection);[RDLock unlock];}
static void RDRequestAction(NSString *action) {
    RDRequestedAction=action;RDActionSequence++;if([action isEqual:@"resume"])RDSetVisible(NO,RDSelection);
    RDWriteStatus();
}
static void RDReadControl(void) {
    [RDLock lock];RDControlReadCount++;
    struct stat st;
    // Files must be owned by this login and not readable/writable by another user.
    if(lstat(RDControlPath.fileSystemRepresentation,&st)!=0 || !S_ISREG(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&0077)!=0 || st.st_size>16384){[RDLock unlock];return;}
    NSData *data=[NSData dataWithContentsOfFile:RDControlPath];
    NSDictionary *json=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if([json isKindOfClass:NSDictionary.class] && [json[@"sequence"] isKindOfClass:NSNumber.class]){
        int64_t seq=[json[@"sequence"] longLongValue];
        if(seq!=RDControlSequence){
            RDControlSequence=seq;RDRequestedAction=@"";
            RDSetVisible([json[@"visible"] boolValue],[json[@"selection"] integerValue]);
            NSString *action=json[@"action"];
            if([action isEqual:@"resume"] || [action isEqual:@"quit"])RDRequestAction(action);
        }
    }
    [RDLock unlock];
}
static void RDWatchControl(void) {
    if(!RDControlPath.length)return;
    NSString *directory=RDControlPath.stringByDeletingLastPathComponent;
    int fd=open(directory.fileSystemRepresentation,O_EVTONLY|O_CLOEXEC);
    if(fd<0)return;
    RDControlWatch=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,DISPATCH_VNODE_WRITE|DISPATCH_VNODE_RENAME|DISPATCH_VNODE_DELETE,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0));
    dispatch_source_set_event_handler(RDControlWatch,^{@autoreleasepool{RDReadControl();}});
    dispatch_source_set_cancel_handler(RDControlWatch,^{close(fd);});dispatch_resume(RDControlWatch);
}

static void RDText(CGContextRef context,NSString *text,CGFloat x,CGFloat y,CGFloat size,CGColorRef color) {
    CTFontRef font=CTFontCreateWithName(CFSTR("HelveticaNeue-Medium"),size,NULL);
    NSDictionary *attrs=@{(__bridge NSString *)kCTFontAttributeName:(__bridge id)font,
        (__bridge NSString *)kCTForegroundColorAttributeName:(__bridge id)color};
    NSAttributedString *a=[[NSAttributedString alloc]initWithString:text attributes:attrs];
    CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
    CGContextSetTextPosition(context,x,y);CTLineDraw(line,context);CFRelease(line);CFRelease(font);
}
@implementation RDRenderer
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if((self=[super init])){self.device=device;self.pipelines=[NSMutableDictionary dictionary];self.panelSelection=-1;}
    return self;
}
- (BOOL)updatePanel {
    if(self.panel && self.panelSelection==RDSelection)return YES;
    const size_t width=640,height=320,row=width*4;
    void *pixels=calloc(height,row);CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg=CGBitmapContextCreate(pixels,width,height,8,row,space,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);CGColorSpaceRelease(space);
    if(!cg){free(pixels);return NO;}
    CGContextSetRGBFillColor(cg,0.045,0.065,0.075,0.96);CGContextFillRect(cg,CGRectMake(0,0,width,height));
    CGContextSetRGBFillColor(cg,0.55,0.96,0.69,1);CGContextFillRect(cg,CGRectMake(0,height-5,width,5));
    CGColorRef white=CGColorCreateGenericRGB(0.96,0.98,0.97,1),muted=CGColorCreateGenericRGB(0.66,0.74,0.72,1);
    RDText(cg,@"READY",32,258,29,white);RDText(cg,@"Sessione di gioco",33,229,15,muted);
    for(NSInteger i=0;i<2;i++){
        CGRect rect=CGRectMake(24,138-i*65,592,53);
        if(i==RDSelection)CGContextSetRGBFillColor(cg,0.17,0.36,0.27,1);else CGContextSetRGBFillColor(cg,0.10,0.13,0.15,1);
        CGContextFillRect(cg,rect);
        RDText(cg,i==0 ? @"Riprendi":@"Chiudi il gioco",43,rect.origin.y+17,20,white);
    }
    RDText(cg,@"Invio / A  Seleziona       Esc / B  Riprendi",33,29,14,muted);
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    desc.usage=MTLTextureUsageShaderRead;desc.storageMode=MTLStorageModeShared;
    id<MTLTexture> texture=[self.device newTextureWithDescriptor:desc];texture.label=@"Ready overlay panel (visible only)";
    if(texture)[texture replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:pixels bytesPerRow:row];
    CGContextRelease(cg);free(pixels);CGColorRelease(white);CGColorRelease(muted);
    self.panel=texture;self.panelSelection=RDSelection;return texture!=nil;
}
- (id<MTLRenderPipelineState>)pipelineForFormat:(MTLPixelFormat)format {
    id<MTLRenderPipelineState> pipeline=self.pipelines[@(format)];if(pipeline)return pipeline;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct O {float4 p [[position]];float2 uv;};\n"
        "vertex O ready_vertex(uint i [[vertex_id]],constant float2 &size [[buffer(0)]]) {"
        "float2 p[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};"
        "O o;o.p=float4(p[i]*size,0,1);o.uv=float2((p[i].x+1)*.5,1-(p[i].y+1)*.5);return o;}\n"
        "fragment float4 ready_fragment(O v [[stage_in]],texture2d<float> panel [[texture(0)]]) {"
        "constexpr sampler s(filter::linear,address::clamp_to_edge);return panel.sample(s,v.uv);}";
    NSError *error=nil;id<MTLLibrary> lib=[self.device newLibraryWithSource:source options:nil error:&error];
    if(!lib){RDError=error.localizedDescription ?: @"Cannot compile overlay shader";return nil;}
    MTLRenderPipelineDescriptor *desc=[MTLRenderPipelineDescriptor new];desc.label=@"Ready in-drawable overlay";
    desc.vertexFunction=[lib newFunctionWithName:@"ready_vertex"];desc.fragmentFunction=[lib newFunctionWithName:@"ready_fragment"];
    desc.colorAttachments[0].pixelFormat=format;desc.colorAttachments[0].blendingEnabled=YES;
    desc.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorOne;desc.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;desc.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    pipeline=[self.device newRenderPipelineStateWithDescriptor:desc error:&error];
    if(!pipeline){RDError=error.localizedDescription ?: @"Cannot create overlay pipeline";return nil;}
    self.pipelines[@(format)]=pipeline;return pipeline;
}
- (BOOL)encodeOn:(id<MTLCommandBuffer>)command texture:(id<MTLTexture>)texture layer:(CAMetalLayer *)layer {
    if(![self updatePanel])return NO;
    id<MTLRenderPipelineState> pipeline=[self pipelineForFormat:texture.pixelFormat];if(!pipeline)return NO;
    if(@available(macOS 26.0,*)){if(layer.residencySet)[command useResidencySet:layer.residencySet];}
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=texture;
    pass.colorAttachments[0].loadAction=MTLLoadActionLoad;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder)return NO;
    encoder.label=@"Ready overlay: same game drawable";
    [encoder setRenderPipelineState:pipeline];[encoder setFragmentTexture:self.panel atIndex:0];
    // Ratios are the half-extent in normalized clip coordinates. Cap at 80% of drawable size.
    float extents[2]={fminf(0.8f,640.0f/(float)texture.width),fminf(0.8f,320.0f/(float)texture.height)};
    [encoder setVertexBytes:extents length:sizeof(extents) atIndex:0];[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[encoder endEncoding];
    // Some hosts use unretained command buffers. Explicitly retain what this pass needs until completion.
    id<MTLTexture> keepTexture=self.panel;id<MTLRenderPipelineState> keepPipeline=pipeline;
    [command addCompletedHandler:^(id<MTLCommandBuffer> done){
        (void)keepTexture;(void)keepPipeline;
        [RDLock lock];
        BOOL failed=done.status!=MTLCommandBufferStatusCompleted || done.error!=nil;
        if(failed){RDGPUFailureCount++;RDError=done.error.localizedDescription ?: @"Overlay command buffer did not complete successfully";}
        else RDGPUCompletedCount++;
        if(failed || RDGPUCompletedCount==1 || RDGPUCompletedCount%120==0)RDWriteStatus();
        [RDLock unlock];
    }];
    return YES;
}
@end

static RDRenderer *RDRendererForDevice(id<MTLDevice> device) {
    if(!RDResources || RDResources.device!=device)RDResources=[[RDRenderer alloc]initWithDevice:device];return RDResources;
}
static void RDPollControllers(void) {
    static NSMapTable<GCController *,NSNumber *> *previous;
    if(!previous)previous=[NSMapTable weakToStrongObjectsMapTable];
    for(GCController *controller in GCController.controllers){
        GCExtendedGamepad *pad=controller.extendedGamepad;if(!pad)continue;
        unsigned flags=(pad.buttonMenu.isPressed?1:0)|(pad.dpad.up.isPressed?2:0)|(pad.dpad.down.isPressed?4:0)|(pad.buttonA.isPressed?8:0)|(pad.buttonB.isPressed?16:0);
        unsigned old=[[previous objectForKey:controller]unsignedIntValue],edge=flags&~old;[previous setObject:@(flags) forKey:controller];
        if(edge&1)RDSetVisible(!RDVisible,RDSelection);
        if(RDVisible){if(edge&2)RDSetVisible(YES,0);if(edge&4)RDSetVisible(YES,1);if(edge&8)RDRequestAction(RDSelection==0?@"resume":@"quit");if(edge&16)RDRequestAction(@"resume");}
    }
}
static BOOL RDShouldRender(void) {
    RDPollControllers();return RDVisible;
}
static void RDRecordDrawable(id command,id<CAMetalDrawable> drawable) {
    if(!drawable || RDEmitting)return;
    NSMutableArray *drawables=objc_getAssociatedObject(command,&RDDrawablesKey);
    if(!drawables){drawables=[NSMutableArray array];objc_setAssociatedObject(command,&RDDrawablesKey,drawables,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    if(![drawables containsObject:drawable])[drawables addObject:drawable];
}
static id RDRenderEncoderHook(id self,SEL cmd,MTLRenderPassDescriptor *descriptor) {
    [RDLock lock];
    if(!RDEmitting){
        for(NSUInteger i=0;i<8;i++){
            id<MTLTexture> texture=descriptor.colorAttachments[i].texture;
            id<CAMetalDrawable> drawable=texture ? [RDLiveDrawables objectForKey:texture]:nil;
            if(!drawable && descriptor.colorAttachments[i].resolveTexture)drawable=[RDLiveDrawables objectForKey:descriptor.colorAttachments[i].resolveTexture];
            RDRecordDrawable(self,drawable);
        }
    }
    IMP original=RDOriginal(self,cmd);[RDLock unlock];
    return original ? ((id(*)(id,SEL,id))original)(self,cmd,descriptor):nil;
}
static void RDPresentHook(id self,SEL cmd,id<MTLDrawable> drawable) {
    [RDLock lock];
    if([drawable conformsToProtocol:@protocol(CAMetalDrawable)]){
        RDRecordDrawable(self,(id<CAMetalDrawable>)drawable);
    }
    IMP original=RDOriginal(self,cmd);[RDLock unlock];if(original)((void(*)(id,SEL,id))original)(self,cmd,drawable);
}
static void RDPresentTimedHook(id self,SEL cmd,id<MTLDrawable> drawable,CFTimeInterval time) {
    [RDLock lock];
    if([drawable conformsToProtocol:@protocol(CAMetalDrawable)]){
        RDRecordDrawable(self,(id<CAMetalDrawable>)drawable);
    }
    IMP original=RDOriginal(self,cmd);[RDLock unlock];if(original)((void(*)(id,SEL,id,CFTimeInterval))original)(self,cmd,drawable,time);
}
static void RDCommitHook(id<MTLCommandBuffer> self,SEL cmd) {
    [RDLock lock];
    BOOL firstPanel=RDResources.panel==nil;
    NSArray *drawables=objc_getAssociatedObject(self,&RDDrawablesKey);
    // Remove before submission: the app, not Ready, owns drawable recycling.
    objc_setAssociatedObject(self,&RDDrawablesKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for(id<CAMetalDrawable> drawable in drawables){
        RDFrameCount++;BOOL show=RDShouldRender();
        RDEmitting=YES;
        if(show && [RDRendererForDevice(self.device) encodeOn:self texture:drawable.texture layer:drawable.layer]){RDOverlayFrameCount++;RDGPUWorkCount++;RDMetal3GPUWorkCount++;}
        RDEmitting=NO;
    }
    IMP original=RDOriginal(self,cmd);
    BOOL report=drawables.count && (RDFrameCount==1 || RDFrameCount%120==0 || (firstPanel && RDResources.panel!=nil));
    if(report)RDWriteStatus();[RDLock unlock];if(original)((void(*)(id,SEL))original)(self,cmd);
}
static void RDSignalDrawableHook(id<MTL4CommandQueue> self,SEL cmd,id<MTLDrawable> raw) API_AVAILABLE(macos(26.0)) {
    [RDLock lock];
    if([raw conformsToProtocol:@protocol(CAMetalDrawable)]){
        id<CAMetalDrawable> drawable=(id<CAMetalDrawable>)raw;RDFrameCount++;
        BOOL firstPanel=RDResources.panel==nil;
        if(RDShouldRender()){
            RDRenderer *resources=RDRendererForDevice(drawable.texture.device);
            if(!resources.queue)resources.queue=[resources.device newCommandQueue];
            if(!resources.event)resources.event=[resources.device newSharedEvent];
            id<MTLCommandBuffer> overlay=[resources.queue commandBuffer];
            uint64_t begin=resources.eventValue+1,end=begin+1;
            if(overlay && resources.event){
                [overlay encodeWaitForEvent:resources.event value:begin];
                RDEmitting=YES;
                BOOL encoded=[resources encodeOn:overlay texture:drawable.texture layer:drawable.layer];
                RDEmitting=NO;
                if(encoded){
                    [overlay encodeSignalEvent:resources.event value:end];
                    // Order actual game work -> overlay work -> original drawable signal entirely on GPU.
                    [self signalEvent:resources.event value:begin];[overlay commit];[self waitForEvent:resources.event value:end];
                    resources.eventValue=end;RDOverlayFrameCount++;RDGPUWorkCount++;RDMetal4GPUWorkCount++;
                }
            }
        }
        if(RDFrameCount==1 || RDFrameCount%120==0 || (firstPanel && RDResources.panel!=nil))RDWriteStatus();
    }
    IMP original=RDOriginal(self,cmd);[RDLock unlock];if(original)((void(*)(id,SEL,id))original)(self,cmd,raw);
}
static id<CAMetalDrawable> RDNextDrawableHook(CAMetalLayer *self,SEL cmd) {
    [RDLock lock];RDLastLayer=self;RDPrepareHooks(self.device);IMP original=RDOriginal(self,cmd);[RDLock unlock];
    id<CAMetalDrawable> drawable=original ? ((id(*)(id,SEL))original)(self,cmd):nil;
    if(drawable){[RDLock lock];[RDLiveDrawables setObject:drawable forKey:drawable.texture];[RDLock unlock];}return drawable;
}
static void RDPrepareHooks(id<MTLDevice> device) {
    if(!device)return;
    BOOL changed=NO;
    if(!RDMetal3Hooked){
        id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> buffer=[queue commandBuffer];Class cls=object_getClass(buffer);
        if(cls){RDHook(cls,@selector(presentDrawable:),(IMP)RDPresentHook);RDHook(cls,@selector(presentDrawable:atTime:),(IMP)RDPresentTimedHook);RDHook(cls,@selector(presentDrawable:afterMinimumDuration:),(IMP)RDPresentTimedHook);RDHook(cls,@selector(renderCommandEncoderWithDescriptor:),(IMP)RDRenderEncoderHook);RDHook(cls,@selector(parallelRenderCommandEncoderWithDescriptor:),(IMP)RDRenderEncoderHook);RDHook(cls,@selector(commit),(IMP)RDCommitHook);RDMetal3Hooked=YES;changed=YES;}
    }
    if(@available(macOS 26.0,*)){
        if(!RDMetal4Hooked && [device respondsToSelector:@selector(newMTL4CommandQueue)]){
            id<MTL4CommandQueue> queue=[device newMTL4CommandQueue];Class cls=object_getClass(queue);
            if(cls){RDHook(cls,@selector(signalDrawable:),(IMP)RDSignalDrawableHook);RDMetal4Hooked=YES;changed=YES;}
        }
    }
    RDInjectionSupported=RDMetal3Hooked || RDMetal4Hooked;if(changed)RDWriteStatus();
}
static void RDSendEventHook(NSApplication *self,SEL cmd,NSEvent *event) {
    [RDLock lock];BOOL consumed=NO;
    static NSMutableIndexSet *consumedKeys;
    static NSMutableIndexSet *consumedButtons;
    if(!consumedKeys){consumedKeys=[NSMutableIndexSet indexSet];consumedButtons=[NSMutableIndexSet indexSet];}
    if(event.type==NSEventTypeKeyDown){
        BOOL toggle=event.keyCode==49 && (event.modifierFlags&NSEventModifierFlagControl) && (event.modifierFlags&NSEventModifierFlagShift);
        if(toggle && !event.isARepeat){RDSetVisible(!RDVisible,RDSelection);consumed=YES;}
        else if(RDVisible){
            consumed=YES;
            switch(event.keyCode){case 126:RDSetVisible(YES,0);break;case 125:RDSetVisible(YES,1);break;case 36:case 76:RDRequestAction(RDSelection==0?@"resume":@"quit");break;case 53:RDRequestAction(@"resume");break;default:break;}
        }
        if(consumed && !event.isARepeat)[consumedKeys addIndex:event.keyCode];
    }else if(event.type==NSEventTypeKeyUp){
        consumed=[consumedKeys containsIndex:event.keyCode];[consumedKeys removeIndex:event.keyCode];
    }else if(RDVisible && event.type==NSEventTypeLeftMouseDown){
        consumed=YES;[consumedButtons addIndex:0];NSView *view=[RDLastLayer.delegate isKindOfClass:NSView.class] ? (NSView *)RDLastLayer.delegate:event.window.contentView;NSPoint p=[view convertPoint:event.locationInWindow fromView:nil];
        CGFloat w=view.bounds.size.width,h=view.bounds.size.height;
        if(view.isFlipped)p.y=h-p.y;
        // Game drawable resolution may differ from Retina backing resolution. Use the
        // exact same normalized extents as the renderer, not an assumed pixel scale.
        CGSize drawableSize=RDLastLayer.drawableSize;
        CGFloat panelW=w*fmin(0.8,640/fmax(drawableSize.width,1)),panelH=h*fmin(0.8,320/fmax(drawableSize.height,1));
        CGFloat nx=(p.x-(w-panelW)/2)/panelW,ny=(p.y-(h-panelH)/2)/panelH;
        if(nx>=24.0/640 && nx<=616.0/640){
            if(ny>=138.0/320 && ny<=191.0/320){RDSetVisible(YES,0);RDRequestAction(@"resume");}
            else if(ny>=73.0/320 && ny<=126.0/320){RDSetVisible(YES,1);RDRequestAction(@"quit");}
        }
    }else if(event.type==NSEventTypeLeftMouseUp || event.type==NSEventTypeRightMouseUp || event.type==NSEventTypeOtherMouseUp){consumed=[consumedButtons containsIndex:event.buttonNumber];[consumedButtons removeIndex:event.buttonNumber];}
    else if(RDVisible && (event.type==NSEventTypeRightMouseDown || event.type==NSEventTypeOtherMouseDown)){consumed=YES;[consumedButtons addIndex:event.buttonNumber];}
    else if(RDVisible && event.type==NSEventTypeScrollWheel)consumed=YES;
    IMP original=RDOriginal(self,cmd);[RDLock unlock];if(!consumed && original)((void(*)(id,SEL,id))original)(self,cmd,event);
}
__attribute__((constructor))static void RDLoad(void){@autoreleasepool{
    const char *control=getenv("M1L_CONTROL_FILE");if(!control || !*control)return;
    RDEnabled=YES;RDLock=[NSRecursiveLock new];RDOriginals=[NSMutableDictionary dictionary];RDLiveDrawables=[NSMapTable weakToWeakObjectsMapTable];
    RDControlPath=[NSString stringWithUTF8String:control];const char *status=getenv("M1L_OVERLAY_STATUS");
    RDStatusPath=status ? [NSString stringWithUTF8String:status]:[RDControlPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"overlay-status.json"];
    RDHook(CAMetalLayer.class,@selector(nextDrawable),(IMP)RDNextDrawableHook);
    RDHook(NSApplication.class,@selector(sendEvent:),(IMP)RDSendEventHook);
    RDReadControl();RDWatchControl();RDWriteStatus();
}}
