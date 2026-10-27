/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdint.h>
#include <stddef.h>
typedef uint32_t DWORD; typedef int32_t HRESULT; typedef uint16_t WCHAR;
typedef void *HANDLE; typedef void *HMODULE;
typedef struct { uint32_t d1; uint16_t d2,d3; uint8_t d4[8]; } GUID;
typedef struct IUnknown IUnknown;
struct IUnknown { void **vtable; };
#define WINAPI __stdcall
#define IMPORT __declspec(dllimport)
#define SUCCEEDED(hr) ((hr)>=0)
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define D3D_FEATURE_LEVEL_11_0 0xb000
#define D3D_DRIVER_TYPE_HARDWARE 1
#define D3D11_SDK_VERSION 7
IMPORT HANDLE WINAPI GetStdHandle(DWORD);
IMPORT int WINAPI WriteFile(HANDLE,const void *,DWORD,DWORD *,void *);
IMPORT void WINAPI ExitProcess(DWORD);
IMPORT DWORD WINAPI GetCurrentProcessId(void);
IMPORT WCHAR *WINAPI GetCommandLineW(void);
IMPORT HMODULE WINAPI LoadLibraryW(const WCHAR *);
IMPORT void *WINAPI GetProcAddress(HMODULE,const char *);
IMPORT int WINAPI FreeLibrary(HMODULE);
static void release(IUnknown *p) { if(p)((uint32_t (WINAPI *)(IUnknown *))p->vtable[2])(p); }
typedef struct {uint32_t bytes,usage,bind,cpu,misc,stride;} BufferDesc;
typedef struct {const void *data;uint32_t pitch,slice;} InitialData;
typedef struct {void *data;uint32_t rowPitch,depthPitch;} MappedData;
static int bufferProbe(IUnknown *device,IUnknown *context) {
    static uint32_t pattern[1024];for(unsigned i=0;i<1024;i++)pattern[i]=0x17c0ffeeu^i;
    BufferDesc sourceDesc={4096,0,0,0,0,0},readDesc={4096,3,0,0x20000,0,0};
    InitialData initial={pattern,0,0};IUnknown *source=NULL,*readback=NULL;
    typedef HRESULT (WINAPI *CreateBuffer)(IUnknown *,const BufferDesc *,const InitialData *,IUnknown **);
    CreateBuffer create=(CreateBuffer)device->vtable[3];
    HRESULT hr=create(device,&sourceDesc,&initial,&source);if(!SUCCEEDED(hr))return 0;
    hr=create(device,&readDesc,NULL,&readback);if(!SUCCEEDED(hr)){release(source);return 0;}
    typedef void (WINAPI *CopyResource)(IUnknown *,IUnknown *,IUnknown *);
    ((CopyResource)context->vtable[47])(context,readback,source);
    MappedData mapped;typedef HRESULT (WINAPI *Map)(IUnknown *,IUnknown *,uint32_t,uint32_t,uint32_t,MappedData *);
    hr=((Map)context->vtable[14])(context,readback,0,1,0,&mapped);
    int valid=SUCCEEDED(hr);
    if(valid){for(unsigned i=0;i<1024;i++)if(((uint32_t *)mapped.data)[i]!=pattern[i])valid=0;typedef void (WINAPI *Unmap)(IUnknown *,IUnknown *,uint32_t);((Unmap)context->vtable[15])(context,readback,0);}
    release(readback);release(source);return valid;
}

static void out(const char *s) { DWORD written; DWORD n=0;while(s[n])n++;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,n,&written,NULL); }
static void hex(HRESULT value) { char b[11]="0x00000000";const char *digits="0123456789abcdef";for(int i=0;i<8;i++)b[9-i]=digits[((unsigned)value>>(i*4))&15];out(b); }
static int contains(const WCHAR *s,const WCHAR *needle) {for(;*s;s++){unsigned i=0;while(needle[i]&&s[i]==needle[i])i++;if(!needle[i])return 1;}return 0;}

void mainCRTStartup(void) {
    if(contains(GetCommandLineW(),L"dx12")) {
        HMODULE module=LoadLibraryW(L"d3d12.dll");
        if(!module){out("{\"api\":\"dx12\",\"deviceCreated\":false,\"reason\":\"LoadLibrary failed\"}\n");ExitProcess(2);}
        typedef HRESULT (WINAPI *Create)(IUnknown *,uint32_t,const GUID *,void **);
        Create create=(Create)GetProcAddress(module,"D3D12CreateDevice");
        if(!create){out("{\"api\":\"dx12\",\"deviceCreated\":false,\"reason\":\"entry point missing\"}\n");ExitProcess(2);}
        static const GUID iid={0x189819f1,0x1db6,0x4b57,{0xbe,0x54,0x18,0x21,0x33,0x9b,0x85,0xf7}};
        IUnknown *device=NULL;HRESULT hr=create(NULL,D3D_FEATURE_LEVEL_11_0,&iid,(void **)&device);
        out("{\"api\":\"dx12\",\"hresult\":\"");hex(hr);out("\",\"deviceCreated\":");out(SUCCEEDED(hr)?"true":"false");out("}\n");
        release(device);FreeLibrary(module);ExitProcess(SUCCEEDED(hr)?0:3);
    }
    if(contains(GetCommandLineW(),L"dx11")) {
        HMODULE module=LoadLibraryW(L"d3d11.dll");
        if(!module){out("{\"api\":\"dx11\",\"deviceCreated\":false,\"reason\":\"LoadLibrary failed\"}\n");ExitProcess(2);}
        typedef HRESULT (WINAPI *Create)(void *,uint32_t,HMODULE,uint32_t,const uint32_t *,uint32_t,uint32_t,IUnknown **,uint32_t *,IUnknown **);
        Create create=(Create)GetProcAddress(module,"D3D11CreateDevice");
        if(!create){out("{\"api\":\"dx11\",\"deviceCreated\":false,\"reason\":\"entry point missing\"}\n");ExitProcess(2);}
        IUnknown *device=NULL,*context=NULL;uint32_t level;
        HRESULT hr=create(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,&device,&level,&context);
        int readback=SUCCEEDED(hr)?bufferProbe(device,context):0;
        out("{\"api\":\"dx11\",\"hresult\":\"");hex(hr);out("\",\"featureLevel\":\"");hex((HRESULT)level);out("\",\"deviceCreated\":");out(SUCCEEDED(hr)?"true":"false");out(",\"gpuBufferReadbackVerified\":");out(readback?"true":"false");out("}\n");
        release(context);release(device);FreeLibrary(module);ExitProcess(SUCCEEDED(hr)&&readback?0:3);
    }
    out("{\"api\":\"win32\",\"pointerBits\":64,\"processId\":");
    DWORD pid=GetCurrentProcessId();char b[12];int i=0;do{b[i++]=(char)('0'+pid%10);pid/=10;}while(pid);for(int j=i-1;j>=0;j--){char c[2]={b[j],0};out(c);}out("}\n");
    ExitProcess(0);
}
