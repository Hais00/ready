/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef READY_HOSTED_SESSION_SCRATCH_H
#define READY_HOSTED_SESSION_SCRATCH_H
#if defined(RHG_INTERPOSE) && defined(__OBJC__)
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <errno.h>
#include <string.h>
/* Guest-local override, opt-in only through SessionManager's FD-validated
 * native-session environment. No HOME, system setting or other process changes. */
static char rhgScratchPath[PATH_MAX];
static pthread_once_t rhgScratchOnce=PTHREAD_ONCE_INIT;
static void rhgScratchRefuse(void){const char line[]="{\"type\":\"hosted-shim-refused\",\"reason\":\"unsafe-native-session-scratch\"}\n";(void)write(2,line,sizeof line-1);_exit(77);}
static void rhgScratchInitialize(void){
 const char *raw=getenv("READY_NATIVE_SESSION_TMPDIR");if(!raw)return;
 size_t length=strnlen(raw,PATH_MAX);if(length<2||length>=PATH_MAX||raw[0]!='/')rhgScratchRefuse();
 while(length>1&&raw[length-1]=='/')length--;
 char requested[PATH_MAX];memcpy(requested,raw,length);requested[length]=0;
 char real[PATH_MAX];if(!realpath(requested,real)||strcmp(real,requested))rhgScratchRefuse();
 int fd=open(requested,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat value={0};char actual[PATH_MAX]={0};
 if(fd<0)rhgScratchRefuse();BOOL valid=fstat(fd,&value)==0&&S_ISDIR(value.st_mode)&&value.st_uid==getuid()&&(value.st_mode&07777)==0700&&fcntl(fd,F_GETPATH,actual)==0&&!strcmp(actual,requested);close(fd);
 if(!valid||length+2>sizeof rhgScratchPath)rhgScratchRefuse();memcpy(rhgScratchPath,requested,length);rhgScratchPath[length]='/';rhgScratchPath[length+1]=0;
}
static const char *rhgSessionScratchPath(void){pthread_once(&rhgScratchOnce,rhgScratchInitialize);return rhgScratchPath[0]?rhgScratchPath:NULL;}
static size_t rhgScratchConfstr(int name,char *buffer,size_t length){
 const char *path=rhgSessionScratchPath();
 if(path&&name==_CS_DARWIN_USER_TEMP_DIR){size_t required=strlen(path)+1;if(buffer&&length){size_t count=required<length?required:length;memcpy(buffer,path,count-1);buffer[count-1]=0;}return required;}
 // dyld leaves references from the interposer image bound to the replacee.
 // dlsym may itself return an interposed binding; call the original symbol.
 return confstr(name,buffer,length);
}
static NSString *rhgScratchTemporaryDirectory(void){
 const char *path=rhgSessionScratchPath();if(path)return [NSString stringWithUTF8String:path];
 return NSTemporaryDirectory();
}
static IMP rhgOriginalFileManagerTemporaryDirectory;
static NSURL *rhgScratchFileManagerTemporaryDirectory(id manager,SEL selector){
 const char *path=rhgSessionScratchPath();if(path)return [NSURL fileURLWithPath:[NSString stringWithUTF8String:path] isDirectory:YES];
 return ((NSURL*(*)(id,SEL))rhgOriginalFileManagerTemporaryDirectory)(manager,selector);
}
static void rhgInstallSessionScratch(void){
 if(!rhgSessionScratchPath())return;
 Method method=class_getInstanceMethod(NSFileManager.class,@selector(temporaryDirectory));
 if(!method)rhgScratchRefuse();rhgOriginalFileManagerTemporaryDirectory=method_setImplementation(method,(IMP)rhgScratchFileManagerTemporaryDirectory);
}
RHG_INTERPOSE(rhgScratchConfstr,confstr);
RHG_INTERPOSE(rhgScratchTemporaryDirectory,NSTemporaryDirectory);
#endif /* guest interposer only; not part of the public Clang module */
#endif
