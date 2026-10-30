#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own native-fullscreen Metal cover culling experiment; no capture/readback/input/game.
Uses the existing native CAMetalDisplayLink guest fixture with a matched root size.
Records both outcomes honestly; it does not assume a one-point gap fixes culling.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
HOST=r'''
@interface OwnMetalCover:NSView @end
@implementation OwnMetalCover
-(CALayer*)makeBackingLayer{return [CAMetalLayer layer];}
@end
int main(int argc,const char**argv){@autoreleasepool{
 umask(077);if(argc!=4)return 2;NSString*mode=@(argv[1]),*root=@(argv[2]),*binary=@(argv[3]);
 if([mode isEqual:@"guest-link-positive"])return guestDisplayLink(root,YES);
 BOOL gap=[mode containsString:@"gap"];
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
 NSWindow*window=[[NSWindow alloc]initWithContentRect:NSMakeRect(80,80,640,400) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];window.title=@"Ready own fullscreen Metal-cover regression";window.releasedWhenClosed=NO;window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
 NSView*container=[[NSView alloc]initWithFrame:NSMakeRect(0,0,640,400)];container.wantsLayer=YES;window.contentView=container;
 __block RemoteHostView*view=nil;__block OwnMetalCover*cover=nil;__block CALayerHost*host=nil;
 __block id<MTLDevice>device=nil;__block id<MTLCommandQueue>queue=nil;
 __block NSTask*task=nil;__block NSTimer*poll=nil;__block NSDictionary*guestReport=nil;
 __block BOOL entered=NO,coverReady=NO,attached=NO,removed=NO,done=NO,exiting=NO;
 __block unsigned coverFrames=0;__block double coverStamp=0;__block uint32_t contextID=0;
 __block int guestStatus=-1;__block NSString*failure=nil;__block NSRect coverFrame=NSZeroRect,rootFrame=NSZeroRect;
 void(^finish)(void)=^{if(exiting)return;exiting=YES;[poll invalidate];if(host)host.contextId=0;
  if(window.styleMask&NSWindowStyleMaskFullScreen)[window toggleFullScreen:nil];
  else{[window orderOut:nil];[window close];done=YES;stopLoop();}
 };
 id exitObserver=[NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidExitFullScreenNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){if(exiting){[window orderOut:nil];[window close];done=YES;stopLoop();}}];
 id enterObserver=[NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidEnterFullScreenNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){
  entered=YES;rootFrame=container.bounds;
  view=[[RemoteHostView alloc]initWithFrame:container.bounds];view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[container addSubview:view];view.wantsLayer=YES;host=(CALayerHost*)view.layer;host.frame=view.bounds;host.opaque=YES;
  coverFrame=container.bounds;if(gap)coverFrame.size.height=MAX(1,coverFrame.size.height-1);
  cover=[[OwnMetalCover alloc]initWithFrame:coverFrame];cover.autoresizingMask=NSViewNotSizable;[container addSubview:cover];cover.wantsLayer=YES;cover.alphaValue=.999;
  CAMetalLayer*layer=(CAMetalLayer*)cover.layer;device=MTLCreateSystemDefaultDevice();queue=[device newCommandQueue];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;layer.opaque=YES;layer.opacity=.999;layer.frame=cover.bounds;layer.contentsScale=window.backingScaleFactor;layer.drawableSize=CGSizeMake(cover.bounds.size.width*window.backingScaleFactor,cover.bounds.size.height*window.backingScaleFactor);layer.allowsNextDrawableTimeout=YES;layer.displaySyncEnabled=YES;
  writeJSON(@{@"width":@(rootFrame.size.width),@"height":@(rootFrame.size.height),@"scale":@(window.backingScaleFactor)},[root stringByAppendingPathComponent:@"host-geometry.json"]);[CATransaction flush];
 }];
 [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];[window toggleFullScreen:nil];
 poll=[NSTimer scheduledTimerWithTimeInterval:.025 repeats:YES block:^(NSTimer*t){
  if(exiting)return;if(!entered)return;
  if(!coverReady){
   if(coverFrames>=8)return;coverFrames++;
   CAMetalLayer*layer=(CAMetalLayer*)cover.layer;id<CAMetalDrawable>d=[layer nextDrawable];
   if(!d){failure=@"cover-nextDrawable-unavailable";finish();return;}
   MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=d.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(.08,.1,.13,1);
   id<MTLCommandBuffer>cb=[queue commandBuffer];id<MTLRenderCommandEncoder>encoder=[cb renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];
   [d addPresentedHandler:^(id<MTLDrawable>shown){double stamp=shown.presentedTime;if(stamp>0)dispatch_async(dispatch_get_main_queue(),^{if(!coverReady){coverReady=YES;coverStamp=stamp;}});}];[cb presentDrawable:d];[cb commit];return;
  }
  if(!task){
   task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:binary];task.arguments=@[@"guest-link-positive",root,binary];
   NSString*out=[root stringByAppendingPathComponent:@"guest.stdout.log"],*err=[root stringByAppendingPathComponent:@"guest.stderr.log"];[[NSData data]writeToFile:out atomically:NO];[[NSData data]writeToFile:err atomically:NO];task.standardOutput=[NSFileHandle fileHandleForWritingAtPath:out];task.standardError=[NSFileHandle fileHandleForWritingAtPath:err];NSError*error=nil;
   if(![task launchAndReturnError:&error]){failure=@"guest-start-failed";finish();}return;
  }
  if(!attached){NSDictionary*context=readJSON([root stringByAppendingPathComponent:@"context.json"]);uint32_t cid=[context[@"contextId"]unsignedIntValue];if(cid){contextID=cid;host.contextId=cid;[CATransaction flush];attached=YES;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{writeJSON(@{@"hostWindowVisible":@(window.visible),@"attachedContextId":@(host.contextId)},[root stringByAppendingPathComponent:@"host-attached"]);});}}
  if(!removed&&[NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"first-native-frame"]]){[cover removeFromSuperview];[CATransaction flush];removed=YES;}
  if(!task.running){[task waitUntilExit];guestStatus=task.terminationStatus;guestReport=readJSON([root stringByAppendingPathComponent:@"guest-result.json"]);finish();}
 }];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,16*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!done){failure=@"overall-deadline";if(task.running){[task terminate];[task waitUntilExit];}finish();dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!done){[window orderOut:nil];[window close];done=YES;stopLoop();}});}});
 [NSApp run];[NSNotificationCenter.defaultCenter removeObserver:enterObserver];[NSNotificationCenter.defaultCenter removeObserver:exitObserver];
 if(task.running){[task terminate];[task waitUntilExit];}
 BOOL completed=entered&&coverReady&&attached&&guestReport!=nil&&!failure;
 emit(@{@"probeCompleted":@(completed),@"gapLogicalPoints":@(gap?1:0),@"nativeFullscreenSpaceEntered":@(entered),@"coverIsOpaqueCAMetalLayer":@YES,@"coverViewAlpha":@.999,@"coverLayerOpacity":@.999,@"coverWasActuallyPresented":@(coverStamp>0),@"coverGPUFrames":@(coverFrames),@"coverFrame":@[@(coverFrame.origin.x),@(coverFrame.origin.y),@(coverFrame.size.width),@(coverFrame.size.height)],@"remoteRootFrame":@[@(rootFrame.origin.x),@(rootFrame.origin.y),@(rootFrame.size.width),@(rootFrame.size.height)],@"positiveHandoffOccurred":@(removed),@"guest":guestReport?:@{},@"guestExitStatus":@(guestStatus),@"failure":failure?:@"",@"hostMetalDeviceUsedOnlyForLoadingCover":@YES,@"noCaptureReadbackInputOrGame":@YES});return completed?0:3;
}}
'''
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-remote-metal-cover-',dir=WORK/'tests'));run.chmod(0o700)
 base=ROOT/'Synthetic/ReadyHostedRemoteLayerProbe.m';paths=[base,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 source=base.read_text().split('int main(int argc,const char**argv)')[0]
 needle='layer.frame=CGRectMake(0,0,192,144);layer.drawableSize=CGSizeMake(192,144);'
 replacement='NSDictionary*geometry=readJSON([root stringByAppendingPathComponent:@"host-geometry.json"]);double gw=[geometry[@"width"]doubleValue],gh=[geometry[@"height"]doubleValue],gs=[geometry[@"scale"]doubleValue];if(gw<1||gh<1||gs<=0){gw=192;gh=144;gs=1;}layer.frame=CGRectMake(0,0,gw,gh);layer.drawableSize=CGSizeMake(gw*gs,gh*gs);'
 assert source.count(needle)==2;source=source.replace(needle,replacement)
 generated=run/'probe.m';generated.write_text(source+HOST)
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','READY_','MTL_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-remote-metal-cover'))
 cmd=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1',str(generated),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-o',str(run/'probe')]
 p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+' compile '+p.stderr[-2500:])
 cases={}
 for case,mode in [('full-metal-cover','host-full'),('one-point-gap','host-gap')]:
  case_root=run/case;case_root.mkdir(mode=0o700)
  p=subprocess.run([str(run/'probe'),mode,str(case_root),str(run/'probe')],env=env,capture_output=True,text=True,timeout=22);(case_root/'stdout.json').write_text(p.stdout);(case_root/'stderr.log').write_text(p.stderr)
  if p.returncode:raise RuntimeError(str(run)+' '+case+' '+p.stdout[-3000:]+p.stderr[-1000:])
  result=json.loads(p.stdout);assert result['probeCompleted'];cases[case]=result
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 report={'probeCompleted':True,'cases':cases,'sourceHashes':before,'generatedProbeSHA256':sha(generated),'noProductionChanges':True,'limitation':'Synthetic native CAMetalDisplayLink producer with static opaque Metal cover; does not establish Cyberpunk behavior or game performance.'};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-remote-metal-cover-tests.json').write_text(json.dumps(out,indent=2)+'\n')
 compact={**out,'cases':{k:{**v,'guest':{g:w for g,w in v['guest'].items()if g not in ('presentedTimes','surfaceIDs')}}for k,v in cases.items()}};print(json.dumps(compact,indent=2))
if __name__=='__main__':main()
