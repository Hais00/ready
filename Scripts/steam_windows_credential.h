/* SPDX-License-Identifier: GPL-3.0-only */
/* Independent Windows RDYAUTH1 parser. The caller supplies its private anonymous
 * stdin pipe. FILE_TYPE_PIPE is not writer authentication. One3s monotonic budget
 * includes EOF. Wine's imported Unix pipe does not support PeekNamedPipe: use a
 * private ReadFile thread, main-thread deadline and bounded cancellation instead.
 * Uncancellable IO terminates ONLY this pre-Valve worker; RAM reclamation is not
 * a promise of forensic zeroization. No TerminateThread or unbounded join. */
#ifndef READY_WINDOWS_STEAM_CREDENTIAL_H
#define READY_WINDOWS_STEAM_CREDENTIAL_H
#include <windows.h>
typedef struct { ULONGLONG steam_id;DWORD app_id;char account[65],token[8193]; } ReadyWindowsCredential;
enum {READY_WIRE_OK,READY_WIRE_PIPE,READY_WIRE_TIMEOUT,READY_WIRE_IO,READY_WIRE_TRUNCATED,READY_WIRE_HEADER,READY_WIRE_LENGTH,READY_WIRE_IDENTITY,READY_WIRE_ACCOUNT,READY_WIRE_TOKEN,READY_WIRE_TRAILING};
static BOOL ready_windows_read_thread_used,ready_windows_read_thread_quiescent=TRUE;
static void (*ready_windows_uncancellable_timeout)(void);
static void ready_windows_zero(void *memory,SIZE_T count){volatile unsigned char *out=memory;while(count--)*out++=0;}
static BOOL ready_windows_is_zero(const void *memory,SIZE_T count){const volatile unsigned char *p=memory;while(count--)if(*p++)return FALSE;return TRUE;}
static DWORD ready_windows_u32be(const unsigned char *p){return ((DWORD)p[0]<<24)|((DWORD)p[1]<<16)|((DWORD)p[2]<<8)|p[3];}
static DWORD ready_windows_exact(HANDLE input,unsigned char *out,DWORD wanted,ULONGLONG deadline,BOOL blocking){
    while(wanted){if(GetTickCount64()>=deadline)return READY_WIRE_TIMEOUT;DWORD available=wanted;if(!blocking){if(!PeekNamedPipe(input,NULL,0,NULL,&available,NULL))return GetLastError()==ERROR_BROKEN_PIPE?READY_WIRE_TRUNCATED:READY_WIRE_IO;if(!available){Sleep(1);continue;}}DWORD read=0,chunk=available<wanted?available:wanted;if(!ReadFile(input,out,chunk,&read,NULL))return GetLastError()==ERROR_BROKEN_PIPE?READY_WIRE_TRUNCATED:READY_WIRE_IO;if(!read)return READY_WIRE_TRUNCATED;out+=read;wanted-=read;}
    return READY_WIRE_OK;
}
static DWORD ready_windows_eof(HANDLE input,ULONGLONG deadline,BOOL blocking){
    if(blocking){unsigned char extra=0;DWORD read=0;BOOL ok=ReadFile(input,&extra,1,&read,NULL);DWORD error=GetLastError();ready_windows_zero(&extra,1);if(!ok)return error==ERROR_BROKEN_PIPE?READY_WIRE_OK:READY_WIRE_IO;return read?READY_WIRE_TRAILING:READY_WIRE_OK;}
    for(;;){if(GetTickCount64()>=deadline)return READY_WIRE_TIMEOUT;DWORD available=0;if(!PeekNamedPipe(input,NULL,0,NULL,&available,NULL))return GetLastError()==ERROR_BROKEN_PIPE?READY_WIRE_OK:READY_WIRE_IO;if(available)return READY_WIRE_TRAILING;Sleep(1);}
}
static DWORD ready_windows_parse(HANDLE input,ReadyWindowsCredential *value,ULONGLONG deadline,BOOL blocking){
    unsigned char header[28]={0};DWORD result=READY_WIRE_OK;ready_windows_zero(value,sizeof *value);
    result=ready_windows_exact(input,header,28,deadline,blocking);if(result)goto done;
    for(unsigned i=0;i<8;i++)if(header[i]!=(unsigned char)"RDYAUTH1"[i]){result=READY_WIRE_HEADER;goto done;}
    DWORD account=ready_windows_u32be(header+8),token=ready_windows_u32be(header+12);value->steam_id=((ULONGLONG)ready_windows_u32be(header+16)<<32)|ready_windows_u32be(header+20);value->app_id=ready_windows_u32be(header+24);
    if(!account||account>64||!token||token>8192){result=READY_WIRE_LENGTH;goto done;}
    if(!value->app_id||value->app_id==0xffffffffU||(value->steam_id>>56)!=1||((value->steam_id>>52)&15)!=1||((value->steam_id>>32)&0xfffff)!=1||!(DWORD)value->steam_id){result=READY_WIRE_IDENTITY;goto done;}
    result=ready_windows_exact(input,(unsigned char*)value->account,account,deadline,blocking);if(result)goto done;
    result=ready_windows_exact(input,(unsigned char*)value->token,token,deadline,blocking);if(result)goto done;
    for(DWORD i=0;i<account;i++){unsigned char c=value->account[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_')){result=READY_WIRE_ACCOUNT;goto done;}}
    for(DWORD i=0;i<token;i++){unsigned char c=value->token[i];if(c<33||c>126){result=READY_WIRE_TOKEN;goto done;}}
    result=ready_windows_eof(input,deadline,blocking);
done:
    ready_windows_zero(header,sizeof header);if(result)ready_windows_zero(value,sizeof *value);return result;
}
typedef struct { HANDLE input;ULONGLONG deadline;ReadyWindowsCredential value;DWORD result; } ReadyWindowsReadContext;
static ReadyWindowsReadContext ready_windows_read_context;
static DWORD WINAPI ready_windows_reader(void *context){ReadyWindowsReadContext *ctx=context;ctx->result=ready_windows_parse(ctx->input,&ctx->value,ctx->deadline,TRUE);return 0;}
static DWORD ready_windows_credential_read(HANDLE input,ReadyWindowsCredential *value){
    ULONGLONG deadline=GetTickCount64()+3000;ready_windows_zero(value,sizeof *value);
    if(!input||input==INVALID_HANDLE_VALUE||GetFileType(input)!=FILE_TYPE_PIPE)return READY_WIRE_PIPE;
    DWORD available=0;if(PeekNamedPipe(input,NULL,0,NULL,&available,NULL)||GetLastError()==ERROR_BROKEN_PIPE)return ready_windows_parse(input,value,deadline,FALSE);
    if(GetLastError()!=ERROR_NOT_SUPPORTED&&GetLastError()!=ERROR_INVALID_FUNCTION)return READY_WIRE_IO;
    ready_windows_read_thread_used=TRUE;ready_windows_read_thread_quiescent=FALSE;ReadyWindowsReadContext *ctx=&ready_windows_read_context;ready_windows_zero(ctx,sizeof *ctx);ctx->input=input;ctx->deadline=deadline;ctx->result=READY_WIRE_IO;
    HANDLE thread=CreateThread(NULL,0,ready_windows_reader,ctx,0,NULL);if(!thread){ready_windows_read_thread_quiescent=TRUE;return READY_WIRE_IO;}
    ULONGLONG now=GetTickCount64();DWORD wait=WaitForSingleObject(thread,now<deadline?(DWORD)(deadline-now):0),result=READY_WIRE_IO;
    if(wait==WAIT_OBJECT_0){result=ctx->result;if(result==READY_WIRE_OK){unsigned char *out=(unsigned char*)value;const volatile unsigned char *in=(const volatile unsigned char*)&ctx->value;for(SIZE_T i=0;i<sizeof *value;i++)out[i]=in[i];}}
    else {CancelSynchronousIo(thread);if(WaitForSingleObject(thread,250)!=WAIT_OBJECT_0){if(ready_windows_uncancellable_timeout)ready_windows_uncancellable_timeout();TerminateProcess(GetCurrentProcess(),2);ExitProcess(2);}result=READY_WIRE_TIMEOUT;}
    ready_windows_read_thread_quiescent=TRUE;CloseHandle(thread);ready_windows_zero(ctx,sizeof *ctx);if(result)ready_windows_zero(value,sizeof *value);return result;
}
#endif
