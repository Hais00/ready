// Bounded direct-drawable experiment: host exports its OWN drawable's
// IOSurface. Guest renders directly into that allocation. Host calls present,
// no encoder.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach.h>
#import <servers/bootstrap.h>
#import <unistd.h>
static double clockNow(void) { return CACurrentMediaTime(); }
static void report(NSString *s) {
  fprintf(stdout, "%s\n", s.UTF8String);
  fflush(stdout);
}
static void pump(double seconds) {
  NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
  do {
    NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                    untilDate:limit
                                       inMode:NSDefaultRunLoopMode
                                      dequeue:YES];
    if (e)
      [NSApp sendEvent:e];
    [NSApp updateWindows];
  } while (limit.timeIntervalSinceNow > 0);
}
static NSArray *ownWindows(void) {
  NSArray *all = CFBridgingRelease(
      CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
  if (!all)
    return @[ @"QUERY_FAILED" ];
  NSMutableArray *mine = [NSMutableArray new];
  for (NSDictionary *w in all)
    if ([w[(id)kCGWindowOwnerPID] intValue] == getpid())
      [mine addObject:w[(id)kCGWindowNumber]];
  return mine;
}
typedef struct {
  mach_msg_header_t h;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  uint32_t frame, width, height, surfaceID;
} SurfaceMessage;
typedef struct {
  mach_msg_header_t h;
  uint32_t frame, surfaceID, status;
  double gpu;
} ReadyMessage;
typedef struct {
  SurfaceMessage m;
  mach_msg_max_trailer_t trailer;
} SurfaceReceive;
typedef struct {
  ReadyMessage m;
  mach_msg_max_trailer_t trailer;
} ReadyReceive;
static int guest(const char *service, int frames) {
  report([NSString
      stringWithFormat:@"DIRECT_GUEST_START pid=%d NSApp_nil=%d ws_windows=%@",
                       getpid(), NSApp == nil, ownWindows()]);
  id<MTLDevice> d = MTLCreateSystemDefaultDevice();
  id<MTLCommandQueue> q = [d newCommandQueue];
  NSError *error = nil;
  NSString *source =
      @"#include <metal_stdlib>\nusing namespace metal;vertex float4 v(uint "
      @"i[[vertex_id]]){float2 "
      @"p[3]={float2(-.7,-.7),float2(.7,-.7),float2(0,.7)};return "
      @"float4(p[i],0,1);}fragment float4 f(){return float4(.1,.9,.2,1);}";
  id<MTLLibrary> lib = [d newLibraryWithSource:source options:nil error:&error];
  if (!lib) {
    report(error.description);
    return 51;
  }
  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  pd.vertexFunction = [lib newFunctionWithName:@"v"];
  pd.fragmentFunction = [lib newFunctionWithName:@"f"];
  pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  id<MTLRenderPipelineState> pipeline =
      [d newRenderPipelineStateWithDescriptor:pd error:&error];
  if (!pipeline) {
    report(error.description);
    return 52;
  }
  mach_port_t host = 0, receive = 0;
  kern_return_t k = bootstrap_look_up(bootstrap_port, service, &host);
  if (k)
    return 53;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &receive);
  ReadyMessage hello = {0};
  hello.h.msgh_bits =
      MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND);
  hello.h.msgh_remote_port = host;
  hello.h.msgh_local_port = receive;
  hello.h.msgh_size = sizeof(hello);
  k = mach_msg(&hello.h, MACH_SEND_MSG, sizeof(hello), 0, 0, 0, 0);
  if (k)
    return 54;
  double gpuTotal = 0, start = clockNow();
  int rendered = 0;
  for (int n = 0; n < frames; n++) {
    @autoreleasepool {
      SurfaceReceive r = {0};
      k = mach_msg(&r.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(r),
                   receive, 10000, 0);
      if (k) {
        report([NSString stringWithFormat:@"DIRECT_GUEST_RECEIVE_ERROR %d", k]);
        return 55;
      }
      IOSurfaceRef surface = IOSurfaceLookupFromMachPort(r.m.port.name);
      mach_port_deallocate(mach_task_self(), r.m.port.name);
      if (!surface)
        return 56;
      MTLTextureDescriptor *td = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                       width:r.m.width
                                      height:r.m.height
                                   mipmapped:NO];
      td.usage = MTLTextureUsageRenderTarget;
      td.storageMode = MTLStorageModeShared;
      id<MTLTexture> texture = [d newTextureWithDescriptor:td
                                                 iosurface:surface
                                                     plane:0];
      if (!texture) {
        report(@"DIRECT_IMPORT_REJECTED texture=nil; STOP, no fallback copy");
        CFRelease(surface);
        return 57;
      }
      uint32_t sid = IOSurfaceGetID(surface);
      if (sid != r.m.surfaceID || texture.iosurface != surface) {
        report(@"DIRECT_IMPORT_IDENTITY_MISMATCH");
        CFRelease(surface);
        return 58;
      }
      MTLRenderPassDescriptor *pass =
          [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = texture;
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      pass.colorAttachments[0].clearColor =
          MTLClearColorMake((n % 255) / 255., .125, .25, 1);
      id<MTLCommandBuffer> cb = [q commandBuffer];
      cb.label = @"Direct guest: one original scene render, no blit";
      id<MTLRenderCommandEncoder> encoder =
          [cb renderCommandEncoderWithDescriptor:pass];
      [encoder setRenderPipelineState:pipeline];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                  vertexStart:0
                  vertexCount:3];
      [encoder endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      double gpu = cb.GPUEndTime - cb.GPUStartTime;
      gpuTotal += gpu;
      if (cb.status == MTLCommandBufferStatusError) {
        report(cb.error.description);
        CFRelease(surface);
        return 59;
      }
      rendered++;
      ReadyMessage ack = {0};
      ack.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
      ack.h.msgh_remote_port = r.m.h.msgh_remote_port;
      ack.h.msgh_size = sizeof(ack);
      ack.frame = r.m.frame;
      ack.surfaceID = sid;
      ack.gpu = gpu;
      k = mach_msg(&ack.h, MACH_SEND_MSG, sizeof(ack), 0, 0, 0, 0);
      if (n % 30 == 0)
        report([NSString
            stringWithFormat:
                @"DIRECT_GUEST_FRAME frame=%d host_surface=%u "
                @"imported_surface=%u own_texture_surface=%u render_encoders=1 "
                @"blit_encoders=0 compute_encoders=0 gpu_ms=%.6f "
                @"allocated=%llu ws_windows=%@",
                n, r.m.surfaceID, sid, IOSurfaceGetID(texture.iosurface),
                gpu * 1000, (unsigned long long)d.currentAllocatedSize,
                ownWindows()]);
      CFRelease(surface);
      if (k)
        return 60;
    }
  }
  NSArray *windows = ownWindows();
  report([NSString
      stringWithFormat:
          @"DIRECT_GUEST_DONE pid=%d frames=%d gpu_ms_mean=%.6f elapsed=%.6f "
          @"NSApp_nil=%d ws_windows=%@ total_render_encoders=%d "
          @"total_blit_encoders=0 total_compute_encoders=0",
          getpid(), rendered, gpuTotal * 1000 / rendered, clockNow() - start,
          NSApp == nil, windows, rendered]);
  return windows.count ? 61 : 0;
}
static int host(const char *service, int frames, int linger) {
  [NSApplication sharedApplication];
  [NSApp finishLaunching];
  id<MTLDevice> d = MTLCreateSystemDefaultDevice();
  NSWindow *w = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(40, 80, 640, 360)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  w.title = @"Native Direct Drawable HOST — only presentation";
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
  v.wantsLayer = YES;
  CAMetalLayer *l = [CAMetalLayer layer];
  l.device = d;
  l.pixelFormat = MTLPixelFormatBGRA8Unorm;
  l.drawableSize = CGSizeMake(640, 360);
  l.framebufferOnly = YES;
  v.layer = l;
  w.contentView = v;
  [w orderFront:nil];
  pump(.05);
  mach_port_t server = 0;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &server);
  mach_port_insert_right(mach_task_self(), server, server,
                         MACH_MSG_TYPE_MAKE_SEND);
  kern_return_t k = bootstrap_register(bootstrap_port, (char *)service, server);
  report([NSString
      stringWithFormat:
          @"DIRECT_HOST_READY pid=%d window=%ld register=%d ws_windows=%@",
          getpid(), (long)w.windowNumber, k, ownWindows()]);
  if (k)
    return 62;
  ReadyReceive hello = {0};
  k = mach_msg(&hello.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(hello),
               server, 10000, 0);
  if (k)
    return 63;
  mach_port_t remote = hello.m.h.msgh_remote_port;
  double presentCallTotal = 0, roundTripTotal = 0;
  int presented = 0;
  for (int n = 0; n < frames; n++) {
    @autoreleasepool {
      pump(.001);
      double begin = clockNow();
      id<CAMetalDrawable> drawable = [l nextDrawable];
      if (!drawable) {
        report(@"DIRECT_NO_DRAWABLE; STOP");
        return 64;
      }
      IOSurfaceRef s = drawable.texture.iosurface;
      if (!s) {
        report(@"DIRECT_IOSURFACE_NIL; STOP, no fallback copy");
        return 40;
      }
      uint32_t sid = IOSurfaceGetID(s);
      mach_port_t sp = IOSurfaceCreateMachPort(s);
      if (!sp) {
        report(@"DIRECT_MACH_EXPORT_REJECTED; STOP");
        return 65;
      }
      SurfaceMessage m = {0};
      m.h.msgh_bits =
          MACH_MSGH_BITS_COMPLEX |
          MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
      m.h.msgh_remote_port = remote;
      m.h.msgh_local_port = server;
      m.h.msgh_size = sizeof(m);
      m.body.msgh_descriptor_count = 1;
      m.port.name = sp;
      m.port.disposition = MACH_MSG_TYPE_COPY_SEND;
      m.port.type = MACH_MSG_PORT_DESCRIPTOR;
      m.frame = n;
      m.width = (uint32_t)drawable.texture.width;
      m.height = (uint32_t)drawable.texture.height;
      m.surfaceID = sid;
      k = mach_msg(&m.h, MACH_SEND_MSG, sizeof(m), 0, 0, 0, 0);
      mach_port_deallocate(mach_task_self(), sp);
      if (k)
        return 66;
      ReadyReceive ack = {0};
      k = mach_msg(&ack.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(ack),
                   server, 10000, 0);
      if (k) {
        report([NSString stringWithFormat:@"DIRECT_HOST_ACK_ERROR %d", k]);
        return 67;
      }
      if (ack.m.frame != n || ack.m.surfaceID != sid)
        return 68;
      double ready = clockNow();
      roundTripTotal += ready - begin;
      [drawable present];
      double submitted = clockNow();
      presentCallTotal += submitted - ready;
      presented++;
      if (n % 30 == 0)
        report([NSString
            stringWithFormat:
                @"DIRECT_HOST_FRAME frame=%d window=%ld drawableID=%llu "
                @"texture_iosurface=%u ack_surface=%u size=%ux%u "
                @"host_command_buffers=0 host_render_encoders=0 "
                @"host_blit_encoders=0 host_compute_encoders=0 "
                @"guest_gpu_ms=%.6f acquire_and_IPC_GPU_wait_ms=%.6f "
                @"present_call_ms=%.6f allocated=%llu ws_windows=%@",
                n, (long)w.windowNumber, drawable.drawableID, sid,
                ack.m.surfaceID, m.width, m.height, ack.m.gpu * 1000,
                (ready - begin) * 1000, (submitted - ready) * 1000,
                (unsigned long long)d.currentAllocatedSize, ownWindows()]);
      pump(.015);
    }
  }
  report([NSString
      stringWithFormat:@"DIRECT_HOST_DONE pid=%d window=%ld frames=%d "
                       @"host_command_buffers=0 host_total_encoders=0 "
                       @"host_fullframe_copies=0 cpu_readbacks=0 "
                       @"acquire_and_roundtrip_mean_ms=%.6f "
                       @"present_call_mean_ms=%.6f ws_windows=%@",
                       getpid(), (long)w.windowNumber, presented,
                       roundTripTotal * 1000 / presented,
                       presentCallTotal * 1000 / presented, ownWindows()]);
  double end = clockNow() + linger;
  while (clockNow() < end)
    pump(.01);
  [w orderOut:nil];
  return 0;
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 4)
      return 2;
    BOOL isGuest = !strcmp(argv[1], "guest");
    int frames = atoi(argv[3]);
    if (frames <= 0 || frames > 600)
      return 3;
    return isGuest ? guest(argv[2], frames)
                   : host(argv[2], frames, argc > 4 ? atoi(argv[4]) : 0);
  }
}
