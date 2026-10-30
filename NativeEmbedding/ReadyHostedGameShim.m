// SPDX-License-Identifier: GPL-3.0-only
// Experimental guest-local logical AppKit window and direct host drawable.
// No real guest NSWindow initializer, copy fallback, or host compositor exists.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <QuartzCore/CATransaction.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <unistd.h>
#import <servers/bootstrap.h>
#import <pthread.h>
#import <math.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#import <fcntl.h>
#import <errno.h>
#import <sys/stat.h>
#import "ReadyHostedGameProtocol.h"
#import "RHGScrollEvent.h"
#import "RHGPerformance.h"

typedef struct {
    uint32_t window,width,height;
    uint64_t pixelFormat,deviceRegistryID;
    double scale;
    double logicalWidth,logicalHeight,quartzX,quartzY,cocoaX,cocoaY;
} RHGWindowMetadata;
static RHGWindowMetadata rhgMetadata;
static os_unfair_lock rhgMetadataLock=OS_UNFAIR_LOCK_INIT;
static uint64_t rhgMetadataRequestID;
static RHGWindowMetadata rhgMetadataSnapshot(void){os_unfair_lock_lock(&rhgMetadataLock);RHGWindowMetadata value=rhgMetadata;os_unfair_lock_unlock(&rhgMetadataLock);return value;}
static void rhgConnect(void);
static void rhgInstallMetal(void);
static BOOL rhgRemoteLayerMode(void);
static BOOL rhgRemoteTraceEnabled(void);
static void rhgInstallRemoteLayer(void);
static void rhgStopRenderActivity(void);
static IMP rhgOriginal(id object,SEL selector);
static void rhgHook(Class type,SEL selector,IMP hook);
static void rhgNoGestureProvider(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        const char text[]="{\"type\":\"hosted-shim-limitation\",\"reason\":\"cocoa-gesture-provider-unavailable\",\"privateGestureContextCreated\":false}\n";
        (void)write(STDERR_FILENO,text,sizeof text-1);
    });
}
static BOOL rhgMainImageCaller(void *address) {
    // DYLD_INSERT_LIBRARIES can occupy image index zero. Identify the unique
    // executable header by its Mach-O type instead of assuming load-list order.
    static const struct mach_header *executable;static dispatch_once_t once;
    dispatch_once(&once,^{
        uint32_t count=_dyld_image_count();if(count>8192)return;
        for(uint32_t i=0;i<count;i++){const struct mach_header *header=_dyld_get_image_header(i);
            if(header&&header->filetype==MH_EXECUTE){if(executable){executable=NULL;return;}executable=header;}}
    });
    Dl_info info={0};return executable&&address&&dladdr(address,&info)&&info.dli_fbase==(const void*)executable;
}
#define RHG_MAIN_CALLER() rhgMainImageCaller(__builtin_extract_return_addr(__builtin_return_address(0)))
static void rhgFail(NSString *reason) __attribute__((noreturn));
static NSString *rhgSafeMetadata(const char *value) {
    if(!value)return nil;size_t length=strnlen(value,257);if(!length||length>256)return nil;
    for(size_t i=0;i<length;i++)if((unsigned char)value[i]<32||(unsigned char)value[i]>126)return nil;
    return [[NSString alloc]initWithBytes:value length:length encoding:NSASCIIStringEncoding];
}
static NSArray *rhgSafeCalleeStack(void) {
    void *frames[12];int count=backtrace(frames,12);NSMutableArray *result=[NSMutableArray new];
    for(int i=2;i<count&&result.count<8;i++){
        Dl_info info={0};if(!dladdr(frames[i],&info))continue;
        const char *image=info.dli_fname?strrchr(info.dli_fname,'/'):NULL;
        image=image?image+1:info.dli_fname;
        [result addObject:@{@"image":rhgSafeMetadata(image)?:@"unavailable",@"symbol":rhgSafeMetadata(info.dli_sname)?:@"unavailable"}];
    }
    return result;
}
static void rhgFailSelector(NSString *reason,Class requested,SEL selector) __attribute__((noreturn));
static void rhgFailSelector(NSString *reason,Class requested,SEL selector) {
    rhgStopRenderActivity();
    NSMutableDictionary *value=[@{@"type":@"hosted-shim-refused",@"reason":reason?:@"unsupported",
        @"realGuestWindowInitializers":@0,@"hiddenGuestWindowFallback":@NO,@"GPUCopyFallback":@NO}mutableCopy];
    NSString *name=rhgSafeMetadata(selector?sel_getName(selector):NULL);
    NSString *type=rhgSafeMetadata(requested?class_getName(requested):NULL);
    Method method=requested&&selector?class_getInstanceMethod(requested,selector):NULL;
    NSString *encoding=rhgSafeMetadata(method?method_getTypeEncoding(method):NULL);
    value[@"selector"]=name?:@"unavailable";value[@"requestedClass"]=type?:@"unavailable";value[@"methodEncoding"]=encoding?:@"unavailable";
    if(NSApp){NSApplicationActivationPolicy policy=NSApp.activationPolicy;
        value[@"guestActivationPolicy"]=policy==NSApplicationActivationPolicyAccessory?@"accessory":policy==NSApplicationActivationPolicyRegular?@"regular":policy==NSApplicationActivationPolicyProhibited?@"prohibited":@"unavailable";}
    value[@"calleeStack"]=rhgSafeCalleeStack(); // Names only; never addresses, paths or arguments.
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if(data){fwrite(data.bytes,1,data.length,stderr);fputc('\n',stderr);fflush(stderr);}_exit(77);
}
static void rhgFail(NSString *reason) {
    rhgStopRenderActivity();
    NSDictionary *value=@{@"type":@"hosted-shim-refused",@"reason":reason?:@"unsupported",
        @"realGuestWindowInitializers":@0,@"hiddenGuestWindowFallback":@NO,@"GPUCopyFallback":@NO};
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if(data){fwrite(data.bytes,1,data.length,stderr);fputc('\n',stderr);fflush(stderr);}
    _exit(77);
}

static BOOL rhgRemoteLayerMode(void){
    static BOOL enabled;static dispatch_once_t once;
    dispatch_once(&once,^{const char *value=getenv("READY_HOSTED_GAME_TRANSPORT");enabled=value&&strcmp(value,"remote-layer")==0;});return enabled;
}
static BOOL rhgRemoteTraceEnabled(void){
    static BOOL enabled;static dispatch_once_t once;
    dispatch_once(&once,^{const char *value=getenv("RHG_REMOTE_TRACE");enabled=value&&strcmp(value,"1")==0;});return enabled;
}
// These declarations describe system runtime selectors; no Apple implementation
// or proprietary framework binary is bundled with this GPL shim.
@interface RHGRemoteContext:NSObject
+(void)setAllowsCGSConnections:(BOOL)allowed;
+(instancetype)remoteContextWithOptions:(NSDictionary*)options;
@property(nonatomic,strong)CALayer *layer;
@property(nonatomic,readonly)uint32_t contextId;
@end

