/* SPDX-License-Identifier: GPL-3.0-only */
/* Real WinHTTP HTTPS/certificate-validation and GDI/DirectWrite raster probes. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define INITGUID
#define _ACRTIMP
#include <windows.h>
#include <winhttp.h>
#include <dwrite.h>
#include <stdint.h>
#include <stddef.h>
int _fltused;
void *memcpy(void *d,const void *s,size_t n){BYTE *o=d;const BYTE *i=s;for(size_t k=0;k<n;k++)o[k]=i[k];return d;}
void *memset(void *d,int v,size_t n){BYTE *o=d;for(size_t k=0;k<n;k++)o[k]=(BYTE)v;return d;}
static BYTE pixels[1048576];
static void out(const char *s){DWORD n=0,w;while(s[n])n++;WriteFile(GetStdHandle((DWORD)-11),s,n,&w,NULL);}
static void number(DWORD n){char b[12];unsigned i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i){char c[2]={b[--i],0};out(c);}}
static void fail(const char *api,const char *stage,DWORD error){out("{\"api\":\"");out(api);out("\",\"stage\":\"");out(stage);out("\",\"error\":");number(error);out(",\"verified\":false}\n");ExitProcess(3);}
static const WCHAR *find(const WCHAR *s,const WCHAR *n){for(;*s;s++){unsigned i=0;while(n[i]&&s[i]==n[i])i++;if(!n[i])return s+i;}return NULL;}
static int ascii_contains(const BYTE *s,DWORD length,const char *n){for(DWORD k=0;k<length;k++){DWORD i=0;while(n[i]&&k+i<length&&s[k+i]==(BYTE)n[i])i++;if(!n[i])return 1;}return 0;}
static DWORD nonzero(const BYTE *p,DWORD count){DWORD n=0;for(DWORD i=0;i<count;i++)if(p[i])n++;return n;}

static void tls(void){
    static WCHAR url[4096],host[512],path[2048];const WCHAR *arg=find(GetCommandLineW(),L"--url=");if(!arg)fail("winhttp","MissingURL",0);unsigned i=0;while(arg[i]&&arg[i]!=' '&&arg[i]!='\"'&&i<4095){url[i]=arg[i];i++;}url[i]=0;
    URL_COMPONENTS parts={0};parts.dwStructSize=sizeof(parts);parts.lpszHostName=host;parts.dwHostNameLength=511;parts.lpszUrlPath=path;parts.dwUrlPathLength=2047;if(!WinHttpCrackUrl(url,0,0,&parts))fail("winhttp","CrackURL",GetLastError());if(parts.nScheme!=INTERNET_SCHEME_HTTPS)fail("winhttp","HTTPSRequired",0);if(!path[0]){path[0]='/';path[1]=0;}
    HINTERNET session=WinHttpOpen(L"ReadyRuntimeProbe/1.0",WINHTTP_ACCESS_TYPE_NO_PROXY,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0);if(!session)fail("winhttp","Open",GetLastError());WinHttpSetTimeouts(session,10000,10000,20000,20000);
    HINTERNET connection=WinHttpConnect(session,host,parts.nPort,0);if(!connection)fail("winhttp","Connect",GetLastError());HINTERNET request=WinHttpOpenRequest(connection,L"GET",path,NULL,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,WINHTTP_FLAG_SECURE);if(!request)fail("winhttp","OpenRequest",GetLastError());
    BOOL sent=WinHttpSendRequest(request,WINHTTP_NO_ADDITIONAL_HEADERS,0,WINHTTP_NO_REQUEST_DATA,0,0,0);DWORD error=sent?0:GetLastError();BOOL received=sent&&WinHttpReceiveResponse(request,NULL);if(sent&&!received)error=GetLastError();
    if(find(GetCommandLineW(),L"--expect-secure-failure")){
        /* Wine's net.c maps a verified certificate error to generic 12157.
         * The orchestrator additionally requires its cert-verify diagnostic;
         * a generic channel failure alone is not a successful negative test. */
        BOOL rejected=!received&&(error==ERROR_WINHTTP_SECURE_FAILURE||error==ERROR_WINHTTP_SECURE_CHANNEL_ERROR||error==ERROR_WINHTTP_SECURE_INVALID_CA);out("{\"api\":\"winhttp\",\"secureFailureRejected\":");out(rejected?"true":"false");out(",\"error\":");number(error);out(",\"certificateValidationBypassUsed\":false}\n");WinHttpCloseHandle(request);WinHttpCloseHandle(connection);WinHttpCloseHandle(session);ExitProcess(rejected?0:4);
    }
    if(!received)fail("winhttp",sent?"ReceiveResponse":"SendRequest",error);DWORD status=0,bytes=sizeof(status);if(!WinHttpQueryHeaders(request,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,NULL,&status,&bytes,NULL))fail("winhttp","Status",GetLastError());
    DWORD total=0;for(;;){DWORD available=0,read=0;if(!WinHttpQueryDataAvailable(request,&available))fail("winhttp","Available",GetLastError());if(!available)break;if(available>sizeof(pixels)-total)available=sizeof(pixels)-total;if(!available)fail("winhttp","ResponseTooLarge",0);if(!WinHttpReadData(request,pixels+total,available,&read))fail("winhttp","Read",GetLastError());total+=read;if(!read)break;}
    DWORD hash=2166136261u;for(DWORD n=0;n<total;n++){hash^=pixels[n];hash*=16777619u;}BOOL marker=ascii_contains(pixels,total,"Example Domain");out("{\"api\":\"winhttp\",\"status\":");number(status);out(",\"bodyBytes\":");number(total);out(",\"bodyFNV1a\":");number(hash);out(",\"exampleMarkerPresent\":");out(marker?"true":"false");out(",\"httpsVerified\":");out(status==200&&total>0?"true":"false");out(",\"certificateValidationBypassUsed\":false}\n");WinHttpCloseHandle(request);WinHttpCloseHandle(connection);WinHttpCloseHandle(session);ExitProcess(status==200&&total>0?0:4);
}

