// SPDX-License-Identifier: GPL-3.0-only
// Our actual drawable allocation is exported. The host never makes a Metal
// command queue/buffer/encoder and never copies or reads pixel bytes.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#import <servers/bootstrap.h>
#import <unistd.h>
#import <sys/resource.h>
#import "NoCopyProxyProtocol.h"
static NSArray *windows(void){NSArray*all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));if(!all)return @[@"query-failed"];NSMutableArray*out=[NSMutableArray new];for(NSDictionary*w in all)if([w[(id)kCGWindowOwnerPID]intValue]==getpid())[out addObject:@{ @"id":w[(id)kCGWindowNumber],@"onscreen":w[(id)kCGWindowIsOnscreen]?:@NO,@"bounds":w[(id)kCGWindowBounds]?:@{} }];return out;}
static double cpuNow(void){struct rusage r;getrusage(RUSAGE_SELF,&r);return r.ru_utime.tv_sec+r.ru_utime.tv_usec/1e6+r.ru_stime.tv_sec+r.ru_stime.tv_usec/1e6;}
static void emit(NSDictionary*v){NSData*d=[NSJSONSerialization dataWithJSONObject:v options:0 error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);fflush(stdout);}
static void pump(void){for(int n=0;n<16;n++){NSEvent*e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES];if(!e)break;[NSApp sendEvent:e];}[NSApp updateWindows];}
@interface NCOffscreenHostWindow:NSWindow @end
@implementation NCOffscreenHostWindow
-(NSRect)constrainFrameRect:(NSRect)rect toScreen:(NSScreen*)screen{if(getenv("READY_NO_COPY_PROXY_OFFSCREEN"))return rect;return [super constrainFrameRect:rect toScreen:screen];}
@end
int main(int argc,char**argv){@autoreleasepool{double cpuStart=cpuNow();
 if(argc>=3&&!strcmp(argv[1],"--census")){NSArray*all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));NSMutableDictionary*out=[NSMutableDictionary new];for(int i=2;i<argc;i++){int pid=atoi(argv[i]);NSMutableArray*found=[NSMutableArray new];for(NSDictionary*entry in all)if([entry[(id)kCGWindowOwnerPID]intValue]==pid)[found addObject:@{@"id":entry[(id)kCGWindowNumber],@"onscreen":entry[(id)kCGWindowIsOnscreen]?:@NO,@"bounds":entry[(id)kCGWindowBounds]?:@{}}];out[@(pid).stringValue]=found;}emit(@{@"type":@"external-census",@"queryAvailable":@(all!=nil),@"windowsByPID":out});return all?0:79;}
 if(argc!=4)return 64;alarm(65);const char*service=argv[1];int frames=atoi(argv[2]),linger=atoi(argv[3]);if(frames<1||frames>600||linger<0||linger>40)return 64;
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
 id<MTLDevice>device=MTLCreateSystemDefaultDevice();if(!device)return 65;
 NSWindow*w=[[NCOffscreenHostWindow alloc]initWithContentRect:NSMakeRect(100,100,640,360) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];w.releasedWhenClosed=NO;w.title=@"Ready NoCopyProxy Lab — HOST ONLY";
 NSView*v=[[NSView alloc]initWithFrame:NSMakeRect(0,0,640,360)];v.wantsLayer=YES;CAMetalLayer*l=[CAMetalLayer layer];l.device=device;l.pixelFormat=MTLPixelFormatBGRA8Unorm;l.drawableSize=CGSizeMake(640,360);l.framebufferOnly=YES;v.layer=l;w.contentView=v;BOOL offscreen=getenv("READY_NO_COPY_PROXY_OFFSCREEN")!=NULL;if(offscreen){[w setFrameOrigin:NSMakePoint(-8192,-8192)];[w orderBack:nil];}else{[w makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}pump();
 mach_port_t server=0;mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&server);mach_port_insert_right(mach_task_self(),server,server,MACH_MSG_TYPE_MAKE_SEND);kern_return_t k=bootstrap_register(bootstrap_port,(char*)service,server);if(k)return 66;
 emit(@{@"type":@"host-ready",@"pid":@(getpid()),@"window":@(w.windowNumber),@"windows":windows(),@"hostCommandBuffers":@0,@"hostEncoders":@0});
 id<CAMetalDrawable> outstanding=nil;uint32_t next=0,sid=0;double start=CACurrentMediaTime(),acquire=0,present=0;unsigned received=0,presented=0;
 while(CACurrentMediaTime()-start<35){@autoreleasepool{
  pump();NCRequestReceive r={0};k=mach_msg(&r.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof r,server,10,MACH_PORT_NULL);if(k==MACH_RCV_TIMED_OUT)continue;if(k)return 67;
  received++;NCRequest*q=&r.message;if(q->h.msgh_size!=sizeof(NCRequest)||q->h.msgh_bits&MACH_MSGH_BITS_COMPLEX)return 68;
  NCReply reply={0};reply.h.msgh_remote_port=q->h.msgh_remote_port;reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_size=sizeof reply;reply.window=(uint32_t)w.windowNumber;reply.width=640;reply.height=360;
  if(q->op==NC_ACQUIRE){
   if(outstanding)return 69;double at=CACurrentMediaTime();outstanding=[l nextDrawable];acquire+=CACurrentMediaTime()-at;if(!outstanding||!outstanding.texture.iosurface)return 70;
   sid=IOSurfaceGetID(outstanding.texture.iosurface);mach_port_t port=IOSurfaceCreateMachPort(outstanding.texture.iosurface);if(!port)return 71;
   reply.h.msgh_bits|=MACH_MSGH_BITS_COMPLEX;reply.body.msgh_descriptor_count=1;reply.port=(mach_msg_port_descriptor_t){.name=port,.disposition=MACH_MSG_TYPE_MOVE_SEND,.type=MACH_MSG_PORT_DESCRIPTOR};reply.frame=next;reply.surface=sid;
  }else if(q->op==NC_PRESENT){
   if(!outstanding||q->frame!=next||q->surface!=sid)return 72;double at=CACurrentMediaTime();[outstanding present];present+=CACurrentMediaTime()-at;presented++;reply.frame=next;reply.surface=sid;
   if(presented==1||presented%30==0)emit(@{@"type":@"host-frame",@"frame":@(next),@"window":@(w.windowNumber),@"drawableSurface":@(sid),@"guestSurface":@(q->surface),@"guestGPUMilliseconds":@(q->gpu*1000),@"windows":windows(),@"hostCommandBuffers":@0,@"hostEncoders":@0,@"hostCopies":@0,@"hostReadbacks":@0});
   outstanding=nil;next++;
  }else if(q->op!=NC_HELLO&&q->op!=NC_DONE)return 73;
  k=mach_msg(&reply.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,reply.h.msgh_size,0,MACH_PORT_NULL,2000,MACH_PORT_NULL);if(k)return 74;
  if(q->op==NC_DONE||presented==(unsigned)frames)break;
 }}
 emit(@{@"type":@"host-done",@"frames":@(presented),@"window":@(w.windowNumber),@"windows":windows(),@"requests":@(received),@"hostCommandBuffers":@0,@"hostRenderEncoders":@0,@"hostBlitEncoders":@0,@"hostComputeEncoders":@0,@"hostCopies":@0,@"hostReadbacks":@0,@"acquireMilliseconds":@(acquire*1000),@"presentCallMilliseconds":@(present*1000),@"elapsedSeconds":@(CACurrentMediaTime()-start),@"CPUSeconds":@(cpuNow()-cpuStart)});
 double until=CACurrentMediaTime()+linger;while(CACurrentMediaTime()<until){pump();usleep(10000);}[w orderOut:nil];return presented==(unsigned)frames?0:75;
}}
