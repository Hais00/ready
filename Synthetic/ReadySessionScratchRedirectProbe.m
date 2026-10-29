// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <limits.h>
int main(void){@autoreleasepool{
 const char *selected=getenv("READY_NATIVE_SESSION_TMPDIR");NSString *expected=selected?[NSString stringWithUTF8String:selected]:nil;
 NSString *foundation=NSTemporaryDirectory();NSString *manager=NSFileManager.defaultManager.temporaryDirectory.path;
 char full[PATH_MAX]={0},small[4]={1,1,1,1};size_t needed=confstr(_CS_DARWIN_USER_TEMP_DIR,full,sizeof full),queried=confstr(_CS_DARWIN_USER_TEMP_DIR,NULL,0),shortNeeded=confstr(_CS_DARWIN_USER_TEMP_DIR,small,sizeof small);
 BOOL cMatch=expected&&[expected isEqualToString:[NSString stringWithUTF8String:full]];
 BOOL nsMatch=expected&&[[foundation stringByStandardizingPath]isEqualToString:[expected stringByStandardizingPath]];
 BOOL fmMatch=expected&&[[manager stringByStandardizingPath]isEqualToString:[expected stringByStandardizingPath]];
 BOOL writeOK=NO;if(expected&&nsMatch){NSURL *file=[NSURL fileURLWithPath:[foundation stringByAppendingPathComponent:@"own-file-backing-probe"]];writeOK=[[@"scratch" dataUsingEncoding:NSUTF8StringEncoding]writeToURL:file options:NSDataWritingAtomic error:nil];}
 char cwd[PATH_MAX]={0};getcwd(cwd,sizeof cwd);const char *oldHome=getenv("FIXTURE_EXPECTED_HOME"),*oldCwd=getenv("FIXTURE_EXPECTED_CWD");
 NSDictionary *out=@{@"foundationMatchesSelected":@(nsMatch),@"fileManagerMatchesSelected":@(fmMatch),@"darwinConfstrMatchesSelected":@(cMatch),@"confstrBufferContract":@(needed==queried&&needed==shortNeeded&&needed>0&&small[3]==0),@"writeSucceededOnSelectedVolume":@(writeOK),@"HOMEUnchanged":@(oldHome&&getenv("HOME")&&!strcmp(oldHome,getenv("HOME"))),@"cwdUnchanged":@(oldCwd&&!strcmp(oldCwd,cwd))};NSData*d=[NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];fwrite(d.bytes,1,d.length,stdout);fputc('\n',stdout);return 0;
}}