static void gdi(void){
    HDC dc=CreateCompatibleDC(NULL);if(!dc)fail("gdi","CreateDC",GetLastError());HFONT font=CreateFontW(-32,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH,L"Arial");if(!font)fail("gdi","CreateFont",GetLastError());HGDIOBJ old=SelectObject(dc,font);MAT2 matrix={{0,1},{0,0},{0,0},{0,1}};GLYPHMETRICS gm={0};DWORD bytes=GetGlyphOutlineW(dc,L'A',GGO_GRAY8_BITMAP,&gm,sizeof(pixels),pixels,&matrix);if(bytes==GDI_ERROR||bytes>sizeof(pixels))fail("gdi","GlyphOutline",GetLastError());DWORD lit=nonzero(pixels,bytes);out("{\"api\":\"gdi\",\"bitmapBytes\":");number(bytes);out(",\"nonzeroAlphaSamples\":");number(lit);out(",\"width\":");number(gm.gmBlackBoxX);out(",\"height\":");number(gm.gmBlackBoxY);out(",\"glyphRasterVerified\":");out(lit&&gm.gmBlackBoxX&&gm.gmBlackBoxY?"true":"false");out("}\n");SelectObject(dc,old);DeleteObject(font);DeleteDC(dc);ExitProcess(lit&&gm.gmBlackBoxX&&gm.gmBlackBoxY?0:4);
}

