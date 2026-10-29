// SPDX-License-Identifier: GPL-3.0-only
// The launcher exports its actual drawable storage. No host Metal queue,
// command buffer, encoder, image copy or pixel readback is created here.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <IOSurface/IOSurface.h>
#import <servers/bootstrap.h>
#import <bsm/libbsm.h>
#import <libproc.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>
#import "ReadyHostedView.h"
#import "ReadyHostedGameProtocol.h"
@class RHGHost;
@interface RHGView:NSView
@property(nonatomic,weak)RHGHost *owner;
@end
@interface RHGHost:NSObject {
@public uint8_t nonce[RHG_NONCE_BYTES];
@public _Atomic bool stopped;
}
@property(nonatomic,weak)NSWindow *window;
@property(nonatomic,strong)RHGView *view;
@property(nonatomic,strong)CAMetalLayer *metal;
@property(nonatomic,strong)id<MTLDevice> device;
@property(nonatomic,strong)id<CAMetalDrawable> drawable;
@property(nonatomic,copy)NSString *service,*nonceString,*expectedExecutable;
@property(atomic)mach_port_t port;
@property(atomic)pid_t guestPID;
@property(nonatomic)uint64_t frameID;
@property(nonatomic)uint32_t surfaceID;
@property(nonatomic)NSUInteger frames,acquires,requests;
@property(nonatomic)BOOL configured,metalHUD,lastFocus,firstFrameAnnounced;
@property(nonatomic,assign)RHGHostFirstFrameCallback firstFrameCallback;
@property(nonatomic,assign)void *firstFrameContext;
@property(nonatomic)int diagnosticFD;
@property(nonatomic,strong)NSLock *inputLock;
@property(nonatomic,strong)NSMutableArray<NSData*> *inputs;
@property(nonatomic)double began;
-(void)record:(NSString*)phase reason:(NSString*)reason;
-(void)input:(NSEvent*)event type:(uint32_t)type;
-(void)shutdown;
@end
static void RHGMainSync(dispatch_block_t block){if(NSThread.isMainThread)block();else dispatch_sync(dispatch_get_main_queue(),block);}
static BOOL RHGFormat(uint32_t format){return format==MTLPixelFormatBGRA8Unorm||format==MTLPixelFormatBGRA8Unorm_sRGB||format==MTLPixelFormatRGBA8Unorm||format==MTLPixelFormatRGBA8Unorm_sRGB||format==MTLPixelFormatRGB10A2Unorm||format==MTLPixelFormatRGBA16Float;}
@implementation RHGView
-(BOOL)acceptsFirstResponder{return YES;}
-(BOOL)isOpaque{return YES;}
-(BOOL)isFlipped{return YES;}
-(void)updateTrackingAreas{for(NSTrackingArea*t in self.trackingAreas)[self removeTrackingArea:t];[self addTrackingArea:[[NSTrackingArea alloc]initWithRect:self.bounds options:NSTrackingMouseMoved|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil]];[super updateTrackingAreas];}
-(void)keyDown:(NSEvent*)e{[self.owner input:e type:RHG_KEY_DOWN];}
-(void)keyUp:(NSEvent*)e{[self.owner input:e type:RHG_KEY_UP];}
-(void)flagsChanged:(NSEvent*)e{[self.owner input:e type:RHG_FLAGS];}
-(void)mouseMoved:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_MOVE];}
-(void)mouseDragged:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_MOVE];}
-(void)rightMouseDragged:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_MOVE];}
-(void)otherMouseDragged:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_MOVE];}
-(void)mouseDown:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_DOWN];}
-(void)mouseUp:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_UP];}
-(void)rightMouseDown:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_DOWN];}
-(void)rightMouseUp:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_UP];}
-(void)otherMouseDown:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_DOWN];}
-(void)otherMouseUp:(NSEvent*)e{[self.owner input:e type:RHG_MOUSE_UP];}
-(void)scrollWheel:(NSEvent*)e{[self.owner input:e type:RHG_SCROLL];}
@end
@implementation RHGHost
-(instancetype)init{if((self=[super init])){atomic_init(&stopped,false);_diagnosticFD=-1;_inputLock=[NSLock new];_inputs=[NSMutableArray new];_began=CACurrentMediaTime();}return self;}
-(void)dealloc{if(_diagnosticFD>=0)close(_diagnosticFD);if(_port)mach_port_destroy(mach_task_self(),_port);}
-(void)record:(NSString*)phase reason:(NSString*)reason{
 if(self.diagnosticFD<0)return;
 NSMutableDictionary*v=[@{@"schema":@1,@"phase":phase,@"elapsedMilliseconds":@((CACurrentMediaTime()-self.began)*1000),@"hostPID":@(getpid()),@"guestPID":@(self.guestPID),@"window":@(self.window.windowNumber),@"frames":@(self.frames),@"acquires":@(self.acquires),@"requests":@(self.requests),@"hostCommandQueues":@0,@"hostCommandBuffers":@0,@"hostEncoders":@0,@"applicationSurfaceCopies":@0,@"pixelReadbacks":@0,@"metalHUDRequested":@(self.metalHUD),@"presentsWithTransaction":@(self.metal.presentsWithTransaction)}mutableCopy];
 if(reason)v[@"reason"]=reason;
 if(self.surfaceID)v[@"surfaceID"]=@(self.surfaceID);
 NSData*d=[NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingSortedKeys error:nil];if(!d)return;
 NSMutableData*line=[d mutableCopy];[line appendBytes:"\n" length:1];const uint8_t*b=line.bytes;size_t offset=0;while(offset<line.length){ssize_t n=write(self.diagnosticFD,b+offset,line.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0)break;offset+=(size_t)n;}
}
-(void)input:(NSEvent*)e type:(uint32_t)type{
 if(atomic_load(&stopped)||!self.firstFrameAnnounced)return;RHGInput input={0};input.type=type;input.modifiers=e.modifierFlags;input.timestamp=e.timestamp;
 if(type==RHG_KEY_DOWN||type==RHG_KEY_UP||type==RHG_FLAGS){input.keyCode=e.keyCode;input.repeat=type==RHG_KEY_DOWN&&e.isARepeat;NSData*text=[((type==RHG_FLAGS?@"":e.charactersIgnoringModifiers)?:@"")dataUsingEncoding:NSUTF8StringEncoding];input.charactersLength=(uint32_t)MIN(sizeof input.characters,text.length);if(input.charactersLength)memcpy(input.characters,text.bytes,input.charactersLength);}
 else{NSPoint p=[self.view convertPoint:e.locationInWindow fromView:nil];input.x=self.view.bounds.size.width>0?p.x/self.view.bounds.size.width:0;input.y=self.view.bounds.size.height>0?p.y/self.view.bounds.size.height:0;input.button=(uint32_t)e.buttonNumber;input.clickCount=(uint32_t)MAX(0,e.clickCount);input.deltaX=e.deltaX;input.deltaY=e.deltaY;}
 [self.inputLock lock];if(self.inputs.count>=128)[self.inputs removeObjectAtIndex:0];[self.inputs addObject:[NSData dataWithBytes:&input length:sizeof input]];[self.inputLock unlock];
}
-(void)shutdown{
 if(atomic_exchange(&stopped,true))return;
 self.firstFrameCallback=NULL;self.firstFrameContext=NULL;
 [self record:@"stopped" reason:nil];
 mach_port_t port=self.port;self.port=MACH_PORT_NULL;if(port)mach_port_destroy(mach_task_self(),port);
 self.drawable=nil;self.metal.developerHUDProperties=@{@"mode":@"disabled"};
}
@end
static void RHGFill(RHGHost*host,RHGReply*reply){
 reply->magic=RHG_MAGIC;reply->version=RHG_VERSION;reply->window=(uint32_t)host.window.windowNumber;
 reply->width=(uint32_t)host.metal.drawableSize.width;reply->height=(uint32_t)host.metal.drawableSize.height;reply->pixelFormat=(uint32_t)host.metal.pixelFormat;reply->deviceRegistryID=host.device.registryID;reply->backingScale=host.window.backingScaleFactor;
 if(reply->op!=RHG_POLL||reply->eventCount)return;
 BOOL focus=host.window.isKeyWindow;
 if(focus!=host.lastFocus){RHGInput change={0};change.type=RHG_FOCUS;change.keyCode=focus?1:0;change.timestamp=CACurrentMediaTime();[host.inputLock lock];[host.inputs addObject:[NSData dataWithBytes:&change length:sizeof change]];[host.inputLock unlock];host.lastFocus=focus;}
 [host.inputLock lock];reply->eventCount=(uint32_t)MIN(RHG_MAX_EVENTS,host.inputs.count);for(uint32_t i=0;i<reply->eventCount;i++)[host.inputs[i]getBytes:&reply->events[i] length:sizeof(RHGInput)];if(reply->eventCount)[host.inputs removeObjectsInRange:NSMakeRange(0,reply->eventCount)];[host.inputLock unlock];
}
static void RHGServe(RHGHost*host){
 while(!atomic_load(&host->stopped)){@autoreleasepool{
  RHGRequestReceive incoming={0};mach_port_t port=host.port;if(!port)break;
  mach_msg_option_t options=MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
  kern_return_t result=mach_msg(&incoming.message.h,options,0,sizeof incoming,port,50,MACH_PORT_NULL);
  if(result==MACH_RCV_TIMED_OUT)continue;if(result!=KERN_SUCCESS)break;
  RHGRequest*q=&incoming.message;__block RHGReply reply={0};
  reply.h.msgh_remote_port=q->h.msgh_remote_port;reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_size=sizeof reply;reply.op=q->op;reply.requestID=q->requestID;
  if(q->h.msgh_size!=sizeof(RHGRequest)||(q->h.msgh_bits&MACH_MSGH_BITS_COMPLEX)){mach_msg_destroy(&q->h);continue;}
  mach_msg_audit_trailer_t*t=(void*)((uint8_t*)q+round_msg(q->h.msgh_size));
  BOOL valid=q->magic==RHG_MAGIC&&q->version==RHG_VERSION&&t->msgh_trailer_type==MACH_MSG_TRAILER_FORMAT_0&&t->msgh_trailer_size>=sizeof(*t)&&audit_token_to_euid(t->msgh_audit)==geteuid()&&timingsafe_bcmp(q->nonce,host->nonce,RHG_NONCE_BYTES)==0;
  pid_t pid=valid?audit_token_to_pid(t->msgh_audit):0;
  if(valid&&host.guestPID==0){char path[PROC_PIDPATHINFO_MAXSIZE]={0};valid=q->op==RHG_HELLO&&proc_pidpath(pid,path,sizeof path)>0&&host.expectedExecutable.length&&strcmp(path,host.expectedExecutable.fileSystemRepresentation)==0;if(valid)host.guestPID=pid;}
  valid=valid&&pid>0&&host.guestPID==pid;
  if(!valid){reply.status=RHG_REJECTED;reply.magic=RHG_MAGIC;reply.version=RHG_VERSION;}
  else RHGMainSync(^{
   host.requests++;RHGFill(host,&reply);
   if(atomic_load(&host->stopped)){reply.status=RHG_STOPPED;return;}
   if(q->op==RHG_HELLO||q->op==RHG_POLL){if(q->op==RHG_HELLO)[host record:@"guest-connected" reason:nil];}
   else if(q->op==RHG_CONFIGURE){
    uint64_t pixels=(uint64_t)q->width*q->height;
    if(host.drawable){reply.status=RHG_BUSY;return;}
    if(!q->width||!q->height||q->width>8192||q->height>8192||pixels>33554432||!RHGFormat(q->pixelFormat)||q->deviceRegistryID!=host.device.registryID){reply.status=RHG_UNSUPPORTED;return;}
    if(host.configured&&host.metal.pixelFormat==q->pixelFormat&&host.metal.drawableSize.width==q->width&&host.metal.drawableSize.height==q->height)return;
    host.metal.pixelFormat=(MTLPixelFormat)q->pixelFormat;host.metal.drawableSize=CGSizeMake(q->width,q->height);host.configured=YES;RHGFill(host,&reply);[host record:@"configured" reason:nil];
   }else if(q->op==RHG_ACQUIRE){
    if(!host.configured){reply.status=RHG_UNSUPPORTED;return;}if(host.drawable){reply.status=RHG_BUSY;return;}
    host.drawable=[host.metal nextDrawable];IOSurfaceRef surface=host.drawable.texture.iosurface;
    if(!surface){host.drawable=nil;reply.status=RHG_UNSUPPORTED;[host record:@"rejected" reason:@"drawable-has-no-exportable-surface"];return;}
    mach_port_t surfacePort=IOSurfaceCreateMachPort(surface);if(!surfacePort){host.drawable=nil;reply.status=RHG_REJECTED;return;}
    host.surfaceID=IOSurfaceGetID(surface);host.acquires++;reply.frameID=host.frameID;reply.surfaceID=host.surfaceID;
    reply.h.msgh_bits|=MACH_MSGH_BITS_COMPLEX;reply.body.msgh_descriptor_count=1;reply.port=(mach_msg_port_descriptor_t){.name=surfacePort,.disposition=MACH_MSG_TYPE_MOVE_SEND,.type=MACH_MSG_PORT_DESCRIPTOR};
   }else if(q->op==RHG_PRESENT){
    if(!host.drawable||q->frameID!=host.frameID||q->surfaceID!=host.surfaceID||!isfinite(q->presentTime)||!isfinite(q->gpuSeconds)||q->gpuSeconds<0||q->gpuSeconds>600){reply.status=RHG_REJECTED;return;}
    if(q->presentMode>RHG_PRESENT_MIN_DURATION){reply.status=RHG_UNSUPPORTED;return;}
    BOOL transition=!host.firstFrameAnnounced&&host.firstFrameCallback!=NULL;
    if(transition){[CATransaction begin];[CATransaction setDisableActions:YES];host.metal.presentsWithTransaction=YES;}
    if(!host.firstFrameAnnounced){
      __weak RHGHost*weakHost=host;
      [host.drawable addPresentedHandler:^(id<MTLDrawable> displayed){
        CFTimeInterval timestamp=displayed.presentedTime;
        dispatch_async(dispatch_get_main_queue(),^{[weakHost record:@"first-presentation-result" reason:timestamp>0?@"on-glass-timestamp":@"skipped-no-display-timestamp"];});
      }];
    }
    if(q->presentMode==RHG_PRESENT_NORMAL)[host.drawable present];
    else if(q->presentMode==RHG_PRESENT_AT_TIME)[host.drawable presentAtTime:q->presentTime];
    else [host.drawable presentAfterMinimumDuration:q->presentTime];
    if(transition){
      host.firstFrameAnnounced=YES;
      // This callback can only exchange views/flags. No GPU wait or display
      // capture is performed inside the first presentation transaction.
      host.firstFrameCallback(host.firstFrameContext);
      [CATransaction commit];host.metal.presentsWithTransaction=NO;
      [host record:@"first-gpu-complete-transition" reason:nil];
    }else host.firstFrameAnnounced=YES;
    reply.frameID=host.frameID;reply.surfaceID=host.surfaceID;host.frames++;
    if(host.frames==1||host.frames%120==0)[host record:@"present-call" reason:nil];host.drawable=nil;host.frameID++;
   }else if(q->op==RHG_DONE){[host record:@"guest-done" reason:nil];host.drawable=nil;}
   else reply.status=RHG_UNSUPPORTED;
  });
  if(reply.h.msgh_remote_port){kern_return_t sent=mach_msg(&reply.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,reply.h.msgh_size,0,MACH_PORT_NULL,2000,MACH_PORT_NULL);if(sent!=KERN_SUCCESS){if(reply.body.msgh_descriptor_count)mach_msg_destroy(&reply.h);RHGMainSync(^{[host record:@"peer-lost" reason:nil];});}}
 }}
}
RHGHostRef RHGHostCreate(void*windowPointer,bool hud,const char*expectedExecutable,const char*diagnosticPath){
 if(!NSThread.isMainThread||!windowPointer||!expectedExecutable||!diagnosticPath)return NULL;
 NSWindow*window=(__bridge NSWindow*)windowPointer;RHGHost*host=[RHGHost new];host.window=window;host.expectedExecutable=[NSString stringWithUTF8String:expectedExecutable];host.metalHUD=hud;
 host.diagnosticFD=open(diagnosticPath,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(host.diagnosticFD<0)return NULL;
 host.device=MTLCreateSystemDefaultDevice();if(!host.device)return NULL;
 host.service=[@RHG_SERVICE_PREFIX stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];arc4random_buf(host->nonce,sizeof host->nonce);NSMutableString*hex=[NSMutableString new];for(unsigned i=0;i<RHG_NONCE_BYTES;i++)[hex appendFormat:@"%02x",host->nonce[i]];host.nonceString=hex;
 RHGView*view=[[RHGView alloc]initWithFrame:window.contentView.bounds];view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;view.owner=host;view.wantsLayer=YES;host.view=view;
 CAMetalLayer*layer=[CAMetalLayer layer];layer.device=host.device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;layer.opaque=YES;layer.backgroundColor=NSColor.blackColor.CGColor;layer.contentsScale=window.backingScaleFactor;layer.drawableSize=CGSizeMake(MAX(1,view.bounds.size.width*window.backingScaleFactor),MAX(1,view.bounds.size.height*window.backingScaleFactor));layer.maximumDrawableCount=3;view.layer=layer;layer.presentsWithTransaction=NO;host.metal=layer;
 if(hud)layer.developerHUDProperties=@{@"mode":@"main",@"MTL_HUD_ENABLED":@1,@"MTL_HUD_DISABLE_MENU_BAR":@1,@"MTL_HUD_ALIGNMENT":@"topleft",@"MTL_HUD_ELEMENTS":@"device,layersize,fps,framenumber,frameinterval,frameintervalgraph,presentdelay"};
 mach_port_t port=MACH_PORT_NULL;if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)!=KERN_SUCCESS)return NULL;host.port=port;
 if(mach_port_insert_right(mach_task_self(),host.port,host.port,MACH_MSG_TYPE_MAKE_SEND)!=KERN_SUCCESS||bootstrap_register(bootstrap_port,(char*)host.service.UTF8String,host.port)!=KERN_SUCCESS)return NULL;
 [host record:@"host-ready" reason:nil];dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{RHGServe(host);dispatch_async(dispatch_get_main_queue(),^{host.view.owner=nil;host.view=nil;host.metal=nil;});});return (__bridge_retained RHGHostRef)host;
}
void*RHGHostGetView(RHGHostRef ref){return ref?(__bridge void*)((__bridge RHGHost*)ref).view:NULL;}
const char*RHGHostService(RHGHostRef ref){return ref?((__bridge RHGHost*)ref).service.UTF8String:NULL;}
const char*RHGHostNonce(RHGHostRef ref){return ref?((__bridge RHGHost*)ref).nonceString.UTF8String:NULL;}
void RHGHostSetFirstFrameCallback(RHGHostRef ref,void*context,RHGHostFirstFrameCallback callback){if(ref)RHGMainSync(^{RHGHost*host=(__bridge RHGHost*)ref;host.firstFrameContext=context;host.firstFrameCallback=callback;});}
void RHGHostStop(RHGHostRef ref){if(ref)RHGMainSync(^{[((__bridge RHGHost*)ref)shutdown];});}
void RHGHostDestroy(RHGHostRef ref){if(ref){RHGHostStop(ref);CFRelease((CFTypeRef)ref);}}
void RHGHostResize(RHGHostRef ref){if(ref)RHGMainSync(^{RHGHost*host=(__bridge RHGHost*)ref;host.metal.contentsScale=host.window.backingScaleFactor;if(!host.configured)host.metal.drawableSize=CGSizeMake(MAX(1,host.view.bounds.size.width*host.window.backingScaleFactor),MAX(1,host.view.bounds.size.height*host.window.backingScaleFactor));});}
uint32_t RHGHostWindowNumber(RHGHostRef ref){return ref?(uint32_t)((__bridge RHGHost*)ref).window.windowNumber:0;}
int32_t RHGHostGuestPID(RHGHostRef ref){return ref?((__bridge RHGHost*)ref).guestPID:0;}
