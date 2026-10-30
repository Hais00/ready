#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual Swift fullscreen controller with controlled notifications/host. No shown
window, actual Space transition, GPU, input, capture, account, SDK or game."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
CORE=r'''import Foundation
public enum LauncherError:Error {case busy,unavailable(String),failed(String)}
public enum GamePlatform {case macOS,windows}
public struct GameVariant {public let platform:GamePlatform;public let executable:String?}
public struct Game {public let storeID:String;public var id:String{storeID}}
public struct LauncherPaths {public init(){};public var logs:URL{URL(fileURLWithPath:"/")}}
public enum NativeBinaryProbe {public static func applicationExecutable(_ url:URL)throws->URL{url}}
public enum AtomicFile {public static func writePrivate(_ data:Data,to url:URL)throws{try data.write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}}
'''
FRONTEND=r'''import AppKit
import LauncherCore
// Scalar fixture identity only: never creates a Metal device or GPU resource.
struct FixtureCanvasDevice {let registryID:UInt64=42}
final class MetalCanvas:NSView {
 let device=FixtureCanvasDevice();var interactionEnabled=true;var releases=0;var resumes=0;var renderResourcesActive=true;var gameInterfaceMode=false;var interfaceMoves=[Int]();var interfaceConfirms=0
 override var acceptsFirstResponder:Bool{interactionEnabled && renderResourcesActive}
 override init(frame:NSRect){super.init(frame:frame);wantsLayer=true}
 required init?(coder:NSCoder){fatalError("Unused fixture coder")}
 func releaseGraphics(){releases+=1;renderResourcesActive=false}
 func resumeGraphics(){resumes+=1;renderResourcesActive=true}
}
// The production helper is deliberately not compiled into this CPU fixture.
// Default capture resolves nil synchronously and never calls ScreenCaptureKit.
enum GameBackdropSnapshot {
 @MainActor static var calls=0
 @MainActor static func capture(window:NSWindow,completion:@escaping @MainActor(CGImage?)->Void){calls+=1;completion(nil)}
}
final class SessionManager {func quit(){}}
final class AppDelegate:NSObject {var window:NSWindow!;var canvas:MetalCanvas!;var hostedWindowPlacement:HostedWindowPlacement?;var hostedPresentation:HostedGamePresentationController?;var paths=LauncherPaths();var project=URL(fileURLWithPath:"/");var session:SessionManager?;func showError(_ error:Error){};func finishLaunchSplash(){};func beginGameInterface(gameID:String){canvas.gameInterfaceMode=true;canvas.interactionEnabled=true;canvas.resumeGraphics()};func endGameInterface(){canvas.releaseGraphics();canvas.gameInterfaceMode=false};func moveGameInterfaceSelection(_ delta:Int){canvas.interfaceMoves.append(delta)};func activateGameInterfaceSelection(){canvas.interfaceConfirms+=1}}
'''
HOST=r'''#import <AppKit/AppKit.h>
#include "FixtureBridge.h"
@interface FixtureGameView:NSView @end
@implementation FixtureGameView
-(BOOL)acceptsFirstResponder{return YES;}
-(BOOL)isFlipped{return YES;}
@end
@interface FixtureHost:NSObject
@property(strong)NSView *view;
@property(assign)void *context;
@property(assign)RHGHostFirstFrameCallback callback;
@property BOOL stopped,overlayVisible;
@end
@implementation FixtureHost @end
static FixtureHost *current;static int created,stops,pointerEnabled,transportMode,hudRequested,failCreate;static uint64_t remoteRegistryID;
void RHGFixtureReset(void){if(current)abort();created=stops=pointerEnabled=transportMode=hudRequested=failCreate=0;remoteRegistryID=0;}
int RHGFixtureCreateCount(void){return created;}
int RHGFixtureStopCount(void){return stops;}
int RHGFixturePointerEnabled(void){return current.overlayVisible?0:pointerEnabled;}
int RHGFixtureOverlayGate(void){return current.overlayVisible?1:0;}
int RHGFixtureTransportMode(void){return transportMode;}
uint64_t RHGFixtureDeviceRegistryID(void){return remoteRegistryID;}
int RHGFixtureHUDRequested(void){return hudRequested;}
void RHGFixtureSetFailCreate(int fail){failCreate=fail;}
void RHGFixturePresent(void){if(current.callback)current.callback(current.context);}
static RHGHostRef fixtureCreate(void*w){created++;if(failCreate)return NULL;FixtureHost*h=[FixtureHost new];h.view=[[FixtureGameView alloc]initWithFrame:((__bridge NSWindow*)w).contentView.bounds];current=h;return (__bridge_retained RHGHostRef)h;}
RHGHostRef RHGHostCreate(void*w,bool hud,const char*e,const char*d){(void)e;(void)d;transportMode=0;hudRequested=hud?1:0;remoteRegistryID=0;return fixtureCreate(w);}
RHGHostRef RHGHostCreateRemote(void*w,uint64_t registryID,const char*e,const char*d){(void)e;(void)d;transportMode=1;remoteRegistryID=registryID;hudRequested=0;return fixtureCreate(w);}
void *RHGHostGetView(RHGHostRef h){return (__bridge void*)((__bridge FixtureHost*)h).view;}
const char *RHGHostService(RHGHostRef h){(void)h;return "app.ready.owned-fixture";}
const char *RHGHostNonce(RHGHostRef h){(void)h;return "0000000000000000000000000000000000000000000000000000000000000000";}
void RHGHostSetFirstFrameCallback(RHGHostRef h,void*c,RHGHostFirstFrameCallback f){FixtureHost*x=(__bridge FixtureHost*)h;x.context=c;x.callback=f;}
void RHGHostSetPointerEnabled(RHGHostRef h,bool e){(void)h;pointerEnabled=e?1:0;}
void RHGHostSetOverlayVisible(RHGHostRef h,bool e){((__bridge FixtureHost*)h).overlayVisible=e;}
bool RHGHostPointerCaptured(RHGHostRef h){(void)h;return false;}
void RHGHostStop(RHGHostRef h){FixtureHost*x=(__bridge FixtureHost*)h;if(!x.stopped){stops++;x.stopped=YES;}x.callback=NULL;x.context=NULL;}
void RHGHostDestroy(RHGHostRef h){RHGHostStop(h);current=nil;CFRelease((CFTypeRef)h);}
void RHGHostResize(RHGHostRef h){(void)h;}
uint32_t RHGHostWindowNumber(RHGHostRef h){(void)h;return 0;}
int32_t RHGHostGuestPID(RHGHostRef h){(void)h;return 0;}
'''
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-fullscreen-',dir=WORK/'tests'));run.chmod(0o700)
    inputs=[ROOT/'Sources/M1Launcher/HostedGamePresentation.swift',ROOT/'Sources/M1Launcher/HostedGameOverlay.swift',ROOT/'Sources/M1Launcher/SessionManager.swift',ROOT/'Synthetic/ReadyHostedFullscreenProbe.swift',pathlib.Path(__file__)]
    before={str(f.relative_to(ROOT)):sha(f)for f in inputs}
    presentation=(ROOT/'Sources/M1Launcher/SessionManager.swift').read_text().split('struct SessionPresentationOverlay {',1)[1].split('private final class PresentationReply',1)[0]
    (run/'Core.swift').write_text(CORE);(run/'Frontend.swift').write_text(FRONTEND+'\nstruct SessionPresentationOverlay {'+presentation);(run/'Host.m').write_text(HOST)
    header=ROOT/'Sources/ReadyHostedView/include/ReadyHostedView.h'
    # Approved C API declarations are repeated only in the fixture bridge. This
    # does not edit the concurrently-owned production header/implementation.
    (run/'FixtureBridge.h').write_text('#include '+json.dumps(str(header))+'\nvoid RHGHostSetPointerEnabled(RHGHostRef,bool);\nbool RHGHostPointerCaptured(RHGHostRef);\nvoid RHGHostSetOverlayVisible(RHGHostRef,bool);\n')
    (run/'module.modulemap').write_text('module ReadyHostedView {header "FixtureBridge.h" export *}\n')
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','MTL_HUD_'))}
    env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-fullscreen'))
    logs=[]
    def call(command,timeout=90):
        p=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout);logs.append(p.stdout+p.stderr);(run/'build.log').write_text('\n'.join(logs))
        if p.returncode:raise RuntimeError('Owned fullscreen fixture failed; private log retained at '+str(run/'build.log'))
        return p
    swift=['xcrun','swiftc','-swift-version','5','-module-cache-path',WORK/'cache/hosted-controller-typecheck']
    call(swift+['-emit-library','-emit-module','-module-name','LauncherCore',run/'Core.swift','-emit-module-path',run/'LauncherCore.swiftmodule','-o',run/'libLauncherCore.dylib'])
    call(['xcrun','clang','-fobjc-arc','-c',run/'Host.m','-I',run,'-o',run/'Host.o'])
    call(swift+['-parse-as-library','-I',run,'-Xcc','-fmodule-map-file='+str(run/'module.modulemap'),run/'Frontend.swift',ROOT/'Sources/M1Launcher/HostedGameOverlay.swift',ROOT/'Sources/M1Launcher/HostedGamePresentation.swift',ROOT/'Synthetic/ReadyHostedFullscreenProbe.swift',run/'Host.o','-L',run,'-lLauncherCore','-Xlinker','-rpath','-Xlinker',run,'-framework','AppKit','-framework','QuartzCore','-o',run/'probe'])
    p=call([run/'probe',run],timeout=15);report=json.loads(p.stdout)
    report['sourceHashes']={str(f.relative_to(ROOT)):sha(f)for f in inputs};assert report['sourceHashes']==before
    report['productionHeaderSHA256']=sha(header);report['hostImplementation']='controlled Objective-C fixture, no production host execution'
    retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
    pointer={'passed':report['passed'],'count':report['count'],'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':report['sourceHashes'],'fixtureOnly':True,'actualSpaceOrCaptureVerified':False}
    (ROOT/'Evidence/hosted-fullscreen-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