@interface RHGWeakWindow:NSObject
@property(weak)id window;
@end
@implementation RHGWeakWindow @end
@interface RHGLogicalWindow:NSObject
@property(copy)NSString *title;
@property(nonatomic,strong)NSView *contentView;
@property(nonatomic,weak)id delegate;
@property NSRect frame;
@property NSSize contentAspectRatio; // Guest hint only; Ready owns host geometry.
@property NSSize minSize,maxSize,contentMinSize,contentMaxSize;
@property NSSize resizeIncrements,contentResizeIncrements,aspectRatio;
@property NSWindowStyleMask styleMask;
@property BOOL releasedWhenClosed,opaque,acceptsMouseMovedEvents,ignoresMouseEvents;
@property(nonatomic)BOOL visible;
@property BOOL notifiedKey,notifiedMain;
@property NSWindowCollectionBehavior collectionBehavior;
@property NSInteger level;
@property(strong)NSColor *backgroundColor;
@property(strong)NSResponder *firstResponder;
@property Class requestedClass;
// Explicitly virtualized selectors measured in the pinned Cyberpunk GameWindow.
// Its original IMPs expect NSWindow/subclass ivars and are NEVER invoked here.
@property BOOL m_isFullscreenMode,m_isActivatePhotoMode,m_hitWorldWidgetStatus,m_isMinimized,m_isActive;
@property BOOL m_clamshellStateChanged,m_ignoreNextMouseMove,m_isMirrorMode,m_forceUpdate,m_resolutionChanged;
@property NSSize m_windowResolution,m_systemResolution;
@property(nonatomic,strong)NSView *m_view;
@property unsigned char m_windowModeWillBe;
@property int m_monitorIdx,m_monitorsCount;
@property uint32_t m_displayID;
@end
static RHGLogicalWindow *rhgWindow;
static unsigned rhgWindowCount;
static char rhgViewWindowKey;
static IMP rhgOriginalViewWindow;
static BOOL rhgFocused=YES;
static void rhgSynchronizeLogicalFocus(RHGLogicalWindow *window);
static NSDictionary<NSNotificationName,NSString*> *rhgFocusDelegateNotifications(void){
    static NSDictionary *values;static dispatch_once_t once;dispatch_once(&once,^{values=@{
        NSWindowDidBecomeKeyNotification:@"windowDidBecomeKey:",NSWindowDidResignKeyNotification:@"windowDidResignKey:",
        NSWindowDidBecomeMainNotification:@"windowDidBecomeMain:",NSWindowDidResignMainNotification:@"windowDidResignMain:"};});return values;
}
// The real guest owns no visible WindowServer window. Tell Foundation about
// this finite user-initiated rendering session without disabling idle sleep.
// Only authenticated POLL focus edges can acquire a token; repeated edges are
// idempotent. This state is independent of the logical window/Main run loop.
static NSLock *rhgRenderActivityLock(void){
    static NSLock *lock;static dispatch_once_t once;
    dispatch_once(&once,^{lock=[NSLock new];});return lock;
}
static id<NSObject> rhgRenderActivityToken;
static BOOL rhgRenderActivityStopped;
static void rhgSetRenderActivity(BOOL focused){
    NSLock *lock=rhgRenderActivityLock();[lock lock];
    if(focused&&!rhgRenderActivityStopped){
        if(!rhgRenderActivityToken)rhgRenderActivityToken=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Hosted game active in Ready"];
    }else if(rhgRenderActivityToken){
        id<NSObject> token=rhgRenderActivityToken;rhgRenderActivityToken=nil;
        [NSProcessInfo.processInfo endActivity:token];
    }
    [lock unlock];
}
static void rhgActivityForTrustedFocus(RHGInput input){
    if(input.type==RHG_FOCUS&&input.keyCode<=1)rhgSetRenderActivity(input.keyCode==1);
}
static void rhgStopRenderActivity(void){
    NSLock *lock=rhgRenderActivityLock();[lock lock];rhgRenderActivityStopped=YES;
    if(rhgRenderActivityToken){id<NSObject> token=rhgRenderActivityToken;rhgRenderActivityToken=nil;[NSProcessInfo.processInfo endActivity:token];}
    [lock unlock];
}
static NSApplicationPresentationOptions rhgLogicalPresentationOptions;
static NSMenu *rhgLogicalMainMenu;
static NSRect rhgContentRect(void) {
    RHGWindowMetadata metadata=rhgMetadataSnapshot();double scale=metadata.scale;
    if(!isfinite(scale)||scale<=0)rhgFail(@"invalid-host-scale");
    return NSMakeRect(0,0,metadata.logicalWidth,metadata.logicalHeight);
}
@implementation RHGLogicalWindow
-(instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer {
    (void)rect;(void)backing;(void)defer;
    self=[super init];if(self){rhgConnect();_frame=rhgContentRect();_styleMask=style;_m_isFullscreenMode=YES;_m_isActive=YES;
        _maxSize=_contentMaxSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);_resizeIncrements=_contentResizeIncrements=NSMakeSize(1,1);
        _m_monitorsCount=1;_m_windowResolution=_m_systemResolution=_frame.size;rhgWindow=self;}return self;
}
-(instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer screen:(NSScreen*)screen {
    (void)screen;return [self initWithContentRect:rect styleMask:style backing:backing defer:defer];
}
-(BOOL)isKindOfClass:(Class)type {
    return type==NSWindow.class || (self.requestedClass&&[self.requestedClass isSubclassOfClass:type]) || [super isKindOfClass:type];
}
-(NSInteger)windowNumber{return rhgMetadataSnapshot().window;}
-(NSScreen*)screen{return NSScreen.mainScreen;}
-(CGFloat)backingScaleFactor{return rhgMetadataSnapshot().scale;}
-(NSRect)contentLayoutRect{return rhgContentRect();}
-(NSRect)contentRectForFrameRect:(NSRect)rect{(void)rect;return rhgContentRect();}
-(NSRect)frameRectForContentRect:(NSRect)rect{return rect;}
-(NSRect)convertRectToBacking:(NSRect)rect {CGFloat s=self.backingScaleFactor;return NSMakeRect(rect.origin.x*s,rect.origin.y*s,rect.size.width*s,rect.size.height*s);}
-(NSRect)convertRectFromBacking:(NSRect)rect {CGFloat s=self.backingScaleFactor;return NSMakeRect(rect.origin.x/s,rect.origin.y/s,rect.size.width/s,rect.size.height/s);}
-(NSPoint)convertPointToScreen:(NSPoint)point {RHGWindowMetadata m=rhgMetadataSnapshot();return NSMakePoint(point.x+m.cocoaX,point.y+m.cocoaY);}
-(NSPoint)convertPointFromScreen:(NSPoint)point {RHGWindowMetadata m=rhgMetadataSnapshot();return NSMakePoint(point.x-m.cocoaX,point.y-m.cocoaY);}
-(NSRect)convertRectToScreen:(NSRect)rect {RHGWindowMetadata m=rhgMetadataSnapshot();return NSOffsetRect(rect,m.cocoaX,m.cocoaY);}
-(NSRect)convertRectFromScreen:(NSRect)rect {RHGWindowMetadata m=rhgMetadataSnapshot();return NSOffsetRect(rect,-m.cocoaX,-m.cocoaY);}
-(void)setContentView:(NSView*)view {
    if(_contentView)objc_setAssociatedObject(_contentView,&rhgViewWindowKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _contentView=view;
    if(view){RHGWeakWindow *link=[RHGWeakWindow new];link.window=self;objc_setAssociatedObject(view,&rhgViewWindowKey,link,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.frame=rhgContentRect();}
}
-(void)setM_view:(NSView*)view{_m_view=view;self.contentView=view;}
-(void)setDelegate:(id)value {
    if(_delegate==value)return;NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    for(NSNotificationName name in rhgFocusDelegateNotifications())if(_delegate)[center removeObserver:_delegate name:name object:self];
    _delegate=value;
    for(NSNotificationName name in rhgFocusDelegateNotifications()){
        SEL selector=NSSelectorFromString(rhgFocusDelegateNotifications()[name]);
        if([value respondsToSelector:selector])[center addObserver:value selector:selector name:name object:self];
    }
}
-(void)setVisible:(BOOL)value{_visible=value;rhgSynchronizeLogicalFocus(self);}
-(BOOL)isVisible{return self.visible;}
-(BOOL)hasTitleBar{return (self.styleMask&NSWindowStyleMaskTitled)!=0;}
-(void)setIsVisible:(BOOL)value{self.visible=value;}
-(id)gestureEnvironment {
    // An unbacked view has no Cocoa window gesture environment. Local typed
    // keyboard/mouse forwarding is separate; no private gesture context is made.
    rhgNoGestureProvider();
    return nil;
}
-(BOOL)isKeyWindow{return self.visible&&rhgFocused;}
-(BOOL)isMainWindow{return self.visible;}
-(BOOL)canBecomeKeyWindow{return YES;}
-(BOOL)canBecomeMainWindow{return YES;}
-(BOOL)acceptsFirstResponder{return YES;}
-(BOOL)isMiniaturized{return NO;}
-(BOOL)makeFirstResponder:(NSResponder*)value{self.firstResponder=value;return YES;}
-(void)makeKeyAndOrderFront:(id)sender{(void)sender;self.visible=YES;}
-(void)orderFront:(id)sender{(void)sender;self.visible=YES;}
-(void)orderBack:(id)sender{(void)sender;self.visible=YES;}
-(void)orderOut:(id)sender{(void)sender;self.visible=NO;}
-(void)makeKeyWindow{self.visible=YES;}
-(void)makeMainWindow{self.visible=YES;}
-(void)setFrame:(NSRect)rect display:(BOOL)display{(void)rect;(void)display;_frame=rhgContentRect();}
-(void)setFrame:(NSRect)rect display:(BOOL)display animate:(BOOL)animate{(void)animate;[self setFrame:rect display:display];}
-(void)setFrameOrigin:(NSPoint)point{(void)point;}
-(void)setContentSize:(NSSize)size{(void)size;self.contentView.frame=rhgContentRect();}
-(void)center{}
-(void)display{}
-(void)displayIfNeeded{}
-(void)update{}
-(void)invalidateCursorRectsForView:(NSView*)view{(void)view;}
-(void)enableCursorRects{}
-(void)disableCursorRects{}
-(void)toggleFullScreen:(id)sender{(void)sender;self.m_isFullscreenMode=YES;}
-(void)toggleWindowFullscreen:(BOOL)value{(void)value;self.m_isFullscreenMode=YES;}
-(void)toggleWindowBorder:(BOOL)value{(void)value;}
-(void)WaitForCompletion:(BOOL)value{(void)value;}
-(void)close{rhgStopRenderActivity();self.visible=NO;self.contentView=nil;if(rhgWindow==self)rhgWindow=nil;}
-(void)performClose:(id)sender{(void)sender;[self close];}
-(id)touchBar{return nil;}
-(id)makeTouchBar{return nil;}
-(void)setTouchBar:(id)value{(void)value;}
-(void)doesNotRecognizeSelector:(SEL)selector{rhgFailSelector(@"unsupported-window-selector",self.requestedClass?:NSWindow.class,selector);}
@end
static void rhgSynchronizeLogicalFocus(RHGLogicalWindow *window){
    if(!window)return;BOOL focused=window.visible&&rhgFocused;window.m_isActive=focused;
    // A logical window still has Cocoa focus semantics. In particular native
    // GameView wheel consumers gate on their controller's key-window callback.
    // Direct key/mouse delivery can otherwise appear healthy while wheel input
    // is discarded. Emit only edges and only for this owned logical window.
    if(window.notifiedKey!=focused){window.notifiedKey=focused;[NSNotificationCenter.defaultCenter postNotificationName:focused?NSWindowDidBecomeKeyNotification:NSWindowDidResignKeyNotification object:window];}
    // The logical main window remains the visible main window while Ready is
    // inactive/overlayed; only key status follows authenticated host focus.
    if(window.notifiedMain!=window.visible){window.notifiedMain=window.visible;[NSNotificationCenter.defaultCenter postNotificationName:window.visible?NSWindowDidBecomeMainNotification:NSWindowDidResignMainNotification object:window];}
}

static id rhgAllocateWindow(id type,SEL selector,NSZone *zone) __attribute__((ns_returns_retained));
static id rhgAllocateWindow(id type,SEL selector,NSZone *zone) {
    (void)selector;
    if(type!=NSWindow.class && ![NSStringFromClass(type) isEqualToString:@"GameWindow"] &&
       ![NSStringFromClass(type) isEqualToString:@"RHGFixtureWindow"])rhgFailSelector(@"unsupported-window-subclass",type,selector);
    if(++rhgWindowCount!=1)rhgFail(@"multiple-game-windows");
    RHGLogicalWindow *window=[RHGLogicalWindow allocWithZone:zone];window.requestedClass=type;return window;
}
static id rhgAllocateWindowSimple(id type,SEL selector) __attribute__((ns_returns_retained));
static id rhgAllocateWindowSimple(id type,SEL selector){return rhgAllocateWindow(type,selector,NULL);}
static id rhgApplicationWindows(id app,SEL selector){if(!RHG_MAIN_CALLER())return ((id(*)(id,SEL))rhgOriginal(app,selector))(app,selector);return rhgWindow?@[rhgWindow]:@[];}
static id rhgApplicationWindow(id app,SEL selector){if(!RHG_MAIN_CALLER())return ((id(*)(id,SEL))rhgOriginal(app,selector))(app,selector);return rhgWindow.visible&&(selector!=@selector(keyWindow)||rhgFocused)?rhgWindow:nil;}
static BOOL rhgApplicationActive(id app,SEL selector){if(!RHG_MAIN_CALLER())return ((BOOL(*)(id,SEL))rhgOriginal(app,selector))(app,selector);return rhgWindow.visible&&rhgFocused;}
static NSApplicationPresentationOptions rhgPresentationOptions(id app,SEL selector){if(!RHG_MAIN_CALLER())return ((NSApplicationPresentationOptions(*)(id,SEL))rhgOriginal(app,selector))(app,selector);return rhgLogicalPresentationOptions;}
static void rhgSetPresentationOptions(id app,SEL selector,NSApplicationPresentationOptions options){(void)app;(void)selector;rhgLogicalPresentationOptions=options;}
static id rhgMainMenu(id app,SEL selector){if(!RHG_MAIN_CALLER())return ((id(*)(id,SEL))rhgOriginal(app,selector))(app,selector);return rhgLogicalMainMenu;}
static void rhgSetMainMenu(id app,SEL selector,NSMenu *menu){(void)app;(void)selector;rhgLogicalMainMenu=menu;}
static void rhgSuppressActivation(id app,SEL selector,BOOL flag){(void)app;(void)selector;(void)flag;}
static void rhgSuppressApplicationAction(id app,SEL selector){(void)app;(void)selector;}
static void rhgSuppressApplicationSender(id app,SEL selector,id sender){(void)app;(void)selector;(void)sender;}
static void rhgUpdateWindows(id app,SEL selector){(void)app;(void)selector;[rhgWindow update];}
static BOOL rhgGameWindowVisible(id type,SEL selector){(void)type;(void)selector;return rhgWindow.visible;}
static void rhgSetGameWindowVisible(id type,SEL selector,BOOL value){(void)type;(void)selector;rhgWindow.visible=value;}
static CGFloat rhgTitlebarHeight(id type,SEL selector){(void)type;(void)selector;return 0;}
static _Thread_local BOOL rhgSettingBackgroundPolicy;
static BOOL rhgBackgroundActivationPolicy(id app,SEL selector,NSApplicationActivationPolicy requested){
    (void)requested;
    if([app activationPolicy]==NSApplicationActivationPolicyAccessory)return YES;
    if(rhgSettingBackgroundPolicy)return NO;
    rhgSettingBackgroundPolicy=YES;
    (void)((BOOL(*)(id,SEL,NSApplicationActivationPolicy))rhgOriginal(app,selector))(app,selector,NSApplicationActivationPolicyAccessory);
    rhgSettingBackgroundPolicy=NO;
    return [app activationPolicy]==NSApplicationActivationPolicyAccessory;
}
static void rhgDeferBackgroundPolicy(void){static dispatch_once_t once;dispatch_once(&once,^{
    dispatch_async(dispatch_get_main_queue(),^{if(NSApp)rhgBackgroundActivationPolicy(NSApp,@selector(setActivationPolicy:),NSApplicationActivationPolicyAccessory);});
});}
static id rhgSharedBackgroundApplication(id type,SEL selector){
    id app=((id(*)(id,SEL))rhgOriginal(type,selector))(type,selector);
    if(!rhgBackgroundActivationPolicy(app,@selector(setActivationPolicy:),NSApplicationActivationPolicyAccessory))rhgDeferBackgroundPolicy();
    return app;
}
static void rhgFinishBackgroundLaunching(id app,SEL selector){
    ((void(*)(id,SEL))rhgOriginal(app,selector))(app,selector);
    if(!rhgBackgroundActivationPolicy(app,@selector(setActivationPolicy:),NSApplicationActivationPolicyAccessory))rhgDeferBackgroundPolicy();
}
static id rhgNoTouchBar(id object,SEL selector){(void)object;(void)selector;return nil;}
static void rhgNoTouchBarSetter(id object,SEL selector,id value){(void)object;(void)selector;(void)value;}
static BOOL rhgTouchBarMenuDisabled(id object,SEL selector){(void)object;(void)selector;return NO;}
static void rhgDisableTouchBarMenu(id object,SEL selector,BOOL value){(void)object;(void)selector;(void)value;}
static id rhgWindowByNumber(id app,SEL selector,NSInteger number){if(!RHG_MAIN_CALLER())return ((id(*)(id,SEL,NSInteger))rhgOriginal(app,selector))(app,selector,number);return number==(NSInteger)rhgMetadataSnapshot().window?rhgWindow:nil;}
static id rhgViewWindow(NSView *view,SEL selector) {
    for(NSView *v=view;v;v=v.superview){RHGWeakWindow *link=objc_getAssociatedObject(v,&rhgViewWindowKey);if(link.window)return link.window;}
    return ((id(*)(id,SEL))rhgOriginalViewWindow)(view,selector);
}
static void rhgReplace(Class type,SEL selector,IMP replacement) {
    Method method=class_getInstanceMethod(type,selector);if(!method)rhgFail(@"missing-window-api");
    if(!class_addMethod(type,selector,replacement,method_getTypeEncoding(method)))method_setImplementation(class_getInstanceMethod(type,selector),replacement);
}
static void rhgInstallWindows(void) {
    Class meta=object_getClass(NSWindow.class);
    rhgReplace(meta,@selector(allocWithZone:),(IMP)rhgAllocateWindow);rhgReplace(meta,@selector(alloc),(IMP)rhgAllocateWindowSimple);
    rhgHook(NSApplication.class,@selector(windows),(IMP)rhgApplicationWindows);
    rhgHook(NSApplication.class,@selector(orderedWindows),(IMP)rhgApplicationWindows);
    rhgHook(NSApplication.class,@selector(mainWindow),(IMP)rhgApplicationWindow);
    rhgHook(NSApplication.class,@selector(keyWindow),(IMP)rhgApplicationWindow);
    rhgHook(NSApplication.class,@selector(windowWithWindowNumber:),(IMP)rhgWindowByNumber);
    rhgHook(NSApplication.class,@selector(isActive),(IMP)rhgApplicationActive);
    // Ready owns the physical menu bar and display presentation policy. Keep
    // public guest hints observable without installing guest menu resources.
    rhgHook(NSApplication.class,@selector(presentationOptions),(IMP)rhgPresentationOptions);
    rhgReplace(NSApplication.class,@selector(setPresentationOptions:),(IMP)rhgSetPresentationOptions);
    rhgHook(NSApplication.class,@selector(mainMenu),(IMP)rhgMainMenu);
    rhgReplace(NSApplication.class,@selector(setMainMenu:),(IMP)rhgSetMainMenu);
    rhgReplace(NSApplication.class,@selector(activateIgnoringOtherApps:),(IMP)rhgSuppressActivation);
    rhgReplace(NSApplication.class,@selector(activate),(IMP)rhgSuppressApplicationAction);
    rhgReplace(NSApplication.class,@selector(deactivate),(IMP)rhgSuppressApplicationAction);
    rhgReplace(NSApplication.class,@selector(unhideWithoutActivation),(IMP)rhgSuppressApplicationAction);
    rhgReplace(NSApplication.class,@selector(unhide:),(IMP)rhgSuppressApplicationSender);
    rhgReplace(NSApplication.class,@selector(updateWindows),(IMP)rhgUpdateWindows);
    rhgHook(NSApplication.class,@selector(setActivationPolicy:),(IMP)rhgBackgroundActivationPolicy);
    rhgHook(object_getClass(NSApplication.class),@selector(sharedApplication),(IMP)rhgSharedBackgroundApplication);
    rhgHook(NSApplication.class,@selector(finishLaunching),(IMP)rhgFinishBackgroundLaunching);
    rhgReplace(NSResponder.class,@selector(touchBar),(IMP)rhgNoTouchBar);
    rhgReplace(NSResponder.class,@selector(makeTouchBar),(IMP)rhgNoTouchBar);
    rhgReplace(NSResponder.class,@selector(setTouchBar:),(IMP)rhgNoTouchBarSetter);
    rhgReplace(NSApplication.class,@selector(isAutomaticCustomizeTouchBarMenuItemEnabled),(IMP)rhgTouchBarMenuDisabled);
    rhgReplace(NSApplication.class,@selector(setAutomaticCustomizeTouchBarMenuItemEnabled:),(IMP)rhgDisableTouchBarMenu);
    rhgReplace(object_getClass(NSTouchBar.class),@selector(isAutomaticCustomizeTouchBarMenuItemEnabled),(IMP)rhgTouchBarMenuDisabled);
    rhgReplace(object_getClass(NSTouchBar.class),@selector(setAutomaticCustomizeTouchBarMenuItemEnabled:),(IMP)rhgDisableTouchBarMenu);
    Class game=objc_getClass("GameWindow");
    if(game){Class gameMeta=object_getClass(game);rhgReplace(gameMeta,NSSelectorFromString(@"isWindowVisible"),(IMP)rhgGameWindowVisible);
        rhgReplace(gameMeta,NSSelectorFromString(@"setIsWindowVisible:"),(IMP)rhgSetGameWindowVisible);
        rhgReplace(gameMeta,NSSelectorFromString(@"titlebarHeight"),(IMP)rhgTitlebarHeight);}
    Method window=class_getInstanceMethod(NSView.class,@selector(window));if(!window)rhgFail(@"missing-view-window-api");
    rhgOriginalViewWindow=method_setImplementation(window,(IMP)rhgViewWindow);
    if(NSApp)rhgBackgroundActivationPolicy(NSApp,@selector(setActivationPolicy:),NSApplicationActivationPolicyAccessory);
}

// ACQUIRE has an independent serialized receive lane: a drawable-pool wait
// must not hold the PRESENT/control/POLL transaction or consume its reply.
static mach_port_t rhgPeer,rhgReceive,rhgAcquireReceive;
static uint8_t rhgNonce[RHG_NONCE_BYTES];
static _Atomic uint64_t rhgRequestID;
static pthread_mutex_t rhgRPCLock=PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t rhgAcquireRPCLock=PTHREAD_MUTEX_INITIALIZER;
static dispatch_semaphore_t rhgFrameAvailable;
@class RHGDrawable;
static pthread_mutex_t rhgAcquisitionLock=PTHREAD_MUTEX_INITIALIZER;
static NSLock *rhgRenderLock;
static NSMutableArray<RHGDrawable*> *rhgOutstandingFrames;
static BOOL rhgPresentWorkerScheduled;
static uint32_t rhgFrameDepth;
static uint64_t rhgConfigurationGeneration,rhgNextExpectedFrameID;
static NSRecursiveLock *rhgHookLock;
static NSMutableDictionary *rhgOriginals;
static __weak CAMetalLayer *rhgGameLayer;
static uint64_t rhgFrames;
typedef struct {
    uint64_t requests,lookups,hits,misses,imports,fallbacks,clears;
    uint32_t entries,maximumEntries;
    bool enabled;
} RHGTextureCacheStats;
typedef struct {
    RHGPerfStats rpcLock[RHG_PERF_OPERATIONS],rpcTotal[RHG_PERF_OPERATIONS];
    RHGPerfStats rpcSend[RHG_PERF_OPERATIONS],rpcReceive[RHG_PERF_OPERATIONS];
    RHGPerfStats frameCredit,importSurface,surfaceLookup,textureWrapper,residency,completionToWorker,workerQueue,completionBody;
    bool guestLayerDisplaySyncEnabled;
    RHGTextureCacheStats textureCache;
} RHGGuestPerformance;
static RHGGuestPerformance rhgPerformance;
static pthread_mutex_t rhgPerfLock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic bool rhgPerfWritePending;
static _Atomic int rhgPerfOutputFD=-1;
static void rhgPerfPrepareOutput(void){
    if(!RHGPerfProfileEnabled()&&!rhgRemoteTraceEnabled())return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        // Capture the inherited diagnostic stream before guest startup can
        // freopen(stderr). No path or additional IPC endpoint is accepted.
        int fd=fcntl(STDERR_FILENO,F_DUPFD_CLOEXEC,3);
        if(fd>=0){(void)fcntl(fd,F_SETNOSIGPIPE,1);atomic_store(&rhgPerfOutputFD,fd);}
    });
}
static void rhgPerfWriteLine(int fd,NSData *line){
    const uint8_t *bytes=line.bytes;size_t offset=0;
    while(offset<line.length){
        ssize_t count=write(fd,bytes+offset,line.length-offset);
        if(count<0&&errno==EINTR)continue;
        if(count<=0)return;
        offset+=(size_t)count;
    }
}
static dispatch_queue_t rhgPresentationWorker(void){
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("app.ready.hosted.present",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));});return queue;
}
static dispatch_queue_t rhgGPUCompletionWorker(void){
    static dispatch_queue_t queue;static dispatch_once_t once;
    // A short GPU fence notification must not wait behind a synchronous host
    // PRESENT/ACK. This is a CPU dispatch queue, not another Metal command queue.
    dispatch_once(&once,^{queue=dispatch_queue_create("app.ready.hosted.gpu-completion",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));});return queue;
}
static void rhgPerfAdd(RHGPerfStats *metric,uint64_t begin,uint64_t end){
    if(!begin)return;pthread_mutex_lock(&rhgPerfLock);RHGPerfInterval(metric,begin,end);pthread_mutex_unlock(&rhgPerfLock);
}
static void rhgPerfReport(uint64_t frames){
    if(!RHGPerfProfileEnabled())return;
    int output=atomic_load(&rhgPerfOutputFD);
    if(output<0||atomic_exchange(&rhgPerfWritePending,true))return;
    pthread_mutex_lock(&rhgPerfLock);RHGGuestPerformance snapshot=rhgPerformance;pthread_mutex_unlock(&rhgPerfLock);
    static dispatch_queue_t writer;static dispatch_once_t once;
    dispatch_once(&once,^{writer=dispatch_queue_create("app.ready.hosted.perf-writer",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));});
    dispatch_async(writer,^{@autoreleasepool{
        NSMutableDictionary *operations=[NSMutableDictionary new];
        for(unsigned op=0;op<RHG_PERF_OPERATIONS;op++)if(snapshot.rpcTotal[op].count){
            operations[RHGPerfOperationName(op)]=@{@"lockWait":RHGPerfStatsJSON(&snapshot.rpcLock[op]),@"total":RHGPerfStatsJSON(&snapshot.rpcTotal[op]),@"send":RHGPerfStatsJSON(&snapshot.rpcSend[op]),@"receive":RHGPerfStatsJSON(&snapshot.rpcReceive[op])};
        }
        NSDictionary *value=@{@"type":@"hosted-guest-performance",@"schema":@1,@"framesAcknowledged":@(frames),@"unit":@"nanoseconds",@"clock":@"mach_continuous_time",@"quantiles":@"log2-bucket-upper-bounds",@"maximumOutstandingFrames":@(rhgFrameDepth),@"guestLayerDisplaySyncEnabled":@(snapshot.guestLayerDisplaySyncEnabled),@"rpc":operations,
            @"frameCredit":RHGPerfStatsJSON(&snapshot.frameCredit),@"surfaceImport":RHGPerfStatsJSON(&snapshot.importSurface),@"surfaceLookup":RHGPerfStatsJSON(&snapshot.surfaceLookup),@"textureWrapper":RHGPerfStatsJSON(&snapshot.textureWrapper),@"residencySetup":RHGPerfStatsJSON(&snapshot.residency),@"gpuCallbackToWorker":RHGPerfStatsJSON(&snapshot.completionToWorker),@"workerQueueWait":RHGPerfStatsJSON(&snapshot.workerQueue),@"gpuCallbackBody":RHGPerfStatsJSON(&snapshot.completionBody),@"hostGPUCommandBuffers":@0,@"applicationSurfaceCopies":@0,
            @"textureCache":@{@"enabled":@(snapshot.textureCache.enabled),@"requests":@(snapshot.textureCache.requests),@"lookups":@(snapshot.textureCache.lookups),@"hits":@(snapshot.textureCache.hits),@"misses":@(snapshot.textureCache.misses),@"imports":@(snapshot.textureCache.imports),@"fallbacks":@(snapshot.textureCache.fallbacks),@"clears":@(snapshot.textureCache.clears),@"entries":@(snapshot.textureCache.entries),@"maximumEntries":@(snapshot.textureCache.maximumEntries)}};
        NSData *json=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
        if(json&&json.length<=65536){NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];rhgPerfWriteLine(output,line);}
        atomic_store(&rhgPerfWritePending,false);
    }});
}
static BOOL rhgConfigured;
static uint32_t rhgConfiguredWidth,rhgConfiguredHeight,rhgConfiguredFormat;
static uint32_t rhgConfiguredDisplaySync;
static uint64_t rhgConfiguredDevice;
static _Atomic uint32_t rhgVirtualHideCount;
static _Atomic bool rhgVirtualHiddenUntilMove;
static char rhgInputKey;
// A coherent cached snapshot: a getter never performs IPC or reads the anchored
// physical cursor. Framework callers retain AppKit's original implementation.
static os_unfair_lock rhgPointerLocationLock=OS_UNFAIR_LOCK_INIT;
static NSPoint rhgPointerScreenLocation;
static NSPoint rhgMouseLocation(id type,SEL selector) {
    if(!RHG_MAIN_CALLER())return ((NSPoint(*)(id,SEL))rhgOriginal(type,selector))(type,selector);
    rhgConnect();os_unfair_lock_lock(&rhgPointerLocationLock);
    NSPoint point=rhgPointerScreenLocation;os_unfair_lock_unlock(&rhgPointerLocationLock);return point;
}

