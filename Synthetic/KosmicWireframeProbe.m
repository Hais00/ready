// SPDX-License-Identifier: GPL-3.0-only
// Offscreen Metal 3/4 pixel readback, not a Kosmickrisp Vulkan implementation test.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <string.h>

static const NSUInteger Tile=128, Width=384, Height=128;
static NSDictionary *Run(id<MTLDevice> device,id<MTLRenderPipelineState> pipeline,BOOL metal4,BOOL strip){
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:Width height:Height mipmapped:NO];
    td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[device newTextureWithDescriptor:td];id<MTLCommandQueue> queue3=[device newCommandQueue];
    if(!texture || !queue3)return @{@"passed":@NO,@"error":@"Texture/queue unavailable"};
    MTLPrimitiveType primitive=strip?MTLPrimitiveTypeTriangleStrip:MTLPrimitiveTypeTriangle;
    if(!metal4){
        id<MTLCommandBuffer> cb=[queue3 commandBuffer];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
        id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass];[enc setRenderPipelineState:pipeline];[enc setCullMode:MTLCullModeNone];
        for(NSUInteger tile=0;tile<3;tile++){
            [enc setViewport:(MTLViewport){tile*Tile,0,Tile,Height,0,1}];[enc setTriangleFillMode:tile==1?MTLTriangleFillModeLines:MTLTriangleFillModeFill];
            [enc drawPrimitives:primitive vertexStart:0 vertexCount:3];
        }
        [enc endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error)return @{@"passed":@NO,@"error":cb.error.description};
    }else if(@available(macOS 26.0,*)){
        NSError *error=nil;MTLResidencySetDescriptor *rd=[MTLResidencySetDescriptor new];rd.initialCapacity=1;
        id<MTLResidencySet> residency=[device newResidencySetWithDescriptor:rd error:&error];if(!residency)return @{@"passed":@NO,@"error":error.description ?: @"No residency set"};
        [residency addAllocation:texture];[residency commit];
        id<MTL4CommandQueue> queue4=[device newMTL4CommandQueue];[queue4 addResidencySet:residency];
        id<MTL4CommandBuffer> cb=[device newCommandBuffer];id<MTL4CommandAllocator> allocator=[device newCommandAllocator];[cb beginCommandBufferWithAllocator:allocator];
        MTL4RenderPassDescriptor *pass=[MTL4RenderPassDescriptor new];pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);pass.renderTargetWidth=Width;pass.renderTargetHeight=Height;pass.defaultRasterSampleCount=1;
        id<MTL4RenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass options:MTL4RenderEncoderOptionNone];[enc setRenderPipelineState:pipeline];[enc setCullMode:MTLCullModeNone];
        for(NSUInteger tile=0;tile<3;tile++){
            [enc setViewport:(MTLViewport){tile*Tile,0,Tile,Height,0,1}];[enc setTriangleFillMode:tile==1?MTLTriangleFillModeLines:MTLTriangleFillModeFill];
            [enc drawPrimitives:primitive vertexStart:0 vertexCount:3];
        }
        [enc endEncoding];[cb endCommandBuffer];id<MTL4CommandBuffer> commands[]={cb};[queue4 commit:commands count:1];
        id<MTLSharedEvent> done=[device newSharedEvent];[queue4 signalEvent:done value:1];
        if(![done waitUntilSignaledValue:1 timeoutMS:5000])return @{@"passed":@NO,@"error":@"Metal 4 GPU completion timeout"};
        [queue4 removeResidencySet:residency];
    }else return @{@"passed":@NO,@"error":@"Metal 4 unavailable"};
    NSUInteger row=Width*4;id<MTLBuffer> buffer=[device newBufferWithLength:row*Height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> copy=[queue3 commandBuffer];id<MTLBlitCommandEncoder> blit=[copy blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(Width,Height,1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*Height];[blit endEncoding];[copy commit];[copy waitUntilCompleted];
    if(copy.error)return @{@"passed":@NO,@"error":copy.error.description};
    const unsigned char *p=buffer.contents;NSUInteger counts[3]={0};BOOL center[3]={0};NSUInteger differentResetPixels=0;
    for(NSUInteger y=0;y<Height;y++)for(NSUInteger x=0;x<Tile;x++){
        for(NSUInteger t=0;t<3;t++){const unsigned char *px=p+y*row+(x+t*Tile)*4;BOOL white=px[0]>240&&px[1]>240&&px[2]>240;counts[t]+=white;if(x==Tile/2&&y==Height/2)center[t]=white;}
        if(memcmp(p+y*row+x*4,p+y*row+(x+2*Tile)*4,4))differentResetPixels++;
    }
    BOOL passed=counts[0]>3000&&counts[1]>100&&counts[1]<counts[0]/8&&counts[0]==counts[2]&&center[0]&&!center[1]&&center[2]&&differentResetPixels==0;
    return @{@"metalVersion":@(metal4?4:3),@"topology":strip?@"triangleStrip":@"triangle",@"filledWhitePixels":@(counts[0]),@"wireframeWhitePixels":@(counts[1]),@"resetFilledWhitePixels":@(counts[2]),@"filledCenterWhite":@(center[0]),@"wireframeCenterWhite":@(center[1]),@"resetDifferentPixels":@(differentResetPixels),@"passed":@(passed)};
}
int main(void){@autoreleasepool{
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device){fprintf(stderr,"Metal unavailable\n");return 2;}
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 probe_vertex(uint id [[vertex_id]]) { constexpr float2 p[3]={float2(-0.75,-0.75),float2(0.75,-0.75),float2(0,0.75)};return float4(p[id],0.5,1); }\nfragment float4 probe_fragment(){return float4(1,1,1,1);}";
    NSError *error=nil;id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];if(!library){fprintf(stderr,"%s\n",error.description.UTF8String);return 3;}
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[library newFunctionWithName:@"probe_vertex"];pd.fragmentFunction=[library newFunctionWithName:@"probe_fragment"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];if(!pipeline){fprintf(stderr,"%s\n",error.description.UTF8String);return 3;}
    NSMutableArray *tests=[NSMutableArray array];BOOL passed=YES;for(int version=3;version<=4;version++)for(int strip=0;strip<2;strip++){NSDictionary *r=Run(device,pipeline,version==4,strip);[tests addObject:r];passed=passed&&[r[@"passed"]boolValue];}
    NSDictionary *result=@{@"schema":@1,@"device":device.name,@"width":@(Width),@"height":@(Height),@"tests":tests,@"passed":@(passed),@"kosmicPatched":@NO,@"vulkanRasterizationVerified":@NO,@"pointPolygonVerified":@NO,@"note":@"Native Metal triangle and strip fill/line/fill with actual GPU pixel readback. Not a Kosmickrisp Vulkan or DXVK compatibility test."};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);return passed?0:4;
}}
