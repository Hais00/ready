// SPDX-License-Identifier: GPL-3.0-only
// Appended to a private shim copy with installation constructor removed. Calls
// the real configuration/cache routine and actual Mach transport, with no GPU.
@interface FixtureConfigDevice:NSObject @end
@implementation FixtureConfigDevice
-(uint64_t)registryID{return 42;}
@end
@interface FixtureConfigLayer:NSObject
@property BOOL displaySyncEnabled;
@property CGSize drawableSize;
@property MTLPixelFormat pixelFormat;
@property(strong)id device;
@end
@implementation FixtureConfigLayer @end
static _Atomic unsigned configRequests;
static _Atomic uint32_t lastConfigSync;
static BOOL wrongACK,invalidACK;
static void configServer(mach_port_t port){for(;;){@autoreleasepool{
 RHGRequestReceive received={0};if(mach_msg(&received.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof received,port,3000,MACH_PORT_NULL))_exit(82);
 RHGRequest request=received.message;RHGReply reply={0};reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_remote_port=request.h.msgh_remote_port;reply.h.msgh_size=sizeof reply;
 reply.magic=RHG_MAGIC;reply.version=RHG_VERSION;reply.op=request.op;reply.requestID=request.requestID;reply.status=RHG_OK;
 reply.window=4242;reply.width=640;reply.height=360;reply.pixelFormat=80;reply.deviceRegistryID=42;reply.backingScale=2;reply.logicalWidth=320;reply.logicalHeight=180;reply.pointerX=reply.pointerY=.5;
 if(request.op==RHG_CONFIGURE){atomic_fetch_add(&configRequests,1);atomic_store(&lastConfigSync,request.displaySyncEnabled);reply.displaySyncEnabled=invalidACK?2:wrongACK?!request.displaySyncEnabled:request.displaySyncEnabled;}
 if(mach_msg(&reply.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof reply,0,MACH_PORT_NULL,2000,MACH_PORT_NULL))_exit(83);
}}}
#define require(value) do{if(!(value)){fprintf(stderr,"vsync-fixture-line:%d\n",__LINE__);_exit(81);}checks++;}while(0)
int main(int argc,char **argv){@autoreleasepool{
 alarm(8);unsigned checks=0;wrongACK=argc==2&&!strcmp(argv[1],"wrong-ack");invalidACK=argc==2&&!strcmp(argv[1],"invalid-ack");
 mach_port_t port=0;const char *name=getenv("READY_HOSTED_GAME_SERVICE");
 if(!name||mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)||mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND)||bootstrap_register(bootstrap_port,(char*)name,port))return 84;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{configServer(port);});rhgConnect();
 FixtureConfigLayer *layer=[FixtureConfigLayer new];layer.device=[FixtureConfigDevice new];layer.drawableSize=CGSizeMake(640,360);layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.displaySyncEnabled=NO;
 RHGRequest request=rhgAdoptLayerConfiguration((CAMetalLayer*)layer);require(request.displaySyncEnabled==0&&atomic_load(&lastConfigSync)==0&&atomic_load(&configRequests)==1);
 (void)rhgAdoptLayerConfiguration((CAMetalLayer*)layer);require(atomic_load(&configRequests)==1);
 layer.displaySyncEnabled=YES;request=rhgAdoptLayerConfiguration((CAMetalLayer*)layer);require(request.displaySyncEnabled==1&&atomic_load(&lastConfigSync)==1&&atomic_load(&configRequests)==2);
 (void)rhgAdoptLayerConfiguration((CAMetalLayer*)layer);require(atomic_load(&configRequests)==2);
 layer.displaySyncEnabled=NO;request=rhgAdoptLayerConfiguration((CAMetalLayer*)layer);require(request.displaySyncEnabled==0&&atomic_load(&lastConfigSync)==0&&atomic_load(&configRequests)==3);
 require(rhgConfiguredDisplaySync==0&&RHG_VERSION==4);
 printf("{\"passed\":true,\"checks\":%u,\"actualMachTransport\":true,\"actualGuestCacheFunction\":true,\"GPUOrUIUsed\":false}\n",checks);return 0;
}}
