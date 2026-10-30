// SPDX-License-Identifier: GPL-3.0-only
// Own IOSurfaces, real Mach rights and GPU clear/readback; no window or game.
#define CHECK(c) do{if(!(c)){fprintf(stderr,"own-texture-cache:%d\n",__LINE__);_exit(81);}}while(0)
static id<MTLDevice>ownDevice;
static CAMetalLayer *ownLayer;
static IOSurfaceRef ownSurface(uint32_t width,uint32_t height){
    size_t row=IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,width*4),size=IOSurfaceAlignProperty(kIOSurfaceAllocSize,row*height);
    return IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth:@(width),(id)kIOSurfaceHeight:@(height),(id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfaceBytesPerRow:@(row),(id)kIOSurfaceAllocSize:@(size),(id)kIOSurfacePixelFormat:@((uint32_t)'BGRA')});
}
static RHGReply ownIncoming(IOSurfaceRef surface,uint64_t generation,uint32_t width,uint32_t height,MTLPixelFormat format){
    mach_port_t receiver=MACH_PORT_NULL;CHECK(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&receiver)==KERN_SUCCESS);CHECK(mach_port_insert_right(mach_task_self(),receiver,receiver,MACH_MSG_TYPE_MAKE_SEND)==KERN_SUCCESS);
    RHGReply sent={0};sent.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0)|MACH_MSGH_BITS_COMPLEX;sent.h.msgh_remote_port=receiver;sent.h.msgh_size=sizeof sent;sent.body.msgh_descriptor_count=1;mach_port_t transferred=IOSurfaceCreateMachPort(surface);CHECK(transferred!=MACH_PORT_NULL);sent.port=(mach_msg_port_descriptor_t){.name=transferred,.disposition=MACH_MSG_TYPE_MOVE_SEND,.type=MACH_MSG_PORT_DESCRIPTOR};
    sent.window=4242;sent.surfaceID=IOSurfaceGetID(surface);sent.width=width;sent.height=height;sent.pixelFormat=(uint32_t)format;sent.deviceRegistryID=ownDevice.registryID;sent.configurationGeneration=generation;
    CHECK(mach_msg(&sent.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sent.h.msgh_size,0,MACH_PORT_NULL,1000,MACH_PORT_NULL)==KERN_SUCCESS);RHGReplyReceive received={0};CHECK(mach_msg(&received.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof received,receiver,1000,MACH_PORT_NULL)==KERN_SUCCESS);CHECK(received.message.body.msgh_descriptor_count==1&&received.message.port.disposition==MACH_MSG_TYPE_PORT_SEND);mach_port_destroy(mach_task_self(),receiver);return received.message;
}
static id<MTLTexture> ownLoad(IOSurfaceRef original,uint64_t generation,MTLPixelFormat format,MTLTextureUsage usage){
    uint32_t width=(uint32_t)IOSurfaceGetWidth(original),height=(uint32_t)IOSurfaceGetHeight(original);ownLayer.pixelFormat=format;
    RHGReply reply=ownIncoming(original,generation,width,height,format);RHGRequest config={.width=width,.height=height};
    pthread_mutex_lock(&rhgAcquisitionLock);IOSurfaceRef surface=rhgValidatedAcquireSurface(ownLayer,reply,config);id<MTLTexture>texture=rhgTextureForSurface(ownDevice,surface,generation,width,height,format,usage);CFRelease(surface);pthread_mutex_unlock(&rhgAcquisitionLock);return texture;
}
static void ownClearCache(void){pthread_mutex_lock(&rhgAcquisitionLock);rhgClearImportedTextures();pthread_mutex_unlock(&rhgAcquisitionLock);}
static BOOL ownCached(IOSurfaceRef surface){for(RHGImportedTextureEntry *entry in rhgImportedTextures)if(entry.surfaceID==IOSurfaceGetID(surface))return YES;return NO;}
static void ownColor(id<MTLTexture>texture,IOSurfaceRef surface,double r,double g,double b){
    id<MTLResidencySet>residency=nil;if(@available(macOS 15.0,*)){MTLResidencySetDescriptor *descriptor=[MTLResidencySetDescriptor new];descriptor.initialCapacity=1;residency=[ownDevice newResidencySetWithDescriptor:descriptor error:nil];CHECK(residency);[residency addAllocation:texture];[residency commit];[residency requestResidency];}
    id<MTLCommandQueue>queue=[ownDevice newCommandQueue];id<MTLCommandBuffer>buffer=[queue commandBuffer];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(r,g,b,1);id<MTLRenderCommandEncoder>encoder=[buffer renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];[buffer commit];[buffer waitUntilCompleted];CHECK(buffer.status==MTLCommandBufferStatusCompleted);[residency endResidency];
    CHECK(IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL)==kIOReturnSuccess);const uint8_t *bytes=IOSurfaceGetBaseAddress(surface);CHECK(bytes&&bytes[0]==(uint8_t)(b*255)&&bytes[1]==(uint8_t)(g*255)&&bytes[2]==(uint8_t)(r*255)&&bytes[3]==255);CHECK(IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL)==kIOReturnSuccess);
}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;alarm(20);const char *mode=argv[1];BOOL enabled=!strcmp(mode,"on")||!strncmp(mode,"bad-",4)||!strcmp(mode,"clear-active");CHECK(rhgTextureCacheEnabled()==enabled);
    ownDevice=MTLCreateSystemDefaultDevice();CHECK(ownDevice);ownLayer=[CAMetalLayer layer];ownLayer.device=ownDevice;ownLayer.pixelFormat=MTLPixelFormatBGRA8Unorm;rhgRenderLock=[NSLock new];rhgOutstandingFrames=[NSMutableArray new];
    RHGReply metadata={.window=4242,.width=4,.height=4,.pixelFormat=80,.deviceRegistryID=ownDevice.registryID,.backingScale=1,.logicalWidth=4,.logicalHeight=4};rhgMetadataFromReply(metadata);
    IOSurfaceRef a=ownSurface(4,4),b=ownSurface(4,4),c=ownSurface(4,4),d=ownSurface(4,4),e=ownSurface(4,4);CHECK(a&&b&&c&&d&&e);MTLTextureUsage usage=MTLTextureUsageRenderTarget;
    id<MTLTexture>a0=ownLoad(a,1,MTLPixelFormatBGRA8Unorm,usage);ownColor(a0,a,1,0,0);
    if(!strncmp(mode,"bad-",4)){
        IOSurfaceRef supplied=!strcmp(mode,"bad-id")?b:a;RHGReply reply=ownIncoming(supplied,1,4,4,MTLPixelFormatBGRA8Unorm);RHGRequest config={.width=4,.height=4};
        if(!strcmp(mode,"bad-id"))reply.surfaceID=IOSurfaceGetID(a);if(!strcmp(mode,"bad-size")){reply.width=8;config.width=8;}if(!strcmp(mode,"bad-device"))reply.deviceRegistryID++;if(!strcmp(mode,"bad-window"))reply.window++;
        pthread_mutex_lock(&rhgAcquisitionLock);(void)rhgValidatedAcquireSurface(ownLayer,reply,config);return 82;
    }
    if(!strcmp(mode,"clear-active")){RHGDrawable *frame=[RHGDrawable new];frame.texture=a0;[rhgOutstandingFrames addObject:frame];ownClearCache();return 83;}
    id<MTLTexture>a1=ownLoad(a,1,MTLPixelFormatBGRA8Unorm,usage);ownColor(a1,a,0,1,0);
    if(!enabled){CHECK(rhgImportedTextures.count==0&&rhgPerformance.textureCache.imports==2&&rhgPerformance.textureCache.hits==0);}
    else{
        CHECK(a0==a1&&rhgImportedTextures.count==1&&rhgPerformance.textureCache.imports==1&&rhgPerformance.textureCache.hits==1);
        RHGDrawable *held=[RHGDrawable new];held.texture=a0;held.importedSurface=(IOSurfaceRef)CFRetain(a);
        id<MTLTexture>generation=ownLoad(a,2,MTLPixelFormatBGRA8Unorm,usage);CHECK(generation&&rhgPerformance.textureCache.imports==2&&rhgImportedTextures.count==2);
        MTLTextureUsage expanded=usage|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;id<MTLTexture>differentUsage=ownLoad(a,2,MTLPixelFormatBGRA8Unorm,expanded);CHECK(differentUsage!=generation&&differentUsage.usage==expanded);
        id<MTLTexture>differentFormat=ownLoad(a,2,MTLPixelFormatBGRA8Unorm_sRGB,expanded);CHECK(differentFormat!=differentUsage&&differentFormat.pixelFormat==MTLPixelFormatBGRA8Unorm_sRGB&&rhgImportedTextures.count==3);
        ownColor(held.texture,a,0,0,1);ownClearCache();CHECK(rhgImportedTextures.count==0);ownColor(held.texture,a,1,1,0);
        id<MTLTexture>newA=ownLoad(a,3,MTLPixelFormatBGRA8Unorm,usage);id<MTLTexture>newB=ownLoad(b,3,MTLPixelFormatBGRA8Unorm,usage);(void)ownLoad(c,3,MTLPixelFormatBGRA8Unorm,usage);CHECK(rhgImportedTextures.count==3);CHECK(ownLoad(a,3,MTLPixelFormatBGRA8Unorm,usage)==newA);
        RHGDrawable *active=[RHGDrawable new];active.texture=newB;[rhgRenderLock lock];[rhgOutstandingFrames addObject:active];[rhgRenderLock unlock];(void)ownLoad(d,3,MTLPixelFormatBGRA8Unorm,usage);CHECK(ownCached(a)&&ownCached(b)&&ownCached(d)&&!ownCached(c)&&rhgImportedTextures.count==3);
        // Defensive helper coverage: simulate all cached wrappers being pinned.
        // This is not a change to the production two-frame protocol limit.
        [rhgRenderLock lock];[rhgOutstandingFrames removeAllObjects];for(RHGImportedTextureEntry *entry in rhgImportedTextures){RHGDrawable *frame=[RHGDrawable new];frame.texture=entry.texture;[rhgOutstandingFrames addObject:frame];}[rhgRenderLock unlock];uint64_t fallbacks=rhgPerformance.textureCache.fallbacks;id<MTLTexture>uncached=ownLoad(e,3,MTLPixelFormatBGRA8Unorm,usage);CHECK(uncached&&!ownCached(e)&&rhgImportedTextures.count==3&&rhgPerformance.textureCache.fallbacks==fallbacks+1);ownColor(uncached,e,1,0,1);
        [rhgRenderLock lock];[rhgOutstandingFrames removeAllObjects];[rhgRenderLock unlock];ownClearCache();CHECK(rhgImportedTextures.count==0&&rhgPerformance.textureCache.maximumEntries<=3&&RHG_MAX_FRAMES_IN_FLIGHT==2);ownColor(held.texture,a,0,1,1);
    }
    CFRelease(a);CFRelease(b);CFRelease(c);CFRelease(d);CFRelease(e);
    NSDictionary *report=@{@"passed":@YES,@"cacheEnabled":@(enabled),@"realMachSurfaceRights":@YES,@"incomingSurfaceValidatedEveryTime":@YES,@"realGPUColorsAndCPUReadback":@YES,@"generationUsageFormatMisses":@(enabled),@"LRUSkipsOutstandingWrappers":@(enabled),@"allPinnedUsesUncachedFallback":@(enabled),@"callerTextureSurvivesCacheClear":@(enabled),@"cacheEntries":@(rhgImportedTextures.count),@"maximumEntries":@(rhgPerformance.textureCache.maximumEntries),@"imports":@(rhgPerformance.textureCache.imports),@"hits":@(rhgPerformance.textureCache.hits),@"frameDepthChanged":@NO,@"UIOrGameOrAccountUsed":@NO};NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return 0;
}}
