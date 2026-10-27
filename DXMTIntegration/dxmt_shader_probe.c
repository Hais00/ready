/* SPDX-License-Identifier: GPL-3.0-only */
/* Original Ready probe. Uses public Wine interface headers, not DXMT implementation code. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
int _fltused=0;
static void output(const char *s){DWORD n=0,written;while(s[n])n++;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,n,&written,NULL);}
static void number(unsigned n){char s[16];unsigned count=0;do{s[count++]=(char)('0'+n%10);n/=10;}while(n);while(count){char c[2]={s[--count],0};output(c);}}
static void hex(HRESULT n){static const char digits[]="0123456789abcdef";char s[11]="0x00000000";for(unsigned i=0;i<8;i++)s[9-i]=digits[((unsigned)n>>(4*i))&15];output(s);}
static SIZE_T length(const char *s){SIZE_T n=0;while(s[n])n++;return n;}
typedef HRESULT (WINAPI *CreateDeviceFn)(IDXGIAdapter*,D3D_DRIVER_TYPE,HMODULE,UINT,const D3D_FEATURE_LEVEL*,UINT,UINT,ID3D11Device**,D3D_FEATURE_LEVEL*,ID3D11DeviceContext**);
void mainCRTStartup(void){
    HRESULT hr=E_FAIL;const char *stage="modules";unsigned white=0,black=0;BOOL center=FALSE,corner=FALSE;
    HMODULE compiler=LoadLibraryW(L"d3dcompiler_47.dll"),d3d=LoadLibraryW(L"d3d11.dll");
    ID3D11Device *device=NULL;ID3D11DeviceContext *ctx=NULL;ID3D11Texture2D *target=NULL,*staging=NULL;ID3D11RenderTargetView *view=NULL;ID3D11RasterizerState *raster=NULL;
    ID3D11VertexShader *vs=NULL;ID3D11PixelShader *ps=NULL;ID3DBlob *vsCode=NULL,*psCode=NULL,*errors=NULL;D3D_FEATURE_LEVEL obtained=0;
    if(!compiler||!d3d)goto done;
    pD3DCompile compile=(pD3DCompile)GetProcAddress(compiler,"D3DCompile");CreateDeviceFn create=(CreateDeviceFn)GetProcAddress(d3d,"D3D11CreateDevice");if(!compile||!create)goto done;
    stage="compile_vertex";
    const char *vsource="float4 main(uint id : SV_VertexID) : SV_Position { static const float2 p[3]={float2(-0.75,-0.75),float2(0.75,-0.75),float2(0,0.75)};return float4(p[id],0.5,1); }";
    const char *psource="float4 main() : SV_Target { return float4(0.2,0.4,0.6,1); }";
    hr=compile(vsource,length(vsource),"ready-probe-vs",NULL,NULL,"main","vs_5_0",0,0,&vsCode,&errors);if(FAILED(hr))goto done;if(errors){ID3D10Blob_Release(errors);errors=NULL;}
    stage="compile_pixel";hr=compile(psource,length(psource),"ready-probe-ps",NULL,NULL,"main","ps_5_0",0,0,&psCode,&errors);if(FAILED(hr))goto done;
    stage="create_device";D3D_FEATURE_LEVEL requested=D3D_FEATURE_LEVEL_11_0;hr=create(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,&requested,1,D3D11_SDK_VERSION,&device,&obtained,&ctx);if(FAILED(hr))goto done;
    stage="create_vertex_shader";hr=ID3D11Device_CreateVertexShader(device,ID3D10Blob_GetBufferPointer(vsCode),ID3D10Blob_GetBufferSize(vsCode),NULL,&vs);if(FAILED(hr))goto done;
    stage="create_pixel_shader";hr=ID3D11Device_CreatePixelShader(device,ID3D10Blob_GetBufferPointer(psCode),ID3D10Blob_GetBufferSize(psCode),NULL,&ps);if(FAILED(hr))goto done;
    D3D11_TEXTURE2D_DESC desc={0};desc.Width=64;desc.Height=64;desc.MipLevels=1;desc.ArraySize=1;desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    stage="create_target";hr=ID3D11Device_CreateTexture2D(device,&desc,NULL,&target);if(FAILED(hr))goto done;
    stage="create_target_view";hr=ID3D11Device_CreateRenderTargetView(device,(ID3D11Resource*)target,NULL,&view);if(FAILED(hr))goto done;
    desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    stage="create_staging";hr=ID3D11Device_CreateTexture2D(device,&desc,NULL,&staging);if(FAILED(hr))goto done;
    D3D11_RASTERIZER_DESC rasterDesc={0};rasterDesc.FillMode=D3D11_FILL_SOLID;rasterDesc.CullMode=D3D11_CULL_NONE;rasterDesc.DepthClipEnable=TRUE;
    stage="create_rasterizer";hr=ID3D11Device_CreateRasterizerState(device,&rasterDesc,&raster);if(FAILED(hr))goto done;
    const FLOAT clear[4]={0,0,0,1};D3D11_VIEWPORT vp={0,0,64,64,0,1};
    ID3D11DeviceContext_ClearRenderTargetView(ctx,view,clear);ID3D11DeviceContext_OMSetRenderTargets(ctx,1,&view,NULL);ID3D11DeviceContext_RSSetViewports(ctx,1,&vp);ID3D11DeviceContext_RSSetState(ctx,raster);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx,D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);ID3D11DeviceContext_VSSetShader(ctx,vs,NULL,0);ID3D11DeviceContext_PSSetShader(ctx,ps,NULL,0);ID3D11DeviceContext_Draw(ctx,3,0);
    ID3D11DeviceContext_CopyResource(ctx,(ID3D11Resource*)staging,(ID3D11Resource*)target);
    stage="map_readback";D3D11_MAPPED_SUBRESOURCE mapped={0};hr=ID3D11DeviceContext_Map(ctx,(ID3D11Resource*)staging,0,D3D11_MAP_READ,0,&mapped);if(FAILED(hr))goto done;
    for(unsigned y=0;y<64;y++)for(unsigned x=0;x<64;x++){
        const unsigned char *p=(const unsigned char*)mapped.pData+y*mapped.RowPitch+x*4;BOOL colored=p[0]==51&&p[1]==102&&p[2]==153&&p[3]==255;BOOL background=p[0]==0&&p[1]==0&&p[2]==0&&p[3]==255;
        white+=colored;black+=background;if(x==32&&y==32)center=colored;if(x==0&&y==0)corner=background;
    }
    ID3D11DeviceContext_Unmap(ctx,(ID3D11Resource*)staging,0);stage="complete";
 done:
    BOOL passed=SUCCEEDED(hr)&&white>800&&white<2000&&black+white==4096&&center&&corner&&obtained>=D3D_FEATURE_LEVEL_11_0;
    output("{\"api\":\"dx11\",\"test\":\"hlsl_triangle_readback\",\"stage\":\"");output(stage);output("\",\"hresult\":\"");hex(hr);output("\",\"featureLevel\":\"");hex(obtained);output("\",\"coloredPixels\":");number(white);output(",\"backgroundPixels\":");number(black);output(",\"centerCorrect\":");output(center?"true":"false");output(",\"cornerCorrect\":");output(corner?"true":"false");output(",\"shaderRasterizationVerified\":");output(passed?"true":"false");output("}\n");
    if(errors){ID3D10Blob_Release(errors);}if(vsCode)ID3D10Blob_Release(vsCode);if(psCode)ID3D10Blob_Release(psCode);
    if(raster)ID3D11RasterizerState_Release(raster);if(view)ID3D11RenderTargetView_Release(view);if(staging)ID3D11Texture2D_Release(staging);if(target)ID3D11Texture2D_Release(target);if(ps)ID3D11PixelShader_Release(ps);if(vs)ID3D11VertexShader_Release(vs);if(ctx)ID3D11DeviceContext_Release(ctx);if(device)ID3D11Device_Release(device);if(compiler)FreeLibrary(compiler);if(d3d)FreeLibrary(d3d);ExitProcess(passed?0:3);
}
