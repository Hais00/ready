#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own CPU-only Mach/AppKit fixtures. No actual game, GPU rendering, SDK or account."""
import hashlib,json,os,pathlib,plistlib,shutil,subprocess,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
DRIVER=r'''
#import <Cocoa/Cocoa.h>
#import <servers/bootstrap.h>
#import <objc/runtime.h>
#import "ReadyHostedGameProtocol.h"
#include <unistd.h>
@interface UnsupportedWindow:NSWindow @end
@implementation UnsupportedWindow @end
@interface RHGFixtureWindow:NSWindow @end
@implementation RHGFixtureWindow @end
#define require(condition) do{if(!(condition)){fprintf(stderr,"fixture-check-line:%d\n",__LINE__);_exit(81);}}while(0)
static void server(mach_port_t port,const char *mode){
 for(;;){@autoreleasepool{
  RHGRequestReceive receive={0};kern_return_t result=mach_msg(&receive.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof receive,port,2000,MACH_PORT_NULL);if(result)_exit(82);
  RHGRequest request=receive.message;
  RHGReply reply={0};reply.h.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0);reply.h.msgh_remote_port=request.h.msgh_remote_port;reply.h.msgh_size=sizeof reply;
  reply.magic=RHG_MAGIC;reply.version=RHG_VERSION;reply.op=request.op;reply.requestID=request.requestID;reply.status=RHG_OK;
  reply.window=4242;reply.width=640;reply.height=360;reply.pixelFormat=80;reply.deviceRegistryID=1;reply.backingScale=2;
  if(!strcmp(mode,"bad-reply"))reply.requestID++;
  if(!strcmp(mode,"bad-metadata"))reply.width=0;
  if(mach_msg(&reply.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof reply,0,MACH_PORT_NULL,2000,MACH_PORT_NULL))_exit(83);
 }}
}
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=2)return 64;alarm(10);const char *mode=argv[1],*name=getenv("READY_HOSTED_GAME_SERVICE");
 mach_port_t port=0;if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port)||mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND)||bootstrap_register(bootstrap_port,(char*)name,port))return 84;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{server(port,mode);});
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];[NSApp finishLaunching];
 require(NSApp.activationPolicy==NSApplicationActivationPolicyAccessory);
 require([NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]&&NSApp.activationPolicy==NSApplicationActivationPolicyAccessory);
 require(NSApp.touchBar==nil&&[NSApp makeTouchBar]==nil);NSApp.touchBar=nil;
 NSApp.automaticCustomizeTouchBarMenuItemEnabled=YES;NSTouchBar.automaticCustomizeTouchBarMenuItemEnabled=YES;
 require(!NSApp.automaticCustomizeTouchBarMenuItemEnabled&&!NSTouchBar.automaticCustomizeTouchBarMenuItemEnabled);
 Class type=!strcmp(mode,"subclass")?RHGFixtureWindow.class:!strcmp(mode,"unsupported")?UnsupportedWindow.class:NSWindow.class;
 NSWindow *window=[[type alloc]initWithContentRect:NSMakeRect(0,0,640,360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 if(!strcmp(mode,"multiple")){(void)[[NSWindow alloc]initWithContentRect:NSZeroRect styleMask:0 backing:NSBackingStoreBuffered defer:NO];return 85;}
 require(![NSStringFromClass(object_getClass(window))isEqualToString:@"NSWindow"]);
 NSView *root=[[NSView alloc]initWithFrame:NSMakeRect(0,0,320,180)],*child=[[NSView alloc]initWithFrame:NSMakeRect(0,0,100,50)];[root addSubview:child];window.contentView=root;[window makeKeyAndOrderFront:nil];
 require(window.windowNumber==4242&&window.backingScaleFactor==2&&window.isVisible&&window.isKeyWindow);
 SEL titleBar=NSSelectorFromString(@"hasTitleBar");
 require(((BOOL(*)(id,SEL))[window methodForSelector:titleBar])(window,titleBar));
 window.styleMask=NSWindowStyleMaskBorderless;require(!((BOOL(*)(id,SEL))[window methodForSelector:titleBar])(window,titleBar));window.styleMask=NSWindowStyleMaskTitled;
 NSRect frameBefore=window.frame;window.contentAspectRatio=NSMakeSize(16,9);
 require(NSEqualSizes(window.contentAspectRatio,NSMakeSize(16,9))&&NSEqualRects(window.frame,frameBefore));
 require(NSEqualSizes(window.minSize,NSZeroSize)&&NSEqualSizes(window.contentMinSize,NSZeroSize));
 require(window.maxSize.width==CGFLOAT_MAX&&window.contentMaxSize.height==CGFLOAT_MAX);
 require(NSEqualSizes(window.resizeIncrements,NSMakeSize(1,1))&&NSEqualSizes(window.contentResizeIncrements,NSMakeSize(1,1)));
 window.minSize=NSMakeSize(100,80);window.maxSize=NSMakeSize(1200,900);window.contentMinSize=NSMakeSize(90,70);window.contentMaxSize=NSMakeSize(1100,800);
 window.resizeIncrements=NSMakeSize(2,3);window.contentResizeIncrements=NSMakeSize(4,5);window.aspectRatio=NSMakeSize(4,3);
 require(NSEqualSizes(window.minSize,NSMakeSize(100,80))&&NSEqualSizes(window.maxSize,NSMakeSize(1200,900)));
 require(NSEqualSizes(window.contentMinSize,NSMakeSize(90,70))&&NSEqualSizes(window.contentMaxSize,NSMakeSize(1100,800)));
 require(NSEqualSizes(window.resizeIncrements,NSMakeSize(2,3))&&NSEqualSizes(window.contentResizeIncrements,NSMakeSize(4,5)));
 require(NSEqualSizes(window.aspectRatio,NSMakeSize(4,3))&&NSEqualRects(window.frame,frameBefore));
 NSPoint point=NSMakePoint(41.5,53.25);NSRect rect=NSMakeRect(7.5,11.25,123.5,71.75);
 require(NSEqualPoints([window convertPointFromScreen:[window convertPointToScreen:point]],point));
 require(NSEqualRects([window convertRectFromScreen:[window convertRectToScreen:rect]],rect)&&NSEqualRects(window.frame,frameBefore));
 [NSApp activate];[NSApp activateIgnoringOtherApps:YES];[NSApp unhide:nil];
 require(NSApp.isActive);
 require(NSRunningApplication.currentApplication.isActive);
 require([NSRunningApplication.currentApplication activateWithOptions:NSApplicationActivateIgnoringOtherApps]);
 NSMenu *logicalMenu=[[NSMenu alloc]initWithTitle:@"Owned fixture logical menu"];
 [logicalMenu addItemWithTitle:@"Controlled fixture item" action:NULL keyEquivalent:@""];
 NSApp.mainMenu=logicalMenu;NSApp.presentationOptions=NSApplicationPresentationAutoHideDock|NSApplicationPresentationAutoHideMenuBar;
 require(NSApp.mainMenu==logicalMenu&&NSApp.presentationOptions==(NSApplicationPresentationAutoHideDock|NSApplicationPresentationAutoHideMenuBar));
 SEL visibleAlias=NSSelectorFromString(@"setIsVisible:");
 ((void(*)(id,SEL,BOOL))[window methodForSelector:visibleAlias])(window,visibleAlias,NO);require(!window.isVisible&&NSApp.keyWindow==nil);
 ((void(*)(id,SEL,BOOL))[window methodForSelector:visibleAlias])(window,visibleAlias,YES);require(window.isVisible&&NSApp.keyWindow==window);
 require(NSApp.windows.count==1&&NSApp.mainWindow==window&&NSApp.keyWindow==window&&[NSApp windowWithWindowNumber:4242]==window);
 require([NSApp valueForKey:@"keyWindow"]==nil&&[NSApp valueForKey:@"mainWindow"]==nil&&[[NSApp valueForKey:@"windows"]count]==0);
 require(![[NSApp valueForKey:@"active"]boolValue]&&[NSApp valueForKey:@"mainMenu"]==nil);
 NSMethodSignature *signature=[NSApp methodSignatureForSelector:@selector(keyWindow)];NSInvocation *invocation=[NSInvocation invocationWithMethodSignature:signature];
 invocation.selector=@selector(keyWindow);[invocation invokeWithTarget:NSApp];__unsafe_unretained id frameworkWindow=nil;[invocation getReturnValue:&frameworkWindow];require(frameworkWindow==nil);
 for(int i=0;i<5;i++)[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 require(NSApp.keyWindow==window&&NSApp.isActive);
 require(root.window==window&&child.window==window&&[window isKindOfClass:NSWindow.class]);
 NSClickGestureRecognizer *click=[[NSClickGestureRecognizer alloc]initWithTarget:nil action:NULL];
 NSPanGestureRecognizer *pan=[[NSPanGestureRecognizer alloc]initWithTarget:nil action:NULL];
 [child addGestureRecognizer:click];[child addGestureRecognizer:pan];require(click.view==child&&pan.view==child);
 require(child.gestureRecognizers.count==2);[root addGestureRecognizer:click];require(click.view==root&&child.gestureRecognizers.count==1);
 root.gestureRecognizers=@[];require(click.view==nil&&root.gestureRecognizers.count==0);
 child.gestureRecognizers=@[click,pan];require(click.view==child&&pan.view==child&&child.gestureRecognizers.count==2);
 SEL gestureProvider=NSSelectorFromString(@"gestureEnvironment");
 require(((id(*)(id,SEL))[window methodForSelector:gestureProvider])(window,gestureProvider)==nil);
 [child removeGestureRecognizer:click];[child removeGestureRecognizer:pan];require(click.view==nil&&pan.view==nil);
 NSRect cursorRect=NSMakeRect(3,5,50,20);NSCursor *cursor=NSCursor.arrowCursor;
 [child resetCursorRects];for(int i=0;i<1000;i++)[child addCursorRect:cursorRect cursor:cursor];[child removeCursorRect:cursorRect cursor:cursor];
 [child addCursorRect:child.bounds cursor:cursor];[child discardCursorRects];
 require([window makeFirstResponder:child]&&window.firstResponder==child);
 [NSApp updateWindows];
 if(!strcmp(mode,"unknown-selector")){((void(*)(id,SEL))[window methodForSelector:NSSelectorFromString(@"unsupportedOwnedFixtureSelector")])(window,NSSelectorFromString(@"unsupportedOwnedFixtureSelector"));return 86;}
 NSArray *census=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));unsigned own=0;
 for(NSDictionary *entry in census)if([entry[(id)kCGWindowOwnerPID]intValue]==getpid())own++;
 require(own==0);[window close];require(NSApp.windows.count==0&&child.window==nil);
 puts("{\"passed\":true,\"logicalNSAppWindowLinks\":true,\"viewWindowLinks\":true,\"realGuestWindowServerResources\":0,\"GPUCommands\":0}");return 0;
}}
'''
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-shim-cpu-',dir=WORK/'tests'));run.chmod(0o700)
 include=ROOT/'Sources/ReadyHostedView/include';shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';header=include/'ReadyHostedGameProtocol.h'
 before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in[shim,header]}
 driver=run/'driver.m';driver.write_text(DRIVER);library=run/'shim.dylib'
 bundle=run/'HostedGuestFixture.app';contents=bundle/'Contents';macos=contents/'MacOS';macos.mkdir(parents=True,mode=0o700);binary=macos/'driver'
 (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'driver','CFBundleIdentifier':'local.ready.hosted.fixture.'+uuid.uuid4().hex,'CFBundlePackageType':'APPL','LSUIElement':True,'NSHighResolutionCapable':True}))
 flags=['/usr/bin/clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wall','-Wextra','-Wno-deprecated-declarations','-I',str(include),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics']
 for source,output,extra in [(shim,library,['-dynamiclib']),(driver,binary,[])]:
  result=subprocess.run([*flags,*extra,str(source),'-o',str(output)],capture_output=True,text=True)
  (run/(output.name+'.build.log')).write_text(result.stdout+result.stderr)
  if result.returncode:raise RuntimeError(result.stderr[-6000:])
 checks={}
 regular=run/'RegularGuestFixture.app/Contents';(regular/'MacOS').mkdir(parents=True,mode=0o700);shutil.copy2(binary,regular/'MacOS/driver')
 (regular/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'driver','CFBundleIdentifier':'local.ready.hosted.regular.'+uuid.uuid4().hex,'CFBundlePackageType':'APPL','LSUIElement':False}))
 for mode,expected in [('logical',0),('regular-policy',0),('subclass',0),('unsupported',77),('multiple',77),('unknown-selector',77),('bad-reply',77),('bad-metadata',77)]:
  env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM'))}
  env.update(DYLD_INSERT_LIBRARIES=str(library),READY_HOSTED_GAME_SERVICE='local.ready.hostedgame.fixture.'+uuid.uuid4().hex,READY_HOSTED_GAME_NONCE='a1'*32,MTL_HUD_ENABLED='0')
  executable=regular/'MacOS/driver'if mode=='regular-policy'else binary
  result=subprocess.run([str(executable),mode],env=env,capture_output=True,text=True,timeout=15)
  (run/(mode+'.stdout.log')).write_text(result.stdout);(run/(mode+'.stderr.log')).write_text(result.stderr)
  if result.returncode!=expected:raise RuntimeError('Own shim fixture failed '+mode+' exit '+str(result.returncode)+' '+result.stderr[-2000:]+' Retained '+str(run))
  if expected==0:assert json.loads(result.stdout)['realGuestWindowServerResources']==0
  else:assert any(json.loads(line).get('hiddenGuestWindowFallback')is False for line in result.stderr.splitlines()if line.startswith('{'))
  if mode=='unsupported':
   refusal=next(json.loads(line)for line in result.stderr.splitlines()if line.startswith('{')and json.loads(line).get('reason')=='unsupported-window-subclass')
   assert refusal['requestedClass']=='UnsupportedWindow'and refusal['selector']in('alloc','allocWithZone:')
  checks[mode]=True
 assert before=={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in[shim,header]}
 report={'passed':True,'checks':checks,'count':len(checks),'sourceHashes':before,'fixtureOnly':True,'gameAccountOrSDKExecuted':False,'GPURenderingExecuted':False,'retainedRoot':str(run)}
 (run/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
