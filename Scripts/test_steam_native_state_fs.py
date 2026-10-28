#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own benign filesystem fixtures ONLY. Never load/execute a Valve client.

Compile a worker-local interposer plus arm64/x86_64 test processes on the marked
work volume. Sandbox denial controls are independent from the path adaptation.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WORK = Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
SOURCE = ROOT / 'Scripts/steam_native_state_fs.c'
FIXTURE = r'''
#define _DARWIN_C_SOURCE 1
#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <spawn.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <utime.h>
static int checks;
#define CHECK(name, condition) do { if (!(condition)) { fprintf(stderr,"fixture failed: %s errno=%d\n",name,errno); return 1; } checks++; } while(0)
static void path(char out[PATH_MAX],const char *root,const char *suffix){snprintf(out,PATH_MAX,"%s/%s",root,suffix);}
static int content(const char *p,const char *expected){char data[128]={0};FILE *f=fopen(p,"r");if(!f)return 0;size_t n=fread(data,1,sizeof data-1,f);fclose(f);return n==strlen(expected)&&!strcmp(data,expected);}
extern char **environ;
int main(int argc,char **argv){
 if(argc==2&&!strcmp(argv[1],"--child")){int fd=open("spawned",O_CREAT|O_WRONLY,0600);if(fd<0)return 3;int ok=write(fd,"owned child",11)==11;close(fd);return ok?0:4;}

 const char *original=getenv("READY_STEAM_ORIGINAL_STATE_ROOT"),*private=getenv("READY_STEAM_PRIVATE_STATE_ROOT"),*other=getenv("READY_FIXTURE_OTHER_ROOT"),*sentinel=getenv("READY_FIXTURE_SENTINEL");
 char a[PATH_MAX],b[PATH_MAX],code[PATH_MAX],outside[PATH_MAX],cwd[PATH_MAX];struct stat st;struct statfs fs;
 CHECK("HOME unchanged",!strcmp(getenv("HOME"),getenv("READY_FIXTURE_EXPECTED_HOME")));
 path(a,original,"state.bin");CHECK("reads private state instead of original",content(a,sentinel));
 path(a,original,"original-only.bin");CHECK("does not seed original account state",access(a,F_OK)<0&&errno==ENOENT);
 path(a,original,"created");int fd=open(a,O_CREAT|O_WRONLY|O_TRUNC,0600);CHECK("open maps writes",fd>=0);CHECK("write mapped fd",write(fd,sentinel,strlen(sentinel))==(ssize_t)strlen(sentinel));close(fd);
 CHECK("fopen mapped read",content(a,sentinel));CHECK("stat mapped",stat(a,&st)==0&&st.st_size==(off_t)strlen(sentinel));CHECK("lstat mapped",lstat(a,&st)==0);
 CHECK("access mapped",access(a,R_OK|W_OK)==0);CHECK("chmod mapped",chmod(a,0640)==0);CHECK("utime mapped",utime(a,NULL)==0);CHECK("statfs mapped",statfs(a,&fs)==0);
 CHECK("setxattr mapped",setxattr(a,"com.ready.fixture","ok",2,0,0)==0);char attr[8]={0};CHECK("getxattr mapped",getxattr(a,"com.ready.fixture",attr,sizeof attr,0,0)==2&&!memcmp(attr,"ok",2));CHECK("removexattr mapped",removexattr(a,"com.ready.fixture",0)==0);
 fd=open(a,O_RDWR);CHECK("ftruncate mapped fd",fd>=0&&ftruncate(fd,2)==0);CHECK("futimes mapped fd",futimes(fd,NULL)==0);CHECK("fchmod mapped fd",fchmod(fd,0600)==0);close(fd);
 path(b,original,"renamed");CHECK("rename maps both paths",rename(a,b)==0);path(a,original,"copied");CHECK("copyfile maps source and destination",copyfile(b,a,NULL,COPYFILE_DATA)==0);
 char canonical[PATH_MAX];CHECK("realpath mapped",realpath(a,canonical)&&!strncmp(canonical,private,strlen(private)));
 FILE *reopened=fopen(a,"r");CHECK("freopen mapped",reopened&&freopen(a,"r",reopened));fclose(reopened);
 CHECK("remove mapped",remove(a)==0);CHECK("unlink mapped",unlink(b)==0);
 path(a,original,"directory");CHECK("mkdir mapped",mkdir(a,0700)==0);fd=open(a,O_RDONLY|O_DIRECTORY);CHECK("open directory mapped",fd>=0);
 int child=openat(fd,"child",O_CREAT|O_RDWR,0600);CHECK("openat relative maps",child>=0);close(child);
 CHECK("fstatat relative maps",fstatat(fd,"child",&st,0)==0);CHECK("faccessat relative maps",faccessat(fd,"child",R_OK,0)==0);

 posix_spawn_file_actions_t actions;CHECK("spawn actions initialize",posix_spawn_file_actions_init(&actions)==0);
 #pragma clang diagnostic push
 #pragma clang diagnostic ignored "-Wdeprecated-declarations"
 CHECK("spawn chdir mapped",posix_spawn_file_actions_addchdir_np(&actions,a)==0);
 #pragma clang diagnostic pop
 pid_t pid=0;char *child_args[]={argv[0],"--child",NULL};CHECK("own child spawn",posix_spawn(&pid,argv[0],&actions,NULL,child_args,environ)==0);posix_spawn_file_actions_destroy(&actions);
 int status=0;CHECK("own child exited",waitpid(pid,&status,0)==pid&&WIFEXITED(status)&&WEXITSTATUS(status)==0);
 path(b,a,"spawned");CHECK("child cwd writes private",content(b,"owned child"));CHECK("child output removal mapped",unlink(b)==0);
 CHECK("mkdirat mapped",mkdirat(fd,"nested",0700)==0);CHECK("unlinkat directory mapped",unlinkat(fd,"nested",AT_REMOVEDIR)==0);
 CHECK("openat parent traversal refused",openat(fd,"../outside",O_CREAT|O_WRONLY,0600)<0&&errno==EPERM);
 CHECK("chdir maps",chdir(a)==0);CHECK("getcwd is physical private",getcwd(cwd,sizeof cwd)&&!strncmp(cwd,private,strlen(private)));
 FILE *stream=fopen("relative","w");CHECK("relative fopen maps",stream!=NULL);fputs("relative",stream);fclose(stream);
 CHECK("relative parent refused",open("../outside",O_CREAT|O_WRONLY,0600)<0&&errno==EPERM);
 CHECK("unlinkat mapped",unlinkat(fd,"child",0)==0);CHECK("relative remove maps",remove("relative")==0);close(fd);
 CHECK("chdir root maps",chdir(original)==0);CHECK("rmdir maps",rmdir(a)==0);
 DIR *dir=opendir(original);CHECK("opendir mapped",dir!=NULL);closedir(dir);
 path(code,original,"Steam.AppBundle/code.bin");CHECK("code exception reads original",content(code,"original code bytes"));
 CHECK("code open write refused",open(code,O_WRONLY|O_TRUNC)<0&&errno==EROFS);CHECK("code fopen write refused",fopen(code,"w")==NULL&&errno==EROFS);CHECK("code access write refused",access(code,W_OK)<0&&errno==EROFS);
 int codefd=open(code,O_RDONLY);CHECK("code readonly fd",codefd>=0);CHECK("code fd mutation refused",fchmod(codefd,0600)<0&&errno==EROFS);close(codefd);
 CHECK("code chmod refused",chmod(code,0600)<0&&errno==EROFS);CHECK("code unlink refused",unlink(code)<0&&errno==EROFS);
 path(a,private,"Steam.AppBundle/code.bin");CHECK("physical private code alias stays original",content(a,"original code bytes"));CHECK("private code write refused",open(a,O_WRONLY)<0&&errno==EROFS);
 path(a,original,"new-link");CHECK("new symlink refused",symlink("state.bin",a)<0&&errno==EPERM);CHECK("hardlink from code refused",link(code,a)<0&&errno==EPERM);
 path(a,original,"unsafe-alias");CHECK("existing mapped symlink refused",open(a,O_RDONLY)<0&&errno==ELOOP);CHECK("symlink stat refused",stat(a,&st)<0&&errno==ELOOP);char linkbuf[PATH_MAX];CHECK("readlink refused",readlink(a,linkbuf,sizeof linkbuf)<0&&errno==ELOOP);
 path(a,original,"../escape");CHECK("absolute parent traversal refused",open(a,O_CREAT|O_WRONLY,0600)<0&&errno==EPERM);
 path(a,other,"state.bin");CHECK("other profile sandbox read refused",open(a,O_RDONLY)<0&&(errno==EPERM||errno==EACCES));CHECK("other profile sandbox write refused",open(a,O_WRONLY|O_TRUNC)<0&&(errno==EPERM||errno==EACCES));
 path(outside,original,"state.bin");
 #pragma clang diagnostic push
 #pragma clang diagnostic ignored "-Wdeprecated-declarations"
 CHECK("raw syscall original read independently denied",syscall(SYS_open,outside,O_RDONLY,0)<0&&(errno==EPERM||errno==EACCES));
 CHECK("raw syscall original write independently denied",syscall(SYS_open,outside,O_WRONLY|O_TRUNC,0)<0&&(errno==EPERM||errno==EACCES));
 #pragma clang diagnostic pop
 const char *inherited=getenv("READY_FIXTURE_INHERITED_FD");if(inherited)CHECK("original fd mutation refused",ftruncate(atoi(inherited),0)<0);
 CHECK("root environment mutation does not change initialized profile",setenv("READY_STEAM_PRIVATE_STATE_ROOT",other,1)==0);path(a,original,"after-env-change");fd=open(a,O_CREAT|O_WRONLY,0600);CHECK("root frozen before later environment changes",fd>=0);close(fd);
 printf("{\"passed\":true,\"fixtureChecks\":%d,\"valveLoaded\":false}\n",checks);return 0;
}
'''


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory(root):
    result = {}
    for p in sorted(root.rglob('*')):
        info = p.lstat()
        if p.is_symlink(): result[str(p.relative_to(root))] = {'kind': 'symlink', 'target': os.readlink(p)}
        elif p.is_file(): result[str(p.relative_to(root))] = {'kind': 'file', 'sha256': sha(p), 'mode': stat.S_IMODE(info.st_mode)}
    return result


