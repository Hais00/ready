#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual guest-local public Foundation/Darwin temp override; own benign child only."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='scratch-redirect-',dir=WORK/'tests'));run.chmod(0o700);scratch=run/'session tmp with spaces';scratch.mkdir(mode=0o700)
 header=ROOT/'Sources/ReadyHostedView/include/RHGSessionScratch.h';probe=ROOT/'Synthetic/ReadySessionScratchRedirectProbe.m';files=[header,probe,pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 (run/'redirect.m').write_text('#import <Foundation/Foundation.h>\n#define RHG_INTERPOSE(replacement,original) __attribute__((used))static struct{const void *replace,*original;}rhg_interpose_##original __attribute__((section("__DATA,__interpose")))={(const void *)&replacement,(const void *)&original}\n#import "RHGSessionScratch.h"\n__attribute__((constructor))static void install(void){@autoreleasepool{rhgInstallSessionScratch();}}\n')
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','RHG_','MTL_HUD_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/scratch-redirect'))
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-I',str(header.parent),'-framework','Foundation'];logs=[]
 def call(cmd,environment=None,expected=0):
  p=subprocess.run(list(map(str,cmd)),cwd=run,env=environment or env,capture_output=True,text=True,timeout=30);logs.append(p.stderr);(run/'build.log').write_text('\n'.join(logs))
  if p.returncode!=expected:raise RuntimeError('Scratch redirect child failed '+str(run))
  return p
 call(flags+['-dynamiclib',run/'redirect.m','-o',run/'redirect.dylib']);call(['codesign','--force','--sign','-',run/'redirect.dylib']);call(flags+[probe,'-o',run/'child'])
 child={**env,'READY_NATIVE_SESSION_TMPDIR':str(scratch)+'/', 'TMPDIR':str(scratch)+'/', 'FIXTURE_EXPECTED_HOME':env.get('HOME',''),'FIXTURE_EXPECTED_CWD':str(run)}
 baseline=json.loads(call([run/'child'],child).stdout)
 injected={**child,'DYLD_INSERT_LIBRARIES':str(run/'redirect.dylib')};result=json.loads(call([run/'child'],injected).stdout);assert all(result.values()),result
 fallback={k:v for k,v in injected.items()if k!='READY_NATIVE_SESSION_TMPDIR'};plainFallback=json.loads(call([run/'child'],fallback).stdout);assert plainFallback['HOMEUnchanged']and plainFallback['cwdUnchanged']
 negative=[];alias=run/'alias';alias.symlink_to(scratch,target_is_directory=True);wide=run/'not-private';wide.mkdir(mode=0o755);file=run/'regular';file.write_text('own fixture')
 for name,path in [('symlink',alias),('permissions',wide),('regular',file),('missing',run/'missing'),('root',pathlib.Path('/'))]:
  p=call([run/'child'],{**injected,'READY_NATIVE_SESSION_TMPDIR':str(path)},expected=77);assert 'unsafe-native-session-scratch'in p.stderr;negative.append(name)
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files}
 report={'passed':True,'count':len(result)+len(negative)+1,'checks':result,'negativeCases':negative,'plainTMPDIRFoundationRedirected':baseline['foundationMatchesSelected'],'guestLocalFoundationRedirected':result['foundationMatchesSelected'],'ANECompilerDaemonVerified':False,'gameAccountScreenOrGPUUsed':False,'globalSystemSettingsChanged':False,'sourceHashes':before};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/session-scratch-redirect-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