static BOOL rhgFormat(uint64_t format) {
    return format==MTLPixelFormatBGRA8Unorm || format==MTLPixelFormatBGRA8Unorm_sRGB ||
        format==MTLPixelFormatRGBA16Float || format==MTLPixelFormatBGRA10_XR || format==MTLPixelFormatBGRA10_XR_sRGB ||
        format==MTLPixelFormatBGR10_XR || format==MTLPixelFormatBGR10_XR_sRGB;
}
static void rhgMetadataFromReply(RHGReply reply) {
    if(!reply.window || !reply.width || !reply.height || reply.width>8192 || reply.height>8192 ||
       (uint64_t)reply.width*reply.height>33554432 || !rhgFormat(reply.pixelFormat) || !reply.deviceRegistryID ||
       !isfinite(reply.backingScale) || reply.backingScale<=0 || reply.backingScale>8 ||
       !isfinite(reply.logicalWidth)||!isfinite(reply.logicalHeight)||reply.logicalWidth<=0||reply.logicalHeight<=0||reply.logicalWidth>16384||reply.logicalHeight>16384||
       !isfinite(reply.quartzOriginX)||!isfinite(reply.quartzOriginY)||!isfinite(reply.cocoaOriginX)||!isfinite(reply.cocoaOriginY))rhgFail(@"invalid-host-metadata");
    os_unfair_lock_lock(&rhgMetadataLock);
    if(rhgMetadata.window && (reply.window!=rhgMetadata.window || reply.deviceRegistryID!=rhgMetadata.deviceRegistryID)){os_unfair_lock_unlock(&rhgMetadataLock);rhgFail(@"host-identity-changed");}
    if(reply.requestID>=rhgMetadataRequestID){
        rhgMetadata=(RHGWindowMetadata){reply.window,reply.width,reply.height,reply.pixelFormat,reply.deviceRegistryID,reply.backingScale,reply.logicalWidth,reply.logicalHeight,reply.quartzOriginX,reply.quartzOriginY,reply.cocoaOriginX,reply.cocoaOriginY};
        rhgMetadataRequestID=reply.requestID;
    }
    os_unfair_lock_unlock(&rhgMetadataLock);
}
static uint64_t rhgNextRequestID(void){
    uint64_t value=atomic_load_explicit(&rhgRequestID,memory_order_relaxed);
    for(;;){if(value==UINT64_MAX)rhgFail(@"request-sequence-exhausted");if(atomic_compare_exchange_weak_explicit(&rhgRequestID,&value,value+1,memory_order_relaxed,memory_order_relaxed))return value+1;}
}
static RHGReply rhgExchangeLocked(uint32_t operation,RHGRequest fields,uint64_t began,uint64_t locked,pthread_mutex_t *lock,mach_port_t receive) {
    RHGRequest request=fields;
    request.h=(mach_msg_header_t){.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE),
        .msgh_size=sizeof request,.msgh_remote_port=rhgPeer,.msgh_local_port=receive};
    request.magic=RHG_MAGIC;request.version=RHG_VERSION;request.op=operation;request.requestID=rhgNextRequestID();
    memcpy(request.nonce,rhgNonce,sizeof rhgNonce);
    kern_return_t result=mach_msg(&request.h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof request,0,MACH_PORT_NULL,3000,MACH_PORT_NULL);
    uint64_t sent=RHGPerfNow();
    if(result)rhgFail(@"host-send-failed");
    RHGReplyReceive received={0};
    result=mach_msg(&received.message.h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof received,receive,3000,MACH_PORT_NULL);
    uint64_t receivedAt=RHGPerfNow();
    if(result)rhgFail(@"host-reply-deadline");
    RHGReply reply=received.message;
    if(reply.h.msgh_size==sizeof reply&&reply.magic==RHG_MAGIC&&reply.version==RHG_VERSION&&reply.op==operation&&reply.requestID==request.requestID&&reply.status==RHG_STOPPED)rhgStopRenderActivity();
    if(reply.h.msgh_size!=sizeof reply || reply.magic!=RHG_MAGIC || reply.version!=RHG_VERSION ||
       reply.op!=operation || reply.requestID!=request.requestID || reply.eventCount>RHG_MAX_EVENTS ||
       (reply.status!=RHG_OK && !(operation>=RHG_POINTER_ASSOCIATE&&operation<=RHG_POINTER_CURSOR))) {
        mach_msg_destroy(&received.message.h);rhgFail(@"host-rejected-request");
    }
    BOOL complex=(reply.h.msgh_bits&MACH_MSGH_BITS_COMPLEX)!=0;
    if(operation==RHG_ACQUIRE) {
        if(!complex || reply.body.msgh_descriptor_count!=1 || reply.port.type!=MACH_MSG_PORT_DESCRIPTOR ||
           reply.port.name==MACH_PORT_NULL || reply.port.disposition!=MACH_MSG_TYPE_PORT_SEND) {
            mach_msg_destroy(&received.message.h);rhgFail(@"invalid-host-surface-descriptor");
        }
    } else if(complex) {mach_msg_destroy(&received.message.h);rhgFail(@"unexpected-host-descriptor");}
    if(reply.status==RHG_OK){
        if(rhgRemoteLayerMode()&&reply.framesInFlight!=0)rhgFail(@"invalid-remote-frame-depth-ack");
        if(!rhgRemoteLayerMode()&&(reply.framesInFlight<1||reply.framesInFlight>RHG_MAX_FRAMES_IN_FLIGHT||!reply.configurationGeneration||(operation!=RHG_HELLO&&reply.framesInFlight!=rhgFrameDepth)))rhgFail(@"invalid-render-capability-ack");
        if(reply.pointerHideCount>1024||reply.pointerAssociated>1||reply.pointerCaptured>1||reply.pointerHiddenUntilMove>1)rhgFail(@"invalid-virtual-pointer-reply");
        if(!isfinite(reply.pointerX)||!isfinite(reply.pointerY)||reply.pointerX<0||reply.pointerX>1||reply.pointerY<0||reply.pointerY>1||
           !isfinite(reply.logicalWidth)||!isfinite(reply.logicalHeight)||reply.logicalWidth<=0||reply.logicalHeight<=0||reply.logicalWidth>16384||reply.logicalHeight>16384||
           !isfinite(reply.cocoaOriginX)||!isfinite(reply.cocoaOriginY))rhgFail(@"invalid-virtual-pointer-position");
        rhgMetadataFromReply(reply);
        // An asynchronous ACQUIRE may return after newer control/POLL state.
        // Its surface metadata is useful, but it must not rewind the pointer.
        if(operation!=RHG_ACQUIRE){
        // Same coordinate space as logicalWindow.convertPointToScreen:. Host
        // normalized y is top-down; NSEvent.mouseLocation is Cocoa bottom-up.
        NSPoint point=NSMakePoint(reply.cocoaOriginX+reply.pointerX*reply.logicalWidth,
            reply.cocoaOriginY+(1-reply.pointerY)*reply.logicalHeight);
        os_unfair_lock_lock(&rhgPointerLocationLock);rhgPointerScreenLocation=point;os_unfair_lock_unlock(&rhgPointerLocationLock);
        atomic_store(&rhgVirtualHideCount,reply.pointerHideCount);atomic_store(&rhgVirtualHiddenUntilMove,reply.pointerHiddenUntilMove!=0);
        }
    }
    pthread_mutex_unlock(lock);
    if(began){unsigned op=operation<RHG_PERF_OPERATIONS?operation:0;
        rhgPerfAdd(&rhgPerformance.rpcLock[op],began,locked);rhgPerfAdd(&rhgPerformance.rpcSend[op],locked,sent);
        rhgPerfAdd(&rhgPerformance.rpcReceive[op],sent,receivedAt);rhgPerfAdd(&rhgPerformance.rpcTotal[op],began,RHGPerfNow());}
    return reply;
}
static RHGReply rhgExchange(uint32_t operation,RHGRequest fields) {
    uint64_t began=RHGPerfNow();BOOL acquire=operation==RHG_ACQUIRE;
    pthread_mutex_t *lock=acquire?&rhgAcquireRPCLock:&rhgRPCLock;mach_port_t receive=acquire?rhgAcquireReceive:rhgReceive;
    pthread_mutex_lock(lock);return rhgExchangeLocked(operation,fields,began,RHGPerfNow(),lock,receive);
}
static BOOL rhgTryPoll(RHGReply *reply) {
    uint64_t began=RHGPerfNow();
    // A timer-driven input poll must not queue ahead of pending rendering RPCs.
    // PRESENT/control/POLL share one strictly serialized reply port; ACQUIRE
    // owns its independent receive lane.
    if(pthread_mutex_trylock(&rhgRPCLock)!=0)return NO;
    *reply=rhgExchangeLocked(RHG_POLL,(RHGRequest){0},began,RHGPerfNow(),&rhgRPCLock,rhgReceive);return YES;
}
static int rhgHex(unsigned char value) {
    if(value>='0'&&value<='9')return value-'0';if(value>='a'&&value<='f')return value-'a'+10;return -1;
}
static BOOL rhgReadEventInput(id event,RHGInput *input){NSData *data=objc_getAssociatedObject(event,&rhgInputKey);if(data.length!=sizeof *input)return NO;memcpy(input,data.bytes,sizeof *input);return YES;}
static IMP rhgOriginal(id object,SEL selector);
static void rhgHook(Class type,SEL selector,IMP hook);
static BOOL rhgRunningApplicationActive(NSRunningApplication *app,SEL selector){
    if(RHG_MAIN_CALLER()&&app.processIdentifier==getpid())return rhgWindow.visible&&rhgFocused;
    return ((BOOL(*)(id,SEL))rhgOriginal(app,selector))(app,selector);
}
static BOOL rhgRunningApplicationActivate(NSRunningApplication *app,SEL selector,NSApplicationActivationOptions options){(void)selector;(void)options;return app.processIdentifier==getpid();}
static BOOL rhgRunningApplicationActivateFrom(NSRunningApplication *app,SEL selector,id source,NSApplicationActivationOptions options){(void)source;return rhgRunningApplicationActivate(app,selector,options);}
static BOOL rhgRunningApplicationUnhide(NSRunningApplication *app,SEL selector){(void)selector;return app.processIdentifier==getpid();}
static CGFloat rhgEventDelta(id event,SEL selector){RHGInput input;if(rhgReadEventInput(event,&input)){
    BOOL x=selector==@selector(deltaX)||selector==@selector(scrollingDeltaX);
    BOOL scroll=input.type==RHG_SCROLL&&(selector==@selector(scrollingDeltaX)||selector==@selector(scrollingDeltaY));
    return scroll?(x?input.scrollingDeltaX:input.scrollingDeltaY):(x?input.deltaX:input.deltaY);
 }return ((CGFloat(*)(id,SEL))rhgOriginal(event,selector))(event,selector);}
