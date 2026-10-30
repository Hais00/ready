/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef READY_HOSTED_GAME_PROTOCOL_H
#define READY_HOSTED_GAME_PROTOCOL_H
#include <mach/mach.h>
#include <stdint.h>
#define RHG_MAGIC UINT32_C(0x52484731)
#define RHG_VERSION 6
#define RHG_MAX_FRAMES_IN_FLIGHT 2
#define RHG_MAX_EVENTS 8
#define RHG_NONCE_BYTES 32
#define RHG_SERVICE_PREFIX "local.ready.hostedgame."
enum {RHG_HELLO=1,RHG_CONFIGURE=2,RHG_ACQUIRE=3,RHG_PRESENT=4,RHG_POLL=5,RHG_DONE=6,RHG_POINTER_ASSOCIATE=7,RHG_POINTER_WARP=8,RHG_POINTER_CURSOR=9,RHG_REMOTE_ATTACH=10,RHG_REMOTE_FIRST_FRAME=11};
/* HELLO reserved selects the transport; request/reply layout remains wire V6. */
enum {RHG_TRANSPORT_SURFACE=0,RHG_TRANSPORT_REMOTE_LAYER=1};
enum {RHG_CURSOR_HIDE=1,RHG_CURSOR_SHOW=2,RHG_CURSOR_HIDE_UNTIL_MOVE=3,RHG_CURSOR_CANCEL_UNTIL_MOVE=4};
enum {RHG_OK=0,RHG_REJECTED=1,RHG_STOPPED=2,RHG_BUSY=3,RHG_UNSUPPORTED=4};
enum {RHG_PRESENT_NORMAL=0,RHG_PRESENT_AT_TIME=1,RHG_PRESENT_MIN_DURATION=2};
enum {RHG_KEY_DOWN=1,RHG_KEY_UP=2,RHG_MOUSE_MOVE=3,RHG_MOUSE_DOWN=4,RHG_MOUSE_UP=5,RHG_SCROLL=6,RHG_FLAGS=7,RHG_FOCUS=8};
typedef struct {
 uint32_t type,keyCode,button,clickCount;uint64_t modifiers;
 double x,y,deltaX,deltaY,timestamp;uint32_t repeat,charactersLength;char characters[32];
 /* Preserve AppKit point precision, gesture phases and native CG fields. */
 double scrollingDeltaX,scrollingDeltaY,scrollFixedX,scrollFixedY;
 int64_t scrollLineX,scrollLineY,scrollPointX,scrollPointY;
 uint32_t scrollPrecise,scrollInverted,scrollPhase,scrollMomentumPhase,scrollCGPhase,scrollCGMomentumPhase;
} RHGInput;
typedef struct {
 mach_msg_header_t h;uint32_t magic,version,op,reserved;uint64_t requestID;
 uint8_t nonce[RHG_NONCE_BYTES];uint64_t frameID;uint32_t surfaceID,width,height,pixelFormat;
 uint64_t deviceRegistryID;uint32_t presentMode,displaySyncEnabled;double presentTime,gpuSeconds;
 uint32_t pointerAction,reserved3;double pointerX,pointerY;
 uint64_t configurationGeneration;uint32_t framesInFlight;
} RHGRequest;
typedef struct {
 mach_msg_header_t h;mach_msg_body_t body;mach_msg_port_descriptor_t port;
 uint32_t magic,version,status,op;uint64_t requestID,frameID;
 uint32_t surfaceID,window,width,height,pixelFormat,eventCount;uint64_t deviceRegistryID;
 double backingScale;RHGInput events[RHG_MAX_EVENTS];
 /* Pointer ACK is a virtual guest-policy ACK, never authority to release the
  * host's exclusive physical pointer. Warps change virtual coordinates only. */
 int32_t pointerError;uint32_t pointerCaptured,pointerAssociated,pointerHideCount,pointerHiddenUntilMove;
 double logicalWidth,logicalHeight,quartzOriginX,quartzOriginY,cocoaOriginX,cocoaOriginY;
 /* Authenticated normalized host virtual position; y increases downwards. */
 double pointerX,pointerY;
 /* CONFIGURE ACK: the host's adopted displaySyncEnabled, strictly 0 or 1. */
 uint32_t displaySyncEnabled;
 uint64_t configurationGeneration;uint32_t framesInFlight;
} RHGReply;
typedef struct {RHGRequest message;mach_msg_audit_trailer_t trailer;} RHGRequestReceive;
typedef struct {RHGReply message;mach_msg_max_trailer_t trailer;} RHGReplyReceive;
#endif
