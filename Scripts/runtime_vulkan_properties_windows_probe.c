/* SPDX-License-Identifier: GPL-3.0-only
 * Windows PE64 entry for the EXACT same public-header property chain as the native
 * probe. Win32 declarations come from Wine's public Windows headers; Vulkan
 * functions use the stock headers' VKAPI_PTR/Windows calling convention.
 */
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#define READY_PROPERTIES_WINDOWS
#define main ready_properties_main
#include "runtime_vulkan_properties_probe.c"
#undef main
void mainCRTStartup(void){
    char mode[128];DWORD length=GetEnvironmentVariableA("READY_PROPERTIES_CASE",mode,sizeof(mode));
    if(!length || length>=sizeof(mode))ExitProcess(64);
    char *arguments[]={"ReadyVulkanPropertiesWindowsProbe","vulkan-1.dll",mode,NULL};
    int result=ready_properties_main(3,arguments);
    fflush(NULL);
    ExitProcess((UINT)result);
}
