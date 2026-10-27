/* SPDX-License-Identifier: GPL-3.0-only */
/* A freestanding Windows D3D11 swapchain probe; requires actual feature level 11_0. */
#include <stdint.h>
#include <stddef.h>
typedef void *HWND;typedef void *HINSTANCE;typedef uint32_t DWORD;typedef uint16_t WCHAR;typedef int32_t HRESULT;
typedef struct IUnknown IUnknown;struct IUnknown{void **vtable;};
typedef struct {uint32_t a;uint16_t b,c;uint8_t d[8];} GUID;
typedef intptr_t (__stdcall *WndProc)(HWND,uint32_t,uintptr_t,intptr_t);
#define IMPORT __declspec(dllimport)
IMPORT void *__stdcall GetModuleHandleW(const WCHAR *);
IMPORT void *__stdcall LoadLibraryA(const char *);
IMPORT void *__stdcall GetProcAddress(void *,const char *);
IMPORT const WCHAR *__stdcall GetCommandLineW(void);
IMPORT void __stdcall ExitProcess(DWORD);
IMPORT int __cdecl printf(const char *,...);
struct WindowClass{uint32_t style;WndProc proc;int clsExtra,wndExtra;HINSTANCE instance;void *icon,*cursor,*background;const WCHAR *menu,*name;};
struct Message{HWND hwnd;uint32_t message;uintptr_t wparam;intptr_t lparam;uint32_t time;int x,y;uint32_t privateValue;};
IMPORT uint16_t __stdcall RegisterClassW(const struct WindowClass *);
IMPORT HWND __stdcall CreateWindowExW(DWORD,const WCHAR *,const WCHAR *,DWORD,int,int,int,int,HWND,void *,HINSTANCE,void *);
IMPORT intptr_t __stdcall DefWindowProcW(HWND,uint32_t,uintptr_t,intptr_t);
IMPORT int __stdcall ShowWindow(HWND,int);
IMPORT int __stdcall UpdateWindow(HWND);
IMPORT int __stdcall PeekMessageW(struct Message *,HWND,uint32_t,uint32_t,uint32_t);
IMPORT int __stdcall TranslateMessage(const struct Message *);
IMPORT intptr_t __stdcall DispatchMessageW(const struct Message *);
IMPORT int __stdcall DestroyWindow(HWND);
IMPORT void __stdcall PostQuitMessage(int);
int _fltused=0;
static intptr_t __stdcall windowProc(HWND hwnd,uint32_t msg,uintptr_t wp,intptr_t lp){if(msg==0x10){DestroyWindow(hwnd);return 0;}if(msg==2){PostQuitMessage(0);return 0;}return DefWindowProcW(hwnd,msg,wp,lp);}
static int contains(const WCHAR *s,const WCHAR *needle){for(;*s;s++){unsigned i=0;while(needle[i]&&s[i]==needle[i])i++;if(!needle[i])return 1;}return 0;}
static void release(IUnknown *p){if(p)((uint32_t (__stdcall *)(IUnknown *))p->vtable[2])(p);}
struct ModeDesc{uint32_t width,height,refreshN,refreshD,format,scanline,scaling;};
struct SwapDesc{struct ModeDesc mode;uint32_t samples,quality,usage,count;HWND window;int windowed;uint32_t swap,flags;};
typedef HRESULT (__stdcall *CreateDeviceSwap)(void *,uint32_t,void *,uint32_t,const uint32_t *,uint32_t,uint32_t,const struct SwapDesc *,IUnknown **,IUnknown **,uint32_t *,IUnknown **);

static int run(void){
    HINSTANCE module=GetModuleHandleW(NULL);struct WindowClass cls={0x20,windowProc,0,0,module,NULL,NULL,NULL,NULL,L"ReadyD3D11Probe"};
    if(!RegisterClassW(&cls))return 1;HWND hwnd=CreateWindowExW(0,L"ReadyD3D11Probe",L"Ready · Windows D3D11 Metal presentation probe",0x00cf0000,100,100,960,600,NULL,NULL,module,NULL);
    if(!hwnd)return 1;ShowWindow(hwnd,5);UpdateWindow(hwnd);
    void *dll=LoadLibraryA("d3d11.dll");if(!dll){printf("D3D11 library not loaded\n");return 2;}
    CreateDeviceSwap create=(CreateDeviceSwap)GetProcAddress(dll,"D3D11CreateDeviceAndSwapChain");if(!create)return 2;
    uint32_t requested=0xb000,level=0;struct SwapDesc desc={{0,0,60,1,87,0,0},1,0,0x20,2,hwnd,1,0,0};IUnknown *swap=NULL,*device=NULL,*context=NULL;
    HRESULT hr=create(NULL,1,NULL,0x20,&requested,1,7,&desc,&swap,&device,&level,&context);
    if(hr<0){printf("{\"stage\":\"D3D11CreateDeviceAndSwapChain\",\"hresult\":\"0x%08x\",\"featureLevel\":\"0x%08x\"}\n",(unsigned)hr,level);return 3;}
    static const GUID textureIID={0x6f15aaf2,0xd208,0x4e89,{0x9a,0xb4,0x48,0x95,0x35,0xd3,0x4f,0x9c}};
    typedef HRESULT (__stdcall *GetBuffer)(IUnknown *,uint32_t,const GUID *,IUnknown **);
    typedef HRESULT (__stdcall *CreateRTV)(IUnknown *,IUnknown *,void *,IUnknown **);
    IUnknown *texture=NULL,*view=NULL;hr=((GetBuffer)swap->vtable[9])(swap,0,&textureIID,&texture);
    if(hr>=0)hr=((CreateRTV)device->vtable[9])(device,texture,NULL,&view);release(texture);
    if(hr<0){printf("{\"stage\":\"CreateRenderTarget\",\"hresult\":\"0x%08x\"}\n",(unsigned)hr);return 3;}
    typedef HRESULT (__stdcall *SetFullscreen)(IUnknown *,int,void *);typedef HRESULT (__stdcall *Present)(IUnknown *,uint32_t,uint32_t);typedef void (__stdcall *Clear)(IUnknown *,IUnknown *,const float *);
    int fullscreen=contains(GetCommandLineW(),L"--fullscreen");if(fullscreen)((SetFullscreen)swap->vtable[10])(swap,1,NULL);
    uint32_t frame=0;int running=1;for(;frame<600&&running;frame++){
        struct Message message;while(PeekMessageW(&message,NULL,0,0,1)){if(message.message==0x12){running=0;break;}TranslateMessage(&message);DispatchMessageW(&message);}if(!running)break;
        float color[4]={0.035f,0.09f,0.15f,1.0f};((Clear)context->vtable[50])(context,view,color);hr=((Present)swap->vtable[8])(swap,1,0);
        if(hr<0){printf("{\"stage\":\"Present\",\"hresult\":\"0x%08x\"}\n",(unsigned)hr);break;}
    }
    if(fullscreen)((SetFullscreen)swap->vtable[10])(swap,0,NULL);
    printf("{\"api\":\"d3d11\",\"featureLevel\":\"0x%08x\",\"presentedFrames\":%u,\"fullscreenRequested\":%s,\"directToDisplayVerified\":false}\n",level,frame,fullscreen?"true":"false");
    release(view);release(context);release(swap);release(device);DestroyWindow(hwnd);return frame>=60&&level>=0xb000?0:4;
}
void mainCRTStartup(void){ExitProcess((DWORD)run());}
