/* SPDX-License-Identifier: GPL-3.0-only */
/* Original Vulkan present fixture, used as a thread only in the synthetic input test. */
#include "runtime_vulkan_present.c"
int __stdcall DllMain(void *module,uint32_t reason,void *reserved){(void)module;(void)reason;(void)reserved;return 1;}
__declspec(dllexport) DWORD __stdcall ReadyPresentThread(void *argument){(void)argument;return (DWORD)run();}
