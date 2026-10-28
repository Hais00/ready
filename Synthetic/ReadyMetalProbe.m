// SPDX-License-Identifier: GPL-3.0-only
// Real Metal drawable test host. Does not link the overlay; it must be injected by dyld.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>

typedef char *(*StatusFn)(void);
typedef void (*SetStateFn)(int,int);
static void Pump(double duration){NSDate *until=[NSDate dateWithTimeIntervalSinceNow:duration];do{@autoreleasepool{NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.003] inMode:NSDefaultRunLoopMode dequeue:YES];if(event)[NSApp sendEvent:event];[NSApp updateWindows];}}while([until timeIntervalSinceNow]>0);}
static NSDictionary *Status(StatusFn fn){if(!fn)return @{};char *str=fn();NSData *d=[NSData dataWithBytes:str length:strlen(str)];free(str);return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] ?: @{};}
static void SavePNG(NSData *data,size_t width,size_t height,NSString *path){
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image=CGImageCreate(width,height,8,32,width*4,space,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little,provider,NULL,NO,kCGRenderingIntentDefault);
    NSURL *url=[NSURL fileURLWithPath:path];CGImageDestinationRef output=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
    if(output){CGImageDestinationAddImage(output,image,NULL);CGImageDestinationFinalize(output);CFRelease(output);}CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(space);
}
static NSUInteger ChangedPixels(NSData *a,NSData *b){
    if(a.length!=b.length)return NSUIntegerMax;const unsigned char *aa=a.bytes,*bb=b.bytes;NSUInteger n=0;
    for(NSUInteger i=0;i<a.length;i+=4)if(aa[i]!=bb[i] || aa[i+1]!=bb[i+1] || aa[i+2]!=bb[i+2])n++;return n;
}
static void SendKey(NSWindow *window,unsigned short code,NSEventModifierFlags flags){
    NSEvent *e=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];[NSApp sendEvent:e];
}
static void WriteControl(NSString *path,NSInteger sequence,BOOL visible,NSInteger selection,mode_t mode){
    NSDictionary *value=@{@"sequence":@(sequence),@"visible":@(visible),@"selection":@(selection)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];NSString *temp=[path stringByAppendingString:@".tmp"];[json writeToFile:temp options:0 error:nil];chmod(temp.fileSystemRepresentation,mode);rename(temp.fileSystemRepresentation,path.fileSystemRepresentation);Pump(0.3);
}
@interface ProbeDelegate:NSObject<NSApplicationDelegate,NSWindowDelegate>
@property BOOL closed;
@end
@implementation ProbeDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
- (void)windowWillClose:(NSNotification *)note{self.closed=YES;}
@end
@interface ProbeView:NSView
@end
@implementation ProbeView
- (BOOL)isOpaque{return YES;}
- (CALayer *)makeBackingLayer{return [CAMetalLayer layer];}
@end

