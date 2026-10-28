/* SPDX-License-Identifier: GPL-3.0-only */
/* Independent interoperability probe. No GameNative implementation is copied.
 * CreateInterface factory convention is documented by Valve's public interface.h.
 * Factory/research modes use no real credentials. The explicit bounded candidate
 * accepts only private caller-supplied stdin, with no app/DRM/closed-host EXE calls.
 * --invalid-auth uses only public fixed synthetic strings under IP denial.
 * Running this probe loads proprietary Valve DLL code: build does not execute it. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "steam_windows_login_abi.h"
#include "steam_windows_credential.h"
static DWORD visible_windows;
static BOOL CALLBACK own_visible_window(HWND window,LPARAM ignored){DWORD pid=0;(void)ignored;GetWindowThreadProcessId(window,&pid);if(pid==GetCurrentProcessId()&&IsWindowVisible(window))visible_windows++;return TRUE;}
static DWORD window_count(void){visible_windows=0;EnumWindows(own_visible_window,0);return visible_windows;}
typedef void *(__cdecl *FactoryFn)(const char *,int *);
/* These C-export ABIs are pinned to the six signed DLL hashes in the driver.
 * Valve PE32 wrappers have plain ret; PE64 forwards to slots2,6,1 respectively.
 * Lifecycle-only modes use C exports. Explicit authentication uses the separately
 * pinned Windows member ABI declarations; no Mac offsets are transplanted. */
