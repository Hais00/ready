/* SPDX-License-Identifier: GPL-3.0-only */
/* Deterministic RAW device provider. Test variant only; never shipped as input. */
#define _ACRTIMP
#include <windows.h>
#include <xinput.h>
static SRWLOCK lock=SRWLOCK_INIT;
static XINPUT_STATE states[4];
static BOOL connected[4];
struct stats {DWORD calls;XINPUT_VIBRATION vibration;};
static struct stats values[4];
DWORD WINAPI ReadyTestSeed(DWORD index,const XINPUT_STATE *state,BOOL present){if(index>=4||!state)return ERROR_BAD_ARGUMENTS;AcquireSRWLockExclusive(&lock);states[index]=*state;connected[index]=present;ReleaseSRWLockExclusive(&lock);return 0;}
DWORD WINAPI ReadyTestGetState(DWORD index,XINPUT_STATE *state){if(index>=4||!state)return ERROR_BAD_ARGUMENTS;AcquireSRWLockShared(&lock);DWORD ret=connected[index]?0:ERROR_DEVICE_NOT_CONNECTED;if(!ret)*state=states[index];ReleaseSRWLockShared(&lock);return ret;}
DWORD WINAPI ReadyTestSetState(DWORD index,XINPUT_VIBRATION *state){if(index>=4||!state)return ERROR_BAD_ARGUMENTS;AcquireSRWLockExclusive(&lock);DWORD ret=connected[index]?0:ERROR_DEVICE_NOT_CONNECTED;if(!ret){values[index].calls++;values[index].vibration=*state;}ReleaseSRWLockExclusive(&lock);return ret;}
DWORD WINAPI ReadyTestStats(DWORD index,struct stats *out){if(index>=4||!out)return ERROR_BAD_ARGUMENTS;AcquireSRWLockShared(&lock);*out=values[index];ReleaseSRWLockShared(&lock);return 0;}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,void *reserved){(void)module;(void)reason;(void)reserved;return TRUE;}