def quoted(path):
    return json.dumps(str(path))


def main():
    assert WORK.is_dir() and (WORK / '.ready-external-workspace').read_text().strip() == 'ready project work for thread01a17e79'
    run = Path(tempfile.mkdtemp(prefix='steam-state-fs-fixture-', dir=WORK / 'tests')); run.chmod(0o700)
    (run / '.ready-steam-state-fixture').write_text('owned benign files only\n')
    build = run / 'build'; build.mkdir(mode=0o700)
    fixture = build / 'fixture.c'; fixture.write_text(FIXTURE)
    module_cache = WORK / 'cache/steam-state-fs-clang'; module_cache.mkdir(mode=0o700, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'READY_', 'Steam', 'STEAM', 'SB_'))}
    env['TMPDIR'] = str(WORK / 'tmp') + '/'
    common = ['xcrun', 'clang', '-mmacosx-version-min=14.0', '-O2', '-Wall', '-Wextra', '-Werror', '-fmodules-cache-path=' + str(module_cache)]
    library = build / 'libReadySteamStateFS.dylib'
    commands = [[*common, '-arch', 'arm64', '-arch', 'x86_64', '-dynamiclib', str(SOURCE), '-o', str(library)]]
    for command in commands: subprocess.run(command, env=env, check=True, capture_output=True)
    original = run / 'original normal Steam'; original.mkdir(mode=0o700)
    (original / 'Steam.AppBundle').mkdir()
    (original / 'Steam.AppBundle/code.bin').write_text('original code bytes')
    (original / 'state.bin').write_text('original user state must stay untouched')
    (original / 'original-only.bin').write_text('never import another account')
    original_before = inventory(original)
    checks = {}; runs = []
    for arch in ('arm64', 'x86_64'):
        exe = build / ('fixture-' + arch)
        command = [*common, '-arch', arch, str(fixture), '-o', str(exe)]
        subprocess.run(command, env=env, check=True, capture_output=True); commands.append(command)
        a = run / (arch + '-profile-A'); b = run / (arch + '-profile-B')
        for directory, sentinel in [(a, 'profile-A-only'), (b, 'profile-B-only')]:
            directory.mkdir(mode=0o700); (directory / 'state.bin').write_text(sentinel)
            (directory / 'unsafe-alias').symlink_to(original / 'state.bin')
        for private, other, sentinel in [(a, b, 'profile-A-only'), (b, a, 'profile-B-only')]:
            other_before = inventory(other)
            sandbox = run / (arch + '-' + private.name + '.sb')
            sandbox.write_text('(version 1)\n(allow default)\n(deny file-write*)\n'
                '(allow file-write* (subpath ' + quoted(private) + '))\n'
                '(deny file-read* (subpath ' + quoted(original) + '))\n'
                '(allow file-read-metadata (literal ' + quoted(original) + '))\n'
                '(allow file-read* (subpath ' + quoted(original / 'Steam.AppBundle') + '))\n'
                '(deny file-read* (subpath ' + quoted(other) + '))\n')
            additions = {'DYLD_INSERT_LIBRARIES': str(library), 'READY_STEAM_ORIGINAL_STATE_ROOT': str(original),
                         'READY_STEAM_PRIVATE_STATE_ROOT': str(private), 'READY_FIXTURE_OTHER_ROOT': str(other),
                         'READY_FIXTURE_SENTINEL': sentinel, 'READY_FIXTURE_EXPECTED_HOME': env.get('HOME', '')}
            # The inherited descriptor is to our own synthetic original file.
            # No real user-state descriptor is opened or passed to the process.
            fd = os.open(original / 'state.bin', os.O_RDWR)
            try:
                additions['READY_FIXTURE_INHERITED_FD'] = str(fd)
                command = ['/usr/bin/sandbox-exec', '-f', str(sandbox), '/usr/bin/env', *[k + '=' + v for k, v in additions.items()], str(exe)]
                process = subprocess.run(command, env=env, pass_fds=(fd,), text=True, capture_output=True, timeout=30)
            finally: os.close(fd)
            if process.returncode: raise RuntimeError('Own fixture failed: ' + process.stderr)
            result = json.loads(process.stdout); assert result['passed'] and not result['valveLoaded']
            assert inventory(original) == original_before
            assert inventory(other) == other_before
            assert (private / 'after-env-change').is_file()
            if private == a: assert not (other / 'after-env-change').exists()
            checks[arch + '-' + private.name + '-private-io-and-denials'] = True
            checks[arch + '-' + private.name + '-original-and-other-profile-unchanged'] = True
            runs.append({'architecture': arch, 'profile': private.name, **result})
        # Invalid root configuration exits before the benign fixture body.
        for name, value in [('noncanonical', str(a / '..' / b.name)), ('overlap', str(original / 'nested')), ('unowned-mode', str(a)), ('aliased-root', str(run / (arch + '-alias')))]:
            if name == 'overlap': (original / 'nested').mkdir(mode=0o700)
            if name == 'unowned-mode': a.chmod(0o755)
            if name == 'aliased-root': Path(value).symlink_to(a)
            additions = {'DYLD_INSERT_LIBRARIES': str(library), 'READY_STEAM_ORIGINAL_STATE_ROOT': str(original), 'READY_STEAM_PRIVATE_STATE_ROOT': value}
            process = subprocess.run([str(exe)], env={**env, **additions}, text=True, capture_output=True, timeout=20)
            assert process.returncode == 78
            checks[arch + '-reject-' + name] = True
            if name == 'unowned-mode': a.chmod(0o700)
            if name == 'overlap': (original / 'nested').rmdir()
            if name == 'aliased-root': Path(value).unlink()
    assert inventory(original) == original_before
    report = {'schema': 1, 'fixtureOnly': True, 'passed': all(checks.values()), 'checks': checks, 'checkCount': len(checks), 'runs': runs,
              'sourceSHA256': sha(SOURCE), 'testSHA256': sha(Path(__file__)), 'fixtureCSHA256': sha(fixture), 'dylibSHA256': sha(library),
              'commands': commands, 'fixtureRoot': str(run), 'HOMEChanged': False, 'valveClientExecuted': False,
              'realSteamProcessesModified': False, 'originalUserStateAccessed': False, 'configurationChanged': False,
              'limitations': ['prototype only; not full filesystem virtualization', 'requires independent sandbox and closed inherited descriptors', 'outside namespace and unhooked operations remain sandbox responsibilities', 'no real native Steam or game compatibility proven']}
    path = ROOT / 'Evidence/steam-native-state-fs-fixtures.json'; path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
