/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Included in a copied Wine xinput1_3/main.c after its physical state getter. */
#include "wine/unixlib.h"
#include "runtime_xinput_protocol.h"
static SRWLOCK ready_input_lock=SRWLOCK_INIT;
static SRWLOCK ready_keystroke_lock=SRWLOCK_INIT;
static XINPUT_GAMEPAD ready_last_key_state[XUSER_MAX_COUNT];
static BOOL ready_release_latch[XUSER_MAX_COUNT];
static DWORD ready_packet_epoch;
static DWORD ready_seen_epoch_low,ready_seen_epoch_high;
static BOOL ready_have_epoch;
static struct ready_xinput_capture ready_capture;
static INIT_ONCE ready_unix_once=INIT_ONCE_STATIC_INIT;
static BOOL ready_unix_available;
static DWORD ready_physical_get_keystroke(DWORD,DWORD,XINPUT_KEYSTROKE *);

#ifdef READY_XINPUT_TEST_PROVIDER
static INIT_ONCE ready_test_once=INIT_ONCE_STATIC_INIT;
static DWORD (WINAPI *ready_test_get)(DWORD,XINPUT_STATE *);
static DWORD (WINAPI *ready_test_set)(DWORD,XINPUT_VIBRATION *);
static BOOL CALLBACK ready_load_test(INIT_ONCE *once,void *argument,void **context){
    WCHAR path[4096];HMODULE provider;(void)once;(void)argument;(void)context;
    if(GetEnvironmentVariableW(L"M1L_XINPUT_TEST_PROVIDER",path,ARRAY_SIZE(path))&&
       (provider=LoadLibraryExW(path,NULL,LOAD_WITH_ALTERED_SEARCH_PATH))){ready_test_get=(void *)GetProcAddress(provider,"ReadyTestGetState");ready_test_set=(void *)GetProcAddress(provider,"ReadyTestSetState");}
    return TRUE;
}
#endif
static DWORD ready_raw_get_state(DWORD index,XINPUT_STATE *state){
#ifdef READY_XINPUT_TEST_PROVIDER
    InitOnceExecuteOnce(&ready_test_once,ready_load_test,NULL,NULL);
    return ready_test_get?ready_test_get(index,state):ERROR_DEVICE_NOT_CONNECTED;
#else
    return ready_physical_get_state(index,state);
#endif
}
static DWORD ready_raw_set_state(DWORD index,XINPUT_VIBRATION *vibration){
#ifdef READY_XINPUT_TEST_PROVIDER
    InitOnceExecuteOnce(&ready_test_once,ready_load_test,NULL,NULL);
    return ready_test_set?ready_test_set(index,vibration):ERROR_DEVICE_NOT_CONNECTED;
#else
    return ready_physical_set_state(index,vibration);
#endif
}
/* Preserve Wine's raw state path for its keystroke synthesis. */
static DWORD xinput_get_state(DWORD index,XINPUT_STATE *state){return ready_raw_get_state(index,state);}
static BOOL CALLBACK ready_initialize_unix(INIT_ONCE *once,void *argument,void **context){
    (void)once;(void)argument;(void)context;ready_unix_available=!__wine_init_unix_call();return TRUE;
}
static BOOL ready_neutral(const XINPUT_GAMEPAD *pad){
    return !pad->wButtons&&pad->bLeftTrigger<=XINPUT_GAMEPAD_TRIGGER_THRESHOLD&&pad->bRightTrigger<=XINPUT_GAMEPAD_TRIGGER_THRESHOLD&&
        pad->sThumbLX>=-XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE&&pad->sThumbLX<=XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE&&
        pad->sThumbLY>=-XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE&&pad->sThumbLY<=XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE&&
        pad->sThumbRX>=-XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE&&pad->sThumbRX<=XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE&&
        pad->sThumbRY>=-XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE&&pad->sThumbRY<=XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE;
}
static void ready_refresh_capture(void){
    struct ready_xinput_capture next={0};BOOL previous=ready_capture.active&&ready_capture.visible;
    BOOL new_interval;
    InitOnceExecuteOnce(&ready_unix_once,ready_initialize_unix,NULL,NULL);
    if(ready_unix_available&&WINE_UNIX_CALL(0,&next))memset(&next,0,sizeof(next));
    new_interval=next.active&&((!ready_have_epoch&&(next.capture_epoch_low||next.capture_epoch_high))||(ready_have_epoch&&(next.capture_epoch_low!=ready_seen_epoch_low||next.capture_epoch_high!=ready_seen_epoch_high)));
    if(next.active){ready_seen_epoch_low=next.capture_epoch_low;ready_seen_epoch_high=next.capture_epoch_high;ready_have_epoch=TRUE;}
    if(previous!=(BOOL)(next.active&&next.visible)||new_interval)ready_packet_epoch++;
    ready_capture=next;
    if(!next.active)memset(ready_release_latch,0,sizeof(ready_release_latch));
    else if((next.visible&&!previous)||new_interval){
        XINPUT_VIBRATION zero={0};
        for(DWORD i=0;i<XUSER_MAX_COUNT;i++){ready_release_latch[i]=TRUE;ready_raw_set_state(i,&zero);}
    }
}
/* Called with ready_input_lock held. One final neutral sample drains release edges. */
static BOOL ready_capture_player(DWORD index,const XINPUT_GAMEPAD *raw){
    if(!ready_capture.active)return FALSE;
    if(ready_capture.visible){ready_release_latch[index]=TRUE;return TRUE;}
    if(ready_release_latch[index]){if(ready_neutral(raw)){ready_release_latch[index]=FALSE;ready_packet_epoch++;}return TRUE;}
    return FALSE;
}
static void ready_filter_state(DWORD index,XINPUT_STATE *state){
    AcquireSRWLockExclusive(&ready_input_lock);ready_refresh_capture();
    if(ready_capture_player(index,&state->Gamepad)){
        AcquireSRWLockExclusive(&ready_keystroke_lock);ready_last_key_state[index]=state->Gamepad;ReleaseSRWLockExclusive(&ready_keystroke_lock);
        memset(&state->Gamepad,0,sizeof(state->Gamepad));
    }else if(ready_capture.active)state->Gamepad.wButtons&=~XINPUT_GAMEPAD_START;
    if(ready_capture.active)state->dwPacketNumber+=ready_packet_epoch;
    ReleaseSRWLockExclusive(&ready_input_lock);
}
DWORD WINAPI DECLSPEC_HOTPATCH XInputSetState(DWORD index,XINPUT_VIBRATION *vibration){
    DWORD ret;XINPUT_STATE raw;XINPUT_VIBRATION zero={0};
    if(index>=XUSER_MAX_COUNT||!vibration)return ERROR_BAD_ARGUMENTS;
    AcquireSRWLockExclusive(&ready_input_lock);ready_refresh_capture();
    ret=ready_raw_get_state(index,&raw);
    if(!ret&&ready_capture_player(index,&raw.Gamepad))vibration=&zero;
    if(!ret)ret=ready_raw_set_state(index,vibration);
    ReleaseSRWLockExclusive(&ready_input_lock);return ret;
}
DWORD WINAPI DECLSPEC_HOTPATCH XInputGetKeystroke(DWORD index,DWORD reserved,XINPUT_KEYSTROKE *keystroke){
    DWORD ret;if((index>=XUSER_MAX_COUNT&&index!=XUSER_INDEX_ANY)||!keystroke)return ERROR_BAD_ARGUMENTS;
    AcquireSRWLockExclusive(&ready_input_lock);ready_refresh_capture();ret=ready_physical_get_keystroke(index,reserved,keystroke);ReleaseSRWLockExclusive(&ready_input_lock);return ret;
}
#ifdef READY_XINPUT_TEST_PROVIDER
DWORD WINAPI ReadyInputTestCapture(struct ready_xinput_capture *capture){
    AcquireSRWLockExclusive(&ready_input_lock);ready_refresh_capture();*capture=ready_capture;ReleaseSRWLockExclusive(&ready_input_lock);return ERROR_SUCCESS;
}
#endif
