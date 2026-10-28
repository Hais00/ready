/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Session-local overlay state reader. It never reads or changes any HID device. */
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <pthread.h>
#define WINE_UNIX_LIB
#include "wine/unixlib.h"
#include "runtime_xinput_protocol.h"

struct json {const char *at,*end;};
struct state {bool have_visible,visible,have_sequence,have_pid,have_frame,have_support,have_heartbeat,have_epoch,have_metal3,have_metal4;uint64_t sequence,pid,frame,capture_epoch;bool support,metal,heartbeat;};
static void whitespace(struct json *j){while(j->at<j->end&&(*j->at==' '||*j->at=='\n'||*j->at=='\r'||*j->at=='\t'))j->at++;}
static bool string(struct json *j,char *out,size_t size){size_t n=0;whitespace(j);if(j->at==j->end||*j->at++!='"')return false;while(j->at<j->end){unsigned char c=*j->at++;if(c=='"'){if(out&&size)out[n<size?n:size-1]=0;return true;}if(c<32)return false;if(c=='\\'){if(j->at==j->end)return false;c=*j->at++;if(c=='u'){for(unsigned i=0;i<4;i++){if(j->at==j->end||!((*j->at>='0'&&*j->at<='9')||(*j->at>='a'&&*j->at<='f')||(*j->at>='A'&&*j->at<='F')))return false;j->at++;}c='?';}else if(!strchr("\"\\/bfnrt",c))return false;}if(out&&n+1<size)out[n]=c;n++;}return false;}
static bool literal(struct json *j,const char *text){size_t n=strlen(text);if((size_t)(j->end-j->at)<n||memcmp(j->at,text,n))return false;j->at+=n;return true;}
static bool number(struct json *j,uint64_t *out){uint64_t value=0;const char *start=j->at;if(start==j->end||*start<'0'||*start>'9')return false;while(j->at<j->end&&*j->at>='0'&&*j->at<='9'){unsigned d=*j->at++-'0';if(value>(UINT64_MAX-d)/10)return false;value=value*10+d;}if(j->at-start>1&&*start=='0')return false;*out=value;return true;}
static bool skip_number(struct json *j){const char *start=j->at;if(j->at<j->end&&*j->at=='-')j->at++;uint64_t ignored;if(!number(j,&ignored)){j->at=start;return false;}if(j->at<j->end&&*j->at=='.'){j->at++;const char *digits=j->at;while(j->at<j->end&&*j->at>='0'&&*j->at<='9')j->at++;if(j->at==digits)return false;}if(j->at<j->end&&(*j->at=='e'||*j->at=='E')){j->at++;if(j->at<j->end&&(*j->at=='+'||*j->at=='-'))j->at++;const char *digits=j->at;while(j->at<j->end&&*j->at>='0'&&*j->at<='9')j->at++;if(j->at==digits)return false;}return true;}
static bool skip(struct json *j,unsigned depth){if(depth>8)return false;whitespace(j);if(j->at==j->end)return false;if(*j->at=='"')return string(j,NULL,0);if(*j->at=='{'||*j->at=='['){char open=*j->at++,close=open=='{'?'}':']';whitespace(j);if(j->at<j->end&&*j->at==close){j->at++;return true;}for(;;){if(open=='{'&&(!string(j,NULL,0)))return false;if(open=='{'){whitespace(j);if(j->at==j->end||*j->at++!=':')return false;}if(!skip(j,depth+1))return false;whitespace(j);if(j->at==j->end)return false;if(*j->at==close){j->at++;return true;}if(*j->at++!=',')return false;}}if(skip_number(j))return true;return literal(j,"true")||literal(j,"false")||literal(j,"null");}
static bool parse(const char *text,size_t bytes,struct state *s){struct json j={text,text+bytes};whitespace(&j);if(j.at==j.end||*j.at++!='{')return false;whitespace(&j);if(j.at<j.end&&*j.at=='}'){j.at++;return false;}for(;;){char key[64];if(!string(&j,key,sizeof(key)))return false;whitespace(&j);if(j.at==j.end||*j.at++!=':')return false;whitespace(&j);
    if(!strcmp(key,"visible")){if(s->have_visible)return false;s->have_visible=true;if(literal(&j,"true"))s->visible=true;else if(!literal(&j,"false"))return false;}
    else if(!strcmp(key,"sequence")||!strcmp(key,"controlSequence")){if(s->have_sequence)return false;s->have_sequence=true;if(!number(&j,&s->sequence))return false;}
    else if(!strcmp(key,"pid")){if(s->have_pid)return false;s->have_pid=true;if(!number(&j,&s->pid))return false;}
    else if(!strcmp(key,"frameCount")){if(s->have_frame)return false;s->have_frame=true;if(!number(&j,&s->frame))return false;}
    else if(!strcmp(key,"injectionSupported")){if(s->have_support)return false;s->have_support=true;if(literal(&j,"true"))s->support=true;else if(!literal(&j,"false"))return false;}
    else if(!strcmp(key,"metal3Hooked")||!strcmp(key,"metal4Hooked")){bool *have=!strcmp(key,"metal3Hooked")?&s->have_metal3:&s->have_metal4;if(*have)return false;*have=true;if(literal(&j,"true"))s->metal=true;else if(!literal(&j,"false"))return false;}
    else if(!strcmp(key,"heartbeatActive")){if(s->have_heartbeat)return false;s->have_heartbeat=true;if(literal(&j,"true")||literal(&j,"1"))s->heartbeat=true;else if(!(literal(&j,"false")||literal(&j,"0")))return false;}
    else if(!strcmp(key,"inputCaptureEpoch")){if(s->have_epoch)return false;s->have_epoch=true;if(!number(&j,&s->capture_epoch))return false;}
    else if(!skip(&j,0))return false;whitespace(&j);if(j.at==j.end)return false;if(*j.at=='}'){j.at++;break;}if(*j.at++!=',')return false;}
    whitespace(&j);return j.at==j.end&&s->have_visible&&s->have_sequence;
}
static bool read_owned(const char *path,struct state *result,bool fresh){struct stat st;char buffer[16385];int fd;ssize_t bytes;if(!path||!*path||lstat(path,&st)||!S_ISREG(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0077)||st.st_size<=0||st.st_size>16384)return false;if(fresh){struct timespec now;clock_gettime(CLOCK_REALTIME,&now);double age=(double)(now.tv_sec-st.st_mtimespec.tv_sec)+(now.tv_nsec-st.st_mtimespec.tv_nsec)/1e9;if(age< -1.0||age>3.0)return false;}if((fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC))<0)return false;struct stat opened;if(fstat(fd,&opened)||opened.st_dev!=st.st_dev||opened.st_ino!=st.st_ino||!S_ISREG(opened.st_mode)||opened.st_uid!=geteuid()||(opened.st_mode&0077)||opened.st_size!=st.st_size){close(fd);return false;}bytes=read(fd,buffer,sizeof(buffer));close(fd);if(bytes!=st.st_size)return false;memset(result,0,sizeof(*result));return parse(buffer,(size_t)bytes,result);}
static pthread_mutex_t capture_lock=PTHREAD_MUTEX_INITIALIZER;
static struct ready_xinput_capture cached;
static NTSTATUS read_capture(void *raw){struct ready_xinput_capture *out=raw;pthread_mutex_lock(&capture_lock);memset(&cached,0,sizeof(cached));cached.unix_pid=getpid();cached.reason=1;
    const char *control=getenv("M1L_CONTROL_FILE"),*status=getenv("M1L_OVERLAY_STATUS");char fallback[4096];if(!status&&control){size_t n=strlen(control);if(n<sizeof(fallback)){memcpy(fallback,control,n+1);char *slash=strrchr(fallback,'/');if(slash&&(size_t)(slash-fallback)+21<sizeof(fallback)){strcpy(slash+1,"overlay-status.json");status=fallback;}}}
    struct state command,effective;if(read_owned(control,&command,false)&&read_owned(status,&effective,true)&&effective.have_pid&&effective.pid==(uint64_t)getpid()&&effective.have_frame&&effective.frame>0&&effective.have_support&&effective.support&&effective.metal&&effective.heartbeat){cached.active=1;cached.visible=command.sequence>effective.sequence?command.visible:effective.visible;uint64_t sequence=command.sequence>effective.sequence?command.sequence:effective.sequence;cached.command_sequence_low=(uint32_t)sequence;cached.command_sequence_high=(uint32_t)(sequence>>32);cached.capture_epoch_low=(uint32_t)effective.capture_epoch;cached.capture_epoch_high=(uint32_t)(effective.capture_epoch>>32);cached.reason=0;}
    *out=cached;pthread_mutex_unlock(&capture_lock);return 0;
}
const unixlib_entry_t __wine_unix_call_funcs[]={read_capture};
const unixlib_entry_t __wine_unix_call_wow64_funcs[]={read_capture};
