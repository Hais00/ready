// SPDX-License-Identifier: GPL-3.0-only
// Own artificial pixels only. Exactly one own-window ScreenCaptureKit image;
// no display/broad-content capture, permission request, picker, or SCStream.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>
@interface CAContext:NSObject
+(void)setAllowsCGSConnections:(BOOL)value;
+(instancetype)remoteContextWithOptions:(NSDictionary*)options;
@property(strong)CALayer*layer;
@property(readonly)uint32_t contextId;
-(void)invalidate;
@end
@interface CALayerHost:CALayer
@property uint32_t contextId;
@end
@interface OwnLayerView:NSView @end
@implementation OwnLayerView
-(CALayer*)makeBackingLayer{return [NSClassFromString(@"CALayerHost")new];}
@end
static NSString*root;
static unsigned captureRequests,enumerationRequests;
static void jsonFile(NSDictionary*value,NSString*name){NSData*d=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];NSString*p=[root stringByAppendingPathComponent:name];[d writeToFile:p atomically:YES];chmod(p.fileSystemRepresentation,0600);}
static NSDictionary*readJSON(NSString*name){NSData*d=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:name]];return d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
static void emit(NSDictionary*value){NSData*d=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);fflush(stdout);}
static void stopLoop(void){[NSApp stop:nil];[NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0]atStart:NO];}
static SCWindow*ownWindow(NSArray<SCWindow*>*windows,CGWindowID identity){for(SCWindow*w in windows)if(w.windowID==identity&&w.owningApplication.processID==getpid())return w;return nil;}
static CGImageRef acceptedImage(CGImageRef image,NSError*error){return error?NULL:image;}
static BOOL writePNG(CGImageRef image,NSString*name){NSString*p=[root stringByAppendingPathComponent:name];CGImageDestinationRef d=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:p],CFSTR("public.png"),1,NULL);if(!d)return NO;CGImageDestinationAddImage(d,image,NULL);BOOL done=CGImageDestinationFinalize(d);CFRelease(d);if(done)chmod(p.fileSystemRepresentation,0600);return done;}
static NSMutableData*rgba(CGImageRef image,size_t width,size_t height){NSMutableData*d=[NSMutableData dataWithLength:width*height*4];CGColorSpaceRef s=CGColorSpaceCreateDeviceRGB();CGContextRef c=CGBitmapContextCreate(d.mutableBytes,width,height,8,width*4,s,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);CGColorSpaceRelease(s);if(!c)return nil;CGContextSetInterpolationQuality(c,kCGInterpolationHigh);CGContextDrawImage(c,CGRectMake(0,0,width,height),image);CGContextRelease(c);return d;}
static CGImageRef imageForRGBA(NSData*d,size_t width,size_t height){CGColorSpaceRef s=CGColorSpaceCreateDeviceRGB();CGDataProviderRef p=CGDataProviderCreateWithCFData((__bridge CFDataRef)d);CGImageRef image=CGImageCreate(width,height,8,32,width*4,s,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big,p,NULL,false,kCGRenderingIntentDefault);CGDataProviderRelease(p);CGColorSpaceRelease(s);return image;}
static NSData*gaussian(NSData*input,size_t width,size_t height){
 enum{radius=16};double weights[radius*2+1],sum=0,sigma=8;for(int i=-radius;i<=radius;i++){weights[i+radius]=exp(-(i*i)/(2*sigma*sigma));sum+=weights[i+radius];}for(unsigned i=0;i<radius*2+1;i++)weights[i]/=sum;
 const uint8_t*src=input.bytes;NSMutableData*temporary=[NSMutableData dataWithLength:width*height*4],*result=[NSMutableData dataWithLength:width*height*4];uint8_t*tmp=temporary.mutableBytes,*out=result.mutableBytes;
 for(size_t y=0;y<height;y++)for(size_t x=0;x<width;x++)for(unsigned c=0;c<4;c++){double value=0;for(int i=-radius;i<=radius;i++){NSInteger xx=MAX(0,MIN((NSInteger)width-1,(NSInteger)x+i));value+=src[(y*width+xx)*4+c]*weights[i+radius];}tmp[(y*width+x)*4+c]=(uint8_t)lrint(value);}
 for(size_t y=0;y<height;y++)for(size_t x=0;x<width;x++)for(unsigned c=0;c<4;c++){double value=0;for(int i=-radius;i<=radius;i++){NSInteger yy=MAX(0,MIN((NSInteger)height-1,(NSInteger)y+i));value+=tmp[(yy*width+x)*4+c]*weights[i+radius];}out[(y*width+x)*4+c]=(uint8_t)lrint(value);}return result;
}
static NSDictionary*pixel(NSDictionary*unused,NSData*d,size_t width,size_t x,size_t y){(void)unused;const uint8_t*p=(const uint8_t*)d.bytes+(y*width+x)*4;return @{@"red":@(p[0]),@"green":@(p[1]),@"blue":@(p[2]),@"alpha":@(p[3])};}
static NSDictionary*verifyImage(CGImageRef image){
 NSMutableData*full=rgba(image,640,400),*small=rgba(image,160,100);if(!full||!small)return @{@"passed":@NO,@"reason":@"own-pixel-context-failed"};NSDictionary*left=pixel(nil,full,640,160,200),*right=pixel(nil,full,640,480,200);
 BOOL remote=[left[@"red"]intValue]>200&&[left[@"blue"]intValue]<40&&[left[@"green"]intValue]<40&&[right[@"blue"]intValue]>200&&[right[@"red"]intValue]<40&&[right[@"green"]intValue]<40;
 NSData*blur=gaussian(small,160,100);NSMutableData*dim=[blur mutableCopy];uint8_t*p=dim.mutableBytes;for(size_t i=0;i<160*100;i++)for(unsigned c=0;c<3;c++)p[i*4+c]=(uint8_t)lrint(p[i*4+c]*.5);
 NSDictionary*edgeOriginal=pixel(nil,small,160,79,50),*edgeBlur=pixel(nil,blur,160,79,50),*edgeDim=pixel(nil,dim,160,79,50);BOOL softened=[edgeOriginal[@"red"]intValue]>220&&[edgeOriginal[@"blue"]intValue]<40&&[edgeBlur[@"red"]intValue]>80&&[edgeBlur[@"blue"]intValue]>80&&abs([edgeBlur[@"red"]intValue]-[edgeBlur[@"blue"]intValue])<50;BOOL half=abs([edgeDim[@"red"]intValue]*2-[edgeBlur[@"red"]intValue])<=1&&abs([edgeDim[@"blue"]intValue]*2-[edgeBlur[@"blue"]intValue])<=1;
 CGImageRef b=imageForRGBA(blur,160,100),d=imageForRGBA(dim,160,100);BOOL files=writePNG(image,@"own-original.png")&&writePNG(b,@"own-blurred.png")&&writePNG(d,@"own-blurred-dim50.png");CGImageRelease(b);CGImageRelease(d);
 return @{@"passed":@(remote&&softened&&half&&files),@"remoteMetalPixelsIncluded":@(remote),@"notHostGreenBackgroundOrRedaction":@(remote),@"originalLeft":left,@"originalRight":right,@"originalBoundary":edgeOriginal,@"blurredBoundary":edgeBlur,@"dimmedBoundary":edgeDim,@"gaussianRadius":@16,@"gaussianSigma":@8,@"CPUOnlyBlur":@YES,@"downsampleWidth":@160,@"downsampleHeight":@100,@"blurVerified":@(softened),@"dim50Verified":@(half)};
}
static int guest(void){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];[NSApp finishLaunching];id<MTLDevice>device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue>queue=[device newCommandQueue];Class cls=NSClassFromString(@"CAContext");[(id)cls setAllowsCGSConnections:NO];NSString*__unsafe_unretained const*option=(NSString*__unsafe_unretained const*)dlsym(RTLD_DEFAULT,"kCAContextCIFilterBehavior");CAContext*context=[(id)cls remoteContextWithOptions:option?@{*option:@"ignore"}:@{}];CAMetalLayer*layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.frame=CGRectMake(0,0,640,400);layer.drawableSize=CGSizeMake(640,400);layer.opaque=YES;layer.displaySyncEnabled=YES;layer.framebufferOnly=YES;context.layer=layer;[CATransaction flush];
 NSString*shader=@"#include <metal_stdlib>\nusing namespace metal;vertex float4 v(uint i [[vertex_id]]){float2 p[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};return float4(p[i],0,1);}fragment float4 f(float4 p [[position]]){return p.x<320?float4(1,0,0,1):float4(0,0,1,1);}";NSError*error=nil;id<MTLLibrary>lib=[device newLibraryWithSource:shader options:nil error:&error];MTLRenderPipelineDescriptor*pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=[lib newFunctionWithName:@"f"];pd.colorAttachments[0].pixelFormat=layer.pixelFormat;id<MTLRenderPipelineState>pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];if(!context||!context.contextId||!pipeline)return 10;
 jsonFile(@{@"contextId":@(context.contextId),@"guestWindowCount":@(NSApp.windows.count)},@"context.json");__block unsigned frames=0,positive=0;__block BOOL done=NO;
 NSTimer*timer=[NSTimer scheduledTimerWithTimeInterval:1.0/30 repeats:YES block:^(NSTimer*t){
  if([NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"quit"]]){[t invalidate];jsonFile(@{@"guestWindowCount":@(NSApp.windows.count),@"nativeFrames":@(frames),@"positivePresentedFrames":@(positive),@"passed":@(frames>0&&positive>0&&NSApp.windows.count==0)},@"guest-result.json");dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{context.layer=nil;[context invalidate];done=YES;stopLoop();});return;}
  if(![NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"attached"]])return;
  id<CAMetalDrawable>d=[layer nextDrawable];if(!d)return;MTLRenderPassDescriptor*p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=d.texture;p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:p];[e setRenderPipelineState:pipeline];[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[e endEncoding];[d addPresentedHandler:^(id<MTLDrawable>draw){if(draw.presentedTime>0)dispatch_async(dispatch_get_main_queue(),^{positive++;if(positive==3)jsonFile(@{@"positive":@YES},@"ready.json");});}];[cb presentDrawable:d];[cb commit];frames++;
 }];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!done){[timer invalidate];_exit(11);}});[NSApp run];return 0;
}}
int main(int argc,char**argv){@autoreleasepool{
 umask(077);if(argc!=4)return 2;root=@(argv[2]);if(!strcmp(argv[1],"guest"))return guest();
 if(!strcmp(argv[1],"empty-control")){BOOL pass=ownWindow(@[],UINT32_MAX)==nil;emit(@{@"passed":@(pass),@"fallbackNil":@(pass),@"captureRequests":@0,@"permissionRequests":@0});return pass?0:3;}
 if(!strcmp(argv[1],"error-control")){BOOL pass=acceptedImage(NULL,[NSError errorWithDomain:@"OwnSyntheticDenial" code:1 userInfo:nil])==NULL;emit(@{@"passed":@(pass),@"fallbackNil":@(pass),@"captureRequests":@0,@"permissionRequests":@0});return pass?0:3;}
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];NSWindow*w=[[NSWindow alloc]initWithContentRect:NSMakeRect(100,100,640,400)styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];w.releasedWhenClosed=NO;w.hasShadow=NO;w.opaque=YES;w.backgroundColor=NSColor.greenColor;OwnLayerView*v=[[OwnLayerView alloc]initWithFrame:NSMakeRect(0,0,640,400)];v.wantsLayer=YES;w.contentView=v;[w makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];[CATransaction flush];CGWindowID identity=(CGWindowID)w.windowNumber;
 NSTask*task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@(argv[3])];task.arguments=@[@"guest",root,@(argv[3])];NSError*launchError=nil;if(![task launchAndReturnError:&launchError])return 4;
 __block BOOL attached=NO,started=NO,finished=NO;__block NSDictionary*result=nil;__block BOOL ownerMatched=NO;
 NSTimer*timer=[NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer*t){
  if(!attached){uint32_t cid=[readJSON(@"context.json")[@"contextId"]unsignedIntValue];if(cid){((CALayerHost*)v.layer).contextId=cid;[CATransaction flush];attached=YES;jsonFile(@{@"attached":@YES},@"attached");}}
  if(!started&&[readJSON(@"ready.json")[@"positive"]boolValue]){started=YES;enumerationRequests++;
   [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent*content,NSError*error){
    SCWindow*window=error?nil:ownWindow(content.windows,identity);if(!window){dispatch_async(dispatch_get_main_queue(),^{result=@{@"passed":@NO,@"fallbackNil":@YES,@"reason":@"own-window-unavailable",@"errorCode":@(error.code)};jsonFile(@{},@"quit");});return;}
    ownerMatched=window.owningApplication.processID==getpid();SCContentFilter*filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:window];SCStreamConfiguration*configuration=[SCStreamConfiguration new];configuration.width=640;configuration.height=400;configuration.showsCursor=NO;configuration.capturesAudio=NO;configuration.includeChildWindows=NO;configuration.ignoreShadowsSingleWindow=YES;configuration.preservesAspectRatio=YES;captureRequests++;
    [SCScreenshotManager captureImageWithFilter:filter configuration:configuration completionHandler:^(CGImageRef image,NSError*error){CGImageRef accepted=acceptedImage(image,error);NSDictionary*verified=accepted?verifyImage(accepted):@{@"passed":@NO,@"fallbackNil":@YES,@"errorCode":@(error.code),@"reason":@"own-one-shot-failed"};dispatch_async(dispatch_get_main_queue(),^{result=verified;jsonFile(@{},@"quit");});}];
   }];
  }
  if(started&&result&&!task.running){finished=YES;[t invalidate];stopLoop();}
 }];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,18*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!finished){jsonFile(@{},@"quit");[task terminate];_exit(5);}});[NSApp run];[timer invalidate];[task waitUntilExit];NSDictionary*guestResult=readJSON(@"guest-result.json");((CALayerHost*)v.layer).contextId=0;[w orderOut:nil];v.layer=nil;[w close];BOOL passed=[result[@"passed"]boolValue]&&[guestResult[@"passed"]boolValue]&&ownerMatched&&captureRequests==1&&enumerationRequests==1&&task.terminationStatus==0;NSMutableDictionary*report=[result mutableCopy]?:[NSMutableDictionary new];report[@"passed"]=@(passed);report[@"guest"]=guestResult?:@{};report[@"captureRequests"]=@(captureRequests);report[@"currentProcessEnumerationRequests"]=@(enumerationRequests);report[@"ownWindowOwnerPIDMatched"]=@(ownerMatched);report[@"broadEnumerationUsed"]=@NO;report[@"continuousSCStreamCreated"]=@NO;report[@"permissionRequestOrPreflightOrPickerUsed"]=@NO;report[@"artificialPixelsOnly"]=@YES;emit(report);return passed?0:6;
}}
