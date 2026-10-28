/* SPDX-License-Identifier: GPL-3.0-only */
/* Test-only native image observer: one atomic append per JSON record. */
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
static int audit_fd=-1;
static void image_added(const struct mach_header *header,intptr_t slide){
    (void)slide;Dl_info info={0};if(audit_fd<0||!dladdr(header,&info)||!info.dli_fname)return;
    char record[4096];int at=snprintf(record,sizeof(record),"{\"pid\":%d,\"path\":\"",getpid());
    for(const unsigned char *p=(const unsigned char *)info.dli_fname;*p&&at<(int)sizeof(record)-8;p++){
        if(*p=='\\'||*p=='\"')record[at++]='\\';
        if(*p<32)continue;record[at++]=(char)*p;
    }
    record[at++]='\"';record[at++]='}';record[at++]='\n';
    /* O_APPEND plus a single write prevents interleaving across Wine children. */
    (void)write(audit_fd,record,(size_t)at);
}
__attribute__((constructor)) static void initialize_audit(void){
    const char *path=getenv("READY_NATIVE_AUDIT_LOG");if(!path||path[0]!='/')return;
    audit_fd=open(path,O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC,0600);if(audit_fd>=0)_dyld_register_func_for_add_image(image_added);
}
