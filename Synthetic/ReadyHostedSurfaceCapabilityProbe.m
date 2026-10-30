// SPDX-License-Identifier: GPL-3.0-only
// CPU-only capability identity experiment. Real IPC, no private API/kernel-object inspection.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <unistd.h>
extern char **environ;
typedef struct{mach_msg_header_t header;mach_msg_body_t body;mach_msg_port_descriptor_t port;uint32_t index;}Message;
typedef struct{Message message;mach_msg_trailer_t trailer;}Receive;
static void emit(NSDictionary*value){NSData*d=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);}
static mach_port_urefs_t refs(mach_port_t port){mach_port_urefs_t count=0;return mach_port_get_refs(mach_task_self(),port,MACH_PORT_RIGHT_SEND,&count)==KERN_SUCCESS?count:0;}
static BOOL receive(mach_port_t port,Receive*out){memset(out,0,sizeof(*out));return mach_msg(&out->message.header,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof(*out),port,2000,MACH_PORT_NULL)==KERN_SUCCESS;}
static BOOL sendPort(mach_port_t destination,mach_port_t port,uint32_t index){Message message={0};message.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0)|MACH_MSGH_BITS_COMPLEX;message.header.msgh_size=sizeof(message);message.header.msgh_remote_port=destination;message.body.msgh_descriptor_count=1;message.port=(mach_msg_port_descriptor_t){.name=port,.disposition=MACH_MSG_TYPE_COPY_SEND,.type=MACH_MSG_PORT_DESCRIPTOR};message.index=index;return mach_msg(&message.header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof(message),0,MACH_PORT_NULL,1000,MACH_PORT_NULL)==KERN_SUCCESS;}
static int child(NSString*root){@autoreleasepool{
 mach_port_array_t ports=NULL;mach_msg_type_number_t count=0;kern_return_t kr=mach_ports_lookup(mach_task_self(),&ports,&count);
 if(kr!=KERN_SUCCESS||count<1||ports[0]==MACH_PORT_NULL)return 11;
 mach_port_t parent=ports[0];for(unsigned i=1;i<count;i++)if(ports[i])mach_port_deallocate(mach_task_self(),ports[i]);vm_deallocate(mach_task_self(),(vm_address_t)ports,count*sizeof(mach_port_t));
 mach_port_t endpoint=MACH_PORT_NULL;mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&endpoint);mach_port_insert_right(mach_task_self(),endpoint,endpoint,MACH_MSG_TYPE_MAKE_SEND);
 if(!sendPort(parent,endpoint,99))return 12;
 mach_port_t held=MACH_PORT_NULL;IOSurfaceRef heldSurface=NULL;NSMutableArray*records=[NSMutableArray new];BOOL same=NO,urefsBalanced=NO,distinct=NO;
 for(unsigned i=0;i<3;i++){
  Receive incoming;if(!receive(endpoint,&incoming))return 13;mach_port_t received=incoming.message.port.name;
  if(incoming.message.body.msgh_descriptor_count!=1||incoming.message.index!=i)return 14;
  mach_port_urefs_t before=refs(received);IOSurfaceRef surface=IOSurfaceLookupFromMachPort(received);if(!surface)return 15;
  uint32_t sid=IOSurfaceGetID(surface);BOOL equalName=i==1&&received==held;
  if(i==0){held=received;heldSurface=surface;}
  else{CFRelease(surface);mach_port_deallocate(mach_task_self(),received);}
  mach_port_urefs_t after=refs(held);
  if(i==1){same=equalName;urefsBalanced=before==2&&after==1;}
  if(i==2)distinct=received!=held&&sid!=IOSurfaceGetID(heldSurface);
  [records addObject:@{@"index":@(i),@"sameHeldCapabilityName":@(equalName),@"receivedSendUrefsBeforeRelease":@(before),@"heldSendUrefsAfterRelease":@(after),@"surfaceID":@(sid)}];
 }
 mach_port_deallocate(mach_task_self(),held);BOOL heldGone=refs(held)==0;CFRelease(heldSurface);mach_port_deallocate(mach_task_self(),parent);mach_port_destroy(mach_task_self(),endpoint);
 NSDictionary*report=@{@"childPID":@(getpid()),@"sameSurfaceCapabilityNamesCoalesced":@(same),@"coalescedUrefsBalanced":@(urefsBalanced),@"distinctSurfaceControlPassed":@(distinct),@"heldRightReleased":@(heldGone),@"receives":records};
 NSData*json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];NSString*file=[root stringByAppendingPathComponent:@"child.json"];[json writeToFile:file atomically:YES];chmod(file.fileSystemRepresentation,0600);return distinct&&heldGone?0:16;
}}
int main(int argc,const char**argv){@autoreleasepool{
 umask(077);if(argc!=4)return 2;NSString*mode=@(argv[1]);NSString*root=@(argv[2]);if([mode isEqual:@"child"])return child(root);
 mach_port_t rendezvous=MACH_PORT_NULL;mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&rendezvous);mach_port_insert_right(mach_task_self(),rendezvous,rendezvous,MACH_MSG_TYPE_MAKE_SEND);
 mach_port_array_t previous=NULL;mach_msg_type_number_t previousCount=0;mach_ports_lookup(mach_task_self(),&previous,&previousCount);
 kern_return_t registered=mach_ports_register(mach_task_self(),&rendezvous,1);if(registered!=KERN_SUCCESS){emit(@{@"probeCompleted":@NO,@"stage":@"register-own-rendezvous",@"code":@(registered)});return 3;}
 pid_t childPID=0;char*args[]={(char*)argv[3],"child",(char*)argv[2],(char*)argv[3],NULL};int spawned=posix_spawn(&childPID,argv[3],NULL,NULL,args,environ);
 mach_ports_register(mach_task_self(),previous,previousCount);for(unsigned i=0;i<previousCount;i++)if(previous[i])mach_port_deallocate(mach_task_self(),previous[i]);if(previous)vm_deallocate(mach_task_self(),(vm_address_t)previous,previousCount*sizeof(mach_port_t));
 if(spawned){emit(@{@"probeCompleted":@NO,@"stage":@"spawn-own-child",@"code":@(spawned)});return 4;}
 Receive hello;if(!receive(rendezvous,&hello)){kill(childPID,SIGTERM);waitpid(childPID,NULL,0);emit(@{@"probeCompleted":@NO,@"stage":@"inherited-rendezvous-not-received"});return 5;}
 mach_port_t destination=hello.message.port.name;
 NSDictionary*properties=@{(id)kIOSurfaceWidth:@8,(id)kIOSurfaceHeight:@8,(id)kIOSurfaceBytesPerElement:@4};
 BOOL reused=[mode isEqual:@"parent-reused"];
 IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)properties),other=IOSurfaceCreate((__bridge CFDictionaryRef)properties);
 if(!surface||!other)return 6;mach_port_t first=IOSurfaceCreateMachPort(surface),second=reused?first:IOSurfaceCreateMachPort(surface),control=IOSurfaceCreateMachPort(other);
 BOOL localSame=first==second;mach_port_urefs_t localBefore=refs(first);
 BOOL sent=sendPort(destination,first,0)&&sendPort(destination,second,1)&&sendPort(destination,control,2);
 mach_port_deallocate(mach_task_self(),first);if(second!=first)mach_port_deallocate(mach_task_self(),second);mach_port_deallocate(mach_task_self(),control);
 BOOL localReleased=refs(first)==0&&refs(second)==0&&refs(control)==0;
 CFRelease(surface);CFRelease(other);mach_port_deallocate(mach_task_self(),destination);mach_port_destroy(mach_task_self(),rendezvous);
 int status=0;BOOL exited=NO;for(unsigned i=0;i<400;i++){if(waitpid(childPID,&status,WNOHANG)==childPID){exited=YES;break;}usleep(10000);}if(!exited){kill(childPID,SIGTERM);waitpid(childPID,&status,0);}
 NSData*data=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"child.json"]];NSDictionary*childReport=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:@{};
 BOOL proof=sent&&exited&&WIFEXITED(status)&&WEXITSTATUS(status)==0&&localSame&&localBefore==(reused?1:2)&&localReleased&&[childReport[@"sameSurfaceCapabilityNamesCoalesced"]boolValue]&&[childReport[@"coalescedUrefsBalanced"]boolValue]&&[childReport[@"distinctSurfaceControlPassed"]boolValue]&&[childReport[@"heldRightReleased"]boolValue];
 emit(@{@"probeCompleted":@(sent&&exited),@"capabilityIdentityFastPathSupported":@(proof),@"parentPID":@(getpid()),@"mode":reused?@"one-port-two-COPY_SEND-transfers":@"two-create-calls",@"parentPortNamesEqual":@(localSame),@"parentUrefsAfterTwoCreates":@(localBefore),@"parentSurfaceSendRightsReleased":@(localReleased),@"childExitStatus":@(WIFEXITED(status)?WEXITSTATUS(status):-1),@"child":childReport?:@{},@"CPUOnly":@YES,@"privateAPIOrKernelObjectInspection":@NO});return 0;
}}
