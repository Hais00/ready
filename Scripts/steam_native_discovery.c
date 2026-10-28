/* SPDX-License-Identifier: GPL-3.0-only */
/* Independent metadata-only protocol adapter. No authentication, ownership,
 * ticket or game responses; no global Steam service is looked up/registered. */
#include "steam_native_discovery.h"
#include <CommonCrypto/CommonDigest.h>
#include <servers/bootstrap.h>
#include <mach/mach.h>
#include <bsm/libbsm.h>
#include <pthread.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdio.h>
struct ReadySteamDiscovery {mach_port_t receive;pthread_t thread;_Atomic int stopping;pid_t owner;uint64_t generation;const ReadySteamAuthenticatedHostRecord *record;char name[128],client[512];_Atomic unsigned long long received,valid,rejected,bad_size,bad_protocol,bad_right,bad_audit,complex,version,metadata,unknown,lease_denied,replies,send_failed;_Atomic int last_receive_status,last_request_bytes,last_protocol,last_operation,last_version_argument,last_reply_bytes,last_reply_status,last_send_status,last_record_live;};
static int name_valid(const char *s){const char *prefix="app.ready.steam.ipctool.";size_t n=strlen(prefix);if(!s||strncmp(s,prefix,n)||strlen(s)!=n+32)return 0;for(s+=n;*s;s++)if(!(*s>='0'&&*s<='9')&&!(*s>='a'&&*s<='f'))return 0;return 1;}
static int digest_matches(const char *path,const char *hex){int fd=open(path,O_RDONLY|O_NOFOLLOW);if(fd<0)return 0;struct stat info;if(fstat(fd,&info)||!S_ISREG(info.st_mode)){close(fd);return 0;}CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char block[16384],digest[32];ssize_t n;while((n=read(fd,block,sizeof block))>0)CC_SHA256_Update(&ctx,block,(CC_LONG)n);close(fd);if(n<0)return 0;CC_SHA256_Final(digest,&ctx);for(unsigned i=0;i<32;i++){unsigned a=hex[2*i]<='9'?hex[2*i]-'0':hex[2*i]-'a'+10,b=hex[2*i+1]<='9'?hex[2*i+1]-'0':hex[2*i+1]-'a'+10;if(digest[i]!=(a*16+b))return 0;}return 1;}
static int record_live(const ReadySteamDiscovery *s){return getpid()==s->owner&&s->record->abi_version==1&&s->record->owned_host_pid==s->owner&&s->record->generation==s->generation&&atomic_load_explicit(&s->record->authenticated,memory_order_acquire)==1;}
static void *serve(void *context){ReadySteamDiscovery *s=context;union {uint64_t aligned;unsigned char bytes[4096];} received;
 while(!atomic_load(&s->stopping)){
  memset(&received,0,sizeof received);mach_msg_header_t *request=(mach_msg_header_t*)received.bytes;
  kern_return_t k=mach_msg(request,MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)|MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),0,sizeof received,s->receive,100,MACH_PORT_NULL);
  if(k==MACH_RCV_TIMED_OUT)continue;atomic_store(&s->last_receive_status,k);if(k!=KERN_SUCCESS)continue;atomic_fetch_add(&s->received,1);atomic_store(&s->last_request_bytes,request->msgh_size);atomic_store(&s->last_protocol,request->msgh_id);if(request->msgh_size!=32)atomic_fetch_add(&s->bad_size,1);if(request->msgh_id!=104)atomic_fetch_add(&s->bad_protocol,1);if(request->msgh_bits&MACH_MSGH_BITS_COMPLEX)atomic_fetch_add(&s->complex,1);if(MACH_MSGH_BITS_REMOTE(request->msgh_bits)!=MACH_MSG_TYPE_PORT_SEND)atomic_fetch_add(&s->bad_right,1);
  int valid=!(request->msgh_bits&MACH_MSGH_BITS_COMPLEX)&&request->msgh_size==32&&request->msgh_id==104&&MACH_MSGH_BITS_REMOTE(request->msgh_bits)==MACH_MSG_TYPE_PORT_SEND&&MACH_PORT_VALID(request->msgh_remote_port);
  mach_msg_size_t rounded=(request->msgh_size+3)&~3U;
  if(rounded+sizeof(mach_msg_audit_trailer_t)>sizeof received)valid=0;
  mach_msg_audit_trailer_t *audit=(mach_msg_audit_trailer_t*)(received.bytes+rounded);
  if(valid&&(audit->msgh_trailer_type!=MACH_MSG_TRAILER_FORMAT_0||audit->msgh_trailer_size<sizeof *audit||audit_token_to_euid(audit->msgh_audit)!=getuid())){atomic_fetch_add(&s->bad_audit,1);valid=0;}
  if(!valid){atomic_fetch_add(&s->rejected,1);mach_msg_destroy(request);continue;}atomic_fetch_add(&s->valid,1);
  uint32_t operation=0,argument=0;memcpy(&operation,received.bytes+24,4);memcpy(&argument,received.bytes+28,4);atomic_store(&s->last_operation,operation);atomic_store(&s->last_version_argument,operation==100001?(int)argument:0);int live=record_live(s);atomic_store(&s->last_record_live,live);if(operation==100001)atomic_fetch_add(&s->version,1);else if(operation==14)atomic_fetch_add(&s->metadata,1);else atomic_fetch_add(&s->unknown,1);if(operation==14&&!live)atomic_fetch_add(&s->lease_denied,1);
  union {uint64_t aligned;unsigned char bytes[552];} response;memset(&response,0,sizeof response);mach_msg_header_t *reply=(mach_msg_header_t*)response.bytes;
  reply->msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND,0);reply->msgh_remote_port=request->msgh_remote_port;request->msgh_remote_port=MACH_PORT_NULL;reply->msgh_id=104;reply->msgh_size=32;
  int32_t status=KERN_NOT_SUPPORTED,value=0;
  /* Protocol version is software metadata, independent of auth lease. Never
   * advertise a false old version that would trigger the SDK legacy restart. */
  if(operation==100001&&argument==104){status=0;value=104;reply->msgh_size=40;}
  else if(live&&operation==14){status=0;value=s->owner;reply->msgh_size=552;memcpy(response.bytes+32,s->client,strlen(s->client)+1);}
  memcpy(response.bytes+24,&status,4);memcpy(response.bytes+28,&value,4);
  atomic_store(&s->last_reply_bytes,reply->msgh_size);atomic_store(&s->last_reply_status,status);k=mach_msg(reply,MACH_SEND_MSG|MACH_SEND_TIMEOUT,reply->msgh_size,0,MACH_PORT_NULL,100,MACH_PORT_NULL);atomic_store(&s->last_send_status,k);if(k!=KERN_SUCCESS){atomic_fetch_add(&s->send_failed,1);mach_msg_destroy(reply);}else atomic_fetch_add(&s->replies,1);mach_msg_destroy(request);
 }
 return NULL;
}
int ready_steam_discovery_start(const char *name,const char *client_path,const char *sdk_path,const ReadySteamAuthenticatedHostRecord *record,ReadySteamDiscovery **out){
 if(out)*out=NULL;if(!out||!record||record->abi_version!=1||!record->generation||atomic_load_explicit(&record->authenticated,memory_order_acquire)!=1)return READY_DISCOVERY_AUTH_REQUIRED;
 if(record->owned_host_pid!=getpid())return READY_DISCOVERY_BAD_OWNER;if(!name_valid(name))return READY_DISCOVERY_BAD_NAME;
 char client[PATH_MAX],sdk[PATH_MAX];if(!client_path||!sdk_path||!realpath(client_path,client)||!realpath(sdk_path,sdk)||strlen(client)>=512)return READY_DISCOVERY_BAD_IMAGES;
#ifndef READY_DISCOVERY_TESTING
 if(!digest_matches(client,"b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd")||!digest_matches(sdk,"2cbe2533e09d1561051f417d7b8c784481a2efdc4fc9d1274704ee8a7ef50cb1"))return READY_DISCOVERY_BAD_IMAGES;
#endif
 mach_port_t existing=MACH_PORT_NULL;if(bootstrap_look_up(bootstrap_port,name,&existing)==KERN_SUCCESS){if(MACH_PORT_VALID(existing))mach_port_deallocate(mach_task_self(),existing);return READY_DISCOVERY_REGISTER_FAILED;}
 ReadySteamDiscovery *s=calloc(1,sizeof *s);if(!s)return READY_DISCOVERY_THREAD_FAILED;s->owner=getpid();s->record=record;s->generation=record->generation;strcpy(s->name,name);strcpy(s->client,client);
 if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&s->receive)||mach_port_insert_right(mach_task_self(),s->receive,s->receive,MACH_MSG_TYPE_MAKE_SEND)){if(MACH_PORT_VALID(s->receive))mach_port_destroy(mach_task_self(),s->receive);free(s);return READY_DISCOVERY_REGISTER_FAILED;}
 if(bootstrap_register(bootstrap_port,s->name,s->receive)!=KERN_SUCCESS){mach_port_destroy(mach_task_self(),s->receive);free(s);return READY_DISCOVERY_REGISTER_FAILED;}
 if(pthread_create(&s->thread,NULL,serve,s)){(void)bootstrap_register(bootstrap_port,s->name,MACH_PORT_NULL);mach_port_destroy(mach_task_self(),s->receive);free(s);return READY_DISCOVERY_THREAD_FAILED;}*out=s;return READY_DISCOVERY_OK;
}
void ready_steam_discovery_stop(ReadySteamDiscovery *s){if(!s||s->owner!=getpid())return;atomic_store(&s->stopping,1);pthread_join(s->thread,NULL);(void)bootstrap_register(bootstrap_port,s->name,MACH_PORT_NULL);mach_port_destroy(mach_task_self(),s->receive);memset(s,0,sizeof *s);free(s);}

