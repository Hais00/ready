# SPDX-License-Identifier: GPL-3.0-only
import contextlib,importlib.util,json,os,pathlib,subprocess,sys,tempfile,unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'StoreBridge'))
import bridge,size_plan
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79/tests')
PROFILE='00000000-0000-4000-8000-000000000001'
def request(store='epic',platform='windows'):
    return dict(operation='install_size_plan',store=store,profileID=PROFILE,credentials={'access_token':'private-fixture-token'},options={'gameID':'123'if store=='gog'else'fixture-game','platform':platform,'language':'en'})
class SizeSchemaTests(unittest.TestCase):
    def test_capability_is_store_scoped(self):
        value=bridge.dispatch({'operation':'capabilities'});self.assertEqual(value['operationStores']['install_size_plan'],['epic','gog','amazon'])
    def test_epic_manifest_sizes_not_previous_installation(self):
        c=size_plan.context(request());data={'game':{'app_name':'fixture-game'},'manifest':{'app_name':'fixture-game','disk_size':1200,'download_size':800},'install':{'disk_size':999}}
        value=size_plan.epic_plan(data,c);self.assertEqual((value['installedBytes'],value['downloadBytes']),(1200,800));self.assertTrue(value['verified']);self.assertNotIn('requiredBytes',value)
    def test_epic_wrong_identity_and_missing_manifest_are_unknown(self):
        c=size_plan.context(request())
        self.assertIsNone(size_plan.epic_plan({'game':{'app_name':'other'},'manifest':{'disk_size':1}},c)['installedBytes'])
        self.assertIsNone(size_plan.epic_plan({'game':{'app_name':'fixture-game'},'install':{'disk_size':42}},c)['installedBytes'])
    def test_bad_numeric_types_never_become_zero_or_truncated_bytes(self):
        for value in [True,False,-1,1.2,float('nan'),'1.2','12 GiB',str(2**64),'9'*5000,2**64]:self.assertIsNone(size_plan.uint64(value))
        self.assertEqual(size_plan.uint64(0),0);self.assertEqual(size_plan.uint64(str(2**64-1)),2**64-1)
    def test_gog_selected_depots_keep_language_and_generation(self):
        c=size_plan.context(request('gog','macOS'));data={'gameID':'123','generation':2,'selected':{'disk_size':700,'download_size':450}}
        value=size_plan.gog_plan(data,c);self.assertTrue(value['verified']);self.assertEqual(value['basis']['generation'],2);self.assertEqual(value['platform'],'macOS');self.assertEqual(value['installedBytes'],700)
    def test_gog_unselected_bucket_totals_are_not_assumed_exact(self):
        value=size_plan.gog_plan({'size':{'*':{'disk_size':100},'en-US':{'disk_size':100}}},size_plan.context(request('gog')))
        self.assertFalse(value['verified']);self.assertIsNone(value['installedBytes'])
    def test_gog_catalog_estimate_is_language_platform_specific_download_only(self):
        values=size_plan.gog_catalog_sizes('123',[{'os':'windows','language':'en','total_size':500},{'os':'osx','language':'en','total_size':700},{'os':'windows','language':'fr','total_size':600}])
        self.assertEqual(values['windows']['downloadBytes'],500);self.assertEqual(values['macOS']['downloadBytes'],700);self.assertIsNone(values['windows']['installedBytes']);self.assertFalse(values['windows']['verified'])
    def test_ambiguous_installer_catalog_does_not_choose_a_random_version(self):
        self.assertEqual(size_plan.gog_catalog_sizes('1',[{'os':'windows','language':'en','total_size':2}]*2),{})
    def test_nile_all_package_files_are_measured_but_multpackage_engine_is_not_verified(self):
        data={'gameID':'fixture-game','signatureVerified':True,'packageCount':2,'files':[{'path':'a','size':10,'hash':'x'},{'path':'b','size':20,'hash':'y'},{'path':'a','size':10,'hash':'x'}]}
        value=size_plan.amazon_plan(data,size_plan.context(request('amazon')));self.assertEqual(value['installedBytes'],30);self.assertIsNone(value['downloadBytes']);self.assertFalse(value['verified']);self.assertEqual(value['reason'],'engine_multiple_packages_unverified')
    def test_nile_one_signed_package_reports_disk_only_without_wire_guess(self):
        data={'gameID':'fixture-game','signatureVerified':True,'packageCount':1,'files':[{'path':'bin/game.exe','size':50,'hash':'x'}]}
        value=size_plan.amazon_plan(data,size_plan.context(request('amazon')));self.assertTrue(value['verified']);self.assertEqual(value['installedBytes'],50);self.assertIsNone(value['downloadBytes'])
    def test_nile_missing_signature_conflicting_files_and_escape_fail_closed(self):
        c=size_plan.context(request('amazon'))
        for files in [[{'path':'../a','size':2,'hash':'x'}],[{'path':'a','size':2,'hash':'x'},{'path':'a','size':3,'hash':'y'}]]:
            self.assertIsNone(size_plan.amazon_plan({'gameID':'fixture-game','signatureVerified':True,'packageCount':1,'files':files},c)['installedBytes'])
        self.assertIsNone(size_plan.amazon_plan({'gameID':'fixture-game','packageCount':1,'files':[]},c)['installedBytes'])
    def test_platform_language_gameid_and_dlc_are_not_shell_arguments(self):
        for key,value in [('gameID','https://private.invalid/manifest'),('gameID','../game'),('platform','linux'),('language','en;whoami'),('includeDLC',True)]:
            r=request();r['options'][key]=value
            with self.assertRaises(bridge.BridgeError):size_plan.context(r)
    def test_amazon_mac_never_starts_a_helper(self):
        with patch('subprocess.Popen',side_effect=AssertionError('Unexpected helper')):
            self.assertEqual(size_plan.execute(request('amazon','macOS'))['plan']['status'],'unsupported')

class SizeTransportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='size-plan-',dir=WORK);self.root=pathlib.Path(self.temp.name);self.root.chmod(0o700)
        self.environment=patch.dict(os.environ,{'READY_DATA_ROOT':str(self.root)});self.environment.start()
    def tearDown(self):self.environment.stop();self.temp.cleanup()
    def worker(self,body):
        p=self.root/'fake.py';p.write_text(body);return p
    def execute(self,body,**kw):return size_plan.execute(request(),python=sys.executable,worker=self.worker(body),**kw)
    def test_private_stdin_only_and_cleanup_without_game_directory_access(self):
        body='''import json,sys,os,pathlib
r=json.loads(sys.stdin.readline());secret=r['credentials']['access_token'];assert secret not in str(sys.argv) and secret not in str(dict(os.environ));assert 'installDir'not in r
p=pathlib.Path('credential.json');fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,secret.encode());os.close(fd);assert p.stat().st_mode&0o777==0o600;assert pathlib.Path.cwd().stat().st_mode&0o777==0o700
print(json.dumps({'game':{'app_name':r['context']['gameID']},'manifest':{'disk_size':100,'download_size':50}}))
'''
        value=self.execute(body);self.assertEqual(value['plan']['installedBytes'],100)
        self.assertNotIn('private-fixture-token',json.dumps(value));self.assertEqual(list((self.root/'SizePlans').iterdir()),[])
    def test_timeout_stops_only_own_worker_and_removes_secrets_root(self):
        with self.assertRaises(bridge.BridgeError)as error:self.execute('import time;time.sleep(5)',timeout=.1)
        self.assertEqual(error.exception.code,'size_plan_timeout');self.assertEqual(list((self.root/'SizePlans').iterdir()),[])
    def test_malformed_output_and_oversized_output_never_escape_to_caller(self):
        for body in ["print('private-fixture-token')","print('x'*(4*1024*1024+1))"]:
            with self.assertRaises(bridge.BridgeError)as error:self.execute(body)
            self.assertNotIn('private-fixture-token',str(error.exception))
    def test_helper_error_is_sanitized_to_known_reason(self):
        value=self.execute("print('{\"error\":\"private-fixture-token\"}')")
        self.assertEqual(value['plan']['reason'],'manifest_unavailable');self.assertNotIn('private-fixture-token',json.dumps(value))
    def test_refresh_rotation_survives_later_manifest_failure_only_on_private_credential_channel(self):
        value=self.execute("print('{\"sdkMetadata\":{\"error\":\"manifest_unavailable\"},\"credentials\":{\"access_token\":\"own-rotated-token\"}}')")
        self.assertEqual(value['credentials']['access_token'],'own-rotated-token');self.assertNotIn('own-rotated-token',json.dumps(value['plan']))
    def test_worker_reads_only_owner_private_sdk_token_record(self):
        import size_plan_worker
        config=self.root/'legendary';config.mkdir(mode=0o700);source=config/'user.json'
        source.write_text(json.dumps({'access_token':'own-rotated-token','refresh_token':'own-rotated-refresh','untrusted_detail':'not-returned'}));source.chmod(0o600)
        value=size_plan_worker.refreshed_credentials({'store':'epic'},{'access_token':'own-prior-token'},self.root)
        self.assertEqual(value['access_token'],'own-rotated-token');self.assertNotIn('untrusted_detail',value)
        source.chmod(0o644);self.assertIsNone(size_plan_worker.refreshed_credentials({'store':'epic'},{},self.root))
    def test_bridge_dispatch_refresh_and_plan_routing(self):
        r=request();r['credentials']['expires_at_epoch']=0
        class HTTP:
            def json(self,*args,**kw):return {'access_token':'fresh','refresh_token':'r','expires_in':3600}
        r['credentials']['refresh_token']='r'
        with patch('backend.install_size_plan',return_value={'plan':{'status':'unknown'}})as target:
            result=bridge.dispatch(r,http=HTTP());self.assertEqual(result['plan']['status'],'unknown');self.assertEqual(target.call_args.args[0]['credentials']['access_token'],'fresh')

if __name__=='__main__':unittest.main()
