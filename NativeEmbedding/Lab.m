#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <servers/bootstrap.h>
#import <unistd.h>

// Dedicated owned synthetic apps only. No screen capture, external task ports,
// or game hooks.
static double now(void) { return CACurrentMediaTime(); }
static void pump(double seconds) {
  NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
  do {
    NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:limit
                                           inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
    if (event)
      [NSApp sendEvent:event];
    [NSApp updateWindows];
  } while (limit.timeIntervalSinceNow > 0);
}

static void logline(NSString *s) {
  fprintf(stdout, "%s\n", s.UTF8String);
  fflush(stdout);
}
static NSString *option(int argc, char **argv, NSString *name,
                        NSString *fallback) {
  for (int i = 1; i + 1 < argc; i++)
    if ([name isEqualToString:@(argv[i])])
      return @(argv[i + 1]);
  return fallback;
}
static BOOL flag(int argc, char **argv, const char *name) {
  for (int i = 1; i < argc; i++)
    if (!strcmp(argv[i], name))
      return YES;
  return NO;
}
typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t surface;
  uint32_t frame, w, hgt;
  double produced, gpu;
} Frame;
typedef struct {
  mach_msg_header_t h;
  uint32_t frame, w, hgt, input;
} Ack;
typedef struct {
  Frame msg;
  mach_msg_max_trailer_t trailer;
} Receive;
static NSString *shader =
    @"#include <metal_stdlib>\nusing namespace metal;\nstruct V {float4 p "
    @"[[position]];float2 uv;};\nvertex V vs(uint i [[vertex_id]]) {float2 "
    @"p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};V "
    @"o;o.p=float4(p[i],0,1);o.uv=float2((p[i].x+1)*.5,1-(p[i].y+1)*.5);return "
    @"o;}\nvertex V tri(uint i [[vertex_id]]) {float2 "
    @"p[3]={float2(-.7,-.7),float2(.7,-.7),float2(0,.7)};V "
    @"o;o.p=float4(p[i],0,1);o.uv=float2(0);return o;}\nfragment float4 "
    @"solid(V v [[stage_in]],constant float4 &c [[buffer(0)]]) {return "
    @"c;}\nfragment float4 sampleSurface(V v [[stage_in]],texture2d<float> t "
    @"[[texture(0)]]) {constexpr sampler "
    @"s(coord::normalized,filter::nearest);return t.sample(s,v.uv);}";
