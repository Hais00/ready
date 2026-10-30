// SPDX-License-Identifier: GPL-3.0-only
// Own CPU/FD-only fixture appended to the constructor-disabled actual shim.
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
extern char **environ;
#define CHECK(c) do{if(!(c)){fprintf(stderr,"own-profiler-sink:%d\n",__LINE__);_exit(81);}}while(0)
static BOOL ownWaitSink(double seconds){double end=CACurrentMediaTime()+seconds;while(atomic_load(&rhgPerfWritePending)&&CACurrentMediaTime()<end)[NSThread sleepForTimeInterval:.001];return !atomic_load(&rhgPerfWritePending);}
static int ownExecFD(const char *program,int fd){
    struct stat info={0};CHECK(fstat(fd,&info)==0);char descriptor[32],device[32],inode[32];snprintf(descriptor,sizeof descriptor,"%d",fd);snprintf(device,sizeof device,"%llu",(unsigned long long)info.st_dev);snprintf(inode,sizeof inode,"%llu",(unsigned long long)info.st_ino);
    char *args[]={(char*)program,"child-fd",descriptor,device,inode,NULL};pid_t child=0;CHECK(posix_spawn(&child,program,NULL,NULL,args,environ)==0);int status=0;CHECK(waitpid(child,&status,0)==child&&WIFEXITED(status));return WEXITSTATUS(status);
}
int main(int argc,char **argv){@autoreleasepool{
    alarm(10);
    if(argc==5&&!strcmp(argv[1],"child-fd")){
        struct stat info={0};int fd=(int)strtol(argv[2],NULL,10);BOOL inherited=fstat(fd,&info)==0&&(unsigned long long)info.st_dev==strtoull(argv[3],NULL,10)&&(unsigned long long)info.st_ino==strtoull(argv[4],NULL,10);return inherited?42:0;
    }
    if(argc!=3)return 64;BOOL off=!strcmp(argv[1],"off"),on=!strcmp(argv[1],"on"),blocked=!strcmp(argv[1],"blocked"),broken=!strcmp(argv[1],"broken");CHECK(off||on||blocked||broken);CHECK(RHGPerfProfileEnabled()==!off);
    int pipeFDs[2]={-1,-1};
    if(blocked||broken){
        CHECK(pipe(pipeFDs)==0);
        if(blocked){int flags=fcntl(pipeFDs[1],F_GETFL);CHECK(flags>=0&&fcntl(pipeFDs[1],F_SETFL,flags|O_NONBLOCK)==0);char filler[1024];memset(filler,'x',sizeof filler);while(write(pipeFDs[1],filler,sizeof filler)>0){}CHECK(errno==EAGAIN||errno==EWOULDBLOCK);CHECK(fcntl(pipeFDs[1],F_SETFL,flags)==0);}
        CHECK(dup2(pipeFDs[1],STDERR_FILENO)==STDERR_FILENO);close(pipeFDs[1]);pipeFDs[1]=-1;
    }
    CHECK(atomic_load(&rhgPerfOutputFD)==-1);rhgPerfPrepareOutput();int captured=atomic_load(&rhgPerfOutputFD);rhgPerfPrepareOutput();CHECK(atomic_load(&rhgPerfOutputFD)==captured);
    CHECK(off?captured==-1:captured>=3);
    BOOL execIsolation=NO;
    if(on){
        CHECK(fcntl(captured,F_GETFD)&FD_CLOEXEC);
        int control=dup(STDOUT_FILENO);CHECK(control>=3&&!(fcntl(control,F_GETFD)&FD_CLOEXEC));
        CHECK(ownExecFD(argv[0],control)==42);close(control);CHECK(ownExecFD(argv[0],captured)==0);execIsolation=YES;
    }
    if(broken){close(pipeFDs[0]);pipeFDs[0]=-1;}
    CHECK(freopen(argv[2],"a",stderr)!=NULL);fputs("own-game-stderr-marker\n",stderr);fflush(stderr);
    rhgFrameDepth=2;RHGPerfAddNanoseconds(&rhgPerformance.rpcTotal[RHG_PRESENT],1234);rhgPerfReport(120);
    if(blocked){
        CHECK(atomic_load(&rhgPerfWritePending));[NSThread sleepForTimeInterval:.025];CHECK(atomic_load(&rhgPerfWritePending));
        for(unsigned i=0;i<100;i++)rhgPerfReport(240+i);
        CHECK(atomic_load(&rhgPerfWritePending));int flags=fcntl(pipeFDs[0],F_GETFL);CHECK(flags>=0&&fcntl(pipeFDs[0],F_SETFL,flags|O_NONBLOCK)==0);
        NSMutableData *bytes=[NSMutableData new];double end=CACurrentMediaTime()+3;char buffer[4096];
        for(;;){
            ssize_t count=read(pipeFDs[0],buffer,sizeof buffer);
            if(count>0){CHECK(bytes.length+(NSUInteger)count<=256*1024);[bytes appendBytes:buffer length:(NSUInteger)count];continue;}
            CHECK(count<0&&(errno==EAGAIN||errno==EWOULDBLOCK));
            if(!atomic_load(&rhgPerfWritePending))break;CHECK(CACurrentMediaTime()<end);[NSThread sleepForTimeInterval:.001];
        }
        CHECK(ownWaitSink(1));NSData *brace=[@"{"dataUsingEncoding:NSUTF8StringEncoding];NSRange first=[bytes rangeOfData:brace options:0 range:NSMakeRange(0,bytes.length)];CHECK(first.location!=NSNotFound);
        NSDictionary *profile=[NSJSONSerialization JSONObjectWithData:[bytes subdataWithRange:NSMakeRange(first.location,bytes.length-first.location)] options:0 error:nil];CHECK([profile[@"type"]isEqual:@"hosted-guest-performance"]&&[profile[@"framesAcknowledged"]unsignedLongLongValue]==120);close(pipeFDs[0]);
    }else CHECK(ownWaitSink(3));
    CHECK(!atomic_load(&rhgPerfWritePending));
    NSDictionary *report=@{@"passed":@YES,@"profilingEnabled":@(!off),@"defaultOffCreatesNoSink":@(off&&captured==-1),@"captureIsIdempotent":@YES,@"capturedFDNotInheritedAcrossExec":@(execIsolation),@"stderrReplacedWithFreopen":@YES,@"blockedWriterCoalescesReports":@(blocked),@"closedOriginalConsumerDoesNotCrash":@(broken),@"UIOrGPUOrGameOrAccountUsed":@NO};NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return 0;
}}
