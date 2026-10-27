# SPDX-License-Identifier: GPL-3.0-only
import json,pathlib,plistlib,random,struct,subprocess,sys,tempfile,unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'StoreBridge'))
from bridge import BridgeError
import launch_resolver as resolver

def pe(path,machine=0x8664):
    path.parent.mkdir(parents=True,exist_ok=True)
    header=bytearray(0x86);header[:2]=b'MZ';struct.pack_into('<I',header,0x3c,0x80);header[0x80:0x84]=b'PE\0\0';struct.pack_into('<H',header,0x84,machine);path.write_bytes(header)
    return path

def macho(path,cpu=0x0100000c,platform=1):
    path.parent.mkdir(parents=True,exist_ok=True)
    cmd=struct.pack('<IIIIII',0x32,24,platform,0,0,0)
    path.write_bytes(struct.pack('<IIIIIIII',0xfeedfacf,cpu,0,2,1,len(cmd),0,0)+cmd);path.chmod(0o755)
    return path

def app(root,name='Native',cpu=0x0100000c):
    bundle=root/(name+'.app');binary=macho(bundle/'Contents/MacOS'/name,cpu)
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':name}))
    return bundle,binary

def request(store,platform='windows',metadata=None,identity='123'):
    return {'store':store,'options':{'gameID':identity,'platform':platform,'metadata':metadata or {}}}

class ArgumentTests(unittest.TestCase):
    def test_windows_quotes_preserve_backslashes_empty_arguments_and_shell_text(self):
        line=r'-path "C:\Program Files\assets" "" a\b "a\"b" & $(whoami)'
        self.assertEqual(resolver.windows_arguments(line),['-path',r'C:\Program Files\assets','',r'a\b','a"b','&','$(whoami)'])
    def test_windows_round_trip_against_independent_stdlib_quoting(self):
        randomizer=random.Random(42);alphabet='abcXYZ  \t\\"&$()日本語'
        for _ in range(200):
            args=[''.join(randomizer.choice(alphabet) for _ in range(randomizer.randrange(0,45))) for _ in range(randomizer.randrange(0,9))]
            self.assertEqual(resolver.windows_arguments(subprocess.list2cmdline(args)),args)
    def test_literal_array_is_never_reparsed_or_expanded(self):
        values=['--name','a b','$(touch /tmp/should-not-exist)','&','C:\\literal']
        self.assertEqual(resolver.arguments(values,'windows'),values)
        with self.assertRaises(BridgeError):resolver.arguments(['safe',{'command':'bad'}],'windows')

class RealStoreMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name).resolve();self.install=self.root/'install';self.install.mkdir();self.config=self.root/'config';self.config.mkdir();self.secret=self.root/'secret';self.secret.mkdir()
    def tearDown(self):self.temp.cleanup()
    def resolve(self,r):return resolver.resolve_installed_launch(r,self.config,self.secret,self.install)
    def test_steam_uses_windows_default_pics_entry_and_working_directory(self):
        target=pe(self.install/'Binaries/Game.exe');(self.install/'Data').mkdir()
        r=request('steam',metadata={'launch':[
            {'executable':'LinuxGame','oslist':'linux','type':'default'},
            {'executable':'Binaries\\Game.exe','oslist':'windows','type':'default','arguments':r'-path "C:\Game Assets" -fullscreen','workingdir':'Data','description':'Play'},
            {'executable':'MissingTool.exe','oslist':'windows','type':'option1','description':'Tools'}]})
        result=self.resolve(r);selected=result['installedVariant'];self.assertEqual(selected['executable'],str(target));self.assertEqual(selected['architecture'],'x86_64');self.assertEqual(selected['arguments'],['-path',r'C:\Game Assets','-fullscreen']);self.assertEqual(result['workingDirectory'],str(self.install/'Data'));self.assertFalse(result['launchSelectionRequired'])
    def test_epic_uses_legendary_installed_record_not_an_arbitrary_exe(self):
        pe(self.install/'Unrelated.exe');target=pe(self.install/'Main/Actual.exe');cache=self.secret/'legendary-config';cache.mkdir()
        (cache/'installed.json').write_text(json.dumps({'123':{'title':'Actual Game','install_path':str(self.install),'executable':'Main/Actual.exe','launch_parameters':'-language "en US"'}}))
        selected=self.resolve(request('epic'))['installedVariant'];self.assertEqual(selected['executable'],str(target));self.assertEqual(selected['arguments'],['-language','en US']);self.assertEqual(selected['workingDirectory'],str(target.parent))
    def test_gog_uses_primary_file_task_and_literal_argument_array(self):
        target=pe(self.install/'bin/Game.exe',0x14c);pe(self.install/'Launcher.exe');(self.install/'Data').mkdir()
        (self.install/'goggame-123.info').write_text(json.dumps({'playTasks':[
            {'type':'FileTask','path':'Launcher.exe','name':'Settings'},
            {'type':'FileTask','path':'bin\\Game.exe','isPrimary':True,'workingDir':'Data','arguments':['--safe','a b'],'name':'Play Game'}]}))
        selected=self.resolve(request('gog'))['installedVariant'];self.assertEqual(selected['executable'],str(target));self.assertEqual(selected['architecture'],'x86');self.assertEqual(selected['arguments'],['--safe','a b']);self.assertEqual(selected['workingDirectory'],str(self.install/'Data'))
    def test_amazon_uses_fuel_main_command_arguments_and_working_override(self):
        target=pe(self.install/'Game/Main.exe');(self.install/'Game/Data').mkdir()
        (self.install/'fuel.json').write_text(json.dumps({'SchemaVersion':'2','Main':{'Command':'Game\\Main.exe','Args':['--mode','a b'],'WorkingSubdirOverride':'Game\\Data'}}))
        selected=self.resolve(request('amazon'))['installedVariant'];self.assertEqual(selected['executable'],str(target));self.assertEqual(selected['arguments'],['--mode','a b']);self.assertEqual(selected['workingDirectory'],str(self.install/'Game/Data'))
    @unittest.skipUnless((ROOT/'Runtime/Tools/StoreBridge/venv/bin/python').exists(),'Open JSON5 helper environment not built')
    def test_amazon_json5_comments_and_literal_arrays(self):
        target=pe(self.install/'Game.exe')
        (self.install/'fuel.json').write_text("// upstream fuel uses JSON5\n{SchemaVersion:'2', Main:{Command:'Game.exe', Args:['--literal', 'a b',],},}")
        selected=self.resolve(request('amazon'))['installedVariant'];self.assertEqual(selected['executable'],str(target));self.assertEqual(selected['arguments'],['--literal','a b'])
    def test_steam_native_app_requires_actual_macho_arm64(self):
        bundle,target=app(self.install)
        selected=self.resolve(request('steam','macOS',{'launch':[{'executable':bundle.name,'oslist':'macos','type':'default'}]}))['installedVariant']
        self.assertEqual(selected['architecture'],'arm64');self.assertEqual(selected['executable'],str(target))
    def test_mac_store_flag_does_not_turn_intel_binary_into_arm64(self):
        bundle,target=app(self.install,'Intel',0x01000007)
        selected=self.resolve(request('steam','macOS',{'launch':[{'executable':bundle.name,'oslist':'macos'}]}))['installedVariant'];self.assertEqual(selected['architecture'],'x86_64')
    def test_gog_macos_app_manifest_is_relative_to_bundle(self):
        bundle,target=app(self.install);resources=bundle/'Contents/Resources';resources.mkdir()
        (resources/'goggame-123.info').write_text(json.dumps({'playTasks':[{'type':'FileTask','path':'Contents/MacOS/Native','isPrimary':True,'workingDir':'Contents/Resources'}]}))
        selected=self.resolve(request('gog','macOS'))['installedVariant'];self.assertEqual(selected['executable'],str(target));self.assertEqual(selected['workingDirectory'],str(resources))
    def test_two_valid_launch_entries_remain_an_explicit_choice(self):
        pe(self.install/'First.exe');pe(self.install/'Second.exe')
        result=self.resolve(request('steam',metadata={'launch':[{'executable':'First.exe'},{'executable':'Second.exe'}]}))
        self.assertIsNone(result['installedVariant']);self.assertEqual(len(result['launchCandidates']),2);self.assertTrue(result['launchSelectionRequired'])
    def test_missing_primary_does_not_auto_launch_settings_tool(self):
        pe(self.install/'Settings.exe');(self.install/'goggame-123.info').write_text(json.dumps({'playTasks':[{'path':'MissingGame.exe','isPrimary':True},{'path':'Settings.exe'}]}))
        result=self.resolve(request('gog'));self.assertIsNone(result['installedVariant']);self.assertEqual(len(result['launchCandidates']),1)
    def test_missing_metadata_never_falls_back_to_scanning_exes(self):
        pe(self.install/'ObviousGame.exe');result=self.resolve(request('steam'));self.assertIsNone(result['installedVariant']);self.assertEqual(result['launchCandidates'],[])
    def test_traversal_and_absolute_metadata_paths_are_rejected(self):
        for path in ['../Outside.exe','C:\\Outside.exe','/tmp/Outside.exe','\\\\server\\share\\game.exe']:
            result=self.resolve(request('steam',metadata={'launch':[{'executable':path}]}));self.assertIsNone(result['installedVariant']);self.assertEqual(result['launchIssues'][0]['code'],'unsafe_launch_path')
    def test_symlink_executable_escape_is_rejected_before_binary_read(self):
        outside=pe(self.root/'Outside.exe');(self.install/'Escape.exe').symlink_to(outside)
        result=self.resolve(request('steam',metadata={'launch':[{'executable':'Escape.exe'}]}));self.assertIsNone(result['installedVariant']);self.assertEqual(result['launchIssues'][0]['code'],'unsafe_launch_path')
    def test_native_bundle_executable_symlink_escape_is_rejected_before_inspection(self):
        outside=macho(self.root/'Outside');bundle,target=app(self.install);target.unlink();target.symlink_to(outside)
        with patch.object(resolver,'inspect_native',side_effect=AssertionError('must not inspect outside')):
            result=self.resolve(request('steam','macOS',{'launch':[{'executable':bundle.name}]}))
        self.assertIsNone(result['installedVariant']);self.assertEqual(result['launchIssues'][0]['code'],'unsafe_launch_path')
    def test_working_directory_escape_is_rejected(self):
        pe(self.install/'Game.exe');result=self.resolve(request('steam',metadata={'launch':[{'executable':'Game.exe','workingdir':'..'}]}));self.assertIsNone(result['installedVariant']);self.assertEqual(result['launchIssues'][0]['code'],'unsafe_launch_path')
    def test_mz_filename_without_a_pe_header_is_rejected(self):
        (self.install/'Wrong.exe').write_bytes(b'MZnot-an-executable');result=self.resolve(request('steam',metadata={'launch':[{'executable':'Wrong.exe'}]}));self.assertIsNone(result['installedVariant']);self.assertEqual(result['launchIssues'][0]['code'],'invalid_launch_binary')
    def test_ios_macho_is_not_a_native_macos_launch(self):
        macho(self.install/'Wrong',platform=2);result=self.resolve(request('steam','macOS',{'launch':[{'executable':'Wrong'}]}));self.assertIsNone(result['installedVariant']);self.assertEqual(result['launchIssues'][0]['code'],'unsupported_platform')
    def test_epic_metadata_cannot_point_to_another_installation(self):
        cache=self.secret/'legendary-config';cache.mkdir();(cache/'installed.json').write_text(json.dumps({'123':{'install_path':str(self.root),'executable':'Outside.exe'}}))
        result=self.resolve(request('epic'));self.assertIsNone(result['installedVariant']);self.assertEqual(result['launchIssues'][0]['code'],'unsafe_launch_path')

if __name__=='__main__':unittest.main()