static BOOL rhgEventScrollBool(id event,SEL selector){RHGInput input;if(rhgReadEventInput(event,&input)&&input.type==RHG_SCROLL)return selector==@selector(hasPreciseScrollingDeltas)?input.scrollPrecise:input.scrollInverted;return ((BOOL(*)(id,SEL))rhgOriginal(event,selector))(event,selector);}
static NSEventPhase rhgEventScrollPhase(id event,SEL selector){RHGInput input;if(rhgReadEventInput(event,&input)&&input.type==RHG_SCROLL)return (NSEventPhase)(selector==@selector(phase)?input.scrollPhase:input.scrollMomentumPhase);return ((NSEventPhase(*)(id,SEL))rhgOriginal(event,selector))(event,selector);}
static RHGInput rhgHeldKeys[256],rhgHeldButtons[32],rhgLastScroll;
static BOOL rhgKeyHeld[256],rhgButtonHeld[32],rhgScrollActive;
static uint64_t rhgHeldModifiers;
static RHGInput rhgHeldFlags[256];static BOOL rhgFlagHeld[256];
static void rhgDeliverInput(RHGInput input);
static __weak NSResponder *rhgLatchedScrollTarget;
static BOOL rhgScrollOverride(NSResponder *responder){
    if(!responder || ![responder respondsToSelector:@selector(scrollWheel:)])return NO;
    IMP method=[responder methodForSelector:@selector(scrollWheel:)];
    return method!=class_getMethodImplementation(NSResponder.class,@selector(scrollWheel:)) && method!=class_getMethodImplementation(NSView.class,@selector(scrollWheel:));
}
static NSView *rhgScrollHit(NSView *view,NSPoint point,unsigned depth,unsigned *visited){
    if(!view||depth>32||++*visited>1024||view.isHidden)return nil;
    if(!NSPointInRect(point,view.bounds))return nil;
    for(NSView *child in view.subviews.reverseObjectEnumerator){NSPoint local=[child convertPoint:point fromView:view];NSView *hit=rhgScrollHit(child,local,depth+1,visited);if(hit)return hit;}
    return view;
}
static NSResponder *rhgScrollResponder(RHGLogicalWindow *window,RHGInput input){
    BOOL gesture=(input.scrollPhase!=NSEventPhaseNone || input.scrollMomentumPhase!=NSEventPhaseNone);
    if(gesture && !(input.scrollPhase&(NSEventPhaseBegan|NSEventPhaseMayBegin)) && rhgLatchedScrollTarget)return rhgLatchedScrollTarget;
    NSView *root=window.contentView;NSRect bounds=root.bounds;
    NSPoint point=NSMakePoint(NSMinX(bounds)+input.x*bounds.size.width,NSMinY(bounds)+(root.isFlipped?input.y:1-input.y)*bounds.size.height);
    unsigned visited=0;NSView *hit=rhgScrollHit(root,point,0,&visited);NSResponder *target=nil;
    for(NSView *view=hit;view;view=view.superview)if(rhgScrollOverride(view)){target=view;break;}
    if(!target&&rhgScrollOverride(window.m_view))target=window.m_view;
    if(!target&&rhgScrollOverride(root))target=root;
    if(!target&&rhgScrollOverride(window.firstResponder))target=window.firstResponder;
    if(!target)target=hit?:root;
    if(gesture)rhgLatchedScrollTarget=target;
    static BOOL reported=NO;
    if(!reported&&target){reported=YES;NSDictionary *route=@{@"type":@"hosted-input-route",@"selector":@"scrollWheel:",@"targetClass":NSStringFromClass(object_getClass(target))?:@"unavailable",@"customHandler":@(rhgScrollOverride(target)),@"keyboardResponderUsed":@(target==window.firstResponder)};NSData *line=[NSJSONSerialization dataWithJSONObject:route options:0 error:nil];if(line){fwrite(line.bytes,1,line.length,stderr);fputc('\n',stderr);fflush(stderr);}}
    return target;
}

static NSPoint rhgEventLocation(id event,SEL selector){RHGInput input;if(rhgReadEventInput(event,&input))return NSMakePoint(input.x,input.y);return ((NSPoint(*)(id,SEL))rhgOriginal(event,selector))(event,selector);}
static id rhgEventWindow(id event,SEL selector){RHGInput input;if(rhgReadEventInput(event,&input))return rhgWindow;return ((id(*)(id,SEL))rhgOriginal(event,selector))(event,selector);}
static NSInteger rhgEventWindowNumber(id event,SEL selector){RHGInput input;if(rhgReadEventInput(event,&input))return rhgMetadataSnapshot().window;return ((NSInteger(*)(id,SEL))rhgOriginal(event,selector))(event,selector);}
static void rhgDeliverInput(RHGInput input) {
    RHGLogicalWindow *window=rhgWindow;if(!window)return;
    if(input.type==RHG_FOCUS){
        if(!input.keyCode){
            for(unsigned key=0;key<256;key++)if(rhgKeyHeld[key]){RHGInput up=rhgHeldKeys[key];up.type=RHG_KEY_UP;up.repeat=0;up.modifiers=0;up.timestamp=input.timestamp;rhgDeliverInput(up);}
            for(unsigned button=0;button<32;button++)if(rhgButtonHeld[button]){RHGInput up=rhgHeldButtons[button];up.type=RHG_MOUSE_UP;up.modifiers=0;up.timestamp=input.timestamp;rhgDeliverInput(up);}
            if(rhgHeldModifiers){BOOL held[256];memcpy(held,rhgFlagHeld,sizeof held);memset(rhgFlagHeld,0,sizeof rhgFlagHeld);for(unsigned key=0;key<256;key++)if(held[key]){RHGInput flags=rhgHeldFlags[key];flags.modifiers=0;flags.timestamp=input.timestamp;rhgDeliverInput(flags);}rhgHeldModifiers=0;}
            if(rhgScrollActive){RHGInput end=rhgLastScroll;end.scrollPhase=NSEventPhaseCancelled;end.scrollMomentumPhase=NSEventPhaseEnded;end.scrollCGPhase=kCGScrollPhaseCancelled;end.scrollCGMomentumPhase=kCGMomentumScrollPhaseEnd;end.deltaX=end.deltaY=end.scrollingDeltaX=end.scrollingDeltaY=end.scrollFixedX=end.scrollFixedY=0;end.scrollLineX=end.scrollLineY=end.scrollPointX=end.scrollPointY=0;end.timestamp=input.timestamp;rhgDeliverInput(end);rhgScrollActive=NO;}
        }
        if(!input.keyCode)rhgLatchedScrollTarget=nil;
        rhgFocused=input.keyCode!=0;rhgSynchronizeLogicalFocus(window);return;
    }
    // Cocoa routes wheel events to the view under the pointer (latched for a
    // gesture), not the keyboard first responder. An inherited NSResponder
    // scrollWheel: can silently drop the event in our deliberately unbacked tree.
    NSResponder *target=input.type==RHG_SCROLL?rhgScrollResponder(window,input):(window.firstResponder ?: window.contentView);
    if(!target)return;
    if(!isfinite(input.x)||!isfinite(input.y)||!isfinite(input.deltaX)||!isfinite(input.deltaY))rhgFail(@"invalid-input-coordinates");
    if(input.type==RHG_KEY_DOWN||input.type==RHG_KEY_UP){if(input.keyCode>255)rhgFail(@"invalid-input-keycode");rhgHeldKeys[input.keyCode]=input;rhgKeyHeld[input.keyCode]=input.type==RHG_KEY_DOWN;}
    if(input.type==RHG_MOUSE_DOWN||input.type==RHG_MOUSE_UP){if(input.button>31)rhgFail(@"unsupported-mouse-button");rhgHeldButtons[input.button]=input;rhgButtonHeld[input.button]=input.type==RHG_MOUSE_DOWN;}
    if(input.type==RHG_FLAGS){rhgHeldModifiers=input.modifiers;if(input.keyCode<256){rhgHeldFlags[input.keyCode]=input;rhgFlagHeld[input.keyCode]=input.modifiers!=0;}if(!input.modifiers)memset(rhgFlagHeld,0,sizeof rhgFlagHeld);}
    if(input.type==RHG_SCROLL){if(!RHGScrollInputValid(&input))rhgFail(@"invalid-scroll-input");rhgLastScroll=input;rhgScrollActive=(input.scrollPhase&(NSEventPhaseBegan|NSEventPhaseChanged|NSEventPhaseMayBegin)) || (input.scrollMomentumPhase&(NSEventPhaseBegan|NSEventPhaseChanged));}
    // The host sends normalized positions. Guest AppKit events use logical
    // content points, independently of host-view size or drawable pixel size.
    NSRect content=rhgContentRect();input.x*=content.size.width;
    BOOL flipped=[target isKindOfClass:NSView.class]&&[(NSView*)target isFlipped];
    input.y=(flipped?input.y:1-input.y)*content.size.height;
    NSEvent *event=nil;SEL selector=NULL;NSEventModifierFlags flags=(NSEventModifierFlags)input.modifiers;
    if(input.charactersLength>sizeof input.characters)rhgFail(@"invalid-input-text");
    NSString *characters=[[NSString alloc]initWithBytes:input.characters length:input.charactersLength encoding:NSUTF8StringEncoding];
    if(!characters)rhgFail(@"invalid-input-encoding");
    if(input.type==RHG_KEY_DOWN || input.type==RHG_KEY_UP || input.type==RHG_FLAGS) {
        NSEventType type=input.type==RHG_KEY_DOWN?NSEventTypeKeyDown:input.type==RHG_KEY_UP?NSEventTypeKeyUp:NSEventTypeFlagsChanged;
        event=[NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:input.timestamp windowNumber:window.windowNumber
            context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:input.repeat!=0 keyCode:(unsigned short)input.keyCode];
        selector=input.type==RHG_KEY_DOWN?@selector(keyDown:):input.type==RHG_KEY_UP?@selector(keyUp:):@selector(flagsChanged:);
    } else if(input.type==RHG_MOUSE_MOVE || input.type==RHG_MOUSE_DOWN || input.type==RHG_MOUSE_UP) {
        if(input.button>31)rhgFail(@"unsupported-mouse-button");
        CGEventType type=input.type==RHG_MOUSE_MOVE?kCGEventMouseMoved:input.type==RHG_MOUSE_DOWN?
            (input.button==0?kCGEventLeftMouseDown:input.button==1?kCGEventRightMouseDown:kCGEventOtherMouseDown):
            (input.button==0?kCGEventLeftMouseUp:input.button==1?kCGEventRightMouseUp:kCGEventOtherMouseUp);
        CGEventRef cg=CGEventCreateMouseEvent(NULL,type,CGPointMake(input.x,input.y),(CGMouseButton)input.button);
        if(!cg)rhgFail(@"mouse-event-unavailable");CGEventSetFlags(cg,(CGEventFlags)flags);
        CGEventSetDoubleValueField(cg,kCGMouseEventDeltaX,input.deltaX);CGEventSetDoubleValueField(cg,kCGMouseEventDeltaY,input.deltaY);
        CGEventSetIntegerValueField(cg,kCGMouseEventClickState,input.clickCount);event=[NSEvent eventWithCGEvent:cg];CFRelease(cg);
        selector=input.type==RHG_MOUSE_MOVE?@selector(mouseMoved:):input.type==RHG_MOUSE_DOWN?
            (input.button==0?@selector(mouseDown:):input.button==1?@selector(rightMouseDown:):@selector(otherMouseDown:)):
            (input.button==0?@selector(mouseUp:):input.button==1?@selector(rightMouseUp:):@selector(otherMouseUp:));
    } else if(input.type==RHG_SCROLL) {
        CGEventRef cg=RHGCreateScrollEvent(&input);
        if(!cg)rhgFail(@"scroll-event-unavailable");CGEventSetFlags(cg,(CGEventFlags)flags);CGEventSetLocation(cg,CGPointMake(input.x,input.y));if(isfinite(input.timestamp)&&input.timestamp>=0&&input.timestamp<1000000000)CGEventSetTimestamp(cg,(CGEventTimestamp)(input.timestamp*1e9));event=[NSEvent eventWithCGEvent:cg];CFRelease(cg);selector=@selector(scrollWheel:);
    } else {rhgFail(@"unknown-input-kind");}
    if(event)objc_setAssociatedObject(event,&rhgInputKey,[NSData dataWithBytes:&input length:sizeof input],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(event){Class type=object_getClass(event);rhgHook(type,@selector(deltaX),(IMP)rhgEventDelta);rhgHook(type,@selector(deltaY),(IMP)rhgEventDelta);
        rhgHook(type,@selector(scrollingDeltaX),(IMP)rhgEventDelta);rhgHook(type,@selector(scrollingDeltaY),(IMP)rhgEventDelta);
        rhgHook(type,@selector(hasPreciseScrollingDeltas),(IMP)rhgEventScrollBool);rhgHook(type,@selector(isDirectionInvertedFromDevice),(IMP)rhgEventScrollBool);
        rhgHook(type,@selector(phase),(IMP)rhgEventScrollPhase);rhgHook(type,@selector(momentumPhase),(IMP)rhgEventScrollPhase);
        rhgHook(type,@selector(locationInWindow),(IMP)rhgEventLocation);rhgHook(type,@selector(window),(IMP)rhgEventWindow);
        rhgHook(type,@selector(windowNumber),(IMP)rhgEventWindowNumber);}
    if(event&&selector&&[target respondsToSelector:selector])((void(*)(id,SEL,id))[target methodForSelector:selector])(target,selector,event);
    if(input.type==RHG_SCROLL && (input.scrollPhase==NSEventPhaseCancelled || input.scrollMomentumPhase==NSEventPhaseEnded || input.scrollMomentumPhase==NSEventPhaseCancelled))rhgLatchedScrollTarget=nil;
}
static void rhgConnect(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        const char *name=getenv("READY_HOSTED_GAME_SERVICE"),*nonce=getenv("READY_HOSTED_GAME_NONCE");
        if(!name || strncmp(name,RHG_SERVICE_PREFIX,strlen(RHG_SERVICE_PREFIX)) || !nonce || strlen(nonce)!=RHG_NONCE_BYTES*2)rhgFail(@"missing-owned-host-configuration");
        for(unsigned i=0;i<RHG_NONCE_BYTES;i++){int a=rhgHex(nonce[i*2]),b=rhgHex(nonce[i*2+1]);if(a<0||b<0)rhgFail(@"invalid-host-capability");rhgNonce[i]=(uint8_t)((a<<4)|b);}
        if(bootstrap_look_up(bootstrap_port,name,&rhgPeer) || mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&rhgReceive) || (!rhgRemoteLayerMode()&&mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&rhgAcquireReceive)))rhgFail(@"host-lookup-failed");
        uint32_t wanted=RHG_MAX_FRAMES_IN_FLIGHT;const char *depth=getenv("READY_HOSTED_FRAMES_IN_FLIGHT");
        if(depth){if(!strcmp(depth,"1"))wanted=1;else if(!strcmp(depth,"2"))wanted=2;else rhgFail(@"invalid-frame-depth-policy");}
        if(!rhgRemoteLayerMode()){(void)rhgPresentationWorker();rhgRenderLock=[NSLock new];rhgOutstandingFrames=[NSMutableArray new];}
        RHGReply hello=rhgExchange(RHG_HELLO,(RHGRequest){.reserved=rhgRemoteLayerMode()?RHG_TRANSPORT_REMOTE_LAYER:RHG_TRANSPORT_SURFACE,.framesInFlight=rhgRemoteLayerMode()?0:wanted});
        if(!rhgRemoteLayerMode()){
            if(hello.framesInFlight!=wanted)rhgFail(@"frame-depth-not-adopted");
            rhgFrameDepth=hello.framesInFlight;rhgConfigurationGeneration=hello.configurationGeneration;
            rhgFrameAvailable=dispatch_semaphore_create(rhgFrameDepth);
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{
            for(;;){@autoreleasepool{
                RHGReply reply={0};if(!rhgTryPoll(&reply)){usleep(8000);continue;}
                // Apply the activity lease before dispatching input to Main:
                // loading may block Main and the logical window may not exist.
                for(unsigned i=0;i<reply.eventCount;i++)rhgActivityForTrustedFocus(reply.events[i]);
                if(reply.eventCount)dispatch_async(dispatch_get_main_queue(),^{
                    for(unsigned i=0;i<reply.eventCount;i++)rhgDeliverInput(reply.events[i]);
                });
                // Bound idle polling; full batches drain promptly while yielding
                // between RPCs so rendering can acquire the shared transaction lock.
                usleep(reply.eventCount==RHG_MAX_EVENTS?1000:8000);
            }}
        });
    });
}

