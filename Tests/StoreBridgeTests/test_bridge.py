# SPDX-License-Identifier: GPL-3.0-only
import contextlib, hashlib, importlib.util, io, json, pathlib, plistlib, struct, subprocess, sys, tempfile, time, unittest, urllib.parse, zlib
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'StoreBridge'))
import bridge
import backend

PROFILE='00000000-0000-4000-8000-000000000001'
OTHER='00000000-0000-4000-8000-000000000002'

class FakeHTTP:
    def __init__(self,responses):self.responses=list(responses);self.requests=[]
    def json(self,url,method='GET',headers=None,data=None,form=None):
        self.requests.append(dict(url=url,method=method,headers=headers or {},data=data,form=form))
        if not self.responses:raise AssertionError('Unexpected HTTP call')
        response=self.responses.pop(0)
        if isinstance(response,Exception):raise response
        return response

class ProtocolTests(unittest.TestCase):
    def test_request_rejects_traversal_profile(self):
        with self.assertRaises(bridge.BridgeError):bridge.dispatch(dict(operation='library',store='gog',profileID='../../victim'))
    def test_cli_error_does_not_echo_request_secrets(self):
        secret='private-refresh-token-that-must-not-be-logged'
        r=subprocess.run([sys.executable,str(ROOT/'StoreBridge/bridge.py')],input=json.dumps(dict(operation='unknown',store='gog',profileID=PROFILE,credentials={'refresh_token':secret}))+'\n',text=True,capture_output=True)
        self.assertEqual(r.returncode,1);self.assertNotIn(secret,r.stdout+r.stderr)
        self.assertEqual(json.loads(r.stdout)['type'],'error')
    def test_capabilities_is_usable_without_any_sdk(self):
        result=bridge.dispatch({'operation':'capabilities'});self.assertEqual(result['stores'],['steam','epic','gog','amazon'])
    def test_auth_state_is_profile_bound_and_expires(self):
        a=bridge.StoreAdapter(FakeHTTP([]),'gog');state=a.auth_begin(PROFILE)['authState']
        for profile,age in [(OTHER,0),(PROFILE,901)]:
            copy={**state,'created':time.time()-age}
            with self.assertRaises(bridge.BridgeError):a.auth_complete(profile,{'authState':copy,'code':'one-time-code'})
    def test_gog_redirect_must_match_csrf_state(self):
        a=bridge.StoreAdapter(FakeHTTP([]),'gog');state=a.auth_begin(PROFILE)['authState']
        with self.assertRaises(bridge.BridgeError):a.auth_complete(PROFILE,{'authState':state,'redirectURL':'https://embed.gog.com/on_login_success?code=test&state=wrong'})
    def test_amazon_pkce_verifier_is_not_in_auth_url(self):
        a=bridge.StoreAdapter(FakeHTTP([]),'amazon');flow=a.auth_begin(PROFILE);s=flow['authState'];query=urllib.parse.parse_qs(urllib.parse.urlparse(flow['url']).query)
        expected=bridge.base64.urlsafe_b64encode(hashlib.sha256(s['code_verifier'].encode()).digest()).decode().rstrip('=')
        self.assertEqual(query['openid.oa2.code_challenge'],[expected]);self.assertNotIn(s['code_verifier'],flow['url'])
        self.assertEqual(bytes.fromhex(s['client_id']).decode(),s['device_serial']+'#A2UMVHOX7UP4V7')
    def test_amazon_auth_uses_returned_tokens_and_device_identity(self):
        http=FakeHTTP([{'response':{'success':{'tokens':{'bearer':{'access_token':'a','refresh_token':'r','expires_in':3600}}}}}]);a=bridge.StoreAdapter(http,'amazon');state=a.auth_begin(PROFILE)['authState'];c=a.auth_complete(PROFILE,{'authState':state,'code':'c'})
        self.assertEqual(c['device_serial'],state['device_serial']);self.assertGreater(c['expires_at_epoch'],time.time())
        self.assertEqual(http.requests[0]['data']['auth_data']['code_verifier'],state['code_verifier'])
    def test_expired_credentials_are_refreshed_before_gog_library(self):
        h=FakeHTTP([{'access_token':'fresh','expires_in':3600},{'owned':[]}]);r=bridge.dispatch(dict(operation='library',store='gog',profileID=PROFILE,credentials={'refresh_token':'r','expires_at_epoch':0}),h)
        self.assertEqual(r['games'],[]);self.assertEqual(r['credentials']['access_token'],'fresh');self.assertEqual(h.requests[1]['headers']['Authorization'],'Bearer fresh')

