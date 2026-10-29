/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef READY_HOSTED_VIEW_H
#define READY_HOSTED_VIEW_H
#include <stdbool.h>
#include <stdint.h>
#include "ReadyHostedGameProtocol.h"
#include "RHGPerformance.h"
typedef struct RHGHostOpaque *RHGHostRef;
typedef void (*RHGHostFirstFrameCallback)(void *context);
/* All calls except copy-metrics are on the main thread. Window/view are AppKit
 * object pointers, never copied/reparented between processes. */
RHGHostRef RHGHostCreate(void *window, bool metalHUD, const char *expectedExecutable, const char *diagnosticPath);
void *RHGHostGetView(RHGHostRef host);
const char *RHGHostService(RHGHostRef host);
const char *RHGHostNonce(RHGHostRef host);
void RHGHostSetFirstFrameCallback(RHGHostRef host, void *context, RHGHostFirstFrameCallback callback);
/* Physical pointer ownership remains in Ready. Enable only for the active
 * hosted session; focus/Space/console loss releases independently of guest IPC. */
void RHGHostSetPointerEnabled(RHGHostRef host, bool enabled);
/* In-window overlay gates guest input and releases only this host's pointer. */
void RHGHostSetOverlayVisible(RHGHostRef host, bool visible);
bool RHGHostPointerCaptured(RHGHostRef host);
void RHGHostStop(RHGHostRef host);
void RHGHostDestroy(RHGHostRef host);
void RHGHostResize(RHGHostRef host);
uint32_t RHGHostWindowNumber(RHGHostRef host);
int32_t RHGHostGuestPID(RHGHostRef host);
#endif
