/* SPDX-License-Identifier: GPL-3.0-only */
/* PE32/PE64 API probe: stdin commands, real LoadLibrary/GetProcAddress calls. */
#define _ACRTIMP
#include <windows.h>
#include <xinput.h>
#include "runtime_xinput_protocol.h"
struct stats {DWORD calls;XINPUT_VIBRATION vibration;};
static void out(const char *text){DWORD n=0,w;while(text[n])n++;WriteFile(GetStdHandle((DWORD)-11),text,n,&w,NULL);}
static void number(DWORD n){char b[12];unsigned i=0;do{b[i++]='0'+n%10;n/=10;}while(n);while(i){char c[2]={b[--i],0};out(c);}}
static int equal(const char *a,const char *b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static void field(const char *name,DWORD value){out(",\"");out(name);out("\":");number(value);}
int mainCRTStartup(void){
    static WCHAR dll[80],device_path[4096];GetEnvironmentVariableW(L"M1L_XINPUT_TEST_VERSION",dll,80);GetEnvironmentVariableW(L"M1L_XINPUT_TEST_PROVIDER",device_path,4096);HMODULE device=LoadLibraryW(device_path),module=LoadLibraryW(dll);if(!device||!module){out("{\"error\":\"LoadLibrary\"}\n");ExitProcess(2);}
    DWORD(WINAPI *seed)(DWORD,const XINPUT_STATE *,BOOL)=(void *)GetProcAddress(device,"ReadyTestSeed");DWORD(WINAPI *raw_get)(DWORD,XINPUT_STATE *)=(void *)GetProcAddress(device,"ReadyTestGetState");DWORD(WINAPI *stats_get)(DWORD,struct stats *)=(void *)GetProcAddress(device,"ReadyTestStats");DWORD(WINAPI *get)(DWORD,XINPUT_STATE *)=(void *)GetProcAddress(module,"XInputGetState");DWORD(WINAPI *get_ex)(DWORD,XINPUT_STATE *)=(void *)GetProcAddress(module,(const char *)(UINT_PTR)100);DWORD(WINAPI *key)(DWORD,DWORD,XINPUT_KEYSTROKE *)=(void *)GetProcAddress(module,"XInputGetKeystroke");DWORD(WINAPI *set)(DWORD,XINPUT_VIBRATION *)=(void *)GetProcAddress(module,"XInputSetState");DWORD(WINAPI *capture)(struct ready_xinput_capture *)=(void *)GetProcAddress(module,"ReadyInputTestCapture");
    if(!capture){HMODULE backend=LoadLibraryW(L"xinput1_4.dll");capture=(void *)GetProcAddress(backend,"ReadyInputTestCapture");}
    if(!seed||!raw_get||!stats_get||!get||!set||!capture){out("{\"error\":\"MissingExport\"}\n");ExitProcess(2);}struct ready_xinput_capture info={0};capture(&info);out("{\"ready\":true");field("nativePid",info.unix_pid);field("pointerBits",sizeof(void*)*8);out("}\n");
    DWORD packet=10;char command[80];for(;;){DWORD read=0;unsigned length=0;while(length<79){char c;if(!ReadFile(GetStdHandle((DWORD)-10),&c,1,&read,NULL)||!read)ExitProcess(0);if(c=='\n')break;command[length++]=c;}command[length]=0;if(equal(command,"exit"))ExitProcess(0);
        if(equal(command,"seed-a")||equal(command,"seed-b")||equal(command,"seed-neutral")){XINPUT_STATE state={0};state.dwPacketNumber=++packet;if(equal(command,"seed-a")){state.Gamepad.wButtons=XINPUT_GAMEPAD_A|XINPUT_GAMEPAD_START|0x0400;state.Gamepad.bLeftTrigger=255;state.Gamepad.sThumbLX=20000;}else if(equal(command,"seed-b"))state.Gamepad.wButtons=XINPUT_GAMEPAD_B;seed(0,&state,TRUE);out("{\"seeded\":true}\n");continue;}
        XINPUT_STATE state={0},raw={0},extended={0};XINPUT_KEYSTROKE stroke={0};XINPUT_VIBRATION vibration={77,99};struct stats values={0};BOOL key_only=equal(command,"key-only");DWORD ret=key_only?0:get(0,&state),raw_ret=raw_get(0,&raw),ex_ret=(!key_only&&get_ex)?get_ex(0,&extended):ERROR_NOT_SUPPORTED,key_ret=key?key(0,0,&stroke):ERROR_NOT_SUPPORTED;
        if(equal(command,"rumble"))set(0,&vibration);stats_get(0,&values);capture(&info);out("{\"sample\":true");field("result",ret);field("buttons",state.Gamepad.wButtons);field("leftTrigger",state.Gamepad.bLeftTrigger);field("leftX",(DWORD)(LONG)state.Gamepad.sThumbLX);field("packet",state.dwPacketNumber);field("rawResult",raw_ret);field("rawButtons",raw.Gamepad.wButtons);field("extendedResult",ex_ret);field("extendedButtons",extended.Gamepad.wButtons);field("keystrokeResult",key_ret);field("virtualKey",stroke.VirtualKey);field("keyFlags",stroke.Flags);field("rumbleCalls",values.calls);field("leftMotor",values.vibration.wLeftMotorSpeed);field("rightMotor",values.vibration.wRightMotorSpeed);field("active",info.active);field("visible",info.visible);field("nativePid",info.unix_pid);out("}\n");
    }
}
