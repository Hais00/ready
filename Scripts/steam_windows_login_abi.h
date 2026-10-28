/* SPDX-License-Identifier: GPL-3.0-only */
/* Independent interoperability declarations, scoped to the exact signed Valve
 * Windows DLL hashes in windows-login-abi.json. Static ABI evidence, not a
 * successful authentication or permission to redistribute proprietary DLLs. */
#ifndef READY_WINDOWS_STEAM_LOGIN_ABI_H
#define READY_WINDOWS_STEAM_LOGIN_ABI_H
#include <windows.h>
#include <stddef.h>
#ifdef _WIN64
#define READY_STEAM_MEMBER
#else
#define READY_STEAM_MEMBER __thiscall
#endif
typedef unsigned char ReadySteamBool;
typedef struct { ULONGLONG value; } ReadySteamID;
typedef struct {
    INT user;
    INT callback;
    void *payload;
    INT payloadBytes;
} ReadySteamCallback;
_Static_assert(sizeof(INT)==4,"Windows handles and callback IDs are32bit");
_Static_assert(sizeof(ReadySteamID)==8,"SteamID object payload");
_Static_assert(offsetof(ReadySteamCallback,payload)==8,"callback payload offset");
_Static_assert(offsetof(ReadySteamCallback,payloadBytes)==8+sizeof(void*),"callback size offset");
_Static_assert(sizeof(ReadySteamCallback)==(sizeof(void*)==8?24:16),"callback architecture ABI");
enum {
    READY_ENGINE_GET_USER=8,
    READY_USER_LOG_ON=1,
    READY_USER_BLOGGED_ON=4,
    READY_USER_GET_STEAM_ID=10,
    READY_USER_SET_LOGIN_INFORMATION=54,
    READY_USER_SET_LOGIN_TOKEN=56,
    READY_USER_BIS_SUBSCRIBED_APP=181,
    READY_PUBLIC_CLIENT_GET_APPS=15,
    READY_PUBLIC_CLIENT_SHUTDOWN_IF_NO_PIPES=22,
    READY_PUBLIC_APPS_IS_SUBSCRIBED=6
};
typedef void *(READY_STEAM_MEMBER *ReadyEngineGetUserFn)(void*,INT,INT);
typedef void (READY_STEAM_MEMBER *ReadySetLoginInformationFn)(void*,const char *account,const char *password,ReadySteamBool remember);
typedef void (READY_STEAM_MEMBER *ReadySetLoginTokenFn)(void*,const char *token,const char *account);
typedef INT (READY_STEAM_MEMBER *ReadyUserLogOnFn)(void*,ULONGLONG steamID);
typedef ReadySteamBool (READY_STEAM_MEMBER *ReadyUserBLoggedOnFn)(void*);
/* Windows MSVC returns CSteamID through a hidden buffer, unlike the Mac ABI. */
typedef ReadySteamID *(READY_STEAM_MEMBER *ReadyUserGetSteamIDFn)(void*,ReadySteamID*);
typedef ReadySteamBool (READY_STEAM_MEMBER *ReadyUserIsSubscribedFn)(void*,DWORD appID);
typedef ReadySteamBool (__cdecl *ReadySteamGetCallbackFn)(INT pipe,ReadySteamCallback *message);
typedef void (__cdecl *ReadySteamFreeCallbackFn)(INT pipe);
typedef ReadySteamBool (__cdecl *ReadySteamBLoggedOnFn)(INT user,INT pipe);
typedef INT (__cdecl *ReadySteamLogOnFn)(INT user,INT pipe,ULONGLONG steamID);
typedef void *(READY_STEAM_MEMBER *ReadyPublicGetAppsFn)(void*,INT user,INT pipe,const char *version);
typedef ReadySteamBool (READY_STEAM_MEMBER *ReadyPublicIsSubscribedFn)(void*,DWORD appID);
typedef ReadySteamBool (READY_STEAM_MEMBER *ReadyPublicShutdownFn)(void*);
/* Fetch, inspect/copy a bounded payload, then free on the SAME worker thread;
 * never retain Valve's payload pointer or fetch again before releasing it. */
#endif
