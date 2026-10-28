/* SPDX-License-Identifier: GPL-3.0-only */
/* App-local DLL fixture only. It never synthesizes a controller or edits Wine. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,void *reserved){(void)module;(void)reason;(void)reserved;return TRUE;}
__declspec(dllexport) DWORD WINAPI ReadyPrivateXInputMarker(void){return 0x50524956u;}
__declspec(dllexport) DWORD WINAPI XInputGetKeystroke(DWORD index,DWORD reserved,XINPUT_KEYSTROKE *key){(void)index;(void)reserved;(void)key;return ERROR_DEVICE_NOT_CONNECTED;}
__declspec(dllexport) DWORD WINAPI XInputGetState(DWORD index,XINPUT_STATE *state){(void)index;(void)state;return ERROR_DEVICE_NOT_CONNECTED;}
__declspec(dllexport) DWORD WINAPI XInputSetState(DWORD index,XINPUT_VIBRATION *vibration){(void)index;(void)vibration;return ERROR_DEVICE_NOT_CONNECTED;}
