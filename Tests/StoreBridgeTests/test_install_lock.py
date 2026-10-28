# SPDX-License-Identifier: GPL-3.0-only
import contextlib
import fcntl
import io
import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'StoreBridge'))
import backend
import bridge
import install_lock

PROFILE='00000000-0000-4000-8000-000000000001'
OTHER='00000000-0000-4000-8000-000000000002'
HOLDER='''import pathlib,sys
sys.path.insert(0,sys.argv[1])
import install_lock
install_lock.LOCK_ROOT=pathlib.Path(sys.argv[2])
path=install_lock.canonical_installation(sys.argv[3])
with install_lock.installation_lease(path,sys.argv[4]):
 print('ready',flush=True)
 sys.stdin.read(1)
'''

class InstallationCoordinationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=pathlib.Path(self.temp.name).resolve();self.locks=self.root/'locks'
        for target,name,value in [(install_lock,'LOCK_ROOT',self.locks),(backend,'PROFILE_ROOT',self.root/'Profiles')]:
            p=patch.object(target,name,value);p.start();self.addCleanup(p.stop)
    def request(self,profile=PROFILE,game='one',path=None):
        return {'operation':'download','store':'epic','profileID':profile,'credentials':{'access_token':profile},'options':{'gameID':game,'platform':'windows','installDir':str(path or self.root/'Games'/game)}}
    @contextlib.contextmanager
    def holder(self,path,mode='write'):
        p=subprocess.Popen([sys.executable,'-c',HOLDER,str(ROOT/'StoreBridge'),str(self.locks),str(path),mode],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertTrue(select.select([p.stdout],[],[],5)[0],'Lease subprocess did not start')
            self.assertEqual(p.stdout.readline().strip(),'ready')
            yield p
        finally:
            if p.poll() is None:p.stdin.write('x');p.stdin.flush()
            try:p.communicate(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.communicate()
    def test_two_profiles_cannot_download_same_real_directory(self):
        target=install_lock.canonical_installation(str(self.root/'Game'))
        with self.holder(target),patch.object(backend,'_download_locked',side_effect=AssertionError('Downloader must not start')):
            for profile in (PROFILE,OTHER):
                with self.assertRaises(bridge.BridgeError)as error:backend.download(self.request(profile,path=target))
                self.assertEqual(error.exception.code,'installation_busy')
        with install_lock.installation_lease(target):pass
    def test_symlink_alias_from_another_profile_uses_the_same_lease(self):
        target=install_lock.canonical_installation(str(self.root/'Game'));alias=self.root/'Alias';alias.symlink_to(target,target_is_directory=True)
        self.assertEqual(install_lock.canonical_installation(str(alias)),target)
        with self.holder(target):
            with self.assertRaises(bridge.BridgeError)as error:backend.download(self.request(OTHER,path=alias))
            self.assertEqual(error.exception.code,'installation_busy')
    def test_overlapping_parent_child_targets_are_rejected_but_siblings_are_allowed(self):
        parent=install_lock.canonical_installation(str(self.root/'Games/one'));child=install_lock.canonical_installation(str(parent/'DLC'));sibling=install_lock.canonical_installation(str(self.root/'Games/two'))
        with self.holder(parent):
            with self.assertRaises(bridge.BridgeError)as error:
                with install_lock.installation_lease(child):pass
            self.assertEqual(error.exception.code,'installation_busy')
            with install_lock.installation_lease(sibling):pass
        with self.holder(child):
            with self.assertRaises(bridge.BridgeError):
                with install_lock.installation_lease(parent):pass
    def test_different_games_same_profile_have_independent_cache_and_download_locks(self):
        calls=[]
        def run(request,config,creds,path,identity,fds):
            calls.append((request['options']['gameID'],config,creds,tuple(fds)))
            if request['options']['gameID']=='one':return backend.download(self.request(game='two'))
            return {'completed':'two'}
        with patch.object(backend,'_download_locked',side_effect=run):result=backend.download(self.request())
        self.assertEqual(result,{'completed':'two'});self.assertEqual(len(calls),2);self.assertNotEqual(calls[0][1],calls[1][1]);self.assertTrue(all(call[3]for call in calls))
    def test_account_cache_and_credentials_are_isolated_between_profiles(self):
        calls=[]
        with patch.object(backend,'_download_locked',side_effect=lambda request,config,creds,*rest:calls.append((config,creds))):
            backend.download(self.request());backend.download(self.request(OTHER))
        self.assertNotEqual(calls[0][0],calls[1][0]);self.assertEqual(calls[0][1]['access_token'],PROFILE);self.assertEqual(calls[1][1]['access_token'],OTHER)
        self.assertEqual(calls[0][0].stat().st_mode&0o777,0o700)
    def test_failure_and_cancellation_release_all_locks(self):
        for failure in (bridge.BridgeError('download_failed','fixture'),KeyboardInterrupt()):
            with patch.object(backend,'_download_locked',side_effect=failure):
                with self.assertRaises(type(failure)):backend.download(self.request())
            with install_lock.installation_lease(self.root/'Games/one'):pass
    def test_replaced_installation_is_rejected_before_success(self):
        target=install_lock.canonical_installation(str(self.root/'Game'))
        with install_lock.installation_lease(target)as lease:
            target.rename(self.root/'Old');target.mkdir()
            with self.assertRaises(bridge.BridgeError)as error:install_lock.verify_installation(target,lease.identity)
            self.assertEqual(error.exception.code,'installation_changed')
            with self.assertRaises(bridge.BridgeError):
                with install_lock.installation_lease(target):pass
    def test_installation_cannot_overlap_account_state(self):
        request=self.request(path=backend.PROFILE_ROOT/PROFILE/'Stores/epic')
        with self.assertRaises(bridge.BridgeError)as error:backend.download(request)
        self.assertEqual(error.exception.code,'invalid_path')
    def test_profile_symlink_cannot_alias_another_profile(self):
        original=backend.profile_config(self.request());other=backend.PROFILE_ROOT/OTHER
        other.symlink_to(backend.PROFILE_ROOT/PROFILE,target_is_directory=True)
        with self.assertRaises(bridge.BridgeError)as error:backend.profile_config(self.request(OTHER))
        self.assertEqual(error.exception.code,'unsafe_state_path');self.assertTrue(original.is_dir())
    def test_lock_directory_symlink_is_not_followed(self):
        other=self.root/'elsewhere';other.mkdir();self.locks.symlink_to(other,target_is_directory=True)
        target=install_lock.canonical_installation(str(self.root/'Game'))
        with self.assertRaises(bridge.BridgeError):
            with install_lock.installation_lease(target):pass
        self.assertEqual(list(other.iterdir()),[])
    def test_read_read_is_parallel_for_equal_and_nested_roots(self):
        parent=install_lock.canonical_installation(str(self.root/'Games/one'));child=install_lock.canonical_installation(str(parent/'DLC'))
        for held,wanted in [(parent,parent),(parent,child),(child,parent)]:
            with self.holder(held,'read'):
                with install_lock.installation_lease(wanted,'read'):pass
    def test_read_write_overlap_is_symmetric_in_both_hierarchy_directions(self):
        parent=install_lock.canonical_installation(str(self.root/'Games/one'));child=install_lock.canonical_installation(str(parent/'DLC'))
        for held,wanted in [(parent,parent),(parent,child),(child,parent)]:
            for first,second in [('read','write'),('write','read')]:
                with self.subTest(first=first,held=held,wanted=wanted),self.holder(held,first):
                    with self.assertRaises(bridge.BridgeError)as error:
                        with install_lock.installation_lease(wanted,second):pass
                    self.assertEqual(error.exception.code,'installation_busy')
    def test_reader_and_writer_siblings_do_not_block_each_other(self):
        one=install_lock.canonical_installation(str(self.root/'Games/one'));two=install_lock.canonical_installation(str(self.root/'Games/two'))
        for first,second in [('read','read'),('read','write'),('write','read'),('write','write')]:
            with self.holder(one,first):
                with install_lock.installation_lease(two,second):pass
    @contextlib.contextmanager
    def native_reader(self,path,expect_busy=False):
        host=ROOT/'Build/ReadySessionHost'
        if sys.platform!='darwin' or not host.is_file():self.skipTest('Native macOS ReadySessionHost must be built for cross-language test')
        number=getattr(self,'keeper_number',0)+1;self.keeper_number=number
        ready=self.root/f'keeper-{number}.ready';lease_path=self.root/f'keeper-{number}.prefix.lock'
        handle=lease_path.open('a+b');os.fchmod(handle.fileno(),0o600);fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
        worker='import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();time.sleep(30)'
        argv=[str(host),'--installation',str(path),'--installation-lock-root',str(self.locks),'--',sys.executable,'-c',worker,str(ready)]
        process=subprocess.Popen(argv,stdin=handle,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True);handle.close()
        try:
            if expect_busy:
                _,error=process.communicate(timeout=5);self.assertEqual(process.returncode,73,error);self.assertFalse(ready.exists())
            else:
                until=time.monotonic()+5
                while not ready.exists():
                    self.assertIsNone(process.poll(),'Keeper failed: '+(process.stderr.read()if process.poll()is not None else ''))
                    if time.monotonic()>until:self.fail('Keeper child never signaled installation admission')
                    time.sleep(.02)
            yield process
        finally:
            if process.poll()is None:process.terminate()
            try:process.communicate(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.communicate()
    def test_native_keeper_read_lease_blocks_python_writers_and_allows_other_readers(self):
        parent=install_lock.canonical_installation(str(self.root/'Games'));one=install_lock.canonical_installation(str(parent/'one'));child=install_lock.canonical_installation(str(one/'DLC'));two=install_lock.canonical_installation(str(parent/'two'))
        alias=self.root/'OneAlias';alias.symlink_to(one,target_is_directory=True)
        with self.native_reader(alias):
            for target in (parent,one,child):
                with self.assertRaises(bridge.BridgeError):
                    with install_lock.installation_lease(target,'write'):pass
            with install_lock.installation_lease(two,'write'):pass
            with self.native_reader(child):
                with install_lock.installation_lease(one,'read'):pass
        with install_lock.installation_lease(one,'write'):pass
    def test_python_writer_blocks_native_keeper_for_equal_ancestor_and_nested_targets(self):
        parent=install_lock.canonical_installation(str(self.root/'Games'));one=install_lock.canonical_installation(str(parent/'one'));child=install_lock.canonical_installation(str(one/'DLC'));two=install_lock.canonical_installation(str(parent/'two'))
        with install_lock.installation_lease(one,'write'):
            for target in (parent,one,child):
                with self.native_reader(target,expect_busy=True):pass
            with self.native_reader(two):pass
        with self.native_reader(one):pass

    def test_downloader_keeps_lease_if_the_bridge_process_dies(self):
        target=install_lock.canonical_installation(str(self.root/'Game'))
        code='''import os,pathlib,subprocess,sys
sys.path.insert(0,sys.argv[1])
import install_lock
install_lock.LOCK_ROOT=pathlib.Path(sys.argv[2])
with install_lock.installation_lease(pathlib.Path(sys.argv[3]))as lease:
 child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],pass_fds=lease.fds,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
 print(child.pid,flush=True)
 os._exit(0)
'''
        p=subprocess.Popen([sys.executable,'-c',code,str(ROOT/'StoreBridge'),str(self.locks),str(target)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        child=None
        try:
            self.assertTrue(select.select([p.stdout],[],[],5)[0]);child=int(p.stdout.readline());p.communicate(timeout=5);self.assertEqual(p.returncode,0)
            with self.assertRaises(bridge.BridgeError):
                with install_lock.installation_lease(target):pass
        finally:
            if child is not None:
                with contextlib.suppress(ProcessLookupError):os.kill(child,signal.SIGTERM)
            if p.poll()is None:p.kill();p.communicate()
        until=time.monotonic()+5
        while True:
            try:
                with install_lock.installation_lease(target):pass
                break
            except bridge.BridgeError:
                if time.monotonic()>until:raise
                time.sleep(0.02)

if __name__=='__main__':unittest.main()
