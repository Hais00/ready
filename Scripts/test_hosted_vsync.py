#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual CONFIGURE handler + actual guest cache/Mach, controlled caller/device.
No NSWindow, drawable, GPU commands, normal Steam, account or game execution."""
import hashlib,json,os,pathlib,re,subprocess,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
HOST_MAIN=r'''
#define require(v) do{if(!(v)){fprintf(stderr,"host-config-fixture-line:%d\n",__LINE__);_exit(81);}checks++;}while(0)
int main(void){@autoreleasepool{unsigned checks=0;
 RHGHost *host=[RHGHost new];host.metal=[CAMetalLayer layer];host.device=(id<MTLDevice>)[FixtureRegistryDevice new];
 RHGRequest request={0};request.width=640;request.height=360;request.pixelFormat=MTLPixelFormatBGRA8Unorm;request.deviceRegistryID=42;
 RHGReply reply={0};request.displaySyncEnabled=0;RHGConfigureLayer(host,&request,&reply);
 require(reply.status==RHG_OK&&!host.metal.displaySyncEnabled&&reply.displaySyncEnabled==0&&host.configured);
 require(reply.width==640&&reply.height==360&&reply.pixelFormat==MTLPixelFormatBGRA8Unorm&&reply.deviceRegistryID==42);
 reply.displaySyncEnabled=UINT32_MAX;RHGConfigureLayer(host,&request,&reply);require(reply.displaySyncEnabled==0&&host.changes==1);
 request.displaySyncEnabled=1;RHGConfigureLayer(host,&request,&reply);require(reply.status==RHG_OK&&host.metal.displaySyncEnabled&&reply.displaySyncEnabled==1&&host.changes==2);
 reply.displaySyncEnabled=UINT32_MAX;RHGConfigureLayer(host,&request,&reply);require(reply.displaySyncEnabled==1&&host.changes==2);
 request.displaySyncEnabled=0;RHGConfigureLayer(host,&request,&reply);require(!host.metal.displaySyncEnabled&&reply.displaySyncEnabled==0&&host.changes==3);
 request.displaySyncEnabled=2;reply.status=0;RHGConfigureLayer(host,&request,&reply);require(reply.status==RHG_UNSUPPORTED&&!host.metal.displaySyncEnabled&&host.changes==3);
 request.displaySyncEnabled=1;reply.status=0;host.drawable=[NSObject new];RHGConfigureLayer(host,&request,&reply);require(reply.status==RHG_BUSY&&!host.metal.displaySyncEnabled&&host.changes==3);host.drawable=nil;
 request.deviceRegistryID=43;reply.status=0;RHGConfigureLayer(host,&request,&reply);require(reply.status==RHG_UNSUPPORTED&&!host.metal.displaySyncEnabled);
 request.deviceRegistryID=42;request.width=0;reply.status=0;RHGConfigureLayer(host,&request,&reply);require(reply.status==RHG_UNSUPPORTED&&!host.metal.displaySyncEnabled);
 require(RHG_VERSION==4);
 printf("{\"passed\":true,\"checks\":%u,\"actualCAMetalLayerProperties\":true,\"GPUCommands\":0,\"windows\":0}\n",checks);return 0;}}
'''
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def extract_function(text,signature):
 start=text.index(signature);brace=text.index('{',start);depth=1;end=brace+1
 while depth:
  if text[end]=='{':depth+=1
  elif text[end]=='}':depth-=1
  end+=1
 return text[start:end]
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-vsync-',dir=WORK/'tests'));run.chmod(0o700)
 host=ROOT/'Sources/ReadyHostedView/ReadyHostedView.m';shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';include=ROOT/'Sources/ReadyHostedView/include'
 files=[host,shim,include/'ReadyHostedGameProtocol.h',include/'RHGPerformance.h',ROOT/'Synthetic/ReadyHostedVSyncHostProbe.m',ROOT/'Synthetic/ReadyHostedVSyncGuestProbe.m',pathlib.Path(__file__).resolve()]
 before={str(p.relative_to(ROOT)):sha(p)for p in files}
 host_text=host.read_text();functions='\n'+extract_function(host_text,'static BOOL RHGFormat(')+'\n'+extract_function(host_text,'static void RHGConfigureLayer(')+'\n'
 (run/'host.m').write_text((ROOT/'Synthetic/ReadyHostedVSyncHostProbe.m').read_text()+functions+HOST_MAIN)
 marker='__attribute__((constructor))static void rhgInstall(void)';source=shim.read_text();assert source.count(marker)==1
 (run/'guest.m').write_text(source.replace(marker,'static void rhgInstall(void)')+'\n'+(ROOT/'Synthetic/ReadyHostedVSyncGuestProbe.m').read_text())
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','RHG_','MTL_HUD_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-performance'))
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',include,'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics'];logs=[]
 def call(command,expected=0,environment=None):
  p=subprocess.run(list(map(str,command)),cwd=ROOT,env=environment or env,capture_output=True,text=True,timeout=15);logs.append(p.stdout+p.stderr);(run/'build.log').write_text('\n'.join(logs))
  if p.returncode!=expected:raise RuntimeError('Own VSync fixture failed: '+str(run/'build.log'))
  return p
 for name in ['host','guest']:call(flags+[run/(name+'.m'),'-o',run/name])
 host_result=json.loads(call([run/'host']).stdout);guest_result=None;negative=[]
 for name,expected in [('positive',0),('wrong-ack',77),('invalid-ack',77)]:
  child={**env,'READY_HOSTED_GAME_SERVICE':'local.ready.hostedgame.fixture.'+uuid.uuid4().hex,'READY_HOSTED_GAME_NONCE':'a1'*32}
  p=call([run/'guest',name],expected,child)
  if expected==0:guest_result=json.loads(p.stdout)
  else:
   failure=next(json.loads(s)for s in p.stderr.splitlines()if s.startswith('{'));assert failure['reason']=='host-did-not-adopt-layer-configuration';negative.append(name)
 # Eligibility work is independently owned; bind exactly the tested CONFIGURE
 # helper/format bodies so disjoint concurrent changes cannot falsify this test.
 current=host.read_text();assert functions=='\n'+extract_function(current,'static BOOL RHGFormat(')+'\n'+extract_function(current,'static void RHGConfigureLayer(')+'\n'
 assert all(before[str(p.relative_to(ROOT))]==sha(p)for p in files if p!=host)
 report={'passed':True,'host':host_result,'guest':guest_result,'negativeACKCases':negative,'sourceHashesAtStart':before,'hostConfigurationFunctionsSHA256':hashlib.sha256(functions.encode()).hexdigest(),'fixtureOnly':True,'GPUOrUIOrGameOrAccountUsed':False,'protocolVersion':4}
 path=run/'report.json';path.write_text(json.dumps(report,indent=2)+'\n');path.chmod(0o600)
 pointer={'passed':True,'hostChecks':host_result['checks'],'guestChecks':guest_result['checks'],'negativeACKCases':2,'retainedReport':str(path),'retainedReportSHA256':sha(path),'hostConfigurationFunctionsSHA256':report['hostConfigurationFunctionsSHA256'],'protocolSHA256':sha(include/'ReadyHostedGameProtocol.h'),'fixtureOnly':True,'GPUOrUIOrGameOrAccountUsed':False}
 (ROOT/'Evidence/hosted-vsync-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
