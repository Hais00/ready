/* SPDX-License-Identifier: GPL-3.0-only */
/* Test-only PE entry point: RAW XInput stub and a real Vulkan presenter share one process. */
#define mainCRTStartup ready_xinput_entry
#include "runtime_xinput_probe.c"
#undef mainCRTStartup
int mainCRTStartup(void){
    static WCHAR path[4096];
    GetEnvironmentVariableW(L"M1L_XINPUT_PRESENT_PROVIDER",path,4096);
    HMODULE module=LoadLibraryW(path);
    LPTHREAD_START_ROUTINE entry=module?(void *)GetProcAddress(module,"ReadyPresentThread"):NULL;
    if(!entry||!CreateThread(NULL,0,entry,NULL,0,NULL))ExitProcess(3);
    return ready_xinput_entry();
}
