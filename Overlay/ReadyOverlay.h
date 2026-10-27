// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Diagnostics are deliberately narrow: no process-memory scanning or driver hooks.
// The caller owns the returned UTF-8 allocation and frees it with free().
char *ReadyOverlayCopyStatusJSON(void);
void ReadyOverlaySetStateForTesting(int visible, int selection);
#ifdef __cplusplus
}
#endif
