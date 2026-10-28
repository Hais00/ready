#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <servers/bootstrap.h>
#import <unistd.h>
int native_embedding_shim_marker = 0x52454144;
static IMP originalWindow, originalNext, originalPresent, originalOrder;
static mach_port_t host, reply;
static uint32_t counter;
static IOSurfaceRef shared;
static id<MTLTexture> sharedTexture;
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
static id windowHook(id self, SEL cmd, NSRect rect, NSWindowStyleMask style,
                     NSBackingStoreType backing, BOOL defer) {
  id w = ((id (*)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType,
                  BOOL))originalWindow)(self, cmd, rect, style, backing, defer);
  fprintf(stderr,
          "SHIM_WINDOW pid=%d object=%p contentView=%p windowNumber=%ld "
          "local_windows=%lu\n",
          getpid(), w, [w contentView], (long)[w windowNumber],
          (unsigned long)NSApp.windows.count);
  fflush(stderr);
  return w;
}
static void orderHook(id self, SEL cmd, id sender) {
  if (getenv("NATIVE_EMBED_SERVICE")) {
    fprintf(stderr, "SHIM_SUPPRESS_GUEST_ORDER_FRONT pid=%d window=%ld\n",
            getpid(), (long)[self windowNumber]);
    fflush(stderr);
    return;
  }
  ((void (*)(id, SEL, id))originalOrder)(self, cmd, sender);
}
static void presentHook(id self, SEL cmd, id<CAMetalDrawable> drawable) {
  id<MTLTexture> src = drawable.texture;
  id<MTLDevice> d = src.device;
  uint32_t w = (uint32_t)src.width, h = (uint32_t)src.height;
  if (!shared || IOSurfaceGetWidth(shared) != w ||
      IOSurfaceGetHeight(shared) != h) {
    sharedTexture = nil;
    if (shared)
      CFRelease(shared);
    shared = IOSurfaceCreate((__bridge CFDictionaryRef) @{
      (id)kIOSurfaceWidth : @(w),
      (id)kIOSurfaceHeight : @(h),
      (id)kIOSurfaceBytesPerElement : @4,
      (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA')
    });
    MTLTextureDescriptor *t = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    t.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    t.storageMode = MTLStorageModeShared;
    sharedTexture = [d newTextureWithDescriptor:t iosurface:shared plane:0];
  }
  id<MTLBlitCommandEncoder> blit = [self blitCommandEncoder];
  [blit copyFromTexture:src
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1)
              toTexture:sharedTexture
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit endEncoding];
  // Keep the game-like guest's own drawable acquisition/presentation lifecycle,
  // but hide its window. This adds a full-frame GPU copy. It is deliberately
  // not advertised as zero-copy.
  ((void (*)(id, SEL, id))originalPresent)(self, cmd, drawable);
  [self addCompletedHandler:^(id<MTLCommandBuffer> c) {
    mach_port_t sp = IOSurfaceCreateMachPort(shared);
    Frame m = {0};
    m.h.msgh_bits =
        MACH_MSGH_BITS_COMPLEX |
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    m.h.msgh_size = sizeof(m);
    m.h.msgh_remote_port = host;
    m.h.msgh_local_port = reply;
    m.body.msgh_descriptor_count = 1;
    m.surface.name = sp;
    m.surface.disposition = MACH_MSG_TYPE_COPY_SEND;
    m.surface.type = MACH_MSG_PORT_DESCRIPTOR;
    m.frame = counter++;
    m.w = w;
    m.hgt = h;
    m.produced = CACurrentMediaTime();
    m.gpu = c.GPUEndTime - c.GPUStartTime;
    kern_return_t k = mach_msg(&m.h, MACH_SEND_MSG, sizeof(m), 0, 0, 0, 0);
    mach_port_deallocate(mach_task_self(), sp);
    struct {
      Ack a;
      mach_msg_max_trailer_t t;
    } ack = {0};
    if (!k)
      k = mach_msg(&ack.a.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(ack),
                   reply, 10000, 0);
    if (m.frame % 30 == 0) {
      fprintf(stderr,
              "SHIM_FORWARDED pid=%d frame=%u src=%ux%u surface=%u "
              "copied_bytes=%u gpu_render_plus_copy_ms=%.4f mach_result=%d "
              "requested=%ux%u input=%u\n",
              getpid(), m.frame, w, h, IOSurfaceGetID(shared), w * h * 4,
              m.gpu * 1000, k, ack.a.w, ack.a.hgt, ack.a.input);
      fflush(stderr);
    }
  }];
}
static id nextHook(CAMetalLayer *self, SEL cmd) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *service = getenv("NATIVE_EMBED_SERVICE");
    if (service) {
      kern_return_t k = bootstrap_look_up(bootstrap_port, service, &host);
      mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
      id<MTLCommandQueue> q = [self.device newCommandQueue];
      id<MTLCommandBuffer> c = [q commandBuffer];
      Method method =
          class_getInstanceMethod([c class], @selector(presentDrawable:));
      originalPresent = method_setImplementation(method, (IMP)presentHook);
      fprintf(stderr,
              "SHIM_PRESENT_HOOK pid=%d command_buffer_class=%s lookup=%d\n",
              getpid(), class_getName([c class]), k);
      fflush(stderr);
    }
  });
  self.framebufferOnly = NO;
  return ((id (*)(id, SEL))originalNext)(self, cmd);
}
__attribute__((constructor)) static void install(void) {
  fprintf(stderr, "SHIM_LOADED pid=%d address=%p\n", getpid(),
          &native_embedding_shim_marker);
  fflush(stderr);
  Method m = class_getInstanceMethod([NSWindow class], @selector
                                     (initWithContentRect:
                                                styleMask:backing:defer:));
  originalWindow = method_setImplementation(m, (IMP)windowHook);
  if (getenv("NATIVE_EMBED_SERVICE")) {
    originalOrder = method_setImplementation(
        class_getInstanceMethod([NSWindow class], @selector(orderFront:)),
        (IMP)orderHook);
    originalNext = method_setImplementation(
        class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable)),
        (IMP)nextHook);
  }
}
