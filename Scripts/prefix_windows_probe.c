/* SPDX-License-Identifier: GPL-3.0-only
 * Real Windows API probe for Wine prefix data isolation. No C runtime dependency.
 * --write stores a marker in HKCU, Local AppData, Documents, and Saved Games.
 * --probe only reports whether those markers are visible in the current prefix.
 */
#include <stdint.h>
#include <stddef.h>
typedef uint32_t DWORD;typedef int32_t LONG;typedef void *HANDLE;typedef void *HKEY;
#define API __declspec(dllimport)
#define CALL __stdcall
API HANDLE CALL GetStdHandle(DWORD);
API int CALL WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
API int CALL CloseHandle(HANDLE);
API HANDLE CALL CreateFileA(const char*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
API DWORD CALL GetFileAttributesA(const char*);
API char* CALL GetCommandLineA(void);
API void CALL ExitProcess(DWORD);
API LONG CALL SHGetFolderPathA(void*,int,void*,DWORD,char*);
API LONG CALL RegCreateKeyExA(HKEY,const char*,DWORD,char*,DWORD,DWORD,void*,HKEY*,DWORD*);
API LONG CALL RegSetValueExA(HKEY,const char*,DWORD,DWORD,const unsigned char*,DWORD);
API LONG CALL RegQueryValueExA(HKEY,const char*,DWORD*,DWORD*,unsigned char*,DWORD*);
API LONG CALL RegCloseKey(HKEY);
typedef struct{uint32_t a;uint16_t b,c;uint8_t d[8];} GUID;
API LONG CALL SHGetKnownFolderPath(const GUID*,DWORD,void*,uint16_t**);
API int CALL WideCharToMultiByte(unsigned,DWORD,const uint16_t*,int,char*,int,const char*,int*);
static DWORD length(const char*s){DWORD n=0;while(s[n])n++;return n;}
static void append(char*out,const char*s){while(*out)out++;while(*s)*out++=*s++;*out=0;}
static int contains(const char*s,const char*n){for(;*s;s++){unsigned i=0;while(n[i]&&s[i]==n[i])i++;if(!n[i])return 1;}return 0;}
static void output(const char*s){DWORD written;WriteFile(GetStdHandle((DWORD)-11),s,length(s),&written,NULL);}
static void jsonString(const char*s){output("\"");for(;*s;s++){char c[3]={*s,0,0};if(*s=='\\'||*s=='\"'){c[0]='\\';c[1]=*s;}output(c);}output("\"");}
static int exists(const char*dir){char path[2048];path[0]=0;append(path,dir);append(path,"\\ready-prefix-probe.txt");return GetFileAttributesA(path)!=(DWORD)-1;}
static int writeMarker(const char*dir){char path[2048];path[0]=0;append(path,dir);append(path,"\\ready-prefix-probe.txt");HANDLE h=CreateFileA(path,0x40000000,1,NULL,2,0x80,NULL);if(h==(HANDLE)(intptr_t)-1)return 0;DWORD written=0;int result=WriteFile(h,"profile-marker",14,&written,NULL)&&written==14;CloseHandle(h);return result;}
void mainCRTStartup(void){
    static char docs[2048],appdata[2048],saved[2048];
    LONG d=SHGetFolderPathA(NULL,5|0x8000,NULL,0,docs),a=SHGetFolderPathA(NULL,0x1c|0x8000,NULL,0,appdata);
    static const GUID savedID={0x4c5c32ff,0xbb9d,0x43b0,{0xb5,0xb4,0x2d,0x72,0xe5,0x4e,0xaa,0xa4}};
    uint16_t *savedWide=NULL;LONG sg=SHGetKnownFolderPath(&savedID,0x8000,NULL,&savedWide);
    if(sg>=0&&savedWide)WideCharToMultiByte(65001,0,savedWide,-1,saved,2048,NULL,NULL);
    HKEY key=NULL;LONG k=RegCreateKeyExA((HKEY)(intptr_t)-2147483647,"Software\\ReadyPrefixProbe",0,NULL,0,0xf003f,NULL,&key,NULL);
    int write=contains(GetCommandLineA(),"--write"),written=1;
    if(write){if(k!=0||RegSetValueExA(key,"Marker",0,1,(const unsigned char*)"profile-marker",15)!=0)written=0;written=written&&d>=0&&a>=0&&sg>=0&&writeMarker(docs)&&writeMarker(appdata)&&writeMarker(saved);}
    static char marker[64];DWORD bytes=64,type=0;int registry=k==0&&RegQueryValueExA(key,"Marker",NULL,&type,(unsigned char*)marker,&bytes)==0;
    if(key)RegCloseKey(key);
    output("{\"documentsPath\":");jsonString(docs);output(",\"appDataPath\":");jsonString(appdata);output(",\"savedGamesPath\":");jsonString(saved);
    output(",\"registryMarker\":");output(registry?"true":"false");output(",\"documentsMarker\":");output(exists(docs)?"true":"false");output(",\"appDataMarker\":");output(exists(appdata)?"true":"false");output(",\"savedGamesMarker\":");output(exists(saved)?"true":"false");output(",\"writeSucceeded\":");output(written?"true":"false");output("}\n");
    ExitProcess(d>=0&&a>=0&&sg>=0&&written?0:1);
}
