/* SPDX-License-Identifier: GPL-3.0-only */
/* Bounded Windows D3D12 shader/swapchain probe. No direct-display assertion. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define INITGUID
#define _ACRTIMP
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <stdint.h>
#include <stddef.h>
int _fltused;
void *memcpy(void *d,const void *s,size_t n){unsigned char *o=d;const unsigned char *i=s;for(size_t k=0;k<n;k++)o[k]=i[k];return d;}
void *memset(void *d,int v,size_t n){unsigned char *o=d;for(size_t k=0;k<n;k++)o[k]=(unsigned char)v;return d;}
static void output(const char *s){DWORD n=0,w;while(s[n])n++;WriteFile(GetStdHandle((DWORD)-11),s,n,&w,NULL);}
static void number(unsigned n){char b[12];unsigned i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i){char c[2]={b[--i],0};output(c);}}
static void fail(const char *stage,HRESULT hr){const char *digits="0123456789abcdef";char h[11]="0x00000000";for(unsigned i=0;i<8;i++)h[9-i]=digits[((unsigned)hr>>(i*4))&15];output("{\"stage\":\"");output(stage);output("\",\"hresult\":\"");output(h);output("\",\"verified\":false}\n");ExitProcess(3);}
#define CHECK(s,e) do{HRESULT ready_hr=(e);if(FAILED(ready_hr))fail(s,ready_hr);}while(0)
static LRESULT CALLBACK window_proc(HWND h,UINT m,WPARAM w,LPARAM l){if(m==WM_CLOSE){DestroyWindow(h);return 0;}if(m==WM_DESTROY){PostQuitMessage(0);return 0;}return DefWindowProcW(h,m,w,l);}
static void pipeline(ID3D12Device *device,ID3D12RootSignature **root,ID3D12PipelineState **state,HMODULE library){
    HMODULE compiler_library=LoadLibraryW(L"d3dcompiler_47.dll");if(!compiler_library)fail("LoadShaderCompiler",(HRESULT)0x8007007e);
    typedef HRESULT(WINAPI *Compile)(const void *,SIZE_T,const char *,const D3D_SHADER_MACRO *,ID3DInclude *,const char *,const char *,UINT,UINT,ID3DBlob **,ID3DBlob **);
    typedef HRESULT(WINAPI *Serialize)(const D3D12_ROOT_SIGNATURE_DESC *,D3D_ROOT_SIGNATURE_VERSION,ID3DBlob **,ID3DBlob **);
    Compile compile=(Compile)GetProcAddress(compiler_library,"D3DCompile");Serialize serialize=(Serialize)GetProcAddress(library,"D3D12SerializeRootSignature");if(!compile||!serialize)fail("ShaderEntryPoints",(HRESULT)0x8007007f);
    static const char hlsl[]="float4 vs(uint id:SV_VertexID):SV_Position{float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)};return float4(p[id],0,1);}float4 ps():SV_Target{return float4(0.035,0.09,0.15,1);}";
    ID3DBlob *vs=NULL,*ps=NULL,*signature=NULL,*error=NULL;CHECK("CompileVS",compile(hlsl,sizeof(hlsl)-1,"ready-dx12-present",NULL,NULL,"vs","vs_5_0",0,0,&vs,&error));if(error){ID3D10Blob_Release(error);error=NULL;}
    CHECK("CompilePS",compile(hlsl,sizeof(hlsl)-1,"ready-dx12-present",NULL,NULL,"ps","ps_5_0",0,0,&ps,&error));if(error){ID3D10Blob_Release(error);error=NULL;}
    D3D12_ROOT_SIGNATURE_DESC rd={0};rd.Flags=D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;CHECK("SerializeRoot",serialize(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&signature,&error));if(error)ID3D10Blob_Release(error);
    CHECK("CreateRoot",ID3D12Device_CreateRootSignature(device,0,ID3D10Blob_GetBufferPointer(signature),ID3D10Blob_GetBufferSize(signature),&IID_ID3D12RootSignature,(void **)root));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC p={0};p.pRootSignature=*root;p.VS.pShaderBytecode=ID3D10Blob_GetBufferPointer(vs);p.VS.BytecodeLength=ID3D10Blob_GetBufferSize(vs);p.PS.pShaderBytecode=ID3D10Blob_GetBufferPointer(ps);p.PS.BytecodeLength=ID3D10Blob_GetBufferSize(ps);p.SampleMask=~0u;
    D3D12_RENDER_TARGET_BLEND_DESC *b=&p.BlendState.RenderTarget[0];b->SrcBlend=D3D12_BLEND_ONE;b->DestBlend=D3D12_BLEND_ZERO;b->BlendOp=D3D12_BLEND_OP_ADD;b->SrcBlendAlpha=D3D12_BLEND_ONE;b->DestBlendAlpha=D3D12_BLEND_ZERO;b->BlendOpAlpha=D3D12_BLEND_OP_ADD;b->LogicOp=D3D12_LOGIC_OP_NOOP;b->RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
    p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;p.RasterizerState.DepthClipEnable=TRUE;p.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_ALWAYS;p.DepthStencilState.StencilReadMask=0xff;p.DepthStencilState.StencilWriteMask=0xff;p.DepthStencilState.FrontFace.StencilFailOp=D3D12_STENCIL_OP_KEEP;p.DepthStencilState.FrontFace.StencilDepthFailOp=D3D12_STENCIL_OP_KEEP;p.DepthStencilState.FrontFace.StencilPassOp=D3D12_STENCIL_OP_KEEP;p.DepthStencilState.FrontFace.StencilFunc=D3D12_COMPARISON_FUNC_ALWAYS;p.DepthStencilState.BackFace=p.DepthStencilState.FrontFace;
    p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;p.NumRenderTargets=1;p.RTVFormats[0]=DXGI_FORMAT_B8G8R8A8_UNORM;p.SampleDesc.Count=1;CHECK("CreatePipeline",ID3D12Device_CreateGraphicsPipelineState(device,&p,&IID_ID3D12PipelineState,(void **)state));
    ID3D10Blob_Release(signature);ID3D10Blob_Release(ps);ID3D10Blob_Release(vs);FreeLibrary(compiler_library);
}
static void barrier(ID3D12GraphicsCommandList *list,ID3D12Resource *r,D3D12_RESOURCE_STATES from,D3D12_RESOURCE_STATES to){D3D12_RESOURCE_BARRIER b={0};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition.pResource=r;b.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;b.Transition.StateBefore=from;b.Transition.StateAfter=to;ID3D12GraphicsCommandList_ResourceBarrier(list,1,&b);}
void mainCRTStartup(void){
    HINSTANCE instance=GetModuleHandleW(NULL);WNDCLASSW wc={0};wc.lpfnWndProc=window_proc;wc.hInstance=instance;wc.lpszClassName=L"ReadyD3D12Present";if(!RegisterClassW(&wc))fail("RegisterWindow",(HRESULT)0x80004005);
    HWND window=CreateWindowExW(0,wc.lpszClassName,L"Ready · D3D12 local evaluation presentation",WS_OVERLAPPEDWINDOW,100,100,960,600,NULL,NULL,instance,NULL);if(!window)fail("CreateWindow",(HRESULT)0x80004005);ShowWindow(window,SW_SHOW);UpdateWindow(window);
    HMODULE d3d=LoadLibraryW(L"d3d12.dll"),dxgi=LoadLibraryW(L"dxgi.dll");if(!d3d||!dxgi)fail("LoadD3D12DXGI",(HRESULT)0x8007007e);
    typedef HRESULT(WINAPI *CreateDevice)(IUnknown *,D3D_FEATURE_LEVEL,REFIID,void **);typedef HRESULT(WINAPI *CreateFactory)(UINT,REFIID,void **);
    CreateDevice create_device=(CreateDevice)GetProcAddress(d3d,"D3D12CreateDevice");CreateFactory create_factory=(CreateFactory)GetProcAddress(dxgi,"CreateDXGIFactory2");if(!create_device||!create_factory)fail("CreateEntryPoints",(HRESULT)0x8007007f);
    ID3D12Device *device=NULL;ID3D12CommandQueue *queue=NULL;ID3D12CommandAllocator *allocator=NULL;ID3D12GraphicsCommandList *list=NULL;ID3D12Fence *fence=NULL;ID3D12DescriptorHeap *heap=NULL;ID3D12RootSignature *root=NULL;ID3D12PipelineState *state=NULL;IDXGIFactory2 *factory=NULL;IDXGISwapChain1 *swap1=NULL;IDXGISwapChain3 *swap=NULL;ID3D12Resource *buffers[2]={NULL,NULL};
    CHECK("CreateDevice",create_device(NULL,D3D_FEATURE_LEVEL_11_0,&IID_ID3D12Device,(void **)&device));D3D12_COMMAND_QUEUE_DESC q={0};CHECK("CreateQueue",ID3D12Device_CreateCommandQueue(device,&q,&IID_ID3D12CommandQueue,(void **)&queue));CHECK("CreateFactory",create_factory(0,&IID_IDXGIFactory2,(void **)&factory));
    DXGI_SWAP_CHAIN_DESC1 sd={0};sd.Width=960;sd.Height=600;sd.Format=DXGI_FORMAT_B8G8R8A8_UNORM;sd.SampleDesc.Count=1;sd.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;sd.BufferCount=2;sd.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
    CHECK("CreateSwapchain",IDXGIFactory2_CreateSwapChainForHwnd(factory,(IUnknown *)queue,window,&sd,NULL,NULL,&swap1));CHECK("Swapchain3",IDXGISwapChain1_QueryInterface(swap1,&IID_IDXGISwapChain3,(void **)&swap));
    D3D12_DESCRIPTOR_HEAP_DESC hd={D3D12_DESCRIPTOR_HEAP_TYPE_RTV,2,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};CHECK("CreateRTVHeap",ID3D12Device_CreateDescriptorHeap(device,&hd,&IID_ID3D12DescriptorHeap,(void **)&heap));D3D12_CPU_DESCRIPTOR_HANDLE handles[2];handles[0]=ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);handles[1].ptr=handles[0].ptr+ID3D12Device_GetDescriptorHandleIncrementSize(device,D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    for(UINT i=0;i<2;i++){CHECK("GetBackBuffer",IDXGISwapChain3_GetBuffer(swap,i,&IID_ID3D12Resource,(void **)&buffers[i]));ID3D12Device_CreateRenderTargetView(device,buffers[i],NULL,handles[i]);}
    pipeline(device,&root,&state,d3d);CHECK("CreateAllocator",ID3D12Device_CreateCommandAllocator(device,D3D12_COMMAND_LIST_TYPE_DIRECT,&IID_ID3D12CommandAllocator,(void **)&allocator));CHECK("CreateList",ID3D12Device_CreateCommandList(device,0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator,state,&IID_ID3D12GraphicsCommandList,(void **)&list));CHECK("InitialClose",ID3D12GraphicsCommandList_Close(list));CHECK("CreateFence",ID3D12Device_CreateFence(device,0,D3D12_FENCE_FLAG_NONE,&IID_ID3D12Fence,(void **)&fence));HANDLE event=CreateEventW(NULL,FALSE,FALSE,NULL);if(!event)fail("CreateEvent",(HRESULT)0x80004005);
    unsigned presented=0,occluded=0,submitted=0;int running=1;UINT64 fence_value=0;
    for(unsigned attempt=0;attempt<600&&running;attempt++){
        MSG message;while(PeekMessageW(&message,NULL,0,0,PM_REMOVE)){if(message.message==WM_QUIT){running=0;break;}TranslateMessage(&message);DispatchMessageW(&message);}if(!running)break;
        UINT index=IDXGISwapChain3_GetCurrentBackBufferIndex(swap);if(index>=2)fail("BackBufferIndex",(HRESULT)0x80004005);CHECK("ResetAllocator",ID3D12CommandAllocator_Reset(allocator));CHECK("ResetList",ID3D12GraphicsCommandList_Reset(list,allocator,state));barrier(list,buffers[index],D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_RENDER_TARGET);
        const float black[4]={0,0,0,1};ID3D12GraphicsCommandList_ClearRenderTargetView(list,handles[index],black,0,NULL);ID3D12GraphicsCommandList_OMSetRenderTargets(list,1,&handles[index],FALSE,NULL);ID3D12GraphicsCommandList_SetGraphicsRootSignature(list,root);D3D12_VIEWPORT vp={0,0,960,600,0,1};D3D12_RECT sc={0,0,960,600};ID3D12GraphicsCommandList_RSSetViewports(list,1,&vp);ID3D12GraphicsCommandList_RSSetScissorRects(list,1,&sc);ID3D12GraphicsCommandList_IASetPrimitiveTopology(list,D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);ID3D12GraphicsCommandList_DrawInstanced(list,3,1,0,0);barrier(list,buffers[index],D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PRESENT);CHECK("CloseList",ID3D12GraphicsCommandList_Close(list));ID3D12CommandList *lists[]={(ID3D12CommandList *)list};ID3D12CommandQueue_ExecuteCommandLists(queue,1,lists);submitted++;
        CHECK("SignalFence",ID3D12CommandQueue_Signal(queue,fence,++fence_value));CHECK("FenceEvent",ID3D12Fence_SetEventOnCompletion(fence,fence_value,event));if(WaitForSingleObject(event,15000)!=WAIT_OBJECT_0)fail("WaitGPU",(HRESULT)0x800705b4);
        HRESULT hr=IDXGISwapChain3_Present(swap,1,0);if(FAILED(hr))fail("Present",hr);if(hr==S_OK)presented++;else occluded++;Sleep(16);
    }
    output("{\"api\":\"d3d12\",\"featureLevelRequested\":\"0x0000b000\",\"submittedShaderFrames\":");number(submitted);output(",\"presentedFrames\":");number(presented);output(",\"occludedPresents\":");number(occluded);output(",\"framePacingSleepMS\":16,\"directToDisplayVerified\":false}\n");
    CloseHandle(event);ID3D12Fence_Release(fence);ID3D12GraphicsCommandList_Release(list);ID3D12CommandAllocator_Release(allocator);ID3D12PipelineState_Release(state);ID3D12RootSignature_Release(root);for(UINT i=0;i<2;i++)ID3D12Resource_Release(buffers[i]);ID3D12DescriptorHeap_Release(heap);IDXGISwapChain3_Release(swap);IDXGISwapChain1_Release(swap1);IDXGIFactory2_Release(factory);ID3D12CommandQueue_Release(queue);ID3D12Device_Release(device);DestroyWindow(window);FreeLibrary(dxgi);FreeLibrary(d3d);ExitProcess(presented>=60?0:4);
}