#define DCHECK(s,e) do{HRESULT ready_hr=(e);if(FAILED(ready_hr))fail("dwrite",s,(DWORD)ready_hr);}while(0)
static void dwrite(void){
    HMODULE library=LoadLibraryW(L"dwrite.dll");if(!library)fail("dwrite","LoadLibrary",GetLastError());typedef HRESULT(WINAPI *CreateFactory)(DWRITE_FACTORY_TYPE,REFIID,IUnknown **);CreateFactory create=(CreateFactory)GetProcAddress(library,"DWriteCreateFactory");if(!create)fail("dwrite","EntryPoint",GetLastError());
    IDWriteFactory *factory=NULL;IDWriteFontCollection *collection=NULL;IDWriteFontFamily *family=NULL;IDWriteFont *font=NULL;IDWriteFontFace *face=NULL;IDWriteGlyphRunAnalysis *analysis=NULL;
    DCHECK("CreateFactory",create(DWRITE_FACTORY_TYPE_SHARED,&IID_IDWriteFactory,(IUnknown **)&factory));DCHECK("FontCollection",IDWriteFactory_GetSystemFontCollection(factory,&collection,FALSE));UINT32 count=IDWriteFontCollection_GetFontFamilyCount(collection),index=0;BOOL exists=FALSE;if(!count)fail("dwrite","NoFonts",0);DCHECK("FindFamily",IDWriteFontCollection_FindFamilyName(collection,L"Arial",&index,&exists));if(!exists)index=0;
    DCHECK("GetFamily",IDWriteFontCollection_GetFontFamily(collection,index,&family));DCHECK("MatchingFont",IDWriteFontFamily_GetFirstMatchingFont(family,DWRITE_FONT_WEIGHT_NORMAL,DWRITE_FONT_STRETCH_NORMAL,DWRITE_FONT_STYLE_NORMAL,&font));DCHECK("CreateFace",IDWriteFont_CreateFontFace(font,&face));UINT32 codepoint='A';UINT16 glyph=0;DCHECK("GlyphIndex",IDWriteFontFace_GetGlyphIndices(face,&codepoint,1,&glyph));if(!glyph)fail("dwrite","MissingGlyph",0);
    DWRITE_GLYPH_RUN run={0};run.fontFace=face;run.fontEmSize=32;run.glyphCount=1;run.glyphIndices=&glyph;DCHECK("GlyphRunAnalysis",IDWriteFactory_CreateGlyphRunAnalysis(factory,&run,1,NULL,DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,DWRITE_MEASURING_MODE_NATURAL,0,40,&analysis));RECT bounds={0};DCHECK("AlphaBounds",IDWriteGlyphRunAnalysis_GetAlphaTextureBounds(analysis,DWRITE_TEXTURE_CLEARTYPE_3x1,&bounds));DWORD width=bounds.right-bounds.left,height=bounds.bottom-bounds.top,bytes=width*height*3;if(!width||!height||bytes>sizeof(pixels))fail("dwrite","InvalidBounds",0);
    DCHECK("AlphaTexture",IDWriteGlyphRunAnalysis_CreateAlphaTexture(analysis,DWRITE_TEXTURE_CLEARTYPE_3x1,&bounds,pixels,bytes));DWORD lit=nonzero(pixels,bytes);out("{\"api\":\"dwrite\",\"fontFamilies\":");number(count);out(",\"glyphIndex\":");number(glyph);out(",\"alphaTextureBytes\":");number(bytes);out(",\"nonzeroAlphaSamples\":");number(lit);out(",\"glyphRasterVerified\":");out(lit?"true":"false");out("}\n");IDWriteGlyphRunAnalysis_Release(analysis);IDWriteFontFace_Release(face);IDWriteFont_Release(font);IDWriteFontFamily_Release(family);IDWriteFontCollection_Release(collection);IDWriteFactory_Release(factory);FreeLibrary(library);ExitProcess(lit?0:4);
}
void mainCRTStartup(void){if(find(GetCommandLineW(),L"--tls"))tls();if(find(GetCommandLineW(),L"--gdi"))gdi();if(find(GetCommandLineW(),L"--dwrite"))dwrite();fail("platform","MissingMode",0);}
