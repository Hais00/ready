#!/usr/bin/env python3
"""Build/sign/execute only our dedicated synthetic apps; all products stay on Dati."""
import os,sys,pathlib,subprocess,plistlib,time,json
SRC=pathlib.Path(__file__).resolve().parent
OUT=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '/Volumes/Dati APFS/Codex-ready-01a17e79/tests/native-embedding-20261028')
ROOT=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79').resolve()
if not (ROOT/'.ready-external-workspace').is_file() or ROOT.stat().st_uid!=os.getuid() or ROOT.stat().st_mode & 0o077:
    raise RuntimeError('Expected owned private Dati workspace marker')
if not OUT.resolve().is_relative_to(ROOT):
    raise RuntimeError('All products must remain inside the private Dati workspace')
OUT.mkdir(parents=True,exist_ok=True)
(OUT/"tmp").mkdir(exist_ok=True)
os.environ["TMPDIR"]=str(OUT/"tmp")+"/"
def run(args,**kw):
    return subprocess.run([str(x) for x in args],text=True,capture_output=True,**kw)
def checked(args):
    r=run(args)
    with (OUT/'build-and-sign.jsonl').open('a') as f:f.write(json.dumps({'argv':[str(x) for x in args],'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr})+'\n')
    if r.returncode: raise RuntimeError(str(args)+'\n'+r.stdout+r.stderr)
    return r
common=['xcrun','clang','-fobjc-arc','-O2','-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface']
checked(common+[str(SRC/'Lab.m'),'-o',str(OUT/'Lab')])
checked(common+['-dynamiclib',str(SRC/'EmbeddingShim.m'),'-o',str(OUT/'EmbeddingShim.dylib')])
checked(['codesign','--force','--sign','-',str(OUT/'EmbeddingShim.dylib')])
results={}
for name,dyld,validation,runtime in [('both',1,1,1),('dyld_only',1,0,1),('validation_only',0,1,1),('neither',0,0,1),('ordinary',0,0,0)]:
    app=OUT/(name+'.app');exe=app/'Contents/MacOS/Lab';exe.parent.mkdir(parents=True,exist_ok=True)
    exe.write_bytes((OUT/'Lab').read_bytes());exe.chmod(0o755)
    with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump({'CFBundleIdentifier':'local.ready.nativeembedding.'+name,'CFBundleExecutable':'Lab','CFBundleName':'NativeEmbedding '+name,'CFBundlePackageType':'APPL','LSUIElement':True,'NSHighResolutionCapable':True},f)
    ent={}
    if dyld:ent['com.apple.security.cs.allow-dyld-environment-variables']=True
    if validation:ent['com.apple.security.cs.disable-library-validation']=True
    ep=OUT/(name+'.entitlements.plist')
    with ep.open('wb') as f:plistlib.dump(ent,f)
    args=['codesign','--force','--sign','-','--entitlements',ep]
    if runtime:args+=['--options','runtime']
    checked(args+[app]);verify=checked(['codesign','--verify','--strict','--verbose=4',app]);details=run(['codesign','-dvvv','--entitlements',':-',app]);(OUT/(name+'.signature.txt')).write_text(verify.stdout+verify.stderr+details.stdout+details.stderr)
    env=dict(os.environ,DYLD_INSERT_LIBRARIES=str(OUT/'EmbeddingShim.dylib'))
    r=run([exe,'--probe'],env=env);results[name]={'returncode':r.returncode,'output':r.stdout+r.stderr}
    (OUT/(name+'.probe.txt')).write_text(r.stdout+r.stderr)
    r=run([exe,'--probe','--dlopen',OUT/'EmbeddingShim.dylib']);(OUT/(name+'.dlopen.txt')).write_text(r.stdout+r.stderr)
(OUT/'matrix.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))

# Separate owned application bundles, so Launch Services and UI inspection distinguish host/guest.
import shutil
for role in ('Host','Guest'):
    app=OUT/('NativeEmbedding'+role+'.app')
    if app.exists():shutil.rmtree(app)
    shutil.copytree(OUT/'both.app',app)
    info=app/'Contents/Info.plist'
    data=plistlib.loads(info.read_bytes());data['CFBundleIdentifier']='local.ready.nativeembedding.'+role.lower();data['CFBundleName']='NativeEmbedding'+role
    info.write_bytes(plistlib.dumps(data))
    checked(['codesign','--force','--sign','-','--options','runtime','--entitlements',OUT/'both.entitlements.plist',app])
    r=checked(['codesign','--verify','--strict','--verbose=4',app]);details=run(['codesign','-dvvv','--entitlements',':-',app]);(OUT/(role+'.signature.txt')).write_text(r.stdout+r.stderr+details.stdout+details.stderr)

checked(['xcrun','clang','-fobjc-arc','-framework','Cocoa',SRC/'LaunchContext.m','-o',OUT/'LaunchContext'])
checked(['codesign','--force','--sign','-',OUT/'LaunchContext'])
launch_results={}
for name in results:
    receipt=OUT/(name+'.nsworkspace.probe.txt')
    receipt.unlink(missing_ok=True)
    r=run([OUT/'LaunchContext',OUT/(name+'.app'),OUT/'EmbeddingShim.dylib',receipt],timeout=15)
    for i in range(40):
        if receipt.exists():break
        time.sleep(.05)
    launch_results[name]={'launcher_exit':r.returncode,'output':r.stdout+r.stderr,'probe':receipt.read_text() if receipt.exists() else '<no receipt>'}
(OUT/'nsworkspace.matrix.json').write_text(json.dumps(launch_results,indent=2))

import hashlib,platform,datetime
snapshot=OUT/'source';snapshot.mkdir(exist_ok=True)
for source in SRC.iterdir():
    if source.suffix in ('.m','.py'):
        shutil.copy2(source,snapshot/source.name)
manifest={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'platform':platform.platform(),'source_and_products':{}}
for file in list(snapshot.iterdir())+[OUT/'Lab',OUT/'EmbeddingShim.dylib',OUT/'LaunchContext',OUT/'NativeEmbeddingHost.app/Contents/MacOS/Lab',OUT/'NativeEmbeddingGuest.app/Contents/MacOS/Lab']:
    manifest['source_and_products'][str(file.relative_to(OUT))]=hashlib.sha256(file.read_bytes()).hexdigest()
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
