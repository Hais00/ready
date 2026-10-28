#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Private JSON pipe supervisor. Reserve the job PGID until all children are gone.

The bridge child is NOT reaped until group cleanup is complete. WNOWAIT keeps
its PID reserved, so group signals can never target a recycled unrelated PGID.
The supervisor keeps stdout open until cleanup, making EOF a lifetime barrier.
"""
import ctypes
import errno
import os
import pathlib
import signal
import sys
import tempfile
import time


def group_members(pgid):
    if sys.platform=='darwin':
        lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
        function=lib.proc_listpids
        function.argtypes=[ctypes.c_uint,ctypes.c_uint,ctypes.c_void_p,ctypes.c_int]
        function.restype=ctypes.c_int
        size=function(2,pgid,None,0)  # PROC_PGRP_ONLY, owned child process group.
        if size<0:raise OSError(ctypes.get_errno(),'Cannot inspect owned process group')
        buffer=(ctypes.c_int*(size//ctypes.sizeof(ctypes.c_int)+64))()
        size=function(2,pgid,buffer,ctypes.sizeof(buffer))
        if size<0:raise OSError(ctypes.get_errno(),'Cannot inspect owned process group')
        class ShortInfo(ctypes.Structure):
            _fields_=[('pid',ctypes.c_uint32),('ppid',ctypes.c_uint32),('pgid',ctypes.c_uint32),('status',ctypes.c_uint32),('name',ctypes.c_char*16),('rest',ctypes.c_uint32*8)]
        inspect=lib.proc_pidinfo
        inspect.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
        inspect.restype=ctypes.c_int
        members=set()
        for pid in buffer[:size//ctypes.sizeof(ctypes.c_int)]:
            if pid<=0:continue
            info=ShortInfo();count=inspect(pid,13,0,ctypes.byref(info),ctypes.sizeof(info))
            if count==0 and ctypes.get_errno()==errno.ESRCH:continue
            if count!=ctypes.sizeof(info):raise OSError(ctypes.get_errno(),'Cannot inspect owned group member')
            # PROC_PIDT_SHORTBSDINFO, SZOMB=5: zombies retain the PID but no FDs.
            if info.pgid==pgid and info.status!=5:members.add(pid)
        return members
    # Linux fixture/CI support. Zombies own no file descriptors.
    members=set()
    for entry in pathlib.Path('/proc').iterdir():
        if not entry.name.isdigit():continue
        try:
            fields=(entry/'stat').read_text().rsplit(')',1)[1].split()
            if fields[0]!='Z' and int(fields[2])==pgid:members.add(int(entry.name))
        except (OSError,ValueError,IndexError):pass
    return members


def send_group(pgid,signum):
    try:os.killpg(pgid,signum)
    except ProcessLookupError:pass
    except PermissionError:
        # Darwin may return EPERM for a group containing only the reserved zombie.
        if group_members(pgid):raise


def run(script):
    with tempfile.TemporaryDirectory(prefix='ready-store-job-') as secret_parent:
        os.chmod(secret_parent,0o700)
        return _run(script,secret_parent)


def _run(script,secret_parent):
    if not all(hasattr(os,name) for name in ('fork','waitid','WNOWAIT','WEXITED','WNOHANG','P_PID')):
        return 71  # Never silently weaken the PID-reservation contract.
    stop=[False]
    def cancel(signum,frame):stop[0]=True
    signal.signal(signal.SIGTERM,cancel)
    signal.signal(signal.SIGINT,cancel)
    if stop[0]:return 130
    pid=os.fork()
    if pid==0:
        try:
            os.setpgid(0,0)
            signal.signal(signal.SIGTERM,signal.SIG_DFL)
            signal.signal(signal.SIGINT,signal.SIG_DFL)
            env={**os.environ,'READY_STORE_SUPERVISED':'1','READY_STORE_PROCESS_GROUP':str(os.getpid()),'READY_STORE_SECRET_PARENT':secret_parent}
            os.execve(sys.executable,[sys.executable,script],env)
        except BaseException:os._exit(127)
    reaped=False
    try:
        try:os.setpgid(pid,pid)
        except OSError as error:
            if error.errno not in (errno.EACCES,errno.ESRCH):raise
        # Only the bridge reads the request. This also makes a broken stdin
        # observable by Swift instead of leaving an unused pipe reader alive.
        os.close(0)
        finished=None;cleanup_at=None;killed=False
        while True:
            if finished is None:
                finished=os.waitid(os.P_PID,pid,os.WEXITED|os.WNOHANG|os.WNOWAIT)
            if finished is not None and not (group_members(pid)-{pid}):break
            if stop[0] or finished is not None:
                if cleanup_at is None:
                    send_group(pid,signal.SIGTERM);cleanup_at=time.monotonic()
                elif not killed and time.monotonic()-cleanup_at>=1.0:
                    send_group(pid,signal.SIGKILL);killed=True
            time.sleep(.02)
        _,status=os.waitpid(pid,0);reaped=True
        if stop[0]:return 130
        return os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 128+os.WTERMSIG(status)
    finally:
        if not reaped:
            # The unreaped child still reserves this exact PGID.
            while True:
                try:send_group(pid,signal.SIGKILL)
                except OSError:pass
                try:
                    if not (group_members(pid)-{pid}):break
                except Exception:
                    # Fail closed: keep the guardian/PID reservation alive until
                    # its owned descendants can be confirmed gone.
                    pass
                time.sleep(.05)
            os.waitpid(pid,0)


if __name__=='__main__':
    if len(sys.argv)!=2 or not pathlib.Path(sys.argv[1]).is_absolute():raise SystemExit(64)
    try:result=run(sys.argv[1])
    except BaseException:result=71  # No traceback, input, bearer data, or URLs.
    raise SystemExit(result)
