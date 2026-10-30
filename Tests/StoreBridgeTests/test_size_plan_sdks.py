# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the installed open SDK parsers with in-memory metadata, offline."""
import json,os,pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
PYTHON=ROOT/'Runtime/Tools/StoreBridge/venv/bin/python'
PROBE=r'''
import json,struct,sys,pathlib,os,tempfile,contextlib,io
sys.path.insert(0,sys.argv[1])
from gogdl.languages import Language
from gogdl.dl.objects import v1,v2
from nile.models.manifest import Manifest
from nile.proto import sds_proto2_pb2 as sds
checks={}
lang=Language.parse('en')
base={'productId':'123','manifest':'shared','languages':['*','en-US'],'size':100,'compressedSize':60}
meta={'baseProductId':'123','installDirectory':'fixture','depots':[base,dict(base,manifest='french',languages=['fr-FR'],size=900),dict(base,productId='456',manifest='dlc',size=800)]}
manifest=v2.Manifest(meta,lang,[],None,False)
checks['gog-v2-base-language-wildcard-selected-once']=len(manifest.depots)==1 and sum(x.size for x in manifest.depots)==100
checks['gog-v2-info-language-buckets-overlap-so-not-summed']=manifest.calculate_download_size()['123']['*']['disk_size']==100 and manifest.calculate_download_size()['123']['en-US']['disk_size']==100
meta1={'product':{'rootGameID':'123','depots':[{'gameIDs':['123'],'manifest':'base','languages':['Neutral'],'size':'20'},{'gameIDs':['456'],'manifest':'dlc','languages':['Neutral'],'size':'90'}]}}
old=v1.Manifest('windows',meta1,lang,[],None,False)
checks['gog-v1-base-neutral-size-normalized']=len(old.depots)==1 and old.depots[0].size==20
header=sds.ManifestHeader();header.compression.algorithm=sds.none;header.signature.algorithm=sds.sha256_with_rsa;header.signature.value=b'not-a-genuine-signature'
h=header.SerializeToString();payload=struct.pack('>I',len(h))+h+sds.Manifest().SerializeToString()
try:Manifest().parse(payload);checks['nile-refuses-unsigned-or-invalid-signed-manifest']=False
except ValueError:checks['nile-refuses-unsigned-or-invalid-signed-manifest']=True
from size_plan_worker import epic,gog
from legendary.cli import LegendaryCLI
old_info=LegendaryCLI.info
LegendaryCLI.info=lambda self,args:print(json.dumps({'game':{'app_name':args.app_name_or_manifest},'manifest':{'disk_size':9,'download_size':6}}))
with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])as private:
 os.chmod(private,0o700)
 result=epic({'gameID':'fixture-game','platform':'windows'},{'access_token':'own-fake-token'},pathlib.Path(private))
 checks['epic-actual-sdk-constructor-and-exit-use-private-directory-and-INI']=result['manifest']['disk_size']==9 and (pathlib.Path(private)/'legendary/config.ini').is_file() and (pathlib.Path(private)/'legendary/user.json').stat().st_mode&0o777==0o600
LegendaryCLI.info=old_info
from gogdl.dl.managers.manager import Manager
from gogdl.dl.managers import v2 as manager2
Manager.get_builds=lambda self,platform:{'items':[{'branch':None,'generation':2,'build_id':'fixture','version_name':'fixture'}]}
def get_meta(self):self.meta=dict(meta)
manager2.Manager.get_meta=get_meta
with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])as private:
 os.chmod(private,0o700)
 result=gog({'gameID':'123','platform':'windows','language':'en'},{'access_token':'own-fake-token','expires_in':3600},pathlib.Path(private))
 checks['gog-actual-worker-manager-selects-base-and-language-depots-once']=result['selected']=={'disk_size':100,'download_size':60} and result['language']=='en-US'
print(json.dumps(checks))
'''
class InstalledSizeSDKTests(unittest.TestCase):
    def test_actual_sdk_schema_selection_and_signature_guards(self):
        if not PYTHON.is_file():self.skipTest('Installed optional open store SDKs are unavailable')
        root=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79/tests')
        with tempfile.TemporaryDirectory(prefix='size-sdk-',dir=root)as temporary:
            env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','PYTHONPATH','PYTHONHOME'))};env.update(PYTHONDONTWRITEBYTECODE='1',TMPDIR=temporary+'/',GOGDL_CONFIG_PATH=temporary+'/gog-import',LEGENDARY_CONFIG_PATH=temporary+'/legendary-import',XDG_CONFIG_HOME=temporary)
            p=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(PYTHON),'-c',PROBE,str(ROOT/'StoreBridge')],env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(p.returncode,0,'Installed SDK in-memory parser test failed')
            checks=json.loads(p.stdout);self.assertEqual(len(checks),6);self.assertTrue(all(checks.values()))
if __name__=='__main__':unittest.main()
