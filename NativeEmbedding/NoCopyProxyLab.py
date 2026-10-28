#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Dedicated OWN window-resource/Metal experiment. No Steam or other apps."""
import argparse,hashlib,json,os,plistlib,subprocess,tempfile,time,uuid
from pathlib import Path
SOURCE=Path(__file__).resolve().parent
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
NAMES=['NoCopyProxyProtocol.h','NoCopyProxyHost.m','NoCopyProxyGuest.m','NoCopyProxyShim.m','NoCopyProxyLab.py']
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def records(path):
    result=[]
    for line in path.read_text().splitlines()if path.exists()else[]:
        try:result.append(json.loads(line))
        except ValueError:pass
    return result
def wait_for(path,kind,process,timeout=8):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        for entry in records(path):
            if entry.get('type')==kind:return entry
        if process.poll()is not None:raise RuntimeError('Own child ended before '+kind)
        time.sleep(.025)
    raise TimeoutError('Own child timed out before '+kind)
def main():
    p=argparse.ArgumentParser(description=__doc__);m=p.add_mutually_exclusive_group();m.add_argument('--build-only',action='store_true');m.add_argument('--offscreen',action='store_true');m.add_argument('--visual',action='store_true');p.add_argument('--frames',type=int,default=90);p.add_argument('--linger',type=int,default=2);a=p.parse_args()
    if not 1<=a.frames<=600 or not 0<=a.linger<=40:raise ValueError('Bounded experiment only')
    assert WORK.stat().st_uid==os.getuid()and(WORK/'.ready-external-workspace').is_file()
    run=Path(tempfile.mkdtemp(prefix='native-no-copy-proxy-',dir=WORK/'tests'));run.chmod(0o700)
    (run/'.ready-nocopyproxy-owned').write_text('own synthetic applications only\n')
    before={n:sha(SOURCE/n)for n in NAMES}
    for n in NAMES:(run/n).write_bytes((SOURCE/n).read_bytes())
    tmp=run/'tmp';tmp.mkdir(mode=0o700)
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','STEAM','Steam','M1L_'))};env['TMPDIR']=str(tmp)+'/'
    cache=WORK/'cache/nocopyproxy-clang';cache.mkdir(mode=0o700,exist_ok=True)
    commands=[]
    def call(args):
        result=subprocess.run(args,capture_output=True,text=True,env=env);commands.append({'argv':list(map(str,args)),'exitCode':result.returncode,'stderr':result.stderr})
        if result.returncode:raise RuntimeError('Own build/inspection failed: '+result.stderr)
        return result
    flags=['/usr/bin/clang','-arch','arm64','-fobjc-arc','-fblocks','-O1','-Wall','-Wextra','-Wno-deprecated-declarations','-fmodules-cache-path='+str(cache),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface']
    host=run/'NoCopyProxyHost';guest=run/'NoCopyProxyGuest';shim=run/'NoCopyProxyShim.dylib'
    call([*flags,str(run/'NoCopyProxyHost.m'),'-o',str(host)])
    call([*flags,str(run/'NoCopyProxyGuest.m'),'-o',str(guest)])
    call([*flags,'-dynamiclib',str(run/'NoCopyProxyShim.m'),'-o',str(shim)])
    ent=run/'entitlements.plist';ent.write_bytes(plistlib.dumps({'com.apple.security.cs.allow-dyld-environment-variables':True,'com.apple.security.cs.disable-library-validation':True}))
    exes={}
    for name,binary in [('Host',host),('Guest',guest)]:
        app=run/('ReadyNoCopyProxy'+name+'.app');exe=app/'Contents/MacOS'/binary.name;exe.parent.mkdir(parents=True);exe.write_bytes(binary.read_bytes());exe.chmod(0o755)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':exe.name,'CFBundleIdentifier':'local.ready.nocopyproxy.'+name.lower(),'CFBundleName':'ReadyNoCopyProxy'+name,'CFBundlePackageType':'APPL','LSUIElement':True,'NSHighResolutionCapable':True}))
        call(['/usr/bin/codesign','--force','--sign','-','--options','runtime','--entitlements',str(ent),str(app)]);call(['/usr/bin/codesign','--verify','--strict',str(app)]);exes[name]=exe
    call(['/usr/bin/codesign','--force','--sign','-',str(shim)])
    (run/'build.json').write_text(json.dumps(commands,indent=2)+'\n')
    report={'schema':1,'fixtureOnly':True,'SourceHashes':before,'guestExecutableSHA256':sha(exes['Guest']),'hostExecutableSHA256':sha(exes['Host']),'shimSHA256':sha(shim),'runRoot':str(run),'baselinePending':True,'visualVerified':False,'otherApplicationsTouched':False,'proprietaryCodeUsed':False}
    if not(a.visual or a.offscreen):
        report['buildOnly']=True
    else:
        # Foreground baseline is deliberately prohibited in offscreen mode.
        if a.visual:
            log=run/'baseline.jsonl'
            with log.open('w')as out:
                base=subprocess.Popen([str(exes['Guest']),str(min(a.frames,30))],stdout=out,stderr=out,env=env)
                try:base.wait(timeout=15)
                finally:
                    if base.poll()is None:base.terminate();base.wait(timeout=3)
            report['baselineExecutableSHA256']=sha(exes['Guest']);report['baselineExit']=base.returncode;report['baseline']=records(log);report['baselinePending']=False
        service='local.ready.nocopyproxy.'+uuid.uuid4().hex
        hl=run/'host.jsonl';gl=run/'guest.jsonl'
        he=dict(env,**({'READY_NO_COPY_PROXY_OFFSCREEN':'1'}if a.offscreen else{}))
        ge=dict(env,DYLD_INSERT_LIBRARIES=str(shim),READY_NO_COPY_PROXY_SERVICE=service)
        own=[]
        try:
            with hl.open('w')as hlog,gl.open('w')as glog:
                h=subprocess.Popen([str(exes['Host']),service,str(a.frames),str(a.linger)],stdout=hlog,stderr=hlog,env=he);own.append(h)
                ready=wait_for(hl,'host-ready',h)
                report['injectedExecutableSHA256']=sha(exes['Guest']);g=subprocess.Popen([str(exes['Guest']),str(a.frames)],stdout=glog,stderr=glog,env=ge);own.append(g)
                report['ownHostPID']=h.pid;report['ownGuestPID']=g.pid
                (run/'running.json').write_text(json.dumps({'hostPID':h.pid,'guestPID':g.pid,'hostApp':str(exes['Host'].parents[2]),'guestApp':str(exes['Guest'].parents[2])})+'\n')
                try:wait_for(gl,'guest-window',g,5)
                except RuntimeError:pass
                census=call([str(exes['Host']),'--census',str(h.pid),str(g.pid)])
                report['independentCensus']=json.loads(census.stdout)
                report['guestExit']=g.wait(timeout=20)
                if report['guestExit']!=0:h.terminate()
                report['hostExit']=h.wait(timeout=45)
        except Exception as error:report['failure']=str(error)
        finally:
            for child in own:
                if child.poll()is None:
                    child.terminate()
                    try:child.wait(timeout=3)
                    except subprocess.TimeoutExpired:child.kill();child.wait(timeout=3)
        report['host']=records(hl);report['guest']=records(gl)
        hd=next((r for r in report['host']if r.get('type')=='host-done'),None);gd=next((r for r in report['guest']if r.get('type')=='guest-done'),None)
        report['renderPipelineSucceeded']=bool(hd and gd and hd['frames']==gd['frames']==a.frames and report.get('guestExit')==0 and report.get('hostExit')==0)
        report['sameGuestBinary']=before=={n:sha(SOURCE/n)for n in NAMES}and sha(exes['Guest'])==report['guestExecutableSHA256']
        report['offscreenRequested']=a.offscreen
    assert before=={n:sha(SOURCE/n)for n in NAMES}
    path=run/'report.json';path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'report':str(path),'reportSHA256':sha(path),'renderPipelineSucceeded':report.get('renderPipelineSucceeded'),'guestExit':report.get('guestExit'),'failure':report.get('failure'),'runRoot':str(run)}),flush=True)
if __name__=='__main__':main()
