/* SPDX-License-Identifier: GPL-3.0-only */
/* Native reader unit probe only: no Wine, GPU, controller device or prefix. */
#include <stdio.h>
#include "runtime_xinput_unix.c"
static int owned_text(const char *path,const char *text)
{
    int fd=open(path,O_CREAT|O_WRONLY|O_TRUNC,0600);
    if(fd<0)return 0;
    size_t bytes=strlen(text);ssize_t written=write(fd,text,bytes);close(fd);
    return written==(ssize_t)bytes;
}
int main(void)
{
    char directory[]="/tmp/ready-xinput-native-optin-XXXXXX",control[512],status[512],json[1024];
    if(!mkdtemp(directory))return 2;
    snprintf(control,sizeof(control),"%s/control.json",directory);
    snprintf(status,sizeof(status),"%s/overlay-status.json",directory);
    snprintf(json,sizeof(json),"{\"pid\":%u,\"visible\":true,\"controlSequence\":1,\"frameCount\":2,\"injectionSupported\":true,\"metal3Hooked\":true,\"heartbeatActive\":true,\"inputCaptureEpoch\":9}",(unsigned)getpid());
    if(!owned_text(control,"{\"sequence\":1,\"visible\":true}")||!owned_text(status,json))return 3;
    setenv("M1L_CONTROL_FILE",control,1);setenv("M1L_OVERLAY_STATUS",status,1);
    const char *flags[]={NULL,"0","true","01","1"};unsigned passed=0;
    for(unsigned i=0;i<sizeof(flags)/sizeof(flags[0]);i++){
        if(flags[i])setenv("M1L_XINPUT_CAPTURE",flags[i],1);else unsetenv("M1L_XINPUT_CAPTURE");
        struct ready_xinput_capture capture={0};read_capture(&capture);
        unsigned expected=flags[i]&&!strcmp(flags[i],"1");
        if(capture.unix_pid==(unsigned)getpid()&&capture.active==expected&&capture.visible==expected&&(!expected||capture.capture_epoch_low==9))passed++;
    }
    unlink(control);unlink(status);rmdir(directory);
    printf("{\"protocolVersion\":2,\"nativeUnitOnly\":true,\"winePrefixStarted\":false,\"cases\":5,\"passedCases\":%u,\"passed\":%s}\n",passed,passed==5?"true":"false");
    return passed==5?0:4;
}