int main(int argc,const char **argv){@autoreleasepool{
    BOOL metal4=NO,fullScreen=NO,scheduled=NO,presentationOnly=NO,sessionProbe=NO;NSInteger frameCount=60;NSString *out=@"Evidence";
    for(int i=1;i<argc;i++){if(!strcmp(argv[i],"--metal4"))metal4=YES;else if(!strcmp(argv[i],"--scheduled-present"))scheduled=YES;else if(!strcmp(argv[i],"--fullscreen"))fullScreen=YES;else if(!strcmp(argv[i],"--presentation-probe"))presentationOnly=YES;else if(!strcmp(argv[i],"--session-probe"))sessionProbe=YES;else if(!strcmp(argv[i],"--output") && i+1<argc)out=[NSString stringWithUTF8String:argv[++i]];else if(!strcmp(argv[i],"--frames") && i+1<argc)frameCount=MAX(1,atoi(argv[++i]));}
    NSString *label=[NSString stringWithFormat:@"metal%d%@%@",metal4?4:3,scheduled?@"-scheduled":@"",presentationOnly?@"-presentation":@""];
#if defined(__x86_64__)
    label=[label stringByAppendingString:@"-x86_64"];
    NSString *architecture=@"x86_64";
#else
    NSString *architecture=@"arm64";
#endif
    [[NSFileManager defaultManager]createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
    [NSApplication sharedApplication];NSApp.activationPolicy=NSApplicationActivationPolicyRegular;ProbeDelegate *delegate=[ProbeDelegate new];NSApp.delegate=delegate;[NSApp finishLaunching];
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(100,100,960,540) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
    window.title=metal4 ? @"Ready Metal 4 injection probe":@"Ready Metal 3 injection probe";window.delegate=delegate;window.backgroundColor=NSColor.blackColor;window.opaque=YES;window.titleVisibility=NSWindowTitleHidden;window.titlebarAppearsTransparent=YES;window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
    NSView *view=[[ProbeView alloc]initWithFrame:NSMakeRect(0,0,960,540)];view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;view.wantsLayer=YES;CAMetalLayer *layer=(CAMetalLayer *)view.layer;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device){fprintf(stderr,"Metal device unavailable\n");return 2;}
    layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.opaque=YES;layer.framebufferOnly=presentationOnly;layer.maximumDrawableCount=2;layer.displaySyncEnabled=YES;layer.presentsWithTransaction=NO;layer.drawableSize=CGSizeMake(960,540);window.contentView=view;
    [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];Pump(0.2);
    if(fullScreen){[window toggleFullScreen:nil];Pump(1.1);}
    if(presentationOnly){NSRect backing=[view convertRectToBacking:view.bounds];layer.contentsScale=window.backingScaleFactor;layer.drawableSize=backing.size;}
    StatusFn status=(StatusFn)dlsym(RTLD_DEFAULT,"ReadyOverlayCopyStatusJSON");SetStateFn setState=(SetStateFn)dlsym(RTLD_DEFAULT,"ReadyOverlaySetStateForTesting");
    if(!status || !setState){fprintf(stderr,"Overlay was not injected\n");return 3;}
    id<MTLCommandQueue> queue3=[device newCommandQueue];
    id<MTL4CommandQueue> queue4=nil;id<MTL4CommandBuffer> command4=nil;id<MTL4CommandAllocator> allocator4=nil;
    if(metal4){if(@available(macOS 26.0,*)){queue4=[device newMTL4CommandQueue];command4=[device newCommandBuffer];allocator4=[device newCommandAllocator];[queue4 addResidencySet:layer.residencySet];}else{fprintf(stderr,"Metal4 unavailable\n");return 4;}}
    NSMutableArray *phases=[NSMutableArray array];NSMutableArray<NSData *> *images=[NSMutableArray array];NSMutableDictionary *heartbeatTests=[NSMutableDictionary dictionary];
    for(int phase=0;phase<(sessionProbe?1:3);phase++){@autoreleasepool{
        if(!sessionProbe)setState(phase==1,0);Pump(0.03);NSDictionary *before=Status(status);CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();NSData *capture=nil;
        for(NSInteger n=0;n<frameCount && !delegate.closed;n++){@autoreleasepool{
            id<CAMetalDrawable> drawable=[layer nextDrawable];if(!drawable){fprintf(stderr,"No drawable\n");return 5;}
            MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0.035,0.12,0.20,1);
            if(!metal4){id<MTLCommandBuffer> cb=[queue3 commandBuffer];id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass];[enc endEncoding];if(scheduled)[cb addScheduledHandler:^(id<MTLCommandBuffer> command){[drawable present];}];else [cb presentDrawable:drawable];[cb commit];[cb waitUntilCompleted];if(cb.error){fprintf(stderr,"Metal3: %s\n",cb.error.description.UTF8String);return 6;}}
            else if(@available(macOS 26.0,*)){
                [allocator4 reset];[command4 beginCommandBufferWithAllocator:allocator4];
                MTL4RenderPassDescriptor *pass4=[MTL4RenderPassDescriptor new];pass4.colorAttachments[0].texture=drawable.texture;pass4.colorAttachments[0].loadAction=MTLLoadActionClear;pass4.colorAttachments[0].storeAction=MTLStoreActionStore;pass4.colorAttachments[0].clearColor=MTLClearColorMake(0.035,0.12,0.20,1);pass4.renderTargetWidth=drawable.texture.width;pass4.renderTargetHeight=drawable.texture.height;pass4.defaultRasterSampleCount=1;
                id<MTL4RenderCommandEncoder> enc=[command4 renderCommandEncoderWithDescriptor:pass4 options:MTL4RenderEncoderOptionNone];[enc endEncoding];[command4 endCommandBuffer];
                [queue4 waitForDrawable:drawable];id<MTL4CommandBuffer> commands[]={command4};[queue4 commit:commands count:1];[queue4 signalDrawable:drawable];[drawable present];
                // A diagnostic readback queue waits on a queue-level completion event before reading the image.
                id<MTLSharedEvent> done=[device newSharedEvent];[queue4 signalEvent:done value:1];id<MTLCommandBuffer> sync=[queue3 commandBuffer];[sync encodeWaitForEvent:done value:1];[sync commit];[sync waitUntilCompleted];
            }
            if(n==frameCount-1 && !presentationOnly && !sessionProbe){
                NSUInteger width=drawable.texture.width,height=drawable.texture.height,row=width*4;id<MTLBuffer> readback=[device newBufferWithLength:row*height options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> copy=[queue3 commandBuffer];id<MTLBlitCommandEncoder> blit=[copy blitCommandEncoder];[blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*height];[blit endEncoding];[copy commit];[copy waitUntilCompleted];capture=[NSData dataWithBytes:readback.contents length:readback.length];
                SavePNG(capture,width,height,[out stringByAppendingPathComponent:[NSString stringWithFormat:@"overlay-%@-phase%d.png",label,phase]]);
            }
            Pump(0.001);
            if(sessionProbe && n%120==0){
                NSDictionary *geometry=@{@"pid":@(getpid()),@"applicationActive":@(NSApp.isActive),@"keyWindow":@(window.isKeyWindow),@"mainWindow":@(window.isMainWindow),@"frontmostApplicationPID":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier),@"frontmostIsProbe":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==getpid()),@"occlusionVisible":@((window.occlusionState&NSWindowOcclusionStateVisible)!=0),@"windowOpaque":@(window.isOpaque),@"viewOpaque":@(view.isOpaque),@"presentsWithTransaction":@(layer.presentsWithTransaction),@"displayPixelWidth":@(CGDisplayPixelsWide([window.screen.deviceDescription[@"NSScreenNumber"]unsignedIntValue])),@"displayPixelHeight":@(CGDisplayPixelsHigh([window.screen.deviceDescription[@"NSScreenNumber"]unsignedIntValue])),@"frame":@(n),@"fullscreen":@(!!(window.styleMask&NSWindowStyleMaskFullScreen)),@"windowFrame":NSStringFromRect(window.frame),@"screenFrame":NSStringFromRect(window.screen.frame),@"viewFrame":NSStringFromRect(view.frame),@"layerFrame":NSStringFromRect(layer.frame),@"layerBounds":NSStringFromRect(layer.bounds),@"drawableWidth":@(layer.drawableSize.width),@"drawableHeight":@(layer.drawableSize.height),@"framebufferOnly":@(layer.framebufferOnly),@"layerOpaque":@(layer.opaque)};
                NSData *g=[NSJSONSerialization dataWithJSONObject:geometry options:NSJSONWritingPrettyPrinted error:nil];[g writeToFile:[out stringByAppendingPathComponent:@"overlay-probe-window.json"] atomically:YES];
            }
        }}
        if(!sessionProbe && phase>0){
            NSDictionary *pausedBefore=Status(status);Pump(1.3);NSDictionary *pausedAfter=Status(status);
            BOOL alive=[pausedAfter[@"heartbeatSequence"]unsignedLongLongValue]>[pausedBefore[@"heartbeatSequence"]unsignedLongLongValue]+2;
            BOOL noGPU=[pausedAfter[@"gpuOverlaySubmissions"]unsignedLongLongValue]==[pausedBefore[@"gpuOverlaySubmissions"]unsignedLongLongValue] && [pausedAfter[@"frameCount"]unsignedLongLongValue]==[pausedBefore[@"frameCount"]unsignedLongLongValue];
            BOOL resourceState=phase==1 || [pausedAfter[@"trackedTextureBytes"]unsignedLongLongValue]==0;
            heartbeatTests[phase==1?@"visiblePauseAliveWithoutGPUWork":@"hiddenPauseAliveWithoutGPUWorkOrTextures"]=@(alive && noGPU && resourceState);
        }
        if(capture)[images addObject:capture];NSDictionary *after=Status(status);
        [phases addObject:@{@"phase":@(phase),@"before":before,@"after":after,@"startUnixTime":@(began+kCFAbsoluteTimeIntervalSince1970),@"endUnixTime":@(CFAbsoluteTimeGetCurrent()+kCFAbsoluteTimeIntervalSince1970),@"seconds":@(CFAbsoluteTimeGetCurrent()-began),@"deviceCurrentAllocatedSize":@(device.currentAllocatedSize)}];
    }}
    if(sessionProbe){NSDictionary *result=@{@"status":Status(status),@"phases":phases};NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:[out stringByAppendingPathComponent:@"overlay-session.json"] atomically:YES];[window orderOut:nil];return 0;}
    NSDictionary *final=Status(status);BOOL passes=(presentationOnly || (images.count==3 && ChangedPixels(images[0],images[1])>10000 && ChangedPixels(images[0],images[2])==0)) && [final[@"trackedTextureBytes"]unsignedLongLongValue]==0 && [final[@"overlayFrameCount"]unsignedLongLongValue]>=frameCount;
    // Exercise the actual AppKit event hook. Quit is a request to the launcher, never an exit() here.
    SendKey(window,49,NSEventModifierFlagControl|NSEventModifierFlagShift);BOOL keyToggle=[Status(status)[@"visible"]boolValue];
    SendKey(window,125,0);SendKey(window,36,0);BOOL keyQuit=[Status(status)[@"requestedAction"]isEqual:@"quit"];
    SendKey(window,53,0);BOOL keyResume=![Status(status)[@"visible"]boolValue] && [Status(status)[@"requestedAction"]isEqual:@"resume"];
    uint64_t epochBefore=[Status(status)[@"inputCaptureEpoch"]unsignedLongLongValue];setState(YES,0);uint64_t epochOpen=[Status(status)[@"inputCaptureEpoch"]unsignedLongLongValue];setState(YES,1);BOOL epochOnlyOnOpen=epochOpen==epochBefore+1 && [Status(status)[@"inputCaptureEpoch"]unsignedLongLongValue]==epochOpen;setState(YES,0);uint64_t mouseActionBefore=[Status(status)[@"actionSequence"]unsignedLongLongValue];
    CGFloat mousePanelH=view.bounds.size.height*fmin(0.8,320/fmax(layer.drawableSize.height,1));
    NSPoint mousePoint=NSMakePoint(view.bounds.size.width/2,(view.bounds.size.height-mousePanelH)/2+mousePanelH*(99.5/320));
    mousePoint=[view convertPoint:mousePoint toView:nil];
    NSEvent *mouse=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:mousePoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];[NSApp sendEvent:mouse];
    BOOL mouseQuit=[Status(status)[@"requestedAction"]isEqual:@"quit"] && [Status(status)[@"actionSequence"]unsignedLongLongValue]>mouseActionBefore;
    setState(NO,0);
    NSString *control=[NSString stringWithUTF8String:getenv("M1L_CONTROL_FILE") ?: ""];
    WriteControl(control,2,YES,1,0600);BOOL fileShow=[Status(status)[@"visible"]boolValue] && [Status(status)[@"controlSequence"]integerValue]==2;
    WriteControl(control,3,NO,0,0644);BOOL insecureIgnored=[Status(status)[@"controlSequence"]integerValue]==2;
    WriteControl(control,4,NO,0,0600);BOOL fileHide=![Status(status)[@"visible"]boolValue] && [Status(status)[@"controlSequence"]integerValue]==4;
    passes=passes && epochOnlyOnOpen && keyToggle && keyQuit && keyResume && mouseQuit && fileShow && insecureIgnored && fileHide && [heartbeatTests[@"visiblePauseAliveWithoutGPUWork"]boolValue] && [heartbeatTests[@"hiddenPauseAliveWithoutGPUWorkOrTextures"]boolValue];
    NSDictionary *input=@{@"inputCaptureEpoch":@(epochOnlyOnOpen),@"keyboardToggle":@(keyToggle),@"keyboardQuitRequest":@(keyQuit),@"keyboardResume":@(keyResume),@"mouseQuitRequest":@(mouseQuit),@"controlFileShow":@(fileShow),@"insecureControlIgnored":@(insecureIgnored),@"controlFileHide":@(fileHide)};
    NSDictionary *result=@{@"schema":@1,@"processArchitecture":architecture,@"metalVersion":@(metal4?4:3),@"presentationStyle":scheduled?@"scheduledHandler":@"default",@"device":device.name,@"framesPerPhase":@(frameCount),@"phases":phases,@"inputTests":input,@"heartbeatTests":heartbeatTests,@"framebufferOnly":@(layer.framebufferOnly),@"fullscreen":@(!!(window.styleMask&NSWindowStyleMaskFullScreen)),@"windowCount":@(NSApp.windows.count),@"layerSublayerCount":@(layer.sublayers.count),@"changedPixelsShown":@(images.count>=2?ChangedPixels(images[0],images[1]):0),@"changedPixelsAfterHide":@(images.count==3?ChangedPixels(images[0],images[2]):0),@"passed":@(passes),@"directToDisplayVerified":@NO,@"note":presentationOnly ? @"Opaque framebuffer-only fullscreen-eligible presentation. Direct mode still requires authoritative Metal HUD or Instruments evidence.":@"Readback probe intentionally uses framebufferOnly=NO. It proves in-drawable injection and cleanup, not exclusive presentation or game compatibility."};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];[json writeToFile:[out stringByAppendingPathComponent:[NSString stringWithFormat:@"overlay-%@.json",label]] atomically:YES];puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    [window orderOut:nil];return passes?0:7;
}}
