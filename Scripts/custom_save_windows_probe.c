/* SPDX-License-Identifier: GPL-3.0-only */
#include <stdint.h>
typedef uint32_t DWORD; typedef void *HANDLE;
#define API __declspec(dllimport)
#define CALL __stdcall
API HANDLE CALL GetStdHandle(DWORD);
API int CALL WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
API int CALL CloseHandle(HANDLE);
API HANDLE CALL CreateFileA(const char*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
API DWORD CALL GetFileAttributesA(const char*);
API char* CALL GetCommandLineA(void);
API void CALL ExitProcess(DWORD);
static DWORD len(const char *s){DWORD n=0;while(s[n])n++;return n;}
static int contains(const char*s,const char*n){for(;*s;s++){unsigned i=0;while(n[i]&&s[i]==n[i])i++;if(!n[i])return 1;}return 0;}
static void out(const char*s){DWORD n;WriteFile(GetStdHandle((DWORD)-11),s,len(s),&n,0);}
void mainCRTStartup(void){
    const char *path="C:\\ProgramData\\ReadyGame\\Saves\\ready-save-probe.txt";
    int write=contains(GetCommandLineA(),"--write"),success=1;
    if(write){
        HANDLE file=CreateFileA(path,0x40000000,1,0,2,0x80,0);DWORD bytes=0;
        if(file==(HANDLE)(intptr_t)-1)success=0;
        else{success=WriteFile(file,"private-save",12,&bytes,0)&&bytes==12;CloseHandle(file);}
    }
    out("{\"customMarker\":");out(GetFileAttributesA(path)!=(DWORD)-1?"true":"false");
    out(",\"writeSucceeded\":");out(success?"true":"false");out("}\n");ExitProcess(success?0:1);
}