static id<MTLRenderPipelineState> makePipeline(id<MTLDevice> d, BOOL sampling) {
  NSError *e = nil;
  id<MTLLibrary> l = [d newLibraryWithSource:shader options:nil error:&e];
  if (!l) {
    logline(e.description);
    exit(3);
  }
  MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
  p.vertexFunction = [l newFunctionWithName:sampling ? @"vs" : @"tri"];
  p.fragmentFunction =
      [l newFunctionWithName:sampling ? @"sampleSurface" : @"solid"];
  p.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  id r = [d newRenderPipelineStateWithDescriptor:p error:&e];
  if (!r) {
    logline(e.description);
    exit(3);
  }
  return r;
}
static id<MTLTexture> surfaceTexture(id<MTLDevice> d, IOSurfaceRef s,
                                     uint32_t w, uint32_t h) {
  MTLTextureDescriptor *t = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  t.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  t.storageMode = MTLStorageModeShared;
  return [d newTextureWithDescriptor:t iosurface:s plane:0];
}
@interface LabView : NSView
@property uint32_t inputCount;
@end
@implementation LabView
- (BOOL)acceptsFirstResponder {
  return YES;
}
- (void)mouseDown:(NSEvent *)e {
  self.inputCount++;
  logline([NSString stringWithFormat:@"INPUT pid=%d mouse=(%.1f,%.1f) count=%u",
                                     getpid(), e.locationInWindow.x,
                                     e.locationInWindow.y, self.inputCount]);
}
- (void)keyDown:(NSEvent *)e {
  self.inputCount++;
  logline([NSString stringWithFormat:@"INPUT pid=%d key=%u count=%u", getpid(),
                                     e.keyCode, self.inputCount]);
}
@end
static NSWindow *window(NSString *title, id<MTLDevice> d, CAMetalLayer **out,
                        LabView **viewOut) {
  NSWindow *w = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(50, 80, 640, 360)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  w.title = title;
  LabView *v = [[LabView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
  v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  v.wantsLayer = YES;
  CAMetalLayer *l = [CAMetalLayer layer];
  l.device = d;
  l.pixelFormat = MTLPixelFormatBGRA8Unorm;
  l.framebufferOnly = NO;
  l.drawableSize = CGSizeMake(640, 360);
  v.layer = l;
  w.contentView = v;
  [w makeFirstResponder:v];
  [w orderFront:nil];
  *out = l;
  if (viewOut)
    *viewOut = v;
  logline([NSString stringWithFormat:@"WINDOW pid=%d windowNumber=%ld view=%p "
                                     @"layer=%p visible=%d scale=%.2f",
                                     getpid(), (long)w.windowNumber, v, l,
                                     w.isVisible, w.backingScaleFactor]);
  return w;
}
static int probe(int argc, char **argv) {
  logline([NSString
      stringWithFormat:@"PROBE pid=%d dyld_env=%s shim_symbol=%p", getpid(),
                       getenv("DYLD_INSERT_LIBRARIES") ?: "<absent>",
                       dlsym(RTLD_DEFAULT, "native_embedding_shim_marker")]);
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *n = _dyld_get_image_name(i);
    if (strstr(n, "EmbeddingShim"))
      logline([NSString stringWithFormat:@"LOADED_IMAGE %s", n]);
  }
  NSString *p = option(argc, argv, @"--dlopen", nil);
  if (p) {
    void *h = dlopen(p.UTF8String, RTLD_NOW);
    logline([NSString stringWithFormat:@"DLOPEN success=%d error=%s", h != NULL,
                                       h ? "none" : dlerror()]);
  }
  NSString *out =
      NSProcessInfo.processInfo.environment[@"NATIVE_EMBED_PROBE_FILE"];
  if ([out hasPrefix:@"/Volumes/Dati APFS/Codex-ready-01a17e79/"]) {
    NSString *record = [NSString
        stringWithFormat:@"pid=%d env=%s loaded_marker=%p\n", getpid(),
                         getenv("DYLD_INSERT_LIBRARIES") ?: "<absent>",
                         dlsym(RTLD_DEFAULT, "native_embedding_shim_marker")];
    [record writeToFile:out
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
  }
  return 0;
}
static int guest(int argc, char **argv) {
  id<MTLDevice> d = MTLCreateSystemDefaultDevice();
  id<MTLCommandQueue> q = [d newCommandQueue];
  id<MTLRenderPipelineState> p = makePipeline(d, NO);
  int frames = [option(argc, argv, @"--frames", @"180") intValue];
  NSString *service = option(argc, argv, @"--forward", nil);
  mach_port_t host = MACH_PORT_NULL, reply = MACH_PORT_NULL;
  CAMetalLayer *layer = nil;
  NSWindow *w = nil;
  NSWindow *localHost = nil;
  if (service) {
    for (int n = 0; n < 100; n++) {
      if (bootstrap_look_up(bootstrap_port, service.UTF8String, &host) ==
          KERN_SUCCESS)
        break;
      usleep(50000);
    }
    if (!host) {
      logline(@"ERROR bootstrap lookup");
      return 4;
    }
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
  } else {
    [NSApplication sharedApplication];
    [NSApp finishLaunching];
    w = window(@"Native Embedding GUEST (independent)", d, &layer, NULL);
    NSString *foreign = option(argc, argv, @"--foreign-window-number", nil);
    if (foreign)
      logline([NSString
          stringWithFormat:@"FOREIGN_WINDOW_LOOKUP pid=%d number=%@ result=%p "
                           @"local_windows=%lu",
                           getpid(), foreign,
                           [NSApp windowWithWindowNumber:foreign.intValue],
                           (unsigned long)NSApp.windows.count]);
    if (flag(argc, argv, "--reparent-local")) {
      NSView *moved = w.contentView;
      NSInteger old = w.windowNumber;
      CAMetalLayer *unused = nil;
      localHost =
          window(@"Native Embedding SAME PROCESS HOST", d, &unused, NULL);
      w.contentView = [NSView new];
      localHost.contentView = moved;
      [w orderOut:nil];
      logline([NSString
          stringWithFormat:@"LOCAL_REPARENT pid=%d from=%ld to=%ld "
                           @"view_window=%ld same_process=1",
                           getpid(), (long)old, (long)localHost.windowNumber,
                           (long)moved.window.windowNumber]);
    }
  }
  uint32_t width = 640, height = 360, inputApplied = 0;
  IOSurfaceRef s = NULL;
  id<MTLTexture> texture = nil;
  double start = now(), totalGPU = 0;
  logline([NSString
      stringWithFormat:
          @"GUEST_START pid=%d forward=%d device=%@ allocated=%llu", getpid(),
          service != nil, d.name, (unsigned long long)d.currentAllocatedSize]);
  for (uint32_t f = 0; f < frames; f++) {
    @autoreleasepool {
      if (!s || IOSurfaceGetWidth(s) != width ||
          IOSurfaceGetHeight(s) != height) {
        texture = nil;
        if (s)
          CFRelease(s);
        s = IOSurfaceCreate((__bridge CFDictionaryRef) @{
          (id)kIOSurfaceWidth : @(width),
          (id)kIOSurfaceHeight : @(height),
          (id)kIOSurfaceBytesPerElement : @4,
          (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA')
        });
        texture = surfaceTexture(d, s, width, height);
        logline([NSString
            stringWithFormat:@"GUEST_SURFACE frame=%u id=%u size=%ux%u "
                             @"bytes=%zu allocated=%llu",
                             f, IOSurfaceGetID(s), width, height,
                             IOSurfaceGetAllocSize(s),
                             (unsigned long long)d.currentAllocatedSize]);
      }
      id<CAMetalDrawable> drawable = nil;
      id<MTLTexture> target = texture;
      if (!service) {
        pump(.001);
        drawable = [layer nextDrawable];
        if (!drawable) {
          logline(@"ERROR guest no drawable");
          return 5;
        }
        target = drawable.texture;
      }
      MTLRenderPassDescriptor *r =
          [MTLRenderPassDescriptor renderPassDescriptor];
      r.colorAttachments[0].texture = target;
      r.colorAttachments[0].loadAction = MTLLoadActionClear;
      r.colorAttachments[0].storeAction = MTLStoreActionStore;
      r.colorAttachments[0].clearColor =
          MTLClearColorMake((f % 255) / 255.0, .125, .25, 1);
      id<MTLCommandBuffer> c = [q commandBuffer];
      id<MTLRenderCommandEncoder> e = [c renderCommandEncoderWithDescriptor:r];
      [e setRenderPipelineState:p];
      float col[4] = {inputApplied ? .15f : .1f, .9, .2, 1};
      [e setFragmentBytes:col length:sizeof(col) atIndex:0];
      [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [e endEncoding];
      if (drawable)
        [c presentDrawable:drawable];
      [c commit];
      [c waitUntilCompleted];
      if (c.status == MTLCommandBufferStatusError) {
        logline(c.error.description);
        return 6;
      }
      double gpu = c.GPUEndTime - c.GPUStartTime;
      totalGPU += gpu;
      if (service) {
        mach_port_t sp = IOSurfaceCreateMachPort(s);
        Frame m = {0};
        m.h.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
                                       MACH_MSG_TYPE_MAKE_SEND_ONCE);
        m.h.msgh_size = sizeof(m);
        m.h.msgh_remote_port = host;
        m.h.msgh_local_port = reply;
        m.body.msgh_descriptor_count = 1;
        m.surface.name = sp;
        m.surface.disposition = MACH_MSG_TYPE_COPY_SEND;
        m.surface.type = MACH_MSG_PORT_DESCRIPTOR;
        m.frame = f;
        m.w = width;
        m.hgt = height;
        m.produced = now();
        m.gpu = gpu;
        kern_return_t kr =
            mach_msg(&m.h, MACH_SEND_MSG, sizeof(m), 0, 0, 10000, 0);
        mach_port_deallocate(mach_task_self(), sp);
        if (kr) {
          logline([NSString stringWithFormat:@"ERROR guest send %d", kr]);
          return 7;
        }
        struct {
          Ack a;
          mach_msg_max_trailer_t t;
        } a = {0};
        kr = mach_msg(&a.a.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(a),
                      reply, 10000, 0);
        if (kr) {
          logline([NSString stringWithFormat:@"ERROR guest ack %d", kr]);
          return 8;
        }
        width = a.a.w;
        height = a.a.hgt;
        inputApplied = a.a.input;
        if (f % 30 == 0)
          logline([NSString
              stringWithFormat:@"GUEST_ACK frame=%u requested=%ux%u input=%u "
                               @"gpu_ms=%.4f allocated=%llu",
                               f, width, height, a.a.input, gpu * 1000,
                               (unsigned long long)d.currentAllocatedSize]);
      } else
        usleep(10000);
      int pace = [option(argc, argv, @"--pace-ms", @"0") intValue];
      if (pace > 0)
        usleep(pace * 1000);
    }
  }
  logline([NSString
      stringWithFormat:
          @"GUEST_DONE frames=%d elapsed=%.6f mean_gpu_ms=%.6f allocated=%llu",
          frames, now() - start, totalGPU * 1000 / frames,
          (unsigned long long)d.currentAllocatedSize]);
  if (s)
    CFRelease(s);
  double linger = now() + [option(argc, argv, @"--linger", @"0") doubleValue];
  while (now() < linger)
    pump(.01);
  return 0;
}
static int host(int argc, char **argv) {
  [NSApplication sharedApplication];
  [NSApp finishLaunching];
  id<MTLDevice> d = MTLCreateSystemDefaultDevice();
  id<MTLCommandQueue> q = [d newCommandQueue];
  id<MTLRenderPipelineState> p = makePipeline(d, YES);
  NSString *service =
      option(argc, argv, @"--host", @"local.ready.native-embedding");
  BOOL headless = flag(argc, argv, "--headless");
  int frames = [option(argc, argv, @"--frames", @"180") intValue];
  CAMetalLayer *layer = nil;
  LabView *view = nil;
  NSWindow *w = nil;
  if (!headless)
    w = window(@"Native Embedding HOST — existing Ready-like window", d, &layer,
               &view);
  if (flag(argc, argv, "--idle")) {
    double end = now() + [option(argc, argv, @"--linger", @"15") doubleValue];
    while (now() < end)
      pump(.01);
    logline([NSString
        stringWithFormat:@"IDLE_HOST_DONE pid=%d window=%ld local_windows=%lu",
                         getpid(), (long)w.windowNumber,
                         (unsigned long)NSApp.windows.count]);
    return 0;
  }
  mach_port_t port;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
  mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
  kern_return_t k =
      bootstrap_register(bootstrap_port, (char *)service.UTF8String, port);
  logline(
      [NSString stringWithFormat:@"HOST_READY pid=%d service=%@ register=%d "
                                 @"headless=%d allocated=%llu",
                                 getpid(), service, k, headless,
                                 (unsigned long long)d.currentAllocatedSize]);
  if (k)
    return 9;
  __block BOOL done = NO;
  __block int result = 0;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    double start = now(), sumGPU = 0, sumLatency = 0;
    int verified = 0;
    for (int f = 0; f < frames; f++) {
      @autoreleasepool {
        Receive r = {0};
        kern_return_t kr = mach_msg(&r.msg.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                    0, sizeof(r), port, 15000, 0);
        if (kr) {
          logline([NSString stringWithFormat:@"ERROR host receive %d", kr]);
          result = 10;
          break;
        }
        Frame *m = &r.msg;
        IOSurfaceRef s = IOSurfaceLookupFromMachPort(m->surface.name);
        mach_port_deallocate(mach_task_self(), m->surface.name);
        if (!s) {
          result = 11;
          break;
        }
        id<MTLTexture> src = surfaceTexture(d, s, m->w, m->hgt);
        __block id<CAMetalDrawable> drawable = nil;
        __block uint32_t nextW = m->w, nextH = m->hgt, input = 0;
        __block id<MTLTexture> target = nil;
        if (headless) {
          MTLTextureDescriptor *t = [MTLTextureDescriptor
              texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                           width:m->w
                                          height:m->hgt
                                       mipmapped:NO];
          t.storageMode = MTLStorageModeShared;
          t.usage = MTLTextureUsageRenderTarget;
          target = [d newTextureWithDescriptor:t];
          if (f == 59) {
            nextW = 800;
            nextH = 450;
          }
          if (f == 119) {
            nextW = 1280;
            nextH = 720;
            input = 1;
          }
        } else
          dispatch_sync(dispatch_get_main_queue(), ^{
            if (f == 59)
              [w setContentSize:NSMakeSize(800, 450)];
            if (f == 119) {
              layer.contentsScale = 2;
              logline(@"SYNTHETIC backing-scale request=2 (not physical screen "
                      @"transition)");
              NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                            location:NSZeroPoint
                                       modifierFlags:0
                                           timestamp:now()
                                        windowNumber:w.windowNumber
                                             context:nil
                                          characters:@"x"
                         charactersIgnoringModifiers:@"x"
                                           isARepeat:NO
                                             keyCode:7];
              [view keyDown:e];
            }
            CGFloat scale = (f >= 120 ? 2 : w.backingScaleFactor);
            nextW = MAX(1, (uint32_t)(view.bounds.size.width * scale));
            nextH = MAX(1, (uint32_t)(view.bounds.size.height * scale));
            layer.drawableSize = CGSizeMake(nextW, nextH);
            drawable = [layer nextDrawable];
            target = drawable.texture;
            input = view.inputCount;
          });
        if (!target) {
          logline(@"ERROR no drawable (WindowServer/locked-session gate)");
          CFRelease(s);
          result = 12;
          break;
        }
        MTLRenderPassDescriptor *rp =
            [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> c = [q commandBuffer];
        id<MTLRenderCommandEncoder> e =
            [c renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:p];
        [e setFragmentTexture:src atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        if (drawable)
          [c presentDrawable:drawable];
        [c commit];
        [c waitUntilCompleted];
        if (c.status == MTLCommandBufferStatusError) {
          logline(c.error.description);
          result = 13;
          CFRelease(s);
          break;
        }
        double gpu = c.GPUEndTime - c.GPUStartTime;
        sumGPU += gpu;
        sumLatency += now() - m->produced;
        if (f % 30 == 0) {
          uint8_t pixel[4] = {0};
          if (headless)
            [target getBytes:pixel
                 bytesPerRow:4
                  fromRegion:MTLRegionMake2D(m->w / 2, m->hgt / 2, 1, 1)
                 mipmapLevel:0];
          else {
            IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
            uint8_t *b = IOSurfaceGetBaseAddress(s);
            memcpy(pixel,
                   b + (m->hgt / 2) * IOSurfaceGetBytesPerRow(s) +
                       (m->w / 2) * 4,
                   4);
            IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
          }
          uint8_t corner[4] = {0};
          if (headless)
            [target getBytes:corner
                 bytesPerRow:4
                  fromRegion:MTLRegionMake2D(0, 0, 1, 1)
                 mipmapLevel:0];
          else {
            IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
            memcpy(corner, IOSurfaceGetBaseAddress(s), 4);
            IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
          }
          BOOL valid = pixel[1] > 200 && pixel[0] < 80 && pixel[2] < 80 &&
                       abs((int)corner[2] - (int)(m->frame % 255)) <= 1 &&
                       corner[1] == 32 && corner[0] == 64;
          logline([NSString
              stringWithFormat:@"FRAME_CONTENT frame=%u cornerBGRA=%u,%u,%u,%u "
                               @"expectedRed=%u",
                               m->frame, corner[0], corner[1], corner[2],
                               corner[3], m->frame % 255]);
          verified += valid;
          logline([NSString
              stringWithFormat:
                  @"HOST_FRAME frame=%u surface=%u imported=%ux%u next=%ux%u "
                  @"pixelBGRA=%u,%u,%u,%u valid=%d gpu_ms=%.4f latency_ms=%.4f "
                  @"allocated=%llu windows=%lu",
                  m->frame, IOSurfaceGetID(s), m->w, m->hgt, nextW, nextH,
                  pixel[0], pixel[1], pixel[2], pixel[3], valid, gpu * 1000,
                  (now() - m->produced) * 1000,
                  (unsigned long long)d.currentAllocatedSize,
                  (unsigned long)(headless ? 0 : NSApp.windows.count)]);
          if (!valid)
            result = 14;
        }
        Ack a = {0};
        a.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        a.h.msgh_size = sizeof(a);
        a.h.msgh_remote_port = m->h.msgh_remote_port;
        a.frame = m->frame;
        a.w = nextW;
        a.hgt = nextH;
        a.input = input;
        kr = mach_msg(&a.h, MACH_SEND_MSG, sizeof(a), 0, 0, 0, 0);
        CFRelease(s);
        if (kr) {
          result = 15;
          break;
        }
      }
    }
    logline(
        [NSString stringWithFormat:
                      @"HOST_DONE frames=%d verified_samples=%d elapsed=%.6f "
                      @"mean_gpu_ms=%.6f mean_guest_ready_to_host_done_ms=%.6f "
                      @"allocated=%llu result=%d",
                      frames, verified, now() - start, sumGPU * 1000 / frames,
                      sumLatency * 1000 / frames,
                      (unsigned long long)d.currentAllocatedSize, result]);
    dispatch_async(dispatch_get_main_queue(), ^{
      done = YES;
    });
  });
  while (!done)
    pump(.01);
  if (flag(argc, argv, "--fullscreen-cycle") && w) {
    w.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    [w toggleFullScreen:nil];
    double transition = now() + 2;
    while (now() < transition)
      pump(.01);
    logline([NSString
        stringWithFormat:@"HOST_FULLSCREEN_ENTER pid=%d number=%ld "
                         @"style_fullscreen=%d local_windows=%lu",
                         getpid(), (long)w.windowNumber,
                         (w.styleMask & NSWindowStyleMaskFullScreen) != 0,
                         (unsigned long)NSApp.windows.count]);
    [w toggleFullScreen:nil];
    transition = now() + 2;
    while (now() < transition)
      pump(.01);
    logline([NSString
        stringWithFormat:
            @"HOST_FULLSCREEN_EXIT pid=%d number=%ld style_fullscreen=%d",
            getpid(), (long)w.windowNumber,
            (w.styleMask & NSWindowStyleMaskFullScreen) != 0]);
  }
  double linger = now() + [option(argc, argv, @"--linger", @"0") doubleValue];
  while (now() < linger)
    pump(.01);
  [w orderOut:nil];
  return result;
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (flag(argc, argv, "--probe"))
      return probe(argc, argv);
    if (flag(argc, argv, "--host"))
      return host(argc, argv);
    return guest(argc, argv);
  }
}
