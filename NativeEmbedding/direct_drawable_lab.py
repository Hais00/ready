#!/usr/bin/env python3
"""No-copy cooperative experiment, scoped to our dedicated Dati app bundles."""
import pathlib,os,sys,subprocess,plistlib,json,time,hashlib,shutil
SRC=pathlib.Path(__file__).resolve().parent
ROOT=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
OUT=ROOT/'tests/native-direct-drawable-20261028'
assert (ROOT/'.ready-external-workspace').is_file() and ROOT.stat().st_uid==os.getuid()
OUT.mkdir(exist_ok=True);(OUT/'tmp').mkdir(exist_ok=True)
env=os.environ.copy();env['TMPDIR']=str(OUT/'tmp')+'/'
def call(args):
 r=subprocess.run([str(x) for x in args],text=True,capture_output=True,env=env)
 with (OUT/'build-sign.jsonl').open('a') as f:f.write(json.dumps({'argv':[str(x) for x in args],'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})+'\n')
 if r.returncode:raise RuntimeError(r.stderr)
 return r
call(['xcrun','clang','-fobjc-arc','-O2','-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface',SRC/'DirectDrawable.m','-o',OUT/'DirectDrawable'])
ent=OUT/'entitlements.plist';ent.write_bytes(plistlib.dumps({'com.apple.security.cs.allow-dyld-environment-variables':True,'com.apple.security.cs.disable-library-validation':True}))
executables={}
for role in ['Host','Guest']:
 app=OUT/('DirectDrawable'+role+'.app');exe=app/'Contents/MacOS/DirectDrawable';exe.parent.mkdir(parents=True,exist_ok=True);exe.write_bytes((OUT/'DirectDrawable').read_bytes());exe.chmod(0o755)
 info={'CFBundleExecutable':'DirectDrawable','CFBundleIdentifier':'local.ready.directdrawable.'+role.lower(),'CFBundleName':'DirectDrawable'+role,'CFBundlePackageType':'APPL','LSUIElement':True,'NSHighResolutionCapable':True}
 if role=='Guest':info['LSBackgroundOnly']=True
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 call(['codesign','--force','--sign','-','--options','runtime','--entitlements',ent,app]);call(['codesign','--verify','--strict','--verbose=4',app]);r=call(['codesign','-dvvv','--entitlements',':-',app]);(OUT/(role+'.signature.txt')).write_text(r.stdout+r.stderr);executables[role]=exe
service='local.ready.directdrawable.'+str(os.getpid());hf=(OUT/'host.txt').open('w');gf=(OUT/'guest.txt').open('w');host=subprocess.Popen([str(executables['Host']),'host',service,'180','30'],stdout=hf,stderr=subprocess.STDOUT,env=env)
try:
 for i in range(100):
  if 'DIRECT_HOST_READY' in (OUT/'host.txt').read_text():break
  if host.poll() is not None:raise RuntimeError('Host failed before ready')
  time.sleep(.05)
 guest=subprocess.Popen([str(executables['Guest']),'guest',service,'180'],stdout=gf,stderr=subprocess.STDOUT,env=env)
 result={'host_pid':host.pid,'guest_pid':guest.pid,'service':service};(OUT/'running.json').write_text(json.dumps(result));print(result,flush=True)
 result['guest_exit']=guest.wait(timeout=30);result['host_exit']=host.wait(timeout=55)
except Exception as e:
 result={'error':str(e),'host_pid':host.pid}
 for proc in [host]+([guest] if 'guest' in locals() else []):
  if proc.poll() is None:proc.terminate();proc.wait(timeout=5)
(OUT/'result.json').write_text(json.dumps(result,indent=2))
shutil.copy2(SRC/'DirectDrawable.m',OUT/'DirectDrawable.source.m');shutil.copy2(SRC/'direct_drawable_lab.py',OUT/'driver.source.py')
(OUT/'hashes.json').write_text(json.dumps({str(p.relative_to(OUT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [OUT/'DirectDrawable.source.m',OUT/'driver.source.py',*executables.values()]},indent=2));print(result)
