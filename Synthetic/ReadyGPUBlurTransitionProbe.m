// SPDX-License-Identifier: GPL-3.0-only
// Appended to the unchanged production renderer class; owned offscreen pixels.
@interface OwnedBlurDrawable:NSObject<CAMetalDrawable>
@property(strong)id<MTLTexture> texture;
@property(strong)CAMetalLayer *layer;
@property NSUInteger drawableID;
@property CFTimeInterval presentedTime;
@end
@implementation OwnedBlurDrawable
-(void)present{}
-(void)presentAtTime:(double)t{(void)t;}
-(void)presentAfterMinimumDuration:(double)t{(void)t;}
-(void)addPresentedHandler:(MTLDrawablePresentedHandler)handler{(void)handler;}
@end
#define require(x) do{if(!(x)){fprintf(stderr,"transition-fixture-line:%d\n",__LINE__);return 2;}checks++;}while(0)
int main(void){@autoreleasepool{
 unsigned checks=0;RHGOverlayTransition curve={0};RHGOverlayTransitionRetarget(&curve,1,10,.2);
 double previous=-1;for(unsigned i=0;i<=10;i++){double a=RHGOverlayTransitionValue(curve,10+i*.02);require(a>=previous&&a>=0&&a<=1);previous=a;}
 require(fabs(RHGOverlayTransitionValue(curve,10.1)-.5)<1e-8);
 double mid=RHGOverlayTransitionValue(curve,10.07);RHGOverlayTransitionRetarget(&curve,0,10.07,.2);
 require(fabs(RHGOverlayTransitionValue(curve,10.07)-mid)<1e-8&&RHGOverlayTransitionValue(curve,10.3)==0);
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();require(device!=nil);id<MTLCommandQueue>queue=[device newCommandQueue];
 RHGOverlayBlurRenderer*renderer=[[RHGOverlayBlurRenderer alloc]initWithDevice:device format:MTLPixelFormatBGRA8Unorm];require(renderer!=nil);
 unsigned compilations=rhgOverlayPipelineCompilations;
 RHGOverlayBlurRenderer*reopened=[[RHGOverlayBlurRenderer alloc]initWithDevice:device format:MTLPixelFormatBGRA8Unorm];
 require(reopened.pipeline==renderer.pipeline&&rhgOverlayPipelineCompilations==compilations&&reopened.reduced==nil&&reopened.blurred==nil);
 MTLTextureDescriptor*descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
 OwnedBlurDrawable*drawable=[OwnedBlurDrawable new];drawable.texture=[device newTextureWithDescriptor:descriptor];drawable.layer=[CAMetalLayer layer];drawable.layer.device=device;drawable.layer.framebufferOnly=NO;
 uint8_t pixels[64*64*4],result[64*64*4];NSMutableArray*levels=[NSMutableArray new];
 for(unsigned step=0;step<=4;step++){
  for(unsigned i=0;i<64*64;i++){pixels[i*4]=20;pixels[i*4+1]=80;pixels[i*4+2]=160;pixels[i*4+3]=255;}
  [drawable.texture replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:pixels bytesPerRow:64*4];
  float a=step*.25;renderer->transition=(RHGOverlayTransition){a,a,0,0};id<MTLCommandBuffer>command=[queue commandBuffer];
  require([renderer encodeOn:command drawable:drawable]);[command commit];[command waitUntilCompleted];require(command.status==MTLCommandBufferStatusCompleted);
  [drawable.texture getBytes:result bytesPerRow:64*4 fromRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0];unsigned p=(32*64+32)*4;
  require(abs((int)result[p+2]-(int)lround(160*(1-.5*a)))<=3);
  require(abs((int)result[p+1]-(int)lround(80*(1-.5*a)))<=3&&result[p+3]>=253);
  [levels addObject:@{@"opacity":@(a),@"red":@(result[p+2])}];
 }
 for(unsigned y=0;y<64;y++)for(unsigned x=0;x<64;x++){unsigned p=(y*64+x)*4;pixels[p]=x<32?0:160;pixels[p+1]=0;pixels[p+2]=x<32?160:0;pixels[p+3]=255;}
 [drawable.texture replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:pixels bytesPerRow:64*4];renderer->transition=(RHGOverlayTransition){1,1,0,0};
 id<MTLCommandBuffer>command=[queue commandBuffer];require([renderer encodeOn:command drawable:drawable]);[command commit];[command waitUntilCompleted];require(command.status==MTLCommandBufferStatusCompleted);
 [drawable.texture getBytes:result bytesPerRow:64*4 fromRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0];unsigned p=(32*64+32)*4;require(result[p]>15&&result[p+2]>15);
 NSData*data=[NSJSONSerialization dataWithJSONObject:@{@"passed":@YES,@"checks":@(checks),@"blendSamples":levels,@"actualOffscreenMPSAndMetalShader":@YES,@"gameOrScreenCaptureUsed":@NO}options:0 error:nil];puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);return 0;
}}
