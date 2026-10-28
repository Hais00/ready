# SPDX-License-Identifier: GPL-3.0-only
import contextlib
import fcntl
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[2]

class SupervisorProcessTests(unittest.TestCase):
    def test_normal_exit_and_crash_preserve_status_after_zombie_pid_reservation(self):
        with tempfile.TemporaryDirectory()as directory:
            fixture=pathlib.Path(directory)/'bridge.py'
            for code in (0,23):
                fixture.write_text('import sys;print("complete",flush=True);sys.exit('+str(code)+')\n')
                result=subprocess.run([sys.executable,str(ROOT/'StoreBridge/supervisor.py'),str(fixture)],capture_output=True,text=True,timeout=5)
                self.assertEqual(result.returncode,code);self.assertEqual(result.stdout.strip(),'complete')
    def test_cancel_waits_for_stubborn_children_and_grandchildren_and_preserves_other_job(self):
        with tempfile.TemporaryDirectory()as directory:
            root=pathlib.Path(directory).resolve();fixture=root/'bridge.py'
            fixture.write_text('''import fcntl,json,os,pathlib,signal,subprocess,sys,time
request=json.loads(sys.stdin.readline());root=pathlib.Path(request['root'])
signal.signal(signal.SIGTERM,signal.SIG_IGN)
fd=os.open(root/'lease.lock',os.O_CREAT|os.O_RDWR,0o600);fcntl.flock(fd,fcntl.LOCK_EX)
child=subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'],pass_fds=(fd,))
(root/'ready.json').write_text(json.dumps({'bridge':os.getpid(),'child':child.pid,'group':os.getpgrp()}))
print(json.dumps({'type':'progress','fraction':0.1}),flush=True)
while True:time.sleep(.02)
''')
            processes=[]
            try:
                for name in ('one','two'):
                    path=root/name;path.mkdir()
                    p=subprocess.Popen([sys.executable,str(ROOT/'StoreBridge/supervisor.py'),str(fixture)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                    p.stdin.write(json.dumps({'root':str(path)})+'\n');p.stdin.close();processes.append((p,path))
                until=time.monotonic()+5
                while not all((path/'ready.json').exists()for p,path in processes):
                    if time.monotonic()>until:self.fail('Supervisor fixture failed to start')
                    time.sleep(.02)
                first,path=processes[0];second,other=processes[1]
                with (path/'lease.lock').open('rb')as handle:
                    with self.assertRaises(BlockingIOError):fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                started=time.monotonic();first.terminate();self.assertEqual(first.wait(timeout=8),130);self.assertGreater(time.monotonic()-started,.8)
                with (path/'lease.lock').open('rb')as handle:fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                self.assertIsNone(second.poll())
                with (other/'lease.lock').open('rb')as handle:
                    with self.assertRaises(BlockingIOError):fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            finally:
                for p,path in processes:
                    if p.poll()is None:p.terminate()
                    p.wait(timeout=8)
                    if p.stdout:p.stdout.close()
                    if p.stderr:p.stderr.close()
    def test_real_backend_installation_lease_survives_until_all_download_workers_exit(self):
        sys.path.insert(0,str(ROOT/'StoreBridge'))
        import install_lock,bridge
        with tempfile.TemporaryDirectory()as directory:
            root=pathlib.Path(directory).resolve();state=root/'state';tools=root/'tools';tool=tools/'venv/bin/python';tool.parent.mkdir(parents=True)
            ready=root/'engine-ready';install=state/'Games/one';fixture=root/'bridge.py'
            tool.write_text('#!'+sys.executable+'\n'+'''import os,pathlib,signal,subprocess,sys,time
signal.signal(signal.SIGTERM,signal.SIG_IGN)
files=[]
for fd in range(3,256):
 try:os.fstat(fd);files.append(fd)
 except OSError:pass
subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'],pass_fds=tuple(files))
pathlib.Path(os.environ['READY_FIXTURE_READY']).write_text(os.environ['READY_STORE_SECRET_PARENT'])
print('10%',flush=True)
while True:time.sleep(.02)
''');tool.chmod(0o700)
            fixture.write_text('import os,pathlib,sys\nsys.path.insert(0,'+repr(str(ROOT/'StoreBridge'))+')\nimport bridge,backend\nbackend.TOOLS=pathlib.Path(os.environ["READY_FIXTURE_TOOLS"])\nraise SystemExit(bridge.main())\n')
            request={'operation':'download','store':'epic','profileID':'00000000-0000-4000-8000-000000000001','credentials':{'access_token':'fixture-private'},'options':{'gameID':'one','platform':'windows','installDir':str(install)}}
            env={**os.environ,'READY_DATA_ROOT':str(state),'READY_FIXTURE_TOOLS':str(tools),'READY_FIXTURE_READY':str(ready)}
            process=subprocess.Popen([sys.executable,str(ROOT/'StoreBridge/supervisor.py'),str(fixture)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
            try:
                process.stdin.write(json.dumps(request)+'\n');process.stdin.close()
                until=time.monotonic()+5
                while not ready.exists():
                    if time.monotonic()>until:self.fail('Backend fixture engine never started')
                    time.sleep(.02)
                auth_parent=pathlib.Path(ready.read_text())
                self.assertEqual(auth_parent.stat().st_mode&0o777,0o700)
                self.assertTrue(list(auth_parent.rglob('user.json')))
                with patch.object(install_lock,'LOCK_ROOT',state/'InstallLocks'):
                    with self.assertRaises(bridge.BridgeError):
                        with install_lock.installation_lease(install):pass
                    process.terminate();time.sleep(.1)
                    self.assertIsNone(process.poll())
                    with self.assertRaises(bridge.BridgeError):
                        with install_lock.installation_lease(install):pass
                    self.assertEqual(process.wait(timeout=8),130)
                    self.assertFalse(auth_parent.exists())
                    with install_lock.installation_lease(install):pass
            finally:
                if process.poll()is None:process.terminate();process.wait(timeout=8)
                process.stdout.close()

    def test_state_root_rejects_relative_and_symlink_without_changing_source_root(self):
        with tempfile.TemporaryDirectory()as directory:
            root=pathlib.Path(directory).resolve();owned=root/'owned';owned.mkdir();alias=root/'alias';alias.symlink_to(owned,target_is_directory=True)
            code='import sys;sys.path.insert(0,sys.argv[1]);import state_paths;print(state_paths.state_root())'
            for value in ('relative',str(alias)):
                env={**os.environ,'READY_DATA_ROOT':value}
                result=subprocess.run([sys.executable,'-c',code,str(ROOT/'StoreBridge')],capture_output=True,text=True,env=env)
                self.assertNotEqual(result.returncode,0)
            env={**os.environ,'READY_DATA_ROOT':str(owned)}
            result=subprocess.run([sys.executable,'-c',code,str(ROOT/'StoreBridge')],capture_output=True,text=True,env=env,check=True)
            self.assertEqual(pathlib.Path(result.stdout.strip()),owned);self.assertEqual(owned.stat().st_mode&0o777,0o700)

if __name__=='__main__':unittest.main()
