/* SPDX-License-Identifier: GPL-3.0-only */
/* Independent bounded anonymous-pipe handoff. No credentials in argv/env/logs.
 * Wire: RDYAUTH1 | accountLen:u32be | tokenLen:u32be | steamID:u64be |
 * appID:u32be | account ASCII | token ASCII | EOF. No raw ticket transport.
 * One 3-second CLOCK_MONOTONIC budget covers the complete frame AND EOF.
 * The caller owns this read descriptor and supplies a private anonymous pipe;
 * a FIFO-type check alone does not authenticate the writer or its identity. */
#ifndef READY_STEAM_HOST_CREDENTIAL_H
#define READY_STEAM_HOST_CREDENTIAL_H
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
typedef struct {
    uint64_t steam_id;
    uint32_t app_id;
    char account[65],token[8193];
} ready_steam_credential;
static void ready_credential_zero(void *memory,size_t size) {
    /* Volatile stores keep this standalone on Darwin without assuming the
     * non-Darwin explicit_bzero API or an optional libc extension. */
    volatile unsigned char *out=memory;while(size--)*out++=0;
}
static void ready_steam_credential_clear(ready_steam_credential *value) {
    ready_credential_zero(value,sizeof *value);
}
static uint32_t ready_u32be(const unsigned char *p) {
    return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
}
static int ready_credential_remaining(const struct timespec *deadline) {
    struct timespec now;
    if(clock_gettime(CLOCK_MONOTONIC,&now))return -1;
    int64_t ns=((int64_t)deadline->tv_sec-now.tv_sec)*1000000000+(deadline->tv_nsec-now.tv_nsec);
    if(ns<=0){errno=ETIMEDOUT;return -1;}
    return (int)((ns+999999)/1000000);
}
static int ready_credential_wait(int fd,const struct timespec *deadline) {
    for(;;){
        int timeout=ready_credential_remaining(deadline);if(timeout<0)return -1;
        struct pollfd wait={fd,POLLIN,0};int rc=poll(&wait,1,timeout);
        if(rc<0&&errno==EINTR)continue;
        if(rc<0)return -1;
        if(rc==0){errno=ETIMEDOUT;return -1;}
        if(ready_credential_remaining(deadline)<0)return -1;
        if(wait.revents&POLLNVAL){errno=EBADF;return -1;}
        /* HUP can accompany buffered bytes. read() drains them and then reports
         * EOF; it must not be treated as an immediate truncated frame. */
        if(wait.revents&(POLLIN|POLLHUP))return 0;
        errno=EIO;return -1;
    }
}
static int ready_read_exact(int fd,void *data,size_t length,const struct timespec *deadline) {
    unsigned char *out=data;
    while(length) {
        if(ready_credential_wait(fd,deadline))return -1;
        ssize_t count=read(fd,out,length);
        if(count<0&&(errno==EINTR||errno==EAGAIN))continue;
        if(count<0)return -1;
        if(count==0){errno=EPROTO;return -1;}
        out+=count;length-=(size_t)count;
    }
    return 0;
}
static int ready_credential_eof(int fd,const struct timespec *deadline) {
    for(;;){
        if(ready_credential_wait(fd,deadline))return -1;
        unsigned char extra=0;ssize_t count=read(fd,&extra,1);
        ready_credential_zero(&extra,sizeof extra);
        if(count<0&&(errno==EINTR||errno==EAGAIN))continue;
        if(count<0)return -1;
        if(count>0){errno=EPROTO;return -1;}
        return 0;
    }
}
static int ready_steam_credential_read(int fd,ready_steam_credential *value) {
    if(!value){errno=EINVAL;return -1;}
    unsigned char header[28]={0};memset(value,0,sizeof *value);
    int flags=-1,restore=0;struct stat info;struct timespec deadline;
    if(clock_gettime(CLOCK_MONOTONIC,&deadline))goto invalid;
    deadline.tv_sec+=3;
    if(fstat(fd,&info))goto invalid;
    if(!S_ISFIFO(info.st_mode)){errno=EINVAL;goto invalid;}
    flags=fcntl(fd,F_GETFL);
    if(flags<0)goto invalid;
    if((flags&O_ACCMODE)==O_WRONLY){errno=EBADF;goto invalid;}
    /* A second reader or a short readiness race cannot turn a ready poll into
     * an unbounded blocking read. Restore the caller's original flags below. */
    if(!(flags&O_NONBLOCK)){
        if(fcntl(fd,F_SETFL,flags|O_NONBLOCK))goto invalid;
        restore=1;
    }
    if(ready_read_exact(fd,header,sizeof header,&deadline))goto invalid;
    if(memcmp(header,"RDYAUTH1",8)){errno=EPROTO;goto invalid;}
    uint32_t account_length=ready_u32be(header+8),token_length=ready_u32be(header+12);
    value->steam_id=((uint64_t)ready_u32be(header+16)<<32)|ready_u32be(header+20);
    value->app_id=ready_u32be(header+24);
    /* Public, individual desktop identity with a nonzero account number.
     * Structural validity is not authentication or an ownership decision. */
    if(!account_length||account_length>64||!token_length||token_length>8192||!value->app_id||
       (value->steam_id>>56)!=1||((value->steam_id>>52)&15)!=1||
       ((value->steam_id>>32)&0xfffff)!=1||!(uint32_t)value->steam_id){errno=EPROTO;goto invalid;}
    if(ready_read_exact(fd,value->account,account_length,&deadline)||ready_read_exact(fd,value->token,token_length,&deadline))goto invalid;
    for(uint32_t i=0;i<account_length;i++) {
        unsigned char c=(unsigned char)value->account[i];
        if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_')){errno=EPROTO;goto invalid;}
    }
    for(uint32_t i=0;i<token_length;i++) {
        unsigned char c=(unsigned char)value->token[i];if(c<33||c>126){errno=EPROTO;goto invalid;}
    }
    if(ready_credential_eof(fd,&deadline))goto invalid;
    if(restore&&fcntl(fd,F_SETFL,flags))goto invalid;
    ready_credential_zero(header,sizeof header);return 0;
invalid:;
    int failure=errno;
    if(restore)(void)fcntl(fd,F_SETFL,flags);
    ready_credential_zero(header,sizeof header);ready_steam_credential_clear(value);errno=failure;return -1;
}
#endif
