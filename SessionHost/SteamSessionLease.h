// SPDX-License-Identifier: GPL-3.0-only
#ifndef READY_STEAM_SESSION_LEASE_H
#define READY_STEAM_SESSION_LEASE_H
#include <stdint.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
/* A private anonymous socket capability, not a named IPC address. Stream EOF is
 * part of the frame; one monotonic budget covers bytes, ancillary data and EOF. */
static int ready_steam_bootstrap_remaining(const struct timespec *deadline) {
    struct timespec now;if(clock_gettime(CLOCK_MONOTONIC,&now))return -1;
    int64_t ns=((int64_t)deadline->tv_sec-now.tv_sec)*1000000000+deadline->tv_nsec-now.tv_nsec;
    if(ns<=0){errno=ETIMEDOUT;return -1;}return (int)((ns+999999)/1000000);
}
static int ready_steam_bootstrap_wait(int fd,short events,const struct timespec *deadline) {
    for(;;){int ms=ready_steam_bootstrap_remaining(deadline);if(ms<0)return -1;
        struct pollfd p={fd,events,0};int rc=poll(&p,1,ms);
        if(rc<0&&errno==EINTR)continue;
        if(rc<=0){if(!rc)errno=ETIMEDOUT;return -1;}
        if(p.revents&POLLNVAL){errno=EBADF;return -1;}
        if(p.revents&(events|POLLHUP))return 0;errno=EIO;return -1;
    }
}
/* 1 means writer still present with no data, 0 EOF, -1 invalid/data/error. */
static int ready_steam_health_alive(int fd) {
    struct pollfd p={fd,POLLIN,0};int rc=poll(&p,1,0);
    if(rc<0&&errno==EINTR)return 1;
    if(rc<0||p.revents&POLLNVAL)return -1;
    if(!rc)return 1;
    if(p.revents&(POLLIN|POLLHUP|POLLERR)) {
        char byte;ssize_t n=read(fd,&byte,1);
        if(n==0)return 0;
        if(n<0&&(errno==EAGAIN||errno==EINTR))return 1;
        return -1; /* This lease is presence-only: no payload is permitted. */
    }
    return -1;
}
static int ready_steam_receive_leases(int *health,int *control) {
    int received[64],count=0,success=0;unsigned char frame[8];size_t used=0;
    struct stat socket_info;struct sockaddr_un address;socklen_t address_size=sizeof address;
    uid_t peer;gid_t peer_group;int type=0;socklen_t type_size=sizeof type;
    if(fstat(0,&socket_info)||!S_ISSOCK(socket_info.st_mode)||getpeereid(0,&peer,&peer_group)||peer!=geteuid()||
       getsockname(0,(struct sockaddr *)&address,&address_size)||address.sun_family!=AF_UNIX||
       getsockopt(0,SOL_SOCKET,SO_TYPE,&type,&type_size)||type!=SOCK_STREAM)return -1;
    struct timespec deadline;if(clock_gettime(CLOCK_MONOTONIC,&deadline))return -1;deadline.tv_sec+=3;
    int flags=fcntl(0,F_GETFL);if(flags<0||fcntl(0,F_SETFL,flags|O_NONBLOCK))return -1;
    for(;;){
        if(ready_steam_bootstrap_wait(0,POLLIN,&deadline))goto finish;
        unsigned char extra;struct iovec vector={used<sizeof frame?frame+used:&extra,used<sizeof frame?sizeof frame-used:1};
        union {struct cmsghdr align;unsigned char bytes[CMSG_SPACE(64*sizeof(int))];} ancillary;
        memset(&ancillary,0,sizeof ancillary);struct msghdr message={0};message.msg_iov=&vector;message.msg_iovlen=1;
        message.msg_control=ancillary.bytes;message.msg_controllen=sizeof ancillary.bytes;
        ssize_t n=recvmsg(0,&message,MSG_DONTWAIT);
        if(n<0&&(errno==EINTR||errno==EAGAIN))continue;if(n<0)goto finish;
        int invalid=(message.msg_flags&(MSG_CTRUNC|MSG_TRUNC))!=0;
        for(struct cmsghdr *c=CMSG_FIRSTHDR(&message);c;c=CMSG_NXTHDR(&message,c)) {
            if(c->cmsg_level!=SOL_SOCKET||c->cmsg_type!=SCM_RIGHTS||c->cmsg_len<CMSG_LEN(0)||
               (c->cmsg_len-CMSG_LEN(0))%sizeof(int)){invalid=1;continue;}
            size_t entries=(c->cmsg_len-CMSG_LEN(0))/sizeof(int);int *fds=(int *)CMSG_DATA(c);
            for(size_t i=0;i<entries;i++) {
                int fd=fds[i];if(count<64)received[count++]=fd;else{close(fd);invalid=1;}
                if(fcntl(fd,F_SETFD,FD_CLOEXEC))invalid=1;
            }
        }
        if(invalid)goto finish;
        if(n==0){if(used!=sizeof frame)goto finish;break;}
        if(used==sizeof frame)goto finish;
        used+=(size_t)n;
    }
    if(count!=2||memcmp(frame,"RDYSLF1\0",8))goto finish;
    struct stat prefix,pipe;int health_flags=fcntl(received[1],F_GETFL);
    if(fstat(received[0],&prefix)||!S_ISREG(prefix.st_mode)||prefix.st_uid!=geteuid()||
       fstat(received[1],&pipe)||!S_ISFIFO(pipe.st_mode)||pipe.st_uid!=geteuid()||
       health_flags<0||(health_flags&O_ACCMODE)!=O_RDONLY||fcntl(received[1],F_SETFL,health_flags|O_NONBLOCK))goto finish;
    if(ready_steam_health_alive(received[1])!=1)goto finish;
    *control=fcntl(0,F_DUPFD_CLOEXEC,3);if(*control<0)goto finish;
    int no_pipe=1;
    if(setsockopt(*control,SOL_SOCKET,SO_NOSIGPIPE,&no_pipe,sizeof no_pipe)||dup2(received[0],0)<0){close(*control);*control=-1;goto finish;}
    *health=received[1];received[1]=-1;success=1;
finish:
    for(int i=0;i<count;i++)if(received[i]>=0)close(received[i]);
    return success?0:-1;
}
static int ready_steam_acknowledge(int fd) {
    struct timespec deadline;if(clock_gettime(CLOCK_MONOTONIC,&deadline))return -1;deadline.tv_sec+=3;
    const char frame[8]="RDYACK1";size_t sent=0;
    while(sent<sizeof frame){
        if(ready_steam_bootstrap_wait(fd,POLLOUT,&deadline))return -1;
        ssize_t n=send(fd,frame+sent,sizeof frame-sent,MSG_DONTWAIT);
        if(n<0&&(errno==EINTR||errno==EAGAIN))continue;if(n<=0)return -1;sent+=(size_t)n;
    }
    return 0;
}
static int ready_steam_digest_valid(const char *value) {
    if(!value||strlen(value)!=64)return 0;
    for(unsigned i=0;i<64;i++)if(!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f')))return 0;
    return 1;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int ready_steam_pinned_file(const char *path,const char *expected,const char *installation,int executable) {
    char canonical[PATH_MAX];struct stat before,after,named;
    if(!path||path[0]!='/'||!realpath(path,canonical)||strcmp(path,canonical))return 0;
    size_t root_length=strlen(installation);
    if(strncmp(path,installation,root_length)||path[root_length]!='/')return 0;
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return 0;
    int valid=0;
    if(fstat(fd,&before)||!S_ISREG(before.st_mode)||before.st_uid!=geteuid()||(before.st_mode&0022)||(executable&&!(before.st_mode&0111)))goto finish;
    CC_SHA256_CTX context;CC_SHA256_Init(&context);unsigned char bytes[65536],digest[CC_SHA256_DIGEST_LENGTH];
    for(;;){ssize_t count=read(fd,bytes,sizeof bytes);if(count<0&&errno==EINTR)continue;if(count<0)goto finish;if(!count)break;CC_SHA256_Update(&context,bytes,(CC_LONG)count);}
    CC_SHA256_Final(digest,&context);char actual[65];for(unsigned i=0;i<sizeof digest;i++)snprintf(actual+i*2,3,"%02x",digest[i]);
    if(strcmp(actual,expected)||fstat(fd,&after)||lstat(path,&named))goto finish;
    valid=before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&before.st_size==after.st_size&&before.st_mode==after.st_mode&&before.st_uid==after.st_uid&&
        before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&
        before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec&&
        named.st_dev==after.st_dev&&named.st_ino==after.st_ino&&S_ISREG(named.st_mode)&&!strcmp(path,canonical);
finish:
    close(fd);return valid;
}
#pragma clang diagnostic pop
static int ready_steam_validate_game_images(const char *installation,const char *executable,const char *executable_sha,const char *sdk,const char *sdk_sha) {
    char root[PATH_MAX];if(!installation||!realpath(installation,root)||!strcmp(root,"/"))return 0;
    return ready_steam_pinned_file(executable,executable_sha,root,1)&&ready_steam_pinned_file(sdk,sdk_sha,root,0);
}
#endif