// Hook only queues/buffers created by the unchanged guest. No probe queue or
// command buffer is created by this shim; encoder work remains the guest's.
static IMP rhgOriginal(id object,SEL selector) {
    [rhgHookLock lock];IMP result=NULL;
    for(Class type=object_getClass(object);type&&!result;type=class_getSuperclass(type)) {
        result=[rhgOriginals[[NSString stringWithFormat:@"%p:%s",type,sel_getName(selector)]] pointerValue];
    }
    [rhgHookLock unlock];if(!result)rhgFail(@"missing-original-metal-method");return result;
}
static char rhgGestureListKey,rhgGestureViewKey;
static BOOL rhgHostedView(NSView *view){return rhgWindow && view.window==(id)rhgWindow;}
static NSMutableArray *rhgGestureList(NSView *view,BOOL create) {
    NSMutableArray *list=objc_getAssociatedObject(view,&rhgGestureListKey);
    if(!list&&create){list=[NSMutableArray new];objc_setAssociatedObject(view,&rhgGestureListKey,list,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    return list;
}
static id rhgGestureView(NSGestureRecognizer *recognizer,SEL selector) {
    RHGWeakWindow *link=objc_getAssociatedObject(recognizer,&rhgGestureViewKey);
    if(link)return link.window;
    return ((id(*)(id,SEL))rhgOriginal(recognizer,selector))(recognizer,selector);
}
static id rhgGetGestures(NSView *view,SEL selector) {
    if(!rhgHostedView(view))return ((id(*)(id,SEL))rhgOriginal(view,selector))(view,selector);
    return [rhgGestureList(view,NO) copy]?:@[];
}
static void rhgAddGesture(NSView *view,SEL selector,NSGestureRecognizer *recognizer) {
    if(!rhgHostedView(view)){((void(*)(id,SEL,id))rhgOriginal(view,selector))(view,selector,recognizer);return;}
    if(![recognizer isKindOfClass:NSGestureRecognizer.class])rhgFail(@"invalid-logical-gesture-recognizer");
    rhgNoGestureProvider();
    RHGWeakWindow *previous=objc_getAssociatedObject(recognizer,&rhgGestureViewKey);
    NSView *old=previous.window;
    if(old&&old!=view)[rhgGestureList(old,NO)removeObjectIdenticalTo:recognizer];
    NSMutableArray *list=rhgGestureList(view,YES);if(![list containsObject:recognizer])[list addObject:recognizer];
    RHGWeakWindow *link=[RHGWeakWindow new];link.window=view;
    objc_setAssociatedObject(recognizer,&rhgGestureViewKey,link,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    rhgHook(object_getClass(recognizer),@selector(view),(IMP)rhgGestureView);
}
static void rhgRemoveGesture(NSView *view,SEL selector,NSGestureRecognizer *recognizer) {
    if(!rhgHostedView(view)){((void(*)(id,SEL,id))rhgOriginal(view,selector))(view,selector,recognizer);return;}
    [rhgGestureList(view,NO)removeObjectIdenticalTo:recognizer];
    RHGWeakWindow *link=objc_getAssociatedObject(recognizer,&rhgGestureViewKey);if(link.window==view)link.window=nil;
}
static void rhgSetGestures(NSView *view,SEL selector,NSArray *recognizers) {
    if(!rhgHostedView(view)){((void(*)(id,SEL,id))rhgOriginal(view,selector))(view,selector,recognizers);return;}
    if(recognizers && (![recognizers isKindOfClass:NSArray.class]||recognizers.count>1024))rhgFail(@"invalid-logical-gesture-list");
    for(NSGestureRecognizer *recognizer in [rhgGestureList(view,NO)copy])rhgRemoveGesture(view,@selector(removeGestureRecognizer:),recognizer);
    for(NSGestureRecognizer *recognizer in recognizers)rhgAddGesture(view,@selector(addGestureRecognizer:),recognizer);
}
static char rhgCursorRectsKey;
static void rhgLogicalCursorNotice(void){static dispatch_once_t once;dispatch_once(&once,^{
    const char text[]="{\"type\":\"hosted-shim-limitation\",\"reason\":\"hosted-cursor-rects-logical-only\",\"nativeCursorRegistration\":false}\n";
    (void)write(STDERR_FILENO,text,sizeof text-1);
});}
static uintptr_t rhgOpaqueCursor(__unsafe_unretained NSCursor *cursor) {
    uintptr_t pointer=(uintptr_t)(__bridge const void*)cursor;
    // Do not send a class-check message or retain an untrusted receiver. In
    // particular the observed CGFLOAT_MAX bit pattern is never an object.
    if(pointer<4096 || pointer==UINT64_C(0x7fefffffffffffff) || pointer%sizeof(void*)!=0)rhgFail(@"invalid-logical-cursor-argument");
    return pointer;
}
static NSMutableArray *rhgCursorRects(NSView *view,BOOL create){
    NSMutableArray *list=objc_getAssociatedObject(view,&rhgCursorRectsKey);
    if(!list&&create){list=[NSMutableArray new];objc_setAssociatedObject(view,&rhgCursorRectsKey,list,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    return list;
}
static void rhgAddCursorRect(NSView *view,SEL selector,NSRect rect,__unsafe_unretained NSCursor *cursor) {
    if(!rhgHostedView(view)){((void(*)(id,SEL,NSRect,NSCursor*))rhgOriginal(view,selector))(view,selector,rect,cursor);return;}
    uintptr_t pointer=rhgOpaqueCursor(cursor);
    if(!isfinite(rect.origin.x)||!isfinite(rect.origin.y)||!isfinite(rect.size.width)||!isfinite(rect.size.height)||rect.size.width<0||rect.size.height<0)rhgFail(@"invalid-logical-cursor-rect");
    rhgLogicalCursorNotice();NSMutableArray *list=rhgCursorRects(view,YES);
    for(NSDictionary *entry in list)if(NSEqualRects([entry[@"rect"]rectValue],rect)&&[entry[@"cursor"]pointerValue]==(const void*)pointer)return;
    if(list.count>=256)rhgFail(@"logical-cursor-rect-limit");
    [list addObject:@{@"rect":[NSValue valueWithRect:rect],@"cursor":[NSValue valueWithPointer:(const void*)pointer]}];
}
static void rhgRemoveCursorRect(NSView *view,SEL selector,NSRect rect,__unsafe_unretained NSCursor *cursor) {
    if(!rhgHostedView(view)){((void(*)(id,SEL,NSRect,NSCursor*))rhgOriginal(view,selector))(view,selector,rect,cursor);return;}
    uintptr_t pointer=rhgOpaqueCursor(cursor);NSMutableArray *list=rhgCursorRects(view,NO);
    for(NSDictionary *entry in [list copy])if(NSEqualRects([entry[@"rect"]rectValue],rect)&&[entry[@"cursor"]pointerValue]==(const void*)pointer)[list removeObjectIdenticalTo:entry];
}
static void rhgDiscardCursorRects(NSView *view,SEL selector) {
    if(!rhgHostedView(view)){((void(*)(id,SEL))rhgOriginal(view,selector))(view,selector);return;}
    [rhgCursorRects(view,NO)removeAllObjects];
}
static void rhgPrepareHookStorage(void){static dispatch_once_t once;dispatch_once(&once,^{rhgHookLock=[NSRecursiveLock new];rhgOriginals=[NSMutableDictionary new];});}
static void rhgHook(Class type,SEL selector,IMP hook) {
    rhgPrepareHookStorage();
    [rhgHookLock lock];Method method=class_getInstanceMethod(type,selector);
    if(method && method_getImplementation(method)!=hook) {
        NSString *key=[NSString stringWithFormat:@"%p:%s",type,sel_getName(selector)];
        if(!rhgOriginals[key]){
            rhgOriginals[key]=[NSValue valueWithPointer:method_getImplementation(method)];
            if(!class_addMethod(type,selector,hook,method_getTypeEncoding(method)))method_setImplementation(class_getInstanceMethod(type,selector),hook);
        }
    }
    [rhgHookLock unlock];
}
@interface RHGDrawable:NSObject<CAMetalDrawable>
@property(strong)id<MTLTexture>texture;
@property(strong)CAMetalLayer *layer;
@property IOSurfaceRef importedSurface;
@property uint64_t frameID,generation;
@property uint32_t surfaceID,presentMode;
@property double presentTime,gpuSeconds;
@property uint64_t gpuCompletedTick;
@property BOOL fenceRegistered,gpuComplete,presentRequested,presentSent;
@property(nonatomic,strong)id<MTLResidencySet> importedResidency API_AVAILABLE(macos(15.0));
@property BOOL residencyEnded;
-(void)endImportedResidency;
@end
static void rhgRegisterDrawable(RHGDrawable *drawable){
    [rhgRenderLock lock];
    if(rhgOutstandingFrames.count>=rhgFrameDepth||drawable.frameID!=rhgNextExpectedFrameID||drawable.generation!=rhgConfigurationGeneration||rhgNextExpectedFrameID==UINT64_MAX)rhgFail(@"invalid-acquire-frame-identity");
    rhgNextExpectedFrameID++;[rhgOutstandingFrames addObject:drawable];[rhgRenderLock unlock];
}
static BOOL rhgReadyForPresent(RHGDrawable*drawable){@synchronized(drawable){return drawable.gpuComplete&&drawable.presentRequested&&!drawable.presentSent;}}
static void rhgTryPresent(RHGDrawable *drawable) {
    if(!rhgReadyForPresent(drawable))return;
    [rhgRenderLock lock];
    if(![rhgOutstandingFrames containsObject:drawable])rhgFail(@"unregistered-present-frame");
    if(rhgPresentWorkerScheduled||!rhgReadyForPresent(rhgOutstandingFrames.firstObject)){[rhgRenderLock unlock];return;}
    rhgPresentWorkerScheduled=YES;uint64_t enqueued=RHGPerfNow();[rhgRenderLock unlock];
    // Never wait for an earlier fence on this worker. An incomplete head leaves
    // the pump idle; its own later callback will restart it without a lost wakeup.
    dispatch_async(rhgPresentationWorker(),^{@autoreleasepool{
        BOOL first=YES;
        for(;;){
            [rhgRenderLock lock];RHGDrawable*frame=rhgOutstandingFrames.firstObject;
            if(!frame||!rhgReadyForPresent(frame)){rhgPresentWorkerScheduled=NO;[rhgRenderLock unlock];return;}
            RHGRequest request={0};
            @synchronized(frame){frame.presentSent=YES;request.frameID=frame.frameID;request.surfaceID=frame.surfaceID;request.configurationGeneration=frame.generation;request.presentMode=frame.presentMode;request.presentTime=frame.presentTime;request.gpuSeconds=frame.gpuSeconds;}
            [rhgRenderLock unlock];uint64_t entered=RHGPerfNow();
            if(first){rhgPerfAdd(&rhgPerformance.workerQueue,enqueued,entered);first=NO;}
            rhgPerfAdd(&rhgPerformance.completionToWorker,frame.gpuCompletedTick,entered);
            [frame endImportedResidency]; // Only after this frame's genuine GPU fence.
            RHGReply reply=rhgExchange(RHG_PRESENT,request);
            if(reply.frameID!=frame.frameID||reply.surfaceID!=frame.surfaceID||reply.configurationGeneration!=frame.generation)rhgFail(@"present-surface-identity-changed");
            [rhgRenderLock lock];if(rhgOutstandingFrames.firstObject!=frame)rhgFail(@"present-order-changed");[rhgOutstandingFrames removeObjectAtIndex:0];[rhgRenderLock unlock];
            dispatch_semaphore_signal(rhgFrameAvailable); // This exact accepted frame, never an early fence-only credit.
            static uint64_t acknowledged;acknowledged++;if(acknowledged%120==0)rhgPerfReport(acknowledged);
        }
    }});
}
static void rhgRequestPresent(RHGDrawable *drawable,uint32_t mode,double time) {
    if(!isfinite(time)||time<0)rhgFail(@"invalid-presentation-time");
    @synchronized(drawable){if(!drawable.fenceRegistered||drawable.presentRequested)rhgFail(@"unfenced-or-duplicate-present");
        drawable.presentRequested=YES;drawable.presentMode=mode;drawable.presentTime=time;}
    rhgTryPresent(drawable);
}
@implementation RHGDrawable
-(void)endImportedResidency {
    if(@available(macOS 15.0,*)) {
        id<MTLResidencySet> owned=nil;
        @synchronized(self){if(_residencyEnded)return;_residencyEnded=YES;owned=_importedResidency;_importedResidency=nil;}
        [owned endResidency];
    }
}
-(void)dealloc{[self endImportedResidency];if(_importedSurface)CFRelease(_importedSurface);}
-(NSUInteger)drawableID{return (NSUInteger)self.frameID;}
-(CFTimeInterval)presentedTime{return 0;} // Host ACK is present CALL, not on-glass.
-(void)present{rhgRequestPresent(self,RHG_PRESENT_NORMAL,0);}
-(void)presentAtTime:(CFTimeInterval)value{rhgRequestPresent(self,RHG_PRESENT_AT_TIME,value);}
-(void)presentAfterMinimumDuration:(CFTimeInterval)value{rhgRequestPresent(self,RHG_PRESENT_MIN_DURATION,value);}
-(void)addPresentedHandler:(MTLDrawablePresentedHandler)handler{(void)handler;rhgFail(@"on-glass-presented-callback-unsupported");}
-(void)doesNotRecognizeSelector:(SEL)selector{rhgFailSelector(@"unsupported-drawable-selector",self.class,selector);}
@end
static RHGDrawable *rhgProxy(id value) {if(![value isKindOfClass:RHGDrawable.class])rhgFail(@"non-hosted-drawable");return value;}
static void rhgBufferPresent(id<MTLCommandBuffer>buffer,id value,uint32_t mode,double time) {
    RHGDrawable *drawable=rhgProxy(value);
    @synchronized(drawable){if(drawable.fenceRegistered)rhgFail(@"drawable-already-fenced");drawable.fenceRegistered=YES;}
    [buffer addCompletedHandler:^(id<MTLCommandBuffer>completed){
        uint64_t entered=RHGPerfNow();
        if(completed.status!=MTLCommandBufferStatusCompleted)rhgFail(@"guest-metal-command-failed");
        @synchronized(drawable){drawable.gpuSeconds=MAX(0,completed.GPUEndTime-completed.GPUStartTime);drawable.gpuCompletedTick=entered;drawable.gpuComplete=YES;}
        rhgTryPresent(drawable);
        rhgPerfAdd(&rhgPerformance.completionBody,entered,RHGPerfNow());
    }];
    rhgRequestPresent(drawable,mode,time);
}
static void rhgPresent0(id buffer,SEL selector,id drawable){(void)selector;rhgBufferPresent(buffer,drawable,RHG_PRESENT_NORMAL,0);}
static void rhgPresentTime(id buffer,SEL selector,id drawable,double time){(void)selector;rhgBufferPresent(buffer,drawable,RHG_PRESENT_AT_TIME,time);}
static void rhgPresentDuration(id buffer,SEL selector,id drawable,double time){(void)selector;rhgBufferPresent(buffer,drawable,RHG_PRESENT_MIN_DURATION,time);}
static void rhgInstallBuffer(id buffer) {
    if(!buffer)rhgFail(@"missing-guest-command-buffer");Class type=object_getClass(buffer);
    rhgHook(type,@selector(presentDrawable:),(IMP)rhgPresent0);
    rhgHook(type,@selector(presentDrawable:atTime:),(IMP)rhgPresentTime);
    rhgHook(type,@selector(presentDrawable:afterMinimumDuration:),(IMP)rhgPresentDuration);
}
static id rhgCommandBuffer0(id queue,SEL selector){id buffer=((id(*)(id,SEL))rhgOriginal(queue,selector))(queue,selector);rhgInstallBuffer(buffer);return buffer;}
static id rhgCommandBuffer1(id queue,SEL selector,id descriptor){id buffer=((id(*)(id,SEL,id))rhgOriginal(queue,selector))(queue,selector,descriptor);rhgInstallBuffer(buffer);return buffer;}
static void rhgWaitDrawable(id<MTL4CommandQueue>queue,SEL selector,id value) API_AVAILABLE(macos(26.0));
static void rhgWaitDrawable(id<MTL4CommandQueue>queue,SEL selector,id value) {
    (void)selector;RHGDrawable *drawable=rhgProxy(value);
    if(queue.device.registryID!=drawable.texture.device.registryID || drawable.presentSent)rhgFail(@"invalid-metal4-drawable-wait");
    // Host nextDrawable has already waited for the actual display allocation.
}
// One context per actual guest queue. No host queue/command buffer is created.
// At most two pending notifications per queue; overall credits remain negotiated.
@interface RHGMetal4FenceState:NSObject
@property(nonatomic,strong)id<MTLSharedEvent> event;
@property(nonatomic,strong)MTLSharedEventListener *listener;
@property uint64_t deviceID,nextValue;
@property(nonatomic,strong)NSMutableSet<NSNumber*> *pendingValues;
@end
@implementation RHGMetal4FenceState @end
static char rhgMetal4FenceStateKey;
static RHGMetal4FenceState *rhgMetal4FenceState(id<MTL4CommandQueue>queue) API_AVAILABLE(macos(26.0));
static RHGMetal4FenceState *rhgMetal4FenceState(id<MTL4CommandQueue>queue) {
    @synchronized(queue){
        RHGMetal4FenceState *state=objc_getAssociatedObject(queue,&rhgMetal4FenceStateKey);
        if(!state){
            state=[RHGMetal4FenceState new];state.deviceID=queue.device.registryID;state.pendingValues=[NSMutableSet new];
            state.event=[queue.device newSharedEvent];if(!state.event)rhgFail(@"metal4-shared-event-unavailable");
            state.listener=[[MTLSharedEventListener alloc]initWithDispatchQueue:rhgGPUCompletionWorker()];
            if(!state.listener)rhgFail(@"metal4-event-listener-unavailable");
            objc_setAssociatedObject(queue,&rhgMetal4FenceStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if(state.deviceID!=queue.device.registryID)rhgFail(@"metal4-fence-device-changed");
        return state;
    }
}
static void rhgSignalDrawable(id<MTL4CommandQueue>queue,SEL selector,id value) API_AVAILABLE(macos(26.0));
static void rhgSignalDrawable(id<MTL4CommandQueue>queue,SEL selector,id value) {
    (void)selector;RHGDrawable *drawable=rhgProxy(value);
    if(queue.device.registryID!=drawable.texture.device.registryID)rhgFail(@"metal4-device-mismatch");
    @synchronized(drawable){if(drawable.fenceRegistered)rhgFail(@"duplicate-metal4-drawable-signal");drawable.fenceRegistered=YES;}
    RHGMetal4FenceState *state=rhgMetal4FenceState(queue);uint64_t expected;
    @synchronized(state){
        if(state.pendingValues.count>=RHG_MAX_FRAMES_IN_FLIGHT)rhgFail(@"metal4-fence-overlap");
        if(state.nextValue==UINT64_MAX)rhgFail(@"metal4-fence-sequence-exhausted");
        expected=++state.nextValue;[state.pendingValues addObject:@(expected)];
    // Serialize registration plus actual signal submission, not just counter
    // allocation: concurrent producers must never signal value N+1 before N.
    [state.event notifyListener:state.listener atValue:expected block:^(id<MTLSharedEvent>completed,uint64_t signaled){
        uint64_t entered=RHGPerfNow();
        // The block retains this context/drawable until the genuine fence fires,
        // including queue-owner teardown. Metal notifications are one-shot.
        @synchronized(state){
            if(completed!=state.event||signaled<expected||![state.pendingValues containsObject:@(expected)])rhgFail(@"metal4-fence-identity-changed");
            [state.pendingValues removeObject:@(expected)];
        }
        @synchronized(drawable){drawable.gpuCompletedTick=entered;drawable.gpuComplete=YES;}rhgTryPresent(drawable);
        rhgPerfAdd(&rhgPerformance.completionBody,entered,RHGPerfNow());
    }];
    [queue signalEvent:state.event value:expected]; // Same guest GPU fence; no additional work or pixel copy.
    }
}
static void rhgInstallQueue(id queue,BOOL metal4) {
    if(!queue)rhgFail(@"missing-guest-command-queue");Class type=object_getClass(queue);
    if(metal4) {
        if(@available(macOS 26.0,*)){rhgHook(type,@selector(waitForDrawable:),(IMP)rhgWaitDrawable);rhgHook(type,@selector(signalDrawable:),(IMP)rhgSignalDrawable);}
        else rhgFail(@"metal4-unavailable");
    } else {
        rhgHook(type,@selector(commandBuffer),(IMP)rhgCommandBuffer0);
        rhgHook(type,@selector(commandBufferWithUnretainedReferences),(IMP)rhgCommandBuffer0);
        rhgHook(type,@selector(commandBufferWithDescriptor:),(IMP)rhgCommandBuffer1);
    }
}
typedef id (*RHGNew0)(id,SEL) __attribute__((ns_returns_retained));
typedef id (*RHGNew1)(id,SEL,id) __attribute__((ns_returns_retained));
typedef id (*RHGNewCount)(id,SEL,NSUInteger) __attribute__((ns_returns_retained));
typedef id (*RHGNew2)(id,SEL,id,NSError *__autoreleasing *) __attribute__((ns_returns_retained));
static id rhgNewQueue0(id self,SEL selector) __attribute__((ns_returns_retained));
static id rhgNewQueue0(id self,SEL selector){id queue=((RHGNew0)rhgOriginal(self,selector))(self,selector);rhgInstallQueue(queue,selector==@selector(newMTL4CommandQueue));return queue;}
static id rhgNewQueue1(id self,SEL selector,id descriptor) __attribute__((ns_returns_retained));
static id rhgNewQueue1(id self,SEL selector,id descriptor){id queue=((RHGNew1)rhgOriginal(self,selector))(self,selector,descriptor);rhgInstallQueue(queue,NO);return queue;}
static id rhgNewQueueCount(id self,SEL selector,NSUInteger count) __attribute__((ns_returns_retained));
static id rhgNewQueueCount(id self,SEL selector,NSUInteger count){id queue=((RHGNewCount)rhgOriginal(self,selector))(self,selector,count);rhgInstallQueue(queue,NO);return queue;}
static id rhgNewQueue2(id self,SEL selector,id descriptor,NSError *__autoreleasing *error) __attribute__((ns_returns_retained));
static id rhgNewQueue2(id self,SEL selector,id descriptor,NSError *__autoreleasing *error){id queue=((RHGNew2)rhgOriginal(self,selector))(self,selector,descriptor,error);if(queue)rhgInstallQueue(queue,YES);return queue;}
static id rhgInstallDevice(id<MTLDevice>device) {
    if(!device)return nil;Class type=object_getClass(device);
    rhgHook(type,@selector(newCommandQueue),(IMP)rhgNewQueue0);
    rhgHook(type,@selector(newCommandQueueWithMaxCommandBufferCount:),(IMP)rhgNewQueueCount);
    rhgHook(type,@selector(newCommandQueueWithDescriptor:),(IMP)rhgNewQueue1);
    if(@available(macOS 26.0,*)){rhgHook(type,@selector(newMTL4CommandQueue),(IMP)rhgNewQueue0);rhgHook(type,@selector(newMTL4CommandQueueWithDescriptor:error:),(IMP)rhgNewQueue2);}
    return device;
}
static id<MTLDevice>rhgDefaultDevice(void) __attribute__((ns_returns_retained));
static id<MTLDevice>rhgDefaultDevice(void){id<MTLDevice>device=MTLCreateSystemDefaultDevice();return rhgRemoteLayerMode()?device:rhgInstallDevice(device);}
static NSArray<id<MTLDevice>>*rhgAllDevices(void) __attribute__((ns_returns_retained));
static NSArray<id<MTLDevice>>*rhgAllDevices(void){NSArray *devices=MTLCopyAllDevices();if(!rhgRemoteLayerMode())for(id device in devices)rhgInstallDevice(device);return devices;}
#define RHG_INTERPOSE(replacement,original) __attribute__((used))static struct{const void *replace,*original;}rhg_interpose_##original __attribute__((section("__DATA,__interpose")))={(const void *)&replacement,(const void *)&original}
#import "RHGSessionScratch.h"
RHG_INTERPOSE(rhgDefaultDevice,MTLCreateSystemDefaultDevice);
RHG_INTERPOSE(rhgAllDevices,MTLCopyAllDevices);
static CGError rhgPointerRequest(uint32_t operation,uint32_t action,double x,double y){
    rhgConnect();RHGRequest request={0};request.pointerAction=action;request.pointerX=x;request.pointerY=y;
    RHGReply reply=rhgExchange(operation,request);
    if(reply.status!=RHG_OK)return reply.pointerError?(CGError)reply.pointerError:kCGErrorInvalidOperation;
    return kCGErrorSuccess; // Authenticated virtual policy ACK; host owns physical capture.
}
static CGError rhgAssociateMouse(boolean_t connected){return rhgPointerRequest(RHG_POINTER_ASSOCIATE,connected?1:0,0,0);}
static CGError rhgWarpMouse(CGPoint point){
    rhgConnect();RHGWindowMetadata metadata=rhgMetadataSnapshot();double x=(point.x-metadata.quartzX)/metadata.logicalWidth,y=(point.y-metadata.quartzY)/metadata.logicalHeight;
    if(!isfinite(x)||!isfinite(y)||x<0||x>1||y<0||y>1)return kCGErrorIllegalArgument;
    return rhgPointerRequest(RHG_POINTER_WARP,0,x,y); // Never move a physical cursor here.
}
static CGError rhgHideCursor(CGDirectDisplayID display){(void)display;return rhgPointerRequest(RHG_POINTER_CURSOR,RHG_CURSOR_HIDE,0,0);}
static CGError rhgShowCursor(CGDirectDisplayID display){(void)display;return rhgPointerRequest(RHG_POINTER_CURSOR,RHG_CURSOR_SHOW,0,0);}
static void rhgCursorHide(id type,SEL selector){(void)type;(void)selector;(void)rhgHideCursor(0);}
static void rhgCursorUnhide(id type,SEL selector){(void)type;(void)selector;(void)rhgShowCursor(0);}
static void rhgCursorUntilMove(id type,SEL selector,BOOL hidden){(void)type;(void)selector;(void)rhgPointerRequest(RHG_POINTER_CURSOR,hidden?RHG_CURSOR_HIDE_UNTIL_MOVE:RHG_CURSOR_CANCEL_UNTIL_MOVE,0,0);}
static BOOL rhgCursorHidden(id type,SEL selector){(void)type;(void)selector;return rhgVirtualHideCount>0||rhgVirtualHiddenUntilMove;}
RHG_INTERPOSE(rhgAssociateMouse,CGAssociateMouseAndMouseCursorPosition);
RHG_INTERPOSE(rhgWarpMouse,CGWarpMouseCursorPosition);
RHG_INTERPOSE(rhgHideCursor,CGDisplayHideCursor);
RHG_INTERPOSE(rhgShowCursor,CGDisplayShowCursor);

static RHGRequest rhgReadLayerConfiguration(CAMetalLayer *layer){
    CGSize size=layer.drawableSize;
    if(!isfinite(size.width)||!isfinite(size.height)||size.width<1||size.height<1||size.width>8192||size.height>8192)rhgFail(@"invalid-drawable-size");
    RHGRequest configure={0};configure.width=(uint32_t)size.width;configure.height=(uint32_t)size.height;
    configure.pixelFormat=(uint32_t)layer.pixelFormat;configure.deviceRegistryID=layer.device.registryID;
    configure.displaySyncEnabled=layer.displaySyncEnabled?1:0;
    return configure;
}
static RHGRequest rhgAdoptConfiguration(RHGRequest configure){
    configure.configurationGeneration=rhgConfigurationGeneration;
    if(!rhgConfigured || rhgConfiguredWidth!=configure.width || rhgConfiguredHeight!=configure.height ||
       rhgConfiguredFormat!=configure.pixelFormat || rhgConfiguredDevice!=configure.deviceRegistryID || rhgConfiguredDisplaySync!=configure.displaySyncEnabled) {
        RHGReply configuration=rhgExchange(RHG_CONFIGURE,configure);
        if(configuration.width!=configure.width||configuration.height!=configure.height||configuration.pixelFormat!=configure.pixelFormat||configuration.deviceRegistryID!=configure.deviceRegistryID||configuration.displaySyncEnabled>1||configuration.displaySyncEnabled!=configure.displaySyncEnabled||configuration.configurationGeneration!=rhgConfigurationGeneration+1)rhgFail(@"host-did-not-adopt-layer-configuration");
        rhgConfigurationGeneration=configuration.configurationGeneration;
        rhgConfiguredWidth=configure.width;rhgConfiguredHeight=configure.height;
        rhgConfiguredFormat=configure.pixelFormat;rhgConfiguredDevice=configure.deviceRegistryID;rhgConfiguredDisplaySync=configure.displaySyncEnabled;rhgConfigured=YES;
    }
    configure.configurationGeneration=rhgConfigurationGeneration;return configure;
}
static RHGRequest rhgAdoptLayerConfiguration(CAMetalLayer*layer){return rhgAdoptConfiguration(rhgReadLayerConfiguration(layer));}
// Owned only while rhgAcquisitionLock is held. A cached wrapper aliases the
// existing host surface; it does not retain a CAMetalDrawable or copy pixels.
@interface RHGImportedTextureEntry:NSObject
@property IOSurfaceRef surface;
@property(strong)id<MTLTexture> texture;
@property(strong)id<MTLDevice> device;
@property uint64_t generation,deviceID;
@property uint32_t surfaceID,width,height,pixelFormat;
@property MTLTextureUsage usage;
@property MTLStorageMode storageMode;
@property NSUInteger plane;
@end
@implementation RHGImportedTextureEntry
-(void)dealloc{if(_surface)CFRelease(_surface);}
@end
static NSMutableArray<RHGImportedTextureEntry*> *rhgImportedTextures;
static BOOL rhgTextureCacheEnabled(void){
    static BOOL enabled;static dispatch_once_t once;
    dispatch_once(&once,^{const char *value=getenv("RHG_TEXTURE_CACHE");enabled=value&&strcmp(value,"1")==0;});return enabled;
}
static void rhgTextureCacheRecord(BOOL enabled,BOOL hit,BOOL imported,BOOL fallback){
    if(!RHGPerfProfileEnabled())return;
    pthread_mutex_lock(&rhgPerfLock);RHGTextureCacheStats *stats=&rhgPerformance.textureCache;
    stats->enabled=enabled;stats->requests++;if(enabled){stats->lookups++;if(hit)stats->hits++;else stats->misses++;}
    if(imported)stats->imports++;if(fallback)stats->fallbacks++;stats->entries=(uint32_t)rhgImportedTextures.count;
    if(stats->entries>stats->maximumEntries)stats->maximumEntries=stats->entries;pthread_mutex_unlock(&rhgPerfLock);
}
static void rhgClearImportedTextures(void){
    // Never take the acquisition lock from the presentation worker: CONFIGURE
    // drains credits before reaching this acquisition-owned cleanup.
    [rhgRenderLock lock];BOOL outstanding=rhgOutstandingFrames.count!=0;[rhgRenderLock unlock];
    if(outstanding)rhgFail(@"texture-cache-clear-with-outstanding-frames");
    [rhgImportedTextures removeAllObjects];
    if(RHGPerfProfileEnabled()){pthread_mutex_lock(&rhgPerfLock);rhgPerformance.textureCache.clears++;rhgPerformance.textureCache.entries=0;pthread_mutex_unlock(&rhgPerfLock);}
}
static id<MTLTexture> rhgTextureForSurface(id<MTLDevice>device,IOSurfaceRef surface,uint64_t generation,uint32_t width,uint32_t height,MTLPixelFormat format,MTLTextureUsage usage){
    BOOL enabled=rhgTextureCacheEnabled();uint32_t surfaceID=IOSurfaceGetID(surface);uint64_t deviceID=device.registryID;
    if(enabled){
        if(!rhgImportedTextures)rhgImportedTextures=[NSMutableArray new];
        for(NSUInteger i=0;i<rhgImportedTextures.count;i++){
            RHGImportedTextureEntry *entry=rhgImportedTextures[i];
            if(entry.surfaceID==surfaceID&&entry.generation==generation&&entry.device==device&&entry.deviceID==deviceID&&entry.width==width&&entry.height==height&&entry.pixelFormat==format&&entry.usage==usage&&entry.storageMode==MTLStorageModeShared&&entry.plane==0){
                [rhgImportedTextures removeObjectAtIndex:i];[rhgImportedTextures addObject:entry];rhgTextureCacheRecord(YES,YES,NO,NO);return entry.texture;
            }
        }
    }
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];descriptor.storageMode=MTLStorageModeShared;descriptor.usage=usage;
    id<MTLTexture> texture=[device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
    if(!texture||!texture.iosurface||IOSurfaceGetID(texture.iosurface)!=surfaceID)rhgFail(@"same-surface-metal-import-failed");
    BOOL fallback=NO;
    if(enabled){
        if(rhgImportedTextures.count>=3){
            NSUInteger victim=NSNotFound;[rhgRenderLock lock];
            for(NSUInteger i=0;i<rhgImportedTextures.count;i++){
                BOOL active=NO;id<MTLTexture> cached=rhgImportedTextures[i].texture;
                for(RHGDrawable *frame in rhgOutstandingFrames)if(frame.texture==cached){active=YES;break;}
                if(!active){victim=i;break;}
            }
            [rhgRenderLock unlock];if(victim!=NSNotFound)[rhgImportedTextures removeObjectAtIndex:victim];else fallback=YES;
        }
        if(!fallback){RHGImportedTextureEntry *entry=[RHGImportedTextureEntry new];entry.surface=(IOSurfaceRef)CFRetain(surface);entry.texture=texture;entry.device=device;entry.surfaceID=surfaceID;entry.generation=generation;entry.deviceID=deviceID;entry.width=width;entry.height=height;entry.pixelFormat=format;entry.usage=usage;entry.storageMode=MTLStorageModeShared;entry.plane=0;[rhgImportedTextures addObject:entry];}
    }
    rhgTextureCacheRecord(enabled,NO,YES,fallback);return texture;
}
static IOSurfaceRef rhgValidatedAcquireSurface(CAMetalLayer *layer,RHGReply reply,RHGRequest configure){
    IOSurfaceRef surface=IOSurfaceLookupFromMachPort(reply.port.name);mach_port_deallocate(mach_task_self(),reply.port.name);
    if(!surface||IOSurfaceGetID(surface)!=reply.surfaceID||reply.window!=rhgMetadataSnapshot().window||reply.pixelFormat!=layer.pixelFormat||reply.width!=configure.width||reply.height!=configure.height||reply.deviceRegistryID!=layer.device.registryID||IOSurfaceGetWidth(surface)!=reply.width||IOSurfaceGetHeight(surface)!=reply.height)rhgFail(@"host-surface-metadata-mismatch");
    return surface;
}
static id rhgNextDrawable(CAMetalLayer *layer,SEL selector) {
    (void)selector;rhgConnect();
    if(!layer.device || !rhgFormat(layer.pixelFormat))rhgFail(@"unsupported-layer-device-or-format");
    if(RHGPerfProfileEnabled()){pthread_mutex_lock(&rhgPerfLock);rhgPerformance.guestLayerDisplaySyncEnabled=layer.displaySyncEnabled;pthread_mutex_unlock(&rhgPerfLock);}
    if(rhgGameLayer && rhgGameLayer!=layer)rhgFail(@"multiple-swapchain-layers");rhgGameLayer=layer;rhgInstallDevice(layer.device);
    pthread_mutex_lock(&rhgAcquisitionLock);
    RHGRequest wanted=rhgReadLayerConfiguration(layer);
    BOOL changed=!rhgConfigured||rhgConfiguredWidth!=wanted.width||rhgConfiguredHeight!=wanted.height||rhgConfiguredFormat!=wanted.pixelFormat||rhgConfiguredDevice!=wanted.deviceRegistryID||rhgConfiguredDisplaySync!=wanted.displaySyncEnabled;
    uint64_t creditBegan=RHGPerfNow();dispatch_time_t deadline=dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC);
    unsigned needed=changed?rhgFrameDepth:1;
    for(unsigned i=0;i<needed;i++)if(dispatch_semaphore_wait(rhgFrameAvailable,deadline))rhgFail(@"outstanding-frame-deadline");
    rhgPerfAdd(&rhgPerformance.frameCredit,creditBegan,RHGPerfNow());
    if(changed)rhgClearImportedTextures();
    RHGRequest configure=rhgAdoptConfiguration(wanted);
    for(unsigned i=1;i<needed;i++)dispatch_semaphore_signal(rhgFrameAvailable);
    RHGReply reply=rhgExchange(RHG_ACQUIRE,(RHGRequest){.configurationGeneration=rhgConfigurationGeneration});
    if(reply.configurationGeneration!=rhgConfigurationGeneration)rhgFail(@"acquire-generation-changed");
    uint64_t importBegan=RHGPerfNow();
    IOSurfaceRef surface=rhgValidatedAcquireSurface(layer,reply,configure);
    rhgPerfAdd(&rhgPerformance.surfaceLookup,importBegan,RHGPerfNow());
    // The validated exchange already published the coherent host metadata.
    MTLTextureUsage usage=MTLTextureUsageRenderTarget;if(!layer.framebufferOnly)usage|=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
    uint64_t wrapperBegan=RHGPerfNow();
    id<MTLTexture>texture=rhgTextureForSurface(layer.device,surface,reply.configurationGeneration,reply.width,reply.height,layer.pixelFormat,usage);
    uint64_t wrapperEnded=RHGPerfNow();rhgPerfAdd(&rhgPerformance.textureWrapper,wrapperBegan,wrapperEnded);
    rhgPerfAdd(&rhgPerformance.importSurface,importBegan,wrapperEnded);
    RHGDrawable *drawable=[RHGDrawable new];drawable.texture=texture;drawable.layer=layer;drawable.importedSurface=surface;
    if(@available(macOS 15.0,*)) {
        uint64_t residencyBegan=RHGPerfNow();
        MTLResidencySetDescriptor *residencyDescriptor=[MTLResidencySetDescriptor new];residencyDescriptor.initialCapacity=1;
        id<MTLResidencySet> residency=[layer.device newResidencySetWithDescriptor:residencyDescriptor error:nil];
        if(!residency)rhgFail(@"imported-texture-residency-unavailable");
        [residency addAllocation:texture];[residency commit];[residency requestResidency];
        drawable.importedResidency=residency;
        rhgPerfAdd(&rhgPerformance.residency,residencyBegan,RHGPerfNow());
    }
    drawable.frameID=reply.frameID;drawable.surfaceID=reply.surfaceID;drawable.generation=reply.configurationGeneration;rhgRegisterDrawable(drawable);rhgFrames++;pthread_mutex_unlock(&rhgAcquisitionLock);return drawable;
}
// Opt-in remote-layer transport. CoreAnimation owns the native drawable pool
// and presentation timeline; this module never imports or substitutes textures.
static RHGRemoteContext *rhgRemoteContext;
static NSRecursiveLock *rhgRemoteLock;
static IMP rhgRemoteOriginalNext,rhgRemoteOriginalUpdate,rhgRemoteOriginalInit;
static _Atomic bool rhgRemoteFirstArmed,rhgRemoteFirstSent;
enum {RHG_REMOTE_STARTUP_LIMIT=128,RHG_REMOTE_STARTUP_SECONDS=15,RHG_REMOTE_TRACE_LIMIT=8};
static _Atomic unsigned rhgRemoteObserved,rhgRemoteCallbacks;
static char rhgRemoteDrawableMarker;
static id rhgRemoteNextDrawable(CAMetalLayer *layer,SEL selector);
static id rhgRemoteUpdateDrawable(CAMetalDisplayLinkUpdate *update,SEL selector);
static id rhgRemoteDisplayLinkInit(id self __attribute__((ns_consumed)),SEL selector,CAMetalLayer *layer) __attribute__((ns_returns_retained));
static void rhgRemoteRestore(Method method,IMP ours,IMP original){
    if(method&&original&&method_getImplementation(method)==ours)method_setImplementation(method,original);
}
static void rhgRemoteRestoreObservers(void){
    rhgRemoteRestore(class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable)),(IMP)rhgRemoteNextDrawable,rhgRemoteOriginalNext);
    rhgRemoteRestore(class_getInstanceMethod(CAMetalDisplayLinkUpdate.class,@selector(drawable)),(IMP)rhgRemoteUpdateDrawable,rhgRemoteOriginalUpdate);
    rhgRemoteRestore(class_getInstanceMethod(CAMetalDisplayLink.class,@selector(initWithMetalLayer:)),(IMP)rhgRemoteDisplayLinkInit,rhgRemoteOriginalInit);
}
static void rhgRemoteAttach(CAMetalLayer *layer){
    if(!layer)rhgFail(@"remote-layer-missing-native-layer");
    [rhgRemoteLock lock];
    if(rhgGameLayer&&rhgGameLayer!=layer){[rhgRemoteLock unlock];rhgFail(@"multiple-swapchain-layers");}
    rhgGameLayer=layer;
    // Retain the existing game-owned tree, preserving its Metal sublayers and
    // native presentation objects. Never remove the layer from its superlayer.
    CALayer *root=layer;while(root.superlayer)root=root.superlayer;
    if(!rhgRemoteContext){
        rhgConnect();Class cls=NSClassFromString(@"CAContext");
        if(!cls||![cls respondsToSelector:@selector(remoteContextWithOptions:)]||![cls respondsToSelector:@selector(setAllowsCGSConnections:)])rhgFail(@"remote-layer-system-api-unavailable");
        [(id)cls setAllowsCGSConnections:NO];
        NSString * __unsafe_unretained const *option=(NSString * __unsafe_unretained const*)dlsym(RTLD_DEFAULT,"kCAContextCIFilterBehavior");
        rhgRemoteContext=[(id)cls remoteContextWithOptions:option?@{*option:@"ignore"}:@{}];
        if(!rhgRemoteContext||!rhgRemoteContext.contextId)rhgFail(@"remote-layer-context-unavailable");
        rhgRemoteContext.layer=root;[CATransaction flush];
        RHGReply attached=rhgExchange(RHG_REMOTE_ATTACH,(RHGRequest){.surfaceID=rhgRemoteContext.contextId});
        if(attached.surfaceID!=rhgRemoteContext.contextId)rhgFail(@"remote-layer-context-ack-mismatch");
    }else if(rhgRemoteContext.layer!=root){rhgRemoteContext.layer=root;[CATransaction flush];}
    [rhgRemoteLock unlock];
}
static id rhgRemoteNumber(double value){return isfinite(value)?@(value):NSNull.null;}
static NSDictionary *rhgRemoteGeometry(unsigned count){
    if(!rhgRemoteTraceEnabled())return nil;
    NSMutableArray *chain=[NSMutableArray new];
    for(CALayer *layer=rhgGameLayer;layer&&chain.count<8;layer=layer.superlayer){
        CGRect bounds=layer.bounds,frame=layer.frame;CGPoint position=layer.position,anchor=layer.anchorPoint;
        [chain addObject:@{@"class":rhgSafeMetadata(class_getName(object_getClass(layer)))?:@"unavailable",
            @"bounds":@[rhgRemoteNumber(bounds.origin.x),rhgRemoteNumber(bounds.origin.y),rhgRemoteNumber(bounds.size.width),rhgRemoteNumber(bounds.size.height)],
            @"frame":@[rhgRemoteNumber(frame.origin.x),rhgRemoteNumber(frame.origin.y),rhgRemoteNumber(frame.size.width),rhgRemoteNumber(frame.size.height)],
            @"position":@[rhgRemoteNumber(position.x),rhgRemoteNumber(position.y)],@"anchor":@[rhgRemoteNumber(anchor.x),rhgRemoteNumber(anchor.y)],
            @"opacity":rhgRemoteNumber(layer.opacity),@"hidden":@(layer.hidden),@"masksToBounds":@(layer.masksToBounds),@"contentsScale":rhgRemoteNumber(layer.contentsScale),@"geometryFlipped":@(layer.geometryFlipped)}];
    }
    CGSize drawableSize=rhgGameLayer.drawableSize;
    return @{@"type":@"hosted-remote-startup",@"schema":@1,@"observation":@(count+1),@"layerChain":chain,@"drawableSize":@[rhgRemoteNumber(drawableSize.width),rhgRemoteNumber(drawableSize.height)]};
}
static void rhgRemoteWriteGeometry(NSDictionary *geometry){
    if(!geometry)return;int output=atomic_load(&rhgPerfOutputFD);if(output<0)return;
    // Trace-only startup diagnostics must survive the deliberate refusal path's
    // _exit. At most eight bounded rows are written before normal gameplay;
    // no diagnostic write occurs in the native frame loop after handoff.
    NSData *json=[NSJSONSerialization dataWithJSONObject:geometry options:NSJSONWritingSortedKeys error:nil];
    if(json&&json.length<=16384){NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];rhgPerfWriteLine(output,line);}
}
static void rhgRemoteTraceConstructor(void){
    if(!rhgRemoteTraceEnabled())return;
    int output=atomic_load(&rhgPerfOutputFD);struct stat value={0};BOOL valid=output>=0&&fstat(output,&value)==0;
    NSDictionary *row=@{@"type":@"hosted-remote-trace-status",@"schema":@1,@"enabled":@YES,@"sinkAvailable":@(valid),@"sinkRegularFile":@(valid&&S_ISREG(value.st_mode)),@"sinkCloseOnExec":@(output>=0&&(fcntl(output,F_GETFD)&FD_CLOEXEC)!=0)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
    if(json&&json.length<=1024){NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];rhgPerfWriteLine(output>=0?output:STDERR_FILENO,line);}
}
static void rhgRemoteObserveDrawable(id<CAMetalDrawable>drawable){
    if(!drawable||atomic_load(&rhgRemoteFirstSent))return;
    // DisplayLink/update getters can return the same native drawable repeatedly.
    // Count its object+drawableID once, rather than charging each getter read
    // against the bounded startup-frame budget. No drawable is retained here.
    @synchronized(drawable){
        NSNumber *observed=objc_getAssociatedObject(drawable,&rhgRemoteDrawableMarker);
        uint64_t identity=drawable.drawableID;
        if(observed&&observed.unsignedLongLongValue==identity)return;
        objc_setAssociatedObject(drawable,&rhgRemoteDrawableMarker,@(identity),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    unsigned count=atomic_fetch_add(&rhgRemoteObserved,1);
    if(count>=RHG_REMOTE_STARTUP_LIMIT)return;
    atomic_store(&rhgRemoteFirstArmed,true);
    if(count==0)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,RHG_REMOTE_STARTUP_SECONDS*NSEC_PER_SEC),rhgGPUCompletionWorker(),^{
        if(!atomic_load(&rhgRemoteFirstSent)){rhgRemoteRestoreObservers();rhgFail(@"remote-layer-presented-startup-timeout");}
    });
    id<MTLTexture> texture=drawable.texture;
    if(!texture||!texture.width||!texture.height||texture.width>8192||texture.height>8192||!rhgFormat(texture.pixelFormat)||!texture.device.registryID)rhgFail(@"remote-layer-invalid-native-drawable");
    RHGRequest first={.surfaceID=rhgRemoteContext.contextId,.width=(uint32_t)texture.width,.height=(uint32_t)texture.height,.pixelFormat=(uint32_t)texture.pixelFormat,.deviceRegistryID=texture.device.registryID};
    if(count<RHG_REMOTE_TRACE_LIMIT)rhgRemoteWriteGeometry(rhgRemoteGeometry(count));
    [drawable addPresentedHandler:^(id<MTLDrawable>native){
        // A zero timestamp denotes a dropped/warmup frame. It must not uncover
        // Ready or be described as GPU-complete/on-glass presentation.
        double presented=native.presentedTime;
        atomic_fetch_add(&rhgRemoteCallbacks,1);
        if(isfinite(presented)&&presented>0&&!atomic_exchange(&rhgRemoteFirstSent,true)){
            rhgRemoteRestoreObservers();
            dispatch_async(rhgGPUCompletionWorker(),^{@autoreleasepool{RHGReply accepted=rhgExchange(RHG_REMOTE_FIRST_FRAME,first);if(accepted.surfaceID!=first.surfaceID)rhgFail(@"remote-layer-context-ack-mismatch");}});
        }
    }];
    // Bound startup observation even if presentation callbacks run later.
    if(count==RHG_REMOTE_STARTUP_LIMIT-1)rhgRemoteRestoreObservers();
}
static id rhgRemoteNextDrawable(CAMetalLayer *layer,SEL selector){
    rhgRemoteAttach(layer);
    id<CAMetalDrawable>drawable=((id(*)(id,SEL))rhgRemoteOriginalNext)(layer,selector);
    rhgRemoteObserveDrawable(drawable);return drawable;
}
static id rhgRemoteUpdateDrawable(CAMetalDisplayLinkUpdate *update,SEL selector){
    if(rhgGameLayer)rhgRemoteAttach(rhgGameLayer);
    id<CAMetalDrawable>drawable=((id(*)(id,SEL))rhgRemoteOriginalUpdate)(update,selector);
    if(!rhgGameLayer)rhgFail(@"remote-layer-display-link-not-attached");
    rhgRemoteObserveDrawable(drawable);return drawable;
}
typedef id(*RHGRemoteInit)(id __attribute__((ns_consumed)),SEL,CAMetalLayer*) __attribute__((ns_returns_retained));
static id rhgRemoteDisplayLinkInit(id self __attribute__((ns_consumed)),SEL selector,CAMetalLayer *layer){
    rhgRemoteAttach(layer);
    id link=((RHGRemoteInit)rhgRemoteOriginalInit)(self,selector,layer);
    rhgRemoteRestore(class_getInstanceMethod(CAMetalDisplayLink.class,@selector(initWithMetalLayer:)),(IMP)rhgRemoteDisplayLinkInit,rhgRemoteOriginalInit);
    return link;
}
static void rhgInstallRemoteLayer(void){
    rhgRemoteLock=[NSRecursiveLock new];
    Method next=class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable));
    Method update=class_getInstanceMethod(CAMetalDisplayLinkUpdate.class,@selector(drawable));
    Method init=class_getInstanceMethod(CAMetalDisplayLink.class,@selector(initWithMetalLayer:));
    if(!next||!update||!init)rhgFail(@"remote-layer-native-observer-api-unavailable");
    rhgRemoteOriginalNext=method_setImplementation(next,(IMP)rhgRemoteNextDrawable);
    rhgRemoteOriginalUpdate=method_setImplementation(update,(IMP)rhgRemoteUpdateDrawable);
    rhgRemoteOriginalInit=method_setImplementation(init,(IMP)rhgRemoteDisplayLinkInit);
}
static void rhgInstallMetal(void) {
    rhgPrepareHookStorage();
    if(rhgRemoteLayerMode())rhgInstallRemoteLayer();else rhgReplace(CAMetalLayer.class,@selector(nextDrawable),(IMP)rhgNextDrawable);
    rhgHook(object_getClass(NSEvent.class),@selector(mouseLocation),(IMP)rhgMouseLocation);
    rhgHook(NSEvent.class,@selector(deltaX),(IMP)rhgEventDelta);rhgHook(NSEvent.class,@selector(deltaY),(IMP)rhgEventDelta);
    rhgHook(NSEvent.class,@selector(scrollingDeltaX),(IMP)rhgEventDelta);rhgHook(NSEvent.class,@selector(scrollingDeltaY),(IMP)rhgEventDelta);
    rhgHook(NSEvent.class,@selector(locationInWindow),(IMP)rhgEventLocation);rhgHook(NSEvent.class,@selector(window),(IMP)rhgEventWindow);
    rhgHook(NSEvent.class,@selector(windowNumber),(IMP)rhgEventWindowNumber);
    rhgHook(NSRunningApplication.class,@selector(isActive),(IMP)rhgRunningApplicationActive);
    rhgHook(NSRunningApplication.class,@selector(activateWithOptions:),(IMP)rhgRunningApplicationActivate);
    rhgHook(NSRunningApplication.class,@selector(activateFromApplication:options:),(IMP)rhgRunningApplicationActivateFrom);
    rhgHook(NSRunningApplication.class,@selector(unhide),(IMP)rhgRunningApplicationUnhide);
    rhgHook(NSView.class,@selector(gestureRecognizers),(IMP)rhgGetGestures);
    rhgHook(NSView.class,@selector(setGestureRecognizers:),(IMP)rhgSetGestures);
    rhgHook(NSView.class,@selector(addGestureRecognizer:),(IMP)rhgAddGesture);
    rhgHook(NSView.class,@selector(removeGestureRecognizer:),(IMP)rhgRemoveGesture);
    rhgHook(NSGestureRecognizer.class,@selector(view),(IMP)rhgGestureView);
    rhgHook(NSView.class,@selector(addCursorRect:cursor:),(IMP)rhgAddCursorRect);
    rhgHook(NSView.class,@selector(removeCursorRect:cursor:),(IMP)rhgRemoveCursorRect);
    rhgHook(NSView.class,@selector(discardCursorRects),(IMP)rhgDiscardCursorRects);
    Class cursor=object_getClass(NSCursor.class);rhgHook(cursor,@selector(hide),(IMP)rhgCursorHide);rhgHook(cursor,@selector(unhide),(IMP)rhgCursorUnhide);
    rhgHook(cursor,@selector(setHiddenUntilMouseMoves:),(IMP)rhgCursorUntilMove);rhgHook(cursor,NSSelectorFromString(@"isHidden"),(IMP)rhgCursorHidden);
}
__attribute__((constructor))static void rhgInstall(void) {@autoreleasepool{
    const char *service=getenv("READY_HOSTED_GAME_SERVICE"),*nonce=getenv("READY_HOSTED_GAME_NONCE");
    if(!service||!nonce)rhgFail(@"explicit-host-capability-required");
    rhgPerfPrepareOutput();rhgRemoteTraceConstructor();
    rhgInstallSessionScratch();rhgInstallMetal();rhgInstallWindows();
}}
