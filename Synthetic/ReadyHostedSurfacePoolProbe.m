// SPDX-License-Identifier: GPL-3.0-only
// Own tiny window; real drawable pool, Metal writes and presentation. No capture/readback/input.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach.h>

@interface PoolEntry:NSObject
@property(nonatomic,assign)IOSurfaceRef surface;
@property(nonatomic,strong)id<MTLTexture>texture;
@end
@implementation PoolEntry
-(void)dealloc{if(_surface)CFRelease(_surface);}
@end
static NSString *failure;
static unsigned checks;
static BOOL require(BOOL value,NSString*label){checks++;if(!value&&!failure)failure=label;return value;}
static NSDictionary *phase(CAMetalLayer *layer,id<MTLDevice>device,BOOL cached){
 NSMutableDictionary<NSNumber*,PoolEntry*>*cache=[NSMutableDictionary new];
 NSMutableSet<NSNumber*>*seen=[NSMutableSet new];NSMutableArray*ids=[NSMutableArray new];
 NSMutableArray*times=[NSMutableArray new];NSMutableArray*acquireMS=[NSMutableArray new];
 id<MTLCommandQueue>queue=[device newCommandQueue];unsigned imports=0,hits=0,frames=0,maxCache=0;
 double began=CACurrentMediaTime();
 NSMutableArray<id<CAMetalDrawable>>*leases=[NSMutableArray new];
 for(unsigned batch=0;batch<48&&!failure;batch++){
  @autoreleasepool{
   // Two leases plus the currently displayed surface exercise all three pool buffers.
   // Acquiring all three before presenting would stall on the WindowServer front buffer.
   for(;leases.count<2&&!failure;){@autoreleasepool{
    double start=CACurrentMediaTime();id<CAMetalDrawable>d=[layer nextDrawable];
    [acquireMS addObject:@((CACurrentMediaTime()-start)*1000)];
    if(require(d!=nil,@"nextDrawable timed out"))[leases addObject:d];
   }}
   for(unsigned i=0;i<1&&!failure;i++){@autoreleasepool{
    id<CAMetalDrawable>d=leases.firstObject;[leases removeObjectAtIndex:0];
    IOSurfaceRef original=d.texture.iosurface;
    if(!require(original!=NULL,@"drawable has no IOSurface"))break;
    mach_port_t port=IOSurfaceCreateMachPort(original);
    if(!require(port!=MACH_PORT_NULL,@"surface port creation failed"))break;
    IOSurfaceRef incoming=IOSurfaceLookupFromMachPort(port);mach_port_deallocate(mach_task_self(),port);
    if(!require(incoming!=NULL,@"surface import failed"))break;
    uint32_t sid=IOSurfaceGetID(incoming);NSNumber*key=@(sid);[seen addObject:key];[ids addObject:key];
    PoolEntry*entry=cached?cache[key]:nil;
    if(entry){hits++;require(IOSurfaceGetID(entry.surface)==sid&&IOSurfaceGetWidth(entry.surface)==IOSurfaceGetWidth(incoming)&&IOSurfaceGetHeight(entry.surface)==IOSurfaceGetHeight(incoming),@"live cached surface identity or geometry changed");}
    else{
     MTLTextureDescriptor*desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:layer.pixelFormat width:layer.drawableSize.width height:layer.drawableSize.height mipmapped:NO];
     desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageRenderTarget;
     if(!layer.framebufferOnly)desc.usage|=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
     entry=[PoolEntry new];entry.surface=(IOSurfaceRef)CFRetain(incoming);
     entry.texture=[device newTextureWithDescriptor:desc iosurface:incoming plane:0];imports++;
     if(cached){if(!require(cache.count<3,@"cache would exceed genuine three-buffer pool")){CFRelease(incoming);break;}cache[key]=entry;maxCache=MAX(maxCache,(unsigned)cache.count);}
    }
    if(!require(entry.texture!=nil&&IOSurfaceGetID(entry.texture.iosurface)==sid,@"texture aliases wrong surface")){CFRelease(incoming);break;}
    id<MTLResidencySet>residency=nil;
    if(@available(macOS 15.0,*)){
     MTLResidencySetDescriptor*rd=[MTLResidencySetDescriptor new];rd.initialCapacity=1;
     residency=[device newResidencySetWithDescriptor:rd error:nil];
     if(!require(residency!=nil,@"residency unavailable")){CFRelease(incoming);break;}
     [residency addAllocation:entry.texture];[residency commit];[residency requestResidency];
    }
    MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=entry.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(cached?.14:.08,.12+(.04*(i%3)),.2,1);
    id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLRenderCommandEncoder>encoder=[cb renderCommandEncoderWithDescriptor:pass];
    if(!require(encoder!=nil,@"alias render encoder unavailable")){CFRelease(incoming);break;}
    [encoder endEncoding];[cb commit];[cb waitUntilCompleted];
    if(!require(cb.status==MTLCommandBufferStatusCompleted,@"GPU write did not complete")){CFRelease(incoming);break;}
    dispatch_semaphore_t shown=dispatch_semaphore_create(0);__block double stamp=0;
    [d addPresentedHandler:^(id<MTLDrawable>value){stamp=value.presentedTime;dispatch_semaphore_signal(shown);}];
    dispatch_sync(dispatch_get_main_queue(),^{[d presentAfterMinimumDuration:1.0/60.0];});
    BOOL presented=dispatch_semaphore_wait(shown,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0;
    require(presented,@"no presentation callback before deadline");if(presented&&stamp>0)[times addObject:@(stamp)];
    if(@available(macOS 15.0,*)){[residency endResidency];[residency removeAllAllocations];[residency commit];}
    CFRelease(incoming);frames++;d=nil;
   }}
  }
 }
 NSSet*stable=ids.count>3?[NSSet setWithArray:[ids subarrayWithRange:NSMakeRange(3,ids.count-3)]]:[NSSet set];
 require(frames==48,@"phase did not complete all frames");require(times.count>=12,@"fewer than twelve genuine on-screen presentations");require(stable.count==3,@"stable real pool did not reuse exactly three surfaces");
 require(cached?seen.count==3:seen.count<=4,@"unexpected pool surface replacement");
 require(cached?(imports==3&&hits==45):(imports==48&&hits==0),@"unexpected cache imports or hits");
 require(cached?cache.count==3:cache.count==0,@"unexpected cache retention");
 for(NSUInteger i=1;i<times.count;i++)require([times[i] doubleValue]>[times[i-1] doubleValue],@"presentation timestamps did not advance");
 NSDictionary*result=@{@"cacheEnabled":@(cached),@"frames":@(frames),@"actualPresentedFrames":@(times.count),@"uniqueSurfaceCount":@(seen.count),@"stableSurfaceCountAfterThreeWarmupFrames":@(stable.count),@"surfaceIDs":ids,@"presentedTimes":times,@"imports":@(imports),@"cacheHits":@(hits),@"maximumRetainedEntries":@(maxCache),@"acquireMilliseconds":acquireMS,@"elapsedSeconds":@(CACurrentMediaTime()-began)};
 [leases removeAllObjects];[cache removeAllObjects];return result;
}
int main(void){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();if(!require(device!=nil,@"Metal device unavailable"))return 1;
 NSWindow*window=[[NSWindow alloc]initWithContentRect:NSMakeRect(80,80,192,144) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 window.title=@"Ready own surface-pool regression";window.releasedWhenClosed=NO;
 NSView*view=[[NSView alloc]initWithFrame:NSMakeRect(0,0,192,144)];view.wantsLayer=YES;window.contentView=view;
 CAMetalLayer*layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;
 layer.frame=view.bounds;layer.drawableSize=CGSizeMake(192,144);layer.maximumDrawableCount=3;layer.allowsNextDrawableTimeout=YES;layer.displaySyncEnabled=YES;layer.presentsWithTransaction=NO;view.layer=layer;
 [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];[CATransaction flush];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{CFDictionaryRef session=CGSessionCopyCurrentDictionary();NSDictionary*sd=CFBridgingRelease(session);fprintf(stderr,"own-window visible:%d occlusionVisible:%d layerSize:%.0fx%.0f sessionLocked:%d\n",window.visible,(window.occlusionState&NSWindowOcclusionStateVisible)!=0,layer.bounds.size.width,layer.bounds.size.height,[sd[@"CGSSessionScreenIsLocked"]boolValue]);});
 __block BOOL done=NO;__block NSDictionary*report;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
  NSDictionary*uncached=phase(layer,device,NO);NSDictionary*cached=failure?@{}:phase(layer,device,YES);
  report=@{@"passed":@(!failure),@"checks":@(checks),@"failure":failure?:@"",@"uncached":uncached,@"cached":cached,@"poolMaximum":@3,@"sameIOSurfaceAliasGPUWrites":@YES,@"perFrameResidencyAfterGPUFence":@YES,@"screenCaptureOrReadbackOrInputOrGameUsed":@NO};
  dispatch_async(dispatch_get_main_queue(),^{done=YES;[NSApp stop:nil];NSEvent*wake=[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];[NSApp postEvent:wake atStart:NO];});
 }});
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,18*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!done){fprintf(stderr,"surface-pool probe overall deadline\n");[window orderOut:nil];_exit(2);}});
 [NSApp run];
 [window orderOut:nil];view.layer=nil;[window close];
 if(!done){fprintf(stderr,"surface-pool probe overall deadline\n");return 2;}
 NSData*json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return failure?1:0;
}}