class LibraryTests(unittest.TestCase):
    def test_gog_macos_is_not_mislabelled_as_arm64(self):
        h=FakeHTTP([{'owned':[1,1]},{'id':1,'title':'Mac port','images':{'logo':'//cdn.gog.com/a.jpg'},'downloads':{'installers':[{'os':'osx'},{'os':'windows'}]}}]);g=bridge.StoreAdapter(h,'gog').library({'access_token':'a'})
        self.assertEqual(len(g),1);self.assertEqual({v['platform'] for v in g[0]['variants']},{'windows','macOS'})
        self.assertTrue(all(v['architecture']=='unknown' for v in g[0]['variants']));self.assertEqual(g[0]['artworkURL'],'https://cdn.gog.com/a.jpg')
    def test_amazon_paginates_and_deduplicates_owned_entitlements(self):
        def ent(e,t):return {'id':e,'product':{'id':'game','title':t,'productDetail':{'iconUrl':'https://images.example/a.png'}}}
        h=FakeHTTP([{'entitlements':[ent('e1','A')],'nextToken':'next'},{'entitlements':[ent('e2','B')]}]);g=bridge.StoreAdapter(h,'amazon').library({'access_token':'a','device_serial':'serial'})
        self.assertEqual(len(g),1);self.assertEqual(g[0]['title'],'B');self.assertEqual(g[0]['metadata']['entitlementId'],'e2');self.assertEqual(h.requests[1]['data']['nextToken'],'next')
        self.assertEqual(h.requests[0]['data']['hardwareHash'],hashlib.sha256(b'serial').hexdigest().upper())
    def test_amazon_detects_repeated_page_without_returning_partial_library(self):
        h=FakeHTTP([{'entitlements':[],'nextToken':'repeat'},{'entitlements':[],'nextToken':'repeat'}])
        with self.assertRaisesRegex(bridge.BridgeError,'repeated'):bridge.StoreAdapter(h,'amazon').library({'access_token':'a','device_serial':'s'})
    def test_epic_unifies_windows_and_mac_builds_without_assuming_architecture(self):
        h=FakeHTTP([{'records':[{'appName':'app','namespace':'ns','catalogItemId':'cid'}]},[{'appName':'app','namespace':'ns','catalogItemId':'cid'}],[{'appName':'app','namespace':'ns','catalogItemId':'cid'}],{'cid':{'title':'Test title','keyImages':[]}}])
        g=bridge.StoreAdapter(h,'epic').library({'access_token':'a'});self.assertEqual(g[0]['title'],'Test title');self.assertEqual(len(g[0]['variants']),2);self.assertEqual({v['architecture'] for v in g[0]['variants']},{'unknown'})
    def test_library_network_failure_is_not_reported_as_empty_success(self):
        h=FakeHTTP([bridge.BridgeError('authentication_required','expired')])
        with self.assertRaises(bridge.BridgeError):bridge.StoreAdapter(h,'gog').library({'access_token':'expired'})

