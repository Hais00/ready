/* SPDX-License-Identifier: GPL-3.0-only */
/* Production-provider environment/module observation plus the unchanged Vulkan fixture. */
#define mainCRTStartup ready_graphics_fixture_entry
#ifdef READY_CONTROLLER_DXMT
#include "runtime_d3d11_present.c"
#else
#include "runtime_vulkan_present.c"
#endif
#undef mainCRTStartup
IMPORT DWORD __stdcall GetEnvironmentVariableA(const char *,char *,DWORD);
IMPORT DWORD __stdcall GetModuleFileNameA(void *,char *,DWORD);
IMPORT void *__stdcall GetModuleHandleA(const char *);
IMPORT void *__stdcall GetStdHandle(DWORD);
IMPORT int __stdcall WriteFile(void *,const void *,DWORD,DWORD *,void *);
IMPORT void __stdcall Sleep(DWORD);
IMPORT void *__stdcall CreateThread(void *,size_t,DWORD (__stdcall *)(void *),void *,DWORD,DWORD *);
typedef DWORD (__stdcall *KeyFn)(DWORD,DWORD,void *);
_Static_assert(sizeof(void *)==8,"Production controller policy fixture must be PE64");
static KeyFn input_key;
static char record[8192];static unsigned used;
static void text(const char *s){while(*s&&used+1<sizeof(record))record[used++]=*s++;}
static void quoted(const char *s){text("\"");for(;*s;s++){char b[2]={*s,0};if(*s=='\\'||*s=='\"')text("\\");if((unsigned char)*s>=32)text(b);}text("\"");}
static DWORD __stdcall poll_input(void *unused){(void)unused;for(;;){unsigned char stroke[16]={0};if(input_key)input_key(0,0,stroke);Sleep(25);}return 0;}
void mainCRTStartup(void)
{
    static char flag[32],overrides[2048],module_path[4096];
    GetEnvironmentVariableA("M1L_XINPUT_CAPTURE",flag,sizeof(flag)-1);
    GetEnvironmentVariableA("WINEDLLOVERRIDES",overrides,sizeof(overrides)-1);
    void *module=LoadLibraryA("xinput1_4.dll");
    if(module){GetModuleFileNameA(module,module_path,sizeof(module_path)-1);input_key=(KeyFn)GetProcAddress(module,"XInputGetKeystroke");}
    DWORD (__stdcall *private_marker)(void)=module?(void *)GetProcAddress(module,"ReadyPrivateXInputMarker"):NULL;
    unsigned char stroke[16]={0};DWORD key_result=input_key?input_key(0,0,stroke):0xffffffffu;
    text("{\"controllerPolicyProbe\":true,\"pointerBits\":64,\"captureFlag\":");quoted(flag);
    text(",\"dllOverrides\":");quoted(overrides);text(",\"xinputModulePath\":");quoted(module_path);
    text(",\"privateDLLLoaded\":");text(private_marker&&private_marker()==0x50524956u?"true":"false");
    text(",\"testBackendExportPresent\":");text(module&&GetProcAddress(module,"ReadyInputTestCapture")?"true":"false");
    text(",\"testDeviceBackendLoaded\":");text(GetModuleHandleA("ready-test-device.dll")?"true":"false");
    text(",\"xinputKeyCallMade\":");text(key_result!=0xffffffffu?"true":"false");text("}\n");
    DWORD written;WriteFile(GetStdHandle((DWORD)-11),record,used,&written,NULL);
    if(input_key)CreateThread(NULL,0,poll_input,NULL,0,NULL);
    ready_graphics_fixture_entry();
}