size_t ready_steam_discovery_stats_json(ReadySteamDiscovery *s,char *out,size_t capacity){if(!s||!out||!capacity)return 0;
#define C(field) ((unsigned long long)atomic_load(&s->field))
#define I(field) ((int)atomic_load(&s->field))
 int n=snprintf(out,capacity,"{\"serviceStats\":true,\"received\":%llu,\"valid\":%llu,\"rejected\":%llu,\"badSize\":%llu,\"badProtocol\":%llu,\"badReplyRight\":%llu,\"badAudit\":%llu,\"complex\":%llu,\"versionRequests\":%llu,\"metadataRequests\":%llu,\"unknownRequests\":%llu,\"leaseDenied\":%llu,\"replies\":%llu,\"sendFailed\":%llu,\"lastReceiveStatus\":%d,\"lastRequestBytes\":%d,\"lastProtocol\":%d,\"lastOperation\":%d,\"lastVersionArgument\":%d,\"lastReplyBytes\":%d,\"lastReplyStatus\":%d,\"lastSendStatus\":%d,\"lastRecordLive\":%d}",C(received),C(valid),C(rejected),C(bad_size),C(bad_protocol),C(bad_right),C(bad_audit),C(complex),C(version),C(metadata),C(unknown),C(lease_denied),C(replies),C(send_failed),I(last_receive_status),I(last_request_bytes),I(last_protocol),I(last_operation),I(last_version_argument),I(last_reply_bytes),I(last_reply_status),I(last_send_status),I(last_record_live));
#undef C
#undef I
 return n>0&&(size_t)n<capacity?(size_t)n:0;}
