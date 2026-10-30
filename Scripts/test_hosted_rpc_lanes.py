#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Private actual Mach concurrency: held ACQUIRE must not block PRESENT/POLL.

Uses controlled GPU completion, typed send rights and no GPU/window/account.
The private shared-lane control differs only in operation-to-lane routing.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-rpc-lanes-',dir=WORK/'tests'));run.chmod(0o700)
 shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';fixture=ROOT/'Synthetic/ReadyHostedRPCLanesProbe.m';include=ROOT/'Sources/ReadyHostedView/include';files=[shim,fixture,*sorted(include.glob('*.h')),pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files};source=shim.read_text();marker='__attribute__((constructor))static void rhgInstall(void)';assert source.count(marker)==1
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','RHG_','READY_','Steam','STEAM','MTL_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-rpc-lanes'),RHG_PERF_PROFILE='0')
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics'];cases={}
 route='BOOL acquire=operation==RHG_ACQUIRE;';assert source.count(route)==1
 for name,text in [('split',source),('shared',source.replace(route,'BOOL acquire=NO;'))]:
  tested=run/(name+'.m');tested.write_text(text.replace(marker,'static void rhgInstall(void)')+'\n'+fixture.read_text());binary=run/name;p=subprocess.run([*flags,str(tested),'-o',str(binary)],env=env,capture_output=True,text=True,timeout=90);(run/(name+'.build.log')).write_text(p.stdout+p.stderr)
  if p.returncode:raise RuntimeError('Own RPC lane compile failed '+str(run)+'\n'+p.stderr[-1800:])
  modes=[('shared',0)]if name=='shared'else[('independent',0),('bad-acquire-id',77),('bad-present-id',77),('bad-descriptor',77),('bad-nonce',77),('request-overflow',77)]
  for mode,expected in modes:
   p=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(binary),mode],env=env,capture_output=True,text=True,timeout=15);(run/(mode+'.stdout.json')).write_text(p.stdout);(run/(mode+'.stderr.log')).write_text(p.stderr)
   if p.returncode!=expected:raise RuntimeError('Own RPC lane '+mode+' failed '+str(run)+'\n'+p.stderr[-1000:])
   if expected==0:cases[mode]=json.loads(p.stdout);assert cases[mode]['passed']
   else:
    row=next(json.loads(x)for x in p.stderr.splitlines()if x.startswith('{'));reason='request-sequence-exhausted'if mode=='request-overflow'else'invalid-host-surface-descriptor'if mode=='bad-descriptor'else'host-rejected-request';assert row['reason']==reason;cases[mode]={'passed':True,'expectedExit':77,'reason':reason}
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files};report={'passed':True,'cases':cases,'sourceHashes':before,'networkDenied':True,'actualMachIPC':True,'GPUOrUIOrGameOrAccountUsed':False,'protocolVersion':6,'frameDepthChanged':False};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-rpc-lanes-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