class ArchitectureTests(unittest.TestCase):
    def test_actual_macho_header_controls_native_label(self):
        with tempfile.TemporaryDirectory() as d:
            path=pathlib.Path(d)/'test';path.write_bytes(struct.pack('<IIIIIIII',0xfeedfacf,0x0100000c,0,2,0,0,0,0));r=bridge.inspect_native(str(path));self.assertTrue(r['appleSiliconNative']);self.assertEqual(r['architecture'],'arm64')
            path.write_bytes(struct.pack('<IIIIIIII',0xfeedfacf,0x01000007,3,2,0,0,0,0));r=bridge.inspect_native(str(path));self.assertFalse(r['appleSiliconNative']);self.assertEqual(r['architecture'],'x86_64')
    def test_ios_bundle_is_not_a_macos_game(self):
        with tempfile.TemporaryDirectory() as d:
            path=pathlib.Path(d)/'wrong.app';(path/'Contents').mkdir(parents=True);(path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Game','LSRequiresIPhoneOS':True}))
            with self.assertRaises(bridge.BridgeError):bridge.inspect_native(str(path))
    def test_universal_header_bounds_are_checked(self):
        with tempfile.NamedTemporaryFile() as f:
            f.write(struct.pack('>II',0xcafebabe,64));f.flush()
            with self.assertRaises(bridge.BridgeError):bridge.inspect_native(f.name)

class DownloadTests(unittest.TestCase):
    def test_download_result_exposes_validated_metadata_variant(self):
        with tempfile.TemporaryDirectory() as directory:
            d=pathlib.Path(directory).resolve();config=d/'profile';config.mkdir();tool=d/'venv/bin/python';tool.parent.mkdir(parents=True)
            script='''import json,os,pathlib,struct,sys
args=sys.argv[1:];root=pathlib.Path(args[args.index('--base-path')+1])/args[args.index('--game-folder')+1];root.mkdir(exist_ok=True)
head=bytearray(0x86);head[:2]=b'MZ';struct.pack_into('<I',head,0x3c,0x80);head[0x80:0x84]=b'PE\\0\\0';struct.pack_into('<H',head,0x84,0x8664);(root/'Actual.exe').write_bytes(head)
cfg=pathlib.Path(os.environ['LEGENDARY_CONFIG_PATH']);auth=json.loads((cfg/'user.json').read_text());assert auth['access_token']=='private-token';assert (cfg/'user.json').stat().st_mode&0o777==0o600
(cfg/'installed.json').write_text(json.dumps({'app':{'install_path':str(root),'executable':'Actual.exe','launch_parameters':'--title "a b"','needs_verification':False}}))
print('sensitive unfiltered source log: private-token');print('100%')
'''
            tool.write_text('#!'+sys.executable+'\n'+script);tool.chmod(0o700)
            r={'operation':'download','store':'epic','profileID':PROFILE,'credentials':{'access_token':'private-token'},'options':{'gameID':'app','platform':'windows','installDir':str(d/'Game')}}
            out=io.StringIO()
            with patch.object(backend,'TOOLS',d),patch.object(backend,'profile_config',return_value=config),contextlib.redirect_stdout(out):result=backend.download(r)
            self.assertEqual(result['installedVariant']['executable'],str(d/'Game/Actual.exe'));self.assertEqual(result['installedVariant']['arguments'],['--title','a b']);self.assertFalse(result['launchSelectionRequired']);self.assertFalse(result['executionVerified']);self.assertNotIn('private-token',out.getvalue());self.assertFalse(list(config.rglob('user.json')))
    def test_steam_completion_rejects_incomplete_manifest_marker(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);(p/'.DepotDownloader').mkdir()
            # Protobuf dictionary: field 1 entry {field1 depotID=1, field2 manifestID=42}.
            raw=b'\x0a\x04\x08\x01\x10\x2a';compress=zlib.compressobj(wbits=-15);(p/'.DepotDownloader/depot.config').write_bytes(compress.compress(raw)+compress.flush())
            self.assertEqual(backend.steam_manifest_ids(p),[42])
            request={'store':'steam','options':{'gameID':'480'}}
            self.assertTrue(backend.completion_proof(request,p,p,p))
            raw=b'\x0a\x0d\x08\x01\x10'+b'\xff'*9+b'\x01';compress=zlib.compressobj(wbits=-15);(p/'.DepotDownloader/depot.config').write_bytes(compress.compress(raw)+compress.flush())
            self.assertFalse(backend.completion_proof(request,p,p,p))
    def test_epic_exit_zero_with_partial_files_is_not_complete(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);(p/'legendary-config').mkdir();game=p/'game';game.mkdir();(game/'partial.exe').write_bytes(b'partial')
            request={'store':'epic','options':{'gameID':'app'}}
            self.assertFalse(backend.completion_proof(request,p,p,game))
            (p/'legendary-config/installed.json').write_text(json.dumps({'app':{'install_path':str(game),'needs_verification':True}}))
            self.assertFalse(backend.completion_proof(request,p,p,game))
    def test_download_tokens_are_private_and_removed_after_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            d=pathlib.Path(directory);config=d/'profile';config.mkdir();tool=d/'venv/bin/python';tool.parent.mkdir(parents=True)
            tool.write_text('#!'+sys.executable+'\nimport sys\nprint("secret-bearer-token-and-url?access_token=hidden")\nsys.exit(2)\n');tool.chmod(0o700)
            request={'operation':'download','store':'epic','profileID':PROFILE,'credentials':{'access_token':'secret-bearer-token','refresh_token':'secret-refresh-token'},'options':{'gameID':'app','platform':'windows','installDir':str(d/'game')}}
            output=io.StringIO()
            with patch.object(backend,'TOOLS',d),patch.object(backend,'profile_config',return_value=config),contextlib.redirect_stdout(output):
                with self.assertRaises(bridge.BridgeError):backend.download(request)
            self.assertFalse((config/'user.json').exists());self.assertNotIn('secret',output.getvalue());self.assertIn('"phase":"download"',output.getvalue())
    def test_engine_success_is_not_claimed_when_it_installed_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            d=pathlib.Path(directory);config=d/'profile';config.mkdir();tool=d/'venv/bin/python';tool.parent.mkdir(parents=True)
            tool.write_text('#!'+sys.executable+'\nprint("100%")\n');tool.chmod(0o700)
            request={'operation':'download','store':'epic','profileID':PROFILE,'credentials':{'access_token':'a'},'options':{'gameID':'app','installDir':str(d/'game')}}
            with patch.object(backend,'TOOLS',d),patch.object(backend,'profile_config',return_value=config),contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(bridge.BridgeError) as error:backend.download(request)
            self.assertEqual(error.exception.code,'download_incomplete')
    def test_macos_amazon_download_is_explicitly_unsupported(self):
        with tempfile.TemporaryDirectory() as d:
            path=pathlib.Path(d);(path/'venv/bin').mkdir(parents=True);(path/'venv/bin/python').touch()
            request={'store':'amazon','credentials':{},'options':{'gameID':'game','platform':'macOS','installDir':str(path/'game')}}
            with patch.object(backend,'TOOLS',path):
                with self.assertRaises(bridge.BridgeError) as error:backend.prepare_download(request,path,path)
            self.assertEqual(error.exception.code,'unsupported_platform')
    def test_no_store_token_is_a_downloader_argument(self):
        with tempfile.TemporaryDirectory() as d:
            path=pathlib.Path(d);(path/'venv/bin').mkdir(parents=True);(path/'venv/bin/python').touch()
            request={'store':'gog','credentials':{'access_token':'sensitive-access-token','refresh_token':'sensitive-refresh-token'},'options':{'gameID':'game','installDir':str(path/'game')}}
            with patch.object(backend,'TOOLS',path):args,env,stdin,target=backend.prepare_download(request,path,path)
            self.assertNotIn('sensitive',' '.join(args));self.assertIsNone(stdin)
            self.assertEqual((path/'gog-auth.json').stat().st_mode & 0o777,0o600)

if __name__=='__main__':unittest.main()
