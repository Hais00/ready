#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Miniature SDK cache fixtures; never run a compiler or touch the real SDK."""
import json, os, pathlib, shutil, stat, sys, tempfile, unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent))
import store_sdk_cache as module
import store_bootstrap as bootstrap


class SDKCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name).resolve();(self.root/'.ready-sdk-cache-fixture').write_text('Owned fixture\n');(self.root/'source.json').write_text('{"version":"synthetic","sha512":"fixture"}')
        self.sdk=self.root/'dotnet';self.sdk.mkdir();(self.sdk/'host').mkdir();(self.sdk/'host/runtime').write_bytes(b'host stays intact');(self.sdk/'shared').mkdir();(self.sdk/'shared/runtime.dll').write_bytes(b'framework stays intact');(self.sdk/'LICENSE.txt').write_text('retained fixture license')
        for name in module.NAMES:
            (self.sdk/name/'version').mkdir(parents=True);p=self.sdk/name/'version/tool';p.write_bytes((name+' fixture\n').encode()*70);p.chmod(0o751)
        (self.sdk/'sdk/host-link').symlink_to('../host/runtime')
        self.cache=module.SDKCache(self.sdk,fixture=True);self.original=module.snapshot(self.sdk);self.reserve=patch.object(module,'RESTORE_RESERVE',0);self.reserve.start()
    def tearDown(self):self.reserve.stop();self.temp.cleanup()
    def test_roundtrip_bytes_modes_symlink_and_host_preserved(self):
        host=module.sha(self.sdk/'host/runtime');r=self.cache.compact();self.assertTrue(r['compacted']);self.assertTrue(all(not(self.sdk/n).exists()for n in module.NAMES));self.assertEqual(host,module.sha(self.sdk/'host/runtime'));self.assertTrue(self.cache.restore()['restored']);self.assertEqual(self.original,module.snapshot(self.sdk));self.assertEqual('../host/runtime',os.readlink(self.sdk/'sdk/host-link'));self.assertEqual(0o751,stat.S_IMODE((self.sdk/'packs/version/tool').stat().st_mode));self.assertTrue(self.cache.restore()['alreadyComplete'])
    def test_tampered_archive_rejected_before_restore(self):
        self.cache.compact();m=self.cache.load();p=self.cache.cache/m['archive'];p.write_bytes(p.read_bytes()+b'tampered');before=set(self.sdk.iterdir());self.assertRaises(ValueError,self.cache.restore);self.assertEqual(before,set(self.sdk.iterdir()))
    def test_manifest_tampering_rejected(self):
        self.cache.compact();p=self.cache.manifest;x=json.loads(p.read_text());x['entries']['sdk']['mode']=0;p.write_text(json.dumps(x));self.assertRaises(ValueError,self.cache.restore)
    def test_existing_conflict_is_preserved_and_no_other_root_restored(self):
        self.cache.compact();(self.sdk/'packs').mkdir();(self.sdk/'packs/custom').write_text('preserve me');self.assertRaises(ValueError,self.cache.restore);self.assertEqual('preserve me',(self.sdk/'packs/custom').read_text());self.assertFalse((self.sdk/'sdk').exists())
    def test_exact_already_restored_root_allows_idempotent_remainder(self):
        self.cache.compact();self.cache.restore();shutil.rmtree(self.sdk/'templates');self.assertEqual(['templates'],self.cache.restore()['roots']);self.assertEqual(self.original,module.snapshot(self.sdk))
    def test_unrelated_path_and_root_symlink_rejected(self):
        self.assertRaises(ValueError,module.SDKCache,self.sdk);link=self.root/'alias';link.symlink_to(self.sdk);self.assertRaises(ValueError,module.SDKCache,link,fixture=True);self.assertRaises(ValueError,module.relative,'sdk/../host/runtime')
    def test_failed_archive_verification_keeps_original_sdk(self):
        with patch.object(self.cache,'verify_archive',side_effect=ValueError('test verification failure')):self.assertRaises(ValueError,self.cache.compact)
        self.assertEqual(self.original,module.snapshot(self.sdk))
    def test_restore_space_guard_precedes_materialization(self):
        self.cache.compact()
        usage=shutil._ntuple_diskusage(2**30,2**29,2**29)
        with patch.object(module,'RESTORE_RESERVE',512*1024*1024),patch.object(module.shutil,'disk_usage',return_value=usage):
            self.assertRaises(OSError,self.cache.restore)
        self.assertTrue(all(not(self.sdk/name).exists()for name in module.NAMES))

    def test_stale_removal_state_after_delete_can_retry(self):
        self.cache.compact();archive=self.cache.load()['archiveSHA256'];host=module.sha(self.sdk/'host/runtime')
        stage=self.cache.cache/'remove-stale-deleted'
        module.atomic(self.cache.cache/'removal-state.json',{'stage':stage.name,'manifestSHA256':module.sha(self.cache.manifest)})
        self.assertFalse(stage.exists());self.assertTrue(self.cache.compact()['compacted'])
        self.assertFalse(stage.exists());self.assertFalse((self.cache.cache/'removal-state.json').exists())
        self.assertEqual(archive,self.cache.load()['archiveSHA256']);self.assertEqual(host,module.sha(self.sdk/'host/runtime'))

    def test_changed_source_or_mode_rejected_preserving_originals(self):
        source=self.cache.source.read_bytes();self.cache.compact();self.cache.source.write_text('{"version":"different"}')
        self.assertRaises(ValueError,self.cache.compact);self.cache.source.write_bytes(source);self.cache.restore()
        path=self.sdk/'sdk/version/tool';path.chmod(0o640);before=module.snapshot(self.sdk)
        self.assertRaises(ValueError,self.cache.compact);self.assertEqual(before,module.snapshot(self.sdk))
        self.assertEqual(0o640,stat.S_IMODE(path.stat().st_mode))

    def test_existing_unknown_removal_stage_is_never_deleted(self):
        self.cache.compact();stage=self.cache.cache/'remove-existing-unknown';stage.mkdir();unknown=stage/'unrelated';unknown.write_bytes(b'preserve unknown data')
        module.atomic(self.cache.cache/'removal-state.json',{'stage':stage.name,'manifestSHA256':module.sha(self.cache.manifest)})
        self.assertRaises(ValueError,self.cache.compact);self.assertEqual(b'preserve unknown data',unknown.read_bytes())
        self.assertTrue((self.cache.cache/'removal-state.json').exists())

    def test_bootstrap_restores_cache_without_network_or_build(self):
        # Same project layout, but only an owned disposable fixture and fake host.
        project=self.root/'project';parent=project/'Runtime/Tools/StoreBridge';parent.mkdir(parents=True);(parent/'.ready-sdk-cache-fixture').write_text('Owned fixture\n');shutil.copy2(self.root/'source.json',parent/'source.json');shutil.copytree(self.sdk,parent/'dotnet',symlinks=True);(parent/'dotnet/dotnet').write_text('fake host, never executed');real=module.SDKCache(parent/'dotnet',fixture=True);real.compact()
        with patch.object(bootstrap,'ROOT',project),patch.object(module,'SDKCache',side_effect=lambda target:real),patch.object(bootstrap.urllib.request,'urlopen',side_effect=AssertionError('network forbidden')):
            self.assertEqual(parent/'dotnet/dotnet',bootstrap.dotnet())
        self.assertEqual(self.original,module.snapshot(parent/'dotnet'))

if __name__=='__main__':unittest.main()
