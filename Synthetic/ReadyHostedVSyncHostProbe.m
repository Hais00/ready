// SPDX-License-Identifier: GPL-3.0-only
// Prepended to the exact production RHGFormat/RHGConfigureLayer functions by
// test_hosted_vsync.py. Real CAMetalLayer property adoption; no drawable/GPU/UI.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "ReadyHostedGameProtocol.h"
@interface FixtureRegistryDevice:NSObject @end
@implementation FixtureRegistryDevice
-(uint64_t)registryID{return 42;}
@end
@interface RHGHost:NSObject
@property(strong)CAMetalLayer *metal;
@property(strong)id<MTLDevice>device;
@property(strong)id drawable;
@property(strong)NSMutableArray *slots;
@property uint64_t configurationGeneration;
@property BOOL configured;
@property BOOL acquirePending;
@property unsigned changes;
@end
@implementation RHGHost
-(void)record:(NSString*)phase reason:(NSString*)reason{(void)phase;(void)reason;self.changes++;}
@end
static void RHGFill(RHGHost *host,RHGReply *reply){
 reply->configurationGeneration=host.configurationGeneration;reply->framesInFlight=1;
 reply->width=(uint32_t)host.metal.drawableSize.width;reply->height=(uint32_t)host.metal.drawableSize.height;reply->pixelFormat=(uint32_t)host.metal.pixelFormat;reply->deviceRegistryID=host.device.registryID;
}
