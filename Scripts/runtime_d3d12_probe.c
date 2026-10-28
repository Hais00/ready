/* SPDX-License-Identifier: GPL-3.0-only */
/* Freestanding PE64: real D3D12 queue copies and render-target clear/readback. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define INITGUID
#define _ACRTIMP
#include <windows.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <stdint.h>
#include <stddef.h>

int _fltused;
void *memcpy(void *target,const void *source,size_t count){unsigned char *d=target;const unsigned char *s=source;for(size_t i=0;i<count;i++)d[i]=s[i];return target;}
void *memset(void *target,int value,size_t count){unsigned char *d=target;for(size_t i=0;i<count;i++)d[i]=(unsigned char)value;return target;}
static void output(const char *text){DWORD n=0,written;while(text[n])n++;WriteFile(GetStdHandle((DWORD)-11),text,n,&written,NULL);}
static void hexadecimal(HRESULT value){char text[11]="0x00000000";const char *digits="0123456789abcdef";for(unsigned i=0;i<8;i++)text[9-i]=digits[((unsigned)value>>(4*i))&15];output(text);}
static void fail(const char *stage,HRESULT status){output("{\"api\":\"d3d12\",\"stage\":\"");output(stage);output("\",\"hresult\":\"");hexadecimal(status);output("\",\"verified\":false}\n");ExitProcess(3);}
#define CHECK(stage,expression) do{HRESULT ready_status=(expression);if(FAILED(ready_status))fail(stage,ready_status);}while(0)
static D3D12_RESOURCE_DESC buffer_description(UINT64 bytes){D3D12_RESOURCE_DESC desc={0};desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc.Width=bytes;desc.Height=1;desc.DepthOrArraySize=1;desc.MipLevels=1;desc.SampleDesc.Count=1;desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;return desc;}
static void transition(ID3D12GraphicsCommandList *list,ID3D12Resource *resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){D3D12_RESOURCE_BARRIER barrier={0};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;barrier.Transition.pResource=resource;barrier.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;barrier.Transition.StateBefore=before;barrier.Transition.StateAfter=after;ID3D12GraphicsCommandList_ResourceBarrier(list,1,&barrier);}
static void submit(ID3D12CommandQueue *queue,ID3D12GraphicsCommandList *list,ID3D12Fence *fence,HANDLE event,UINT64 value){CHECK("CloseCommandList",ID3D12GraphicsCommandList_Close(list));ID3D12CommandList *lists[]={(ID3D12CommandList *)list};ID3D12CommandQueue_ExecuteCommandLists(queue,1,lists);CHECK("SignalFence",ID3D12CommandQueue_Signal(queue,fence,value));CHECK("FenceEvent",ID3D12Fence_SetEventOnCompletion(fence,value,event));if(WaitForSingleObject(event,15000)!=WAIT_OBJECT_0)fail("WaitForFence",(HRESULT)0x800705b4);}

void mainCRTStartup(void){
    output("READY_DX12_STAGE load_library\n");
    HMODULE library=LoadLibraryW(L"d3d12.dll");if(!library)fail("LoadLibrary",(HRESULT)0x8007007e);
    typedef HRESULT (WINAPI *CreateDevice)(IUnknown *,D3D_FEATURE_LEVEL,REFIID,void **);
    CreateDevice create=(CreateDevice)GetProcAddress(library,"D3D12CreateDevice");if(!create)fail("EntryPoint",(HRESULT)0x8007007f);
    ID3D12Device *device=NULL;ID3D12CommandQueue *queue=NULL;ID3D12CommandAllocator *allocator=NULL;ID3D12GraphicsCommandList *list=NULL;ID3D12Fence *fence=NULL;
    ID3D12Resource *upload=NULL,*gpu=NULL,*readback=NULL,*target=NULL,*pixels=NULL;ID3D12DescriptorHeap *rtv_heap=NULL;
    CHECK("CreateDevice",create(NULL,D3D_FEATURE_LEVEL_11_0,&IID_ID3D12Device,(void **)&device));output("READY_DX12_STAGE device_created\n");
    D3D12_COMMAND_QUEUE_DESC queue_desc={0};CHECK("CreateCommandQueue",ID3D12Device_CreateCommandQueue(device,&queue_desc,&IID_ID3D12CommandQueue,(void **)&queue));
    CHECK("CreateCommandAllocator",ID3D12Device_CreateCommandAllocator(device,D3D12_COMMAND_LIST_TYPE_DIRECT,&IID_ID3D12CommandAllocator,(void **)&allocator));
    CHECK("CreateCommandList",ID3D12Device_CreateCommandList(device,0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator,NULL,&IID_ID3D12GraphicsCommandList,(void **)&list));
    CHECK("CreateFence",ID3D12Device_CreateFence(device,0,D3D12_FENCE_FLAG_NONE,&IID_ID3D12Fence,(void **)&fence));HANDLE event=CreateEventW(NULL,FALSE,FALSE,NULL);if(!event)fail("CreateEvent",(HRESULT)0x80004005);
    D3D12_HEAP_PROPERTIES heap={D3D12_HEAP_TYPE_UPLOAD,D3D12_CPU_PAGE_PROPERTY_UNKNOWN,D3D12_MEMORY_POOL_UNKNOWN,1,1};D3D12_RESOURCE_DESC desc=buffer_description(4096);
    CHECK("CreateUploadBuffer",ID3D12Device_CreateCommittedResource(device,&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_GENERIC_READ,NULL,&IID_ID3D12Resource,(void **)&upload));
    heap.Type=D3D12_HEAP_TYPE_DEFAULT;CHECK("CreateGPUBuffer",ID3D12Device_CreateCommittedResource(device,&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_COPY_DEST,NULL,&IID_ID3D12Resource,(void **)&gpu));
    heap.Type=D3D12_HEAP_TYPE_READBACK;CHECK("CreateReadbackBuffer",ID3D12Device_CreateCommittedResource(device,&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_COPY_DEST,NULL,&IID_ID3D12Resource,(void **)&readback));
    void *mapped=NULL;D3D12_RANGE no_read={0,0},all_bytes={0,4096};CHECK("MapUpload",ID3D12Resource_Map(upload,0,&no_read,&mapped));for(unsigned i=0;i<1024;i++)((uint32_t *)mapped)[i]=0x1793abcdu^i;ID3D12Resource_Unmap(upload,0,&all_bytes);
    ID3D12GraphicsCommandList_CopyBufferRegion(list,gpu,0,upload,0,4096);transition(list,gpu,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_COPY_SOURCE);ID3D12GraphicsCommandList_CopyBufferRegion(list,readback,0,gpu,0,4096);submit(queue,list,fence,event,1);
    CHECK("MapReadback",ID3D12Resource_Map(readback,0,&all_bytes,&mapped));int buffer_correct=1;for(unsigned i=0;i<1024;i++)if(((uint32_t *)mapped)[i]!=(0x1793abcdu^i))buffer_correct=0;ID3D12Resource_Unmap(readback,0,&no_read);if(!buffer_correct)fail("GPUBufferMismatch",(HRESULT)0x80004005);output("READY_DX12_STAGE gpu_buffer_readback_passed\n");
    CHECK("ResetAllocator",ID3D12CommandAllocator_Reset(allocator));CHECK("ResetCommandList",ID3D12GraphicsCommandList_Reset(list,allocator,NULL));
    D3D12_RESOURCE_DESC texture={0};texture.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;texture.Width=16;texture.Height=16;texture.DepthOrArraySize=1;texture.MipLevels=1;texture.Format=DXGI_FORMAT_R8G8B8A8_UNORM;texture.SampleDesc.Count=1;texture.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    heap.Type=D3D12_HEAP_TYPE_DEFAULT;CHECK("CreateRenderTarget",ID3D12Device_CreateCommittedResource(device,&heap,D3D12_HEAP_FLAG_NONE,&texture,D3D12_RESOURCE_STATE_RENDER_TARGET,NULL,&IID_ID3D12Resource,(void **)&target));
    D3D12_DESCRIPTOR_HEAP_DESC rtv_desc={D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};CHECK("CreateRTVHeap",ID3D12Device_CreateDescriptorHeap(device,&rtv_desc,&IID_ID3D12DescriptorHeap,(void **)&rtv_heap));
    D3D12_CPU_DESCRIPTOR_HANDLE rtv=ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtv_heap);ID3D12Device_CreateRenderTargetView(device,target,NULL,rtv);const float clear[4]={0.2f,0.4f,0.6f,1.0f};ID3D12GraphicsCommandList_ClearRenderTargetView(list,rtv,clear,0,NULL);transition(list,target,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;UINT rows;UINT64 row_bytes,total;ID3D12Device_GetCopyableFootprints(device,&texture,0,1,0,&footprint,&rows,&row_bytes,&total);
    heap.Type=D3D12_HEAP_TYPE_READBACK;desc=buffer_description(total);CHECK("CreatePixelReadback",ID3D12Device_CreateCommittedResource(device,&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_COPY_DEST,NULL,&IID_ID3D12Resource,(void **)&pixels));
    D3D12_TEXTURE_COPY_LOCATION source={0},destination={0};source.pResource=target;source.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;destination.pResource=pixels;destination.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;destination.PlacedFootprint=footprint;ID3D12GraphicsCommandList_CopyTextureRegion(list,&destination,0,0,0,&source,NULL);submit(queue,list,fence,event,2);
    D3D12_RANGE pixel_range={0,(SIZE_T)total};CHECK("MapPixels",ID3D12Resource_Map(pixels,0,&pixel_range,&mapped));int clear_correct=1;for(unsigned y=0;y<16;y++)for(unsigned x=0;x<16;x++){uint32_t value=*(uint32_t *)((unsigned char *)mapped+footprint.Offset+y*footprint.Footprint.RowPitch+x*4);if(value!=0xff996633u)clear_correct=0;}ID3D12Resource_Unmap(pixels,0,&no_read);if(!clear_correct)fail("RenderTargetPixelsMismatch",(HRESULT)0x80004005);
    output("READY_DX12_STAGE render_target_clear_readback_passed\n");
    HMODULE compiler_library=LoadLibraryW(L"d3dcompiler_47.dll");if(!compiler_library)fail("LoadShaderCompiler",(HRESULT)0x8007007e);
    typedef HRESULT (WINAPI *CompileShader)(const void *,SIZE_T,const char *,const D3D_SHADER_MACRO *,ID3DInclude *,const char *,const char *,UINT,UINT,ID3DBlob **,ID3DBlob **);
    typedef HRESULT (WINAPI *SerializeRoot)(const D3D12_ROOT_SIGNATURE_DESC *,D3D_ROOT_SIGNATURE_VERSION,ID3DBlob **,ID3DBlob **);
    CompileShader compile=(CompileShader)GetProcAddress(compiler_library,"D3DCompile");SerializeRoot serialize=(SerializeRoot)GetProcAddress(library,"D3D12SerializeRootSignature");if(!compile||!serialize)fail("ShaderEntryPoint",(HRESULT)0x8007007f);
    static const char hlsl[]="float4 vs(uint id:SV_VertexID):SV_Position { float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)}; return float4(p[id],0,1); } float4 ps():SV_Target {return float4(0,1,0,1);}";
    ID3DBlob *vs=NULL,*ps=NULL,*signature=NULL,*errors=NULL;CHECK("CompileVertexShader",compile(hlsl,sizeof(hlsl)-1,"ready-d3d12-test",NULL,NULL,"vs","vs_5_0",0,0,&vs,&errors));if(errors){ID3D10Blob_Release(errors);errors=NULL;}
    CHECK("CompilePixelShader",compile(hlsl,sizeof(hlsl)-1,"ready-d3d12-test",NULL,NULL,"ps","ps_5_0",0,0,&ps,&errors));if(errors){ID3D10Blob_Release(errors);errors=NULL;}
    D3D12_ROOT_SIGNATURE_DESC signature_desc={0};signature_desc.Flags=D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;CHECK("SerializeRootSignature",serialize(&signature_desc,D3D_ROOT_SIGNATURE_VERSION_1,&signature,&errors));if(errors){ID3D10Blob_Release(errors);errors=NULL;}
    ID3D12RootSignature *root=NULL;ID3D12PipelineState *pipeline=NULL;CHECK("CreateRootSignature",ID3D12Device_CreateRootSignature(device,0,ID3D10Blob_GetBufferPointer(signature),ID3D10Blob_GetBufferSize(signature),&IID_ID3D12RootSignature,(void **)&root));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_desc={0};pipeline_desc.pRootSignature=root;pipeline_desc.VS.pShaderBytecode=ID3D10Blob_GetBufferPointer(vs);pipeline_desc.VS.BytecodeLength=ID3D10Blob_GetBufferSize(vs);pipeline_desc.PS.pShaderBytecode=ID3D10Blob_GetBufferPointer(ps);pipeline_desc.PS.BytecodeLength=ID3D10Blob_GetBufferSize(ps);pipeline_desc.SampleMask=~0u;
    D3D12_RENDER_TARGET_BLEND_DESC *blend=&pipeline_desc.BlendState.RenderTarget[0];blend->SrcBlend=D3D12_BLEND_ONE;blend->DestBlend=D3D12_BLEND_ZERO;blend->BlendOp=D3D12_BLEND_OP_ADD;blend->SrcBlendAlpha=D3D12_BLEND_ONE;blend->DestBlendAlpha=D3D12_BLEND_ZERO;blend->BlendOpAlpha=D3D12_BLEND_OP_ADD;blend->LogicOp=D3D12_LOGIC_OP_NOOP;blend->RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
    pipeline_desc.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pipeline_desc.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pipeline_desc.RasterizerState.DepthClipEnable=TRUE;pipeline_desc.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_ALWAYS;pipeline_desc.DepthStencilState.StencilReadMask=0xff;pipeline_desc.DepthStencilState.StencilWriteMask=0xff;
    pipeline_desc.DepthStencilState.FrontFace.StencilFailOp=D3D12_STENCIL_OP_KEEP;pipeline_desc.DepthStencilState.FrontFace.StencilDepthFailOp=D3D12_STENCIL_OP_KEEP;pipeline_desc.DepthStencilState.FrontFace.StencilPassOp=D3D12_STENCIL_OP_KEEP;pipeline_desc.DepthStencilState.FrontFace.StencilFunc=D3D12_COMPARISON_FUNC_ALWAYS;pipeline_desc.DepthStencilState.BackFace=pipeline_desc.DepthStencilState.FrontFace;
    pipeline_desc.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;pipeline_desc.NumRenderTargets=1;pipeline_desc.RTVFormats[0]=DXGI_FORMAT_R8G8B8A8_UNORM;pipeline_desc.SampleDesc.Count=1;CHECK("CreateGraphicsPipeline",ID3D12Device_CreateGraphicsPipelineState(device,&pipeline_desc,&IID_ID3D12PipelineState,(void **)&pipeline));
    CHECK("ResetShaderAllocator",ID3D12CommandAllocator_Reset(allocator));CHECK("ResetShaderCommandList",ID3D12GraphicsCommandList_Reset(list,allocator,pipeline));transition(list,target,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
    const float black[4]={0,0,0,1};ID3D12GraphicsCommandList_ClearRenderTargetView(list,rtv,black,0,NULL);ID3D12GraphicsCommandList_OMSetRenderTargets(list,1,&rtv,FALSE,NULL);ID3D12GraphicsCommandList_SetGraphicsRootSignature(list,root);D3D12_VIEWPORT viewport={0,0,16,16,0,1};D3D12_RECT scissor={0,0,16,16};ID3D12GraphicsCommandList_RSSetViewports(list,1,&viewport);ID3D12GraphicsCommandList_RSSetScissorRects(list,1,&scissor);ID3D12GraphicsCommandList_IASetPrimitiveTopology(list,D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);ID3D12GraphicsCommandList_DrawInstanced(list,3,1,0,0);transition(list,target,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);ID3D12GraphicsCommandList_CopyTextureRegion(list,&destination,0,0,0,&source,NULL);submit(queue,list,fence,event,3);
    CHECK("MapShaderPixels",ID3D12Resource_Map(pixels,0,&pixel_range,&mapped));int shader_correct=1;for(unsigned y=0;y<16;y++)for(unsigned x=0;x<16;x++)if(*(uint32_t *)((unsigned char *)mapped+footprint.Offset+y*footprint.Footprint.RowPitch+x*4)!=0xff00ff00u)shader_correct=0;ID3D12Resource_Unmap(pixels,0,&no_read);if(!shader_correct)fail("ShaderPixelsMismatch",(HRESULT)0x80004005);
    output("{\"api\":\"d3d12\",\"stage\":\"complete\",\"deviceCreated\":true,\"gpuBufferReadbackVerified\":true,\"renderTargetClearReadbackVerified\":true,\"shaderRasterizationVerified\":true,\"pixelsVerified\":256,\"featureLevelRequested\":\"0x0000b000\",\"directToDisplayVerified\":false}\n");
    ID3D12PipelineState_Release(pipeline);ID3D12RootSignature_Release(root);ID3D10Blob_Release(signature);ID3D10Blob_Release(ps);ID3D10Blob_Release(vs);FreeLibrary(compiler_library);
    ID3D12Resource_Release(pixels);ID3D12DescriptorHeap_Release(rtv_heap);ID3D12Resource_Release(target);ID3D12Resource_Release(readback);ID3D12Resource_Release(gpu);ID3D12Resource_Release(upload);ID3D12Fence_Release(fence);ID3D12GraphicsCommandList_Release(list);ID3D12CommandAllocator_Release(allocator);ID3D12CommandQueue_Release(queue);ID3D12Device_Release(device);CloseHandle(event);FreeLibrary(library);ExitProcess(0);
}
