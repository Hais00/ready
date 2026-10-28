#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic private-cache guards only. Never calls a client or authenticates."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock

import steam_private_cache_loader as loader

ACCOUNT = 'fixture_account'
STEAM_ID = (1 << 56) | (1 << 52) | (1 << 32) | 12345


class CacheChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ready-private-cache-fixture-')
        self.work = Path(self.temp.name).resolve(); self.work.chmod(0o700)
        (self.work/'.ready-external-workspace').write_text('ready project work for thread01a17e79\n')
        self.run = self.work/'retained/research-steam-native/fixture'
        self.run.mkdir(parents=True); self.run.chmod(0o700)
        self.config = self.run/'state/client/userdata/private-fixture/config/localconfig.vdf'
        self.config.parent.mkdir(parents=True)
        self.config.write_text('"MachineUserConfigStore" { "ConnectCache" { "'+ACCOUNT+'" "'+('00ab'*40)+'" } }')
        self.report = {'steamKitAuthorization':{'authorized':True,'ownershipTicketReceived':True,'steamID':STEAM_ID,'appID':123},
                       'librarySHA256':'b'*64,'libraryUnchanged':True,'ipcAdapter':{'namespace':'a'*32}}
        self.save_report()

    def tearDown(self):
        self.temp.cleanup()

    def save_report(self):
        p=self.run/'report.json';p.write_text(json.dumps(self.report))
        self.report_sha=hashlib.sha256(p.read_bytes()).hexdigest()

    def load(self):
        return loader._load(self.run,self.work,self.report_sha,'b'*64)

    def test_valid_single_entry_uses_only_sentinel_and_authoritative_receipt(self):
        context=self.load()
        try:
            safe=json.dumps(context.safe)
            self.assertNotIn(ACCOUNT,safe);self.assertNotIn(str(STEAM_ID),safe)
            self.assertTrue(context.safe['requiresCachedLoginMode'])
            self.assertFalse(context.safe['sentinelIsCredential'])
            self.assertFalse(context.safe['cachedNativeAuthenticationVerified'])
            r,w=os.pipe();context.handoff.write_to(w)
            try:data=os.read(r,20000);self.assertEqual(os.read(r,1),b'')
            finally:os.close(r)
            self.assertIn(loader.SENTINEL.encode(),data)
            self.assertNotIn(('00ab'*40).encode(),data)
        finally:context.close()

    def test_wrong_report_digest(self):
        self.report_sha='c'*64
        with self.assertRaisesRegex(loader.PrivateCacheError,'report_mismatch'):self.load()

    def test_authorization_and_namespace_required(self):
        for change in ['authorized','ticket','namespace','image']:
            with self.subTest(change=change):
                before=json.loads(json.dumps(self.report))
                if change=='authorized':self.report['steamKitAuthorization']['authorized']=False
                if change=='ticket':self.report['steamKitAuthorization']['ownershipTicketReceived']=False
                if change=='namespace':self.report['ipcAdapter']['namespace']='bad'
                if change=='image':self.report['librarySHA256']='c'*64
                self.save_report()
                with self.assertRaisesRegex(loader.PrivateCacheError,'unbound_authorization'):self.load()
                self.report=before;self.save_report()

    def test_invalid_account_and_nonopaque_entry_rejected(self):
        for body in ['"bad account" "'+('00ab'*40)+'"','"'+ACCOUNT+'" "plaintext-is-not-a-cache-blob"']:
            self.config.write_text('"ConnectCache" { '+body+' }')
            with self.assertRaisesRegex(loader.PrivateCacheError,'invalid_cache_entry'):self.load()

    def test_multiple_or_missing_entries_rejected(self):
        for body in ['','"'+ACCOUNT+'" "'+('00ab'*40)+'" "second_fixture" "'+('00cd'*40)+'"']:
            self.config.write_text('"ConnectCache" { '+body+' }')
            with self.assertRaisesRegex(loader.PrivateCacheError,'ambiguous_or_missing_cache'):self.load()

    def test_world_writable_config_rejected(self):
        self.config.chmod(0o666)
        with self.assertRaisesRegex(loader.PrivateCacheError,'unsafe_file'):self.load()

    def test_root_alias_rejected(self):
        alias=self.work/'alias';alias.symlink_to(self.run)
        with self.assertRaisesRegex(loader.PrivateCacheError,'unsafe_root'):
            loader._load(alias,self.work,self.report_sha,'b'*64)

    def test_config_symlink_does_not_read_target(self):
        other=self.work/'outside-fixture.vdf';other.write_text('outside sentinel')
        self.config.unlink();self.config.symlink_to(other)
        with self.assertRaises(OSError):self.load()
        self.assertEqual(other.read_text(),'outside sentinel')

    def test_invalid_authoritative_identity_rejected(self):
        self.report['steamKitAuthorization']['steamID']=0;self.save_report()
        with self.assertRaisesRegex(loader.PrivateCacheError,'invalid_authoritative_identity'):self.load()

    def test_public_entry_point_not_retargetable_and_cancel_does_not_read(self):
        with self.assertRaises(TypeError):loader.load_private_cached_login(run=self.run)
        stop=threading.Event();stop.set()
        with self.assertRaisesRegex(loader.PrivateCacheError,'cancelled'):loader.load_private_cached_login(cancel=stop)

    def test_explicit_success_reference_and_original_default_are_separate_pins(self):
        context=object()
        with mock.patch.object(loader,'_load',return_value=context) as load:
            self.assertIs(loader.load_private_cached_login(),context)
            self.assertEqual(load.call_args.args[:3],(loader.RUN,loader.WORK,loader.REPORT_SHA))
            self.assertFalse(load.call_args.kwargs['require_native_success'])
            self.assertIs(loader.load_private_cached_login(reference_report=loader.SUCCESS_RUN/'report.json'),context)
            self.assertEqual(load.call_args.args[:3],(loader.SUCCESS_RUN,loader.WORK,loader.SUCCESS_REPORT_SHA))
            self.assertTrue(load.call_args.kwargs['require_native_success'])

    def test_unapproved_reference_rejected_before_any_cache_read(self):
        with mock.patch.object(loader,'_load') as load:
            with self.assertRaisesRegex(loader.PrivateCacheError,'unapproved_reference'):
                loader.load_private_cached_login(reference_report=self.run/'report.json')
            load.assert_not_called()

    def test_success_reference_requires_native_identity_and_subscription_proof(self):
        with self.assertRaisesRegex(loader.PrivateCacheError,'unverified_native_reference'):
            loader._load(self.run,self.work,self.report_sha,'b'*64,require_native_success=True)
        self.report.update(accountAuthenticated=True,existingSteamProcessesUnchanged=True,
            observations=[{'authenticatedIdentityMatches':True,'genuineSubscriptionObserved':True},
                          {'authenticated':True,'genuineSubscriptionObserved':True}])
        self.save_report()
        context=loader._load(self.run,self.work,self.report_sha,'b'*64,require_native_success=True)
        try:
            self.assertTrue(context.safe['referenceNativeAuthenticationVerified'])
            self.assertFalse(context.safe['cachedNativeAuthenticationVerified'])
        finally:context.close()


if __name__=='__main__':
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CacheChecks))
    print(json.dumps({'fixtureOnly':True,'passed':result.wasSuccessful(),'testMethods':result.testsRun,
                      'actualAuthentication':False,'valveExecuted':False,'normalSteamMetadataRead':False}))
    raise SystemExit(not result.wasSuccessful())