typedef INT (__cdecl *CreateUserFn)(INT *);
typedef INT (__cdecl *CreatePipeFn)(void);
typedef INT (__cdecl *ConnectUserFn)(INT);
typedef void (__cdecl *ReleaseUserFn)(INT,INT);
typedef unsigned char (__cdecl *ReleasePipeFn)(INT);
static HANDLE event_output;
static ReadyWindowsCredential private_credential;
static ULONGLONG credential_read_began;
static void finish(DWORD code){ready_windows_zero(&private_credential,sizeof private_credential);if(event_output)CloseHandle(event_output);ExitProcess(code);}
static void out(const char *text){DWORD bytes=0,written;while(text[bytes])bytes++;WriteFile(event_output?event_output:GetStdHandle(STD_OUTPUT_HANDLE),text,bytes,&written,NULL);}
static void number(DWORD value){char bytes[16];unsigned used=0;do{bytes[used++]='0'+value%10;value/=10;}while(value);while(used){char c[2]={bytes[--used],0};out(c);}}
static int equal(const WCHAR *a,const WCHAR *b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static BOOL in_selected_directory(HMODULE module,const WCHAR *selected,const WCHAR *basename){static WCHAR actual[4096],expected[4096];DWORD n=GetModuleFileNameW(module,actual,4096);unsigned i=0,end=0;if(!n||n>=4096)return FALSE;while(selected[i]&&i<4000){expected[i]=selected[i];if(selected[i]=='\\'||selected[i]=='/')end=i+1;i++;}i=end;while(*basename&&i<4095)expected[i++]=*basename++;expected[i]=0;return !*basename&&equal(actual,expected);}
static void field(const char *name,BOOL value){out(",\"");out(name);out("\":");out(value?"true":"false");}
static void user_event(const char *stage,INT user,INT pipe){out("{\"stage\":\"");out(stage);out("\",\"userHandle\":");number((DWORD)user);out(",\"pipeHandle\":");number((DWORD)pipe);out("}\n");}
static void wire_hard_timeout_event(void){out("{\"stage\":\"credential-parser\",\"parseStatus\":2,\"accepted\":false,\"credentialBufferWiped\":false,\"parseThreadQuiescent\":false,\"processRAMReclaimedOnExit\":true,\"ValveLoaded\":false,\"milliseconds\":");number((DWORD)(GetTickCount64()-credential_read_began));out("}\n");}
static BOOL flag(const WCHAR *name){for(const WCHAR *p=GetCommandLineW();*p;p++)if(*p=='-'&&p[1]=='-'){const WCHAR *q=p,*f=name;while(*f&&*q==*f){q++;f++;}if(!*f&&(!*q||*q==' '||*q=='\t'))return TRUE;}return FALSE;}
void mainCRTStartup(void)
{
    BOOL authenticate=flag(L"--authenticate-bounded"),parse_only=flag(L"--credential-parse-only"),invalid_auth=flag(L"--invalid-auth"),public_shutdown=flag(L"--public-shutdown")||authenticate,serve_user=flag(L"--serve-user"),connect_user=flag(L"--connect-user"),create_user=flag(L"--create-user")||serve_user||invalid_auth||authenticate;
    static WCHAR event_path[4096];DWORD event_count=GetEnvironmentVariableW(L"READY_STEAM_WINDOWS_EVENT_FILE",event_path,4096);
    if(event_count&&event_count<4096&&event_path[1]==':'&&(event_path[2]=='\\'||event_path[2]=='/'))event_output=CreateFileW(event_path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(event_output==INVALID_HANDLE_VALUE)event_output=NULL;
    if((create_user||connect_user||parse_only)&&!event_output){out("{\"stage\":\"input\",\"error\":\"User modes require new private event file\"}\n");finish(2);}
    if(authenticate||parse_only){ready_windows_uncancellable_timeout=wire_hard_timeout_event;ULONGLONG began=GetTickCount64();credential_read_began=began;HANDLE input=GetStdHandle(STD_INPUT_HANDLE);DWORD input_type=GetFileType(input);user_event("credential-read-entered",0,0);DWORD wire=ready_windows_credential_read(input,&private_credential);DWORD wire_error=GetLastError();if(input&&input!=INVALID_HANDLE_VALUE)CloseHandle(input);if(wire||parse_only){ready_windows_zero(&private_credential,sizeof private_credential);out("{\"stage\":\"credential-parser\",\"parseStatus\":");number(wire);out(",\"inputFileType\":");number(input_type);out(",\"lastWin32Error\":");number(wire_error);field("accepted",wire==READY_WIRE_OK);field("credentialBufferWiped",ready_windows_is_zero(&private_credential,sizeof private_credential));field("parseThreadQuiescent",ready_windows_read_thread_quiescent);field("readThreadFallbackUsed",ready_windows_read_thread_used);field("ValveLoaded",FALSE);out(",\"milliseconds\":");number((DWORD)(GetTickCount64()-began));out("}\n");finish(wire?2:0);}}
    BOOL console_private=FALSE;
    if(authenticate){HANDLE nul=CreateFileW(L"NUL",GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);if(nul==INVALID_HANDLE_VALUE)finish(2);HANDLE oldout=GetStdHandle(STD_OUTPUT_HANDLE),olderr=GetStdHandle(STD_ERROR_HANDLE);if(!SetStdHandle(STD_OUTPUT_HANDLE,nul)||!SetStdHandle(STD_ERROR_HANDLE,nul))finish(2);if(oldout&&oldout!=INVALID_HANDLE_VALUE&&oldout!=event_output&&oldout!=nul)CloseHandle(oldout);if(olderr&&olderr!=INVALID_HANDLE_VALUE&&olderr!=oldout&&olderr!=event_output&&olderr!=nul)CloseHandle(olderr);console_private=TRUE;}
    static WCHAR path[4096];DWORD count=GetEnvironmentVariableW(L"READY_STEAM_WINDOWS_CLIENT_DLL",path,4096);
    if(!count||count>=4096){out("{\"stage\":\"input\",\"error\":\"Set explicit owned Valve client DLL path; no credentials accepted\"}\n");finish(2);}
    const WCHAR *name=path;for(const WCHAR *p=path;*p;p++)if(*p=='\\'||*p=='/')name=p+1;
#if defined(_WIN64)
    const WCHAR *allowed=L"steamclient64.dll";
#else
    const WCHAR *allowed=L"steamclient.dll";
#endif
    if(!equal(name,allowed)||!((path[1]==':'&&(path[2]=='\\'||path[2]=='/'))||(path[0]=='\\'&&path[1]=='\\'))){out("{\"stage\":\"input\",\"error\":\"Only explicit Valve client DLL basename/architecture is accepted\"}\n");finish(2);}
    DWORD windows_before=window_count();
    HMODULE module=LoadLibraryExW(path,NULL,LOAD_WITH_ALTERED_SEARCH_PATH);DWORD load_error=module?0:GetLastError();
    out(create_user||connect_user?"{\"stage\":\"factory-ready\",\"pointerBits\":" : "{\"stage\":\"factory-only\",\"pointerBits\":");number(sizeof(void*)*8);field("moduleLoaded",module!=NULL);if(authenticate)field("ValveConsoleSuppressed",console_private);
    if(!module){out(",\"win32Error\":");number(load_error);out("}\n");finish(3);}
    field("clientPathMatchesRequest",in_selected_directory(module,path,allowed));
#if defined(_WIN64)
    HMODULE tier=GetModuleHandleW(L"tier0_s64.dll"),stdlib=GetModuleHandleW(L"vstdlib_s64.dll");
    field("tier0FromSelectedDirectory",tier&&in_selected_directory(tier,path,L"tier0_s64.dll"));
    field("vstdlibFromSelectedDirectory",stdlib&&in_selected_directory(stdlib,path,L"vstdlib_s64.dll"));
#else
    HMODULE tier=GetModuleHandleW(L"tier0_s.dll"),stdlib=GetModuleHandleW(L"vstdlib_s.dll");
    field("tier0FromSelectedDirectory",tier&&in_selected_directory(tier,path,L"tier0_s.dll"));
    field("vstdlibFromSelectedDirectory",stdlib&&in_selected_directory(stdlib,path,L"vstdlib_s.dll"));
#endif
    void *engine=NULL,*public_client=NULL;
    FactoryFn factory=(FactoryFn)GetProcAddress(module,"CreateInterface");field("factoryExport",factory!=NULL);
    field("callbackFetchExport",GetProcAddress(module,"Steam_BGetCallback")!=NULL);field("callbackFreeExport",GetProcAddress(module,"Steam_FreeLastCallback")!=NULL);
    if(factory){
        int error=0;engine=factory("CLIENTENGINE_INTERFACE_VERSION005",&error);field("clientEngine005",engine!=NULL);
        error=0;public_client=factory("SteamClient023",&error);field("steamClient023",public_client!=NULL);
        /* Factory-only mode stops at returned objects. Explicit research modes use the separately pinned Windows ABI declarations. */
    }
    BOOL user_created=FALSE,release_signal=FALSE,invalid_shape=FALSE;DWORD window_peak=windows_before;
    if(create_user){
        out("}\n");
        CreateUserFn create=(CreateUserFn)GetProcAddress(module,"Steam_CreateGlobalUser");
        ReleaseUserFn release=(ReleaseUserFn)GetProcAddress(module,"Steam_ReleaseUser");
        ReleasePipeFn release_pipe=(ReleasePipeFn)GetProcAddress(module,"Steam_BReleaseSteamPipe");
        INT pipe=0,user=0;BOOL released=FALSE,pipe_released=FALSE;
        if(create&&release&&release_pipe){user_event("user-create-entered",0,0);user=create(&pipe);user_event("user-create-returned",user,pipe);user_created=user>0&&pipe>0;
            if((invalid_auth||authenticate)&&user_created&&engine&&public_client){
                void **engine_table=*(void***)engine;
                void *mapped=((ReadyEngineGetUserFn)engine_table[READY_ENGINE_GET_USER])(engine,user,pipe);
                ReadySteamGetCallbackFn get_callback=(ReadySteamGetCallbackFn)GetProcAddress(module,"Steam_BGetCallback");
                ReadySteamFreeCallbackFn free_callback=(ReadySteamFreeCallbackFn)GetProcAddress(module,"Steam_FreeLastCallback");
                ReadySteamBLoggedOnFn logged_on=(ReadySteamBLoggedOnFn)GetProcAddress(module,"Steam_BLoggedOn");
                ReadySteamLogOnFn log_on=(ReadySteamLogOnFn)GetProcAddress(module,"Steam_LogOn");
                if(mapped&&get_callback&&free_callback&&logged_on&&log_on){
                    void **table=*(void***)mapped;user_event(authenticate?"bounded-auth-entered":"synthetic-auth-entered",user,pipe);
                    const char *account=authenticate?private_credential.account:"ready_offline_invalid_account",*token=authenticate?private_credential.token:"ready.invalid.synthetic.token";ULONGLONG expected_identity=authenticate?private_credential.steam_id:76561197960265728ULL;DWORD requested_app=authenticate?private_credential.app_id:0;
                    ((ReadySetLoginInformationFn)table[READY_USER_SET_LOGIN_INFORMATION])(mapped,account,"",authenticate?1:0);
                    ((ReadySetLoginTokenFn)table[READY_USER_SET_LOGIN_TOKEN])(mapped,token,account);
                    ready_windows_zero(&private_credential,sizeof private_credential);INT dispatch=log_on(user,pipe,expected_identity);DWORD callbacks=0,freed=0;BOOL callback_guards=TRUE;
                    ULONGLONG pump_began=GetTickCount64(),pump_deadline=pump_began+(authenticate?25000:2000);
                    while(GetTickCount64()<pump_deadline){for(unsigned batch=0;batch<8&&GetTickCount64()<pump_deadline;batch++){ReadySteamCallback message={0};if(!get_callback(pipe,&message))break;callbacks++;if(message.payloadBytes<0||message.payloadBytes>1048576||(!message.payload&&message.payloadBytes))callback_guards=FALSE;/* Payload remains opaque and never logged. */free_callback(pipe);freed++;}ULONGLONG now=GetTickCount64();if(now<pump_deadline)Sleep((DWORD)((pump_deadline-now)<20?(pump_deadline-now):20));}
                    ReadySteamID identity={0};ReadySteamID *identity_result=((ReadyUserGetSteamIDFn)table[READY_USER_GET_STEAM_ID])(mapped,&identity);BOOL logged=logged_on(user,pipe)!=0;
                    BOOL account_zero=(DWORD)identity.value==0,individual=((identity.value>>52)&15)==1,identity_invalid=identity.value==0||(individual&&account_zero);
                    void *apps=((ReadyPublicGetAppsFn)(*(void***)public_client)[READY_PUBLIC_CLIENT_GET_APPS])(public_client,user,pipe,"STEAMAPPS_INTERFACE_VERSION009");BOOL subscribed=FALSE;if(apps)subscribed=((ReadyPublicIsSubscribedFn)(*(void***)apps)[READY_PUBLIC_APPS_IS_SUBSCRIBED])(apps,requested_app)!=0;
                    out(authenticate?"{\"stage\":\"bounded-auth-result\",\"dispatchResult\":" : "{\"stage\":\"synthetic-auth-result\",\"dispatchResult\":");number((DWORD)dispatch);field("loggedOn",logged);field("identityInvalid",identity_invalid);field(authenticate?"identityMatchesExpected":"identityMatchesSynthetic",identity.value==expected_identity);field("identityAccountIDZero",account_zero);field("identityTypeIndividual",individual);field("hiddenIdentityReturnMatches",identity_result==&identity);field("publicApps009",apps!=NULL);field(authenticate?"ownsRequestedApp":"invalidApp0Subscribed",subscribed);field("credentialBufferWipedAfterDispatch",ready_windows_is_zero(&private_credential,sizeof private_credential));field("authenticatedReady",authenticate&&logged&&identity.value==expected_identity&&identity_result==&identity&&apps&&subscribed&&callback_guards&&callbacks==freed);field("callbackStructGuardsValid",callback_guards);out(",\"callbackPumpMilliseconds\":");number((DWORD)(GetTickCount64()-pump_began));out(",\"callbackCount\":");number(callbacks);out(",\"callbackFreeCount\":");number(freed);field("payloadInspected",FALSE);if(!authenticate)field("realCredentialsUsed",FALSE);out("}\n");invalid_shape=authenticate?(logged&&identity.value==expected_identity&&identity_result==&identity&&apps&&subscribed&&callback_guards&&callbacks==freed):(!logged&&identity_invalid&&identity_result==&identity&&apps&&!subscribed&&callback_guards&&callbacks==freed);
                }
            }
            if(serve_user&&user_created){static WCHAR release_path[4096];DWORD n=GetEnvironmentVariableW(L"READY_STEAM_WINDOWS_RELEASE_FILE",release_path,4096);if(n&&n<4096&&release_path[1]==':'&&(release_path[2]=='\\'||release_path[2]=='/'))for(unsigned i=0;i<6000;i++){DWORD now=window_count();if(now>window_peak)window_peak=now;if(GetFileAttributesW(release_path)!=INVALID_FILE_ATTRIBUTES){release_signal=TRUE;break;}Sleep(20);}}
            if(user_created){release(pipe,user);released=TRUE;user_event("user-release-returned",user,pipe);}if(pipe>0){pipe_released=release_pipe(pipe)!=0;user_event("pipe-release-returned",user,pipe);}}
        out("{\"stage\":\"factory-user-offline\"");field("userLifecycleExports",create&&release&&release_pipe);
        out(",\"userHandle\":");number((DWORD)user);out(",\"pipeHandle\":");number((DWORD)pipe);
        field("userCreated",user_created);field("releaseUserCalled",released);field("pipeReleaseSucceeded",pipe_released);
        if(serve_user)field("releaseSignalReceived",release_signal);
    }
    BOOL connect_exports=TRUE;
    if(connect_user){out("}\n");CreatePipeFn create=(CreatePipeFn)GetProcAddress(module,"Steam_CreateSteamPipe");ConnectUserFn connect=(ConnectUserFn)GetProcAddress(module,"Steam_ConnectToGlobalUser");ReleaseUserFn release=(ReleaseUserFn)GetProcAddress(module,"Steam_ReleaseUser");ReleasePipeFn release_pipe=(ReleasePipeFn)GetProcAddress(module,"Steam_BReleaseSteamPipe");connect_exports=create&&connect&&release&&release_pipe;INT pipe=0,user=0;BOOL released=FALSE,pipe_released=FALSE;if(connect_exports){pipe=create();user_event("client-pipe-created",0,pipe);if(pipe>0){user=connect(pipe);user_event("client-connect-returned",user,pipe);if(user>0){release(pipe,user);released=TRUE;}pipe_released=release_pipe(pipe)!=0;}}out("{\"stage\":\"client-connect-offline\",\"userHandle\":");number((DWORD)user);out(",\"pipeHandle\":");number((DWORD)pipe);field("connectLifecycleExports",connect_exports);field("connectedUser",user>0);field("releaseUserCalled",released);field("pipeReleaseSucceeded",pipe_released);}
    Sleep(500);out(",\"visibleWindowsBefore\":");number(windows_before);out(",\"visibleWindowsAfter\":");number(window_count());field("steamUILoaded",GetModuleHandleW(L"SteamUI.dll")!=NULL);
    out(",\"visibleWindowsPeakDuringHostWait\":");number(window_peak);
    field("credentialsRead",authenticate);field("authenticationAttempted",invalid_auth||authenticate);if(!authenticate)field("realAccountAuthenticationAttempted",FALSE);else field("privateStdinAuthenticationAttempted",TRUE);field("gameLaunchAttempted",FALSE);field("closedHelperExecuted",FALSE);field("ownershipEmulated",FALSE);out("}\n");
    if(public_shutdown&&public_client){user_event("public-shutdown-entered",0,0);ReadySteamBool done=((ReadyPublicShutdownFn)(*(void***)public_client)[READY_PUBLIC_CLIENT_SHUTDOWN_IF_NO_PIPES])(public_client);out("{\"stage\":\"public-shutdown-returned\"");field("shutdownIfNoPipes",done!=0);out("}\n");}
    FreeLibrary(module);finish(factory&&connect_exports&&(!create_user||user_created)&&(!serve_user||release_signal)&&(!(invalid_auth||authenticate)||invalid_shape)?0:4);
}
