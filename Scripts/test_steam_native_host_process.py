#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real POSIX supervisor/lifeline tests; no Steam/Valve/SDK/account execution."""
import hashlib,json,os,pathlib,signal,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
def live(pid):
    result=subprocess.run(['/bin/ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
    return result.returncode==0 and result.stdout.strip()and not result.stdout.strip().startswith('Z')
def main():
    if WORK.resolve()!=WORK or WORK.stat().st_uid!=os.getuid()or WORK.stat().st_mode&0o077 or (WORK/'.ready-external-workspace').read_text()!='ready project work for thread01a17e79\n':raise ValueError('Owned marked external root required')
    run=pathlib.Path(tempfile.mkdtemp(prefix='steam-host-supervisor-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/'Sources/M1Launcher/SteamNativeHostProcess.swift',ROOT/'Synthetic/ReadySteamNativeHostProcessProbe.swift',ROOT/'Synthetic/SteamNativeHostProcessFixture.c',pathlib.Path(__file__)]
    before={str(p.relative_to(ROOT)):sha(p)for p in sources}
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','STEAM','Steam','SB_'))}
    env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/clang-steam-supervisor'))
    library=run/'Steam.AppBundle/Contents/MacOS/steamclient.dylib';library.parent.mkdir(parents=True);library.write_text('Independent fixture data, never executed\n');library.chmod(0o600)
    (run/'deny-read').write_text('Owned sandbox read control\n');(run/'deny-read').chmod(0o600)
    def binding(name,flags):
        host=run/(name+'-host')
        command=['/usr/bin/clang','-O1','-Wall','-Wextra',*flags,str(sources[2]),'-o',str(host)]
        built=subprocess.run(command,env=env,capture_output=True,text=True,timeout=30)
        (run/(name+'-build.log')).write_text(built.stdout+built.stderr)
        if built.returncode:raise RuntimeError('Own host fixture compilation failed')
        names=['host','library','discoveryLibrary','sdk','fsAdapter','ipcAdapter','lookupAdapter']
        value={'schema':1,'kind':'ready-steam-native-host-binding-v1','fixtureOnly':True,'assets':{key:{'path':str(host if key=='host'else library),'sha256':sha(host if key=='host'else library)}for key in names},'extraFiles':[]}
        path=run/(name+'.json');path.write_text(json.dumps(value,sort_keys=True)+'\n');path.chmod(0o600);return path
    normal=binding('normal',[]);binding('bad',['-DBAD_EVENT=1']);binding('lost-events',['-DDROP_EVENTS=1']);binding('hang',['-DIGNORE_LIFELINE=1'])
    probe=run/'ReadySteamNativeHostProcessProbe'
    built=subprocess.run(['/usr/bin/xcrun','swiftc','-swift-version','5','-module-cache-path',str(WORK/'cache/swift-steam-host-supervisor'),str(sources[0]),str(sources[1]),'-o',str(probe)],env=env,capture_output=True,text=True,timeout=120)
    (run/'swift-build.log').write_text(built.stdout+built.stderr)
    if built.returncode:raise RuntimeError('Real supervisor compilation failed; private build log retained')
    env['READY_FIXTURE_SECRET']='fixture_private_not_forwarded'
    checked=subprocess.run([str(probe),str(run),str(normal)],env=env,capture_output=True,text=True,timeout=50)
    (run/'checks.json').write_text(checked.stdout);(run/'checks-stderr.log').write_text(checked.stderr)
    if checked.returncode:raise RuntimeError('Supervisor real-process fixture failed; private diagnostics retained')
    report=json.loads(checked.stdout)
    # Only this explicitly spawned owner is signalled. Its child PID is observed
    # read-only afterwards, never adopted or killed by the test orchestrator.
    parent=subprocess.Popen([str(probe),str(run),str(normal),'--parent-owner'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    ready=run/'parent-ready.json';deadline=time.monotonic()+10
    while not ready.exists()and parent.poll()is None and time.monotonic()<deadline:time.sleep(.02)
    if not ready.exists():parent.kill();parent.wait();raise RuntimeError('Own parent fixture did not become ready')
    child=json.loads(ready.read_text())['pid'];assert live(child)
    parent.send_signal(signal.SIGKILL);parent.wait(timeout=3)
    deadline=time.monotonic()+4
    while live(child)and time.monotonic()<deadline:time.sleep(.02)
    assert not live(child),'Own child survived sole-lifeline-owner death'
    report['checks']['parentSIGKILLClosesSoleWriterNoLiveOrphan']=True;report['count']=len(report['checks'])
    assert not (run/'deny-write').exists()and(run/'deny-read').read_text()=='Owned sandbox read control\n'
    assert before=={str(p.relative_to(ROOT)):sha(p)for p in sources}
    report.update(sourceHashes=before,fixtureRoot=str(run),probeSHA256=sha(probe),bindingSHA256=sha(normal),sandboxControlsExecuted=True,existingSteamInspectedOrChanged=False)
    retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
    pointer={'passed':report['passed'],'count':report['count'],'fixtureOnly':True,'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':before,'realAccountUsed':False,'ValveOrSDKExecuted':False}
    (ROOT/'Evidence/steam-native-host-process-tests.json').write_text(json.dumps(pointer,indent=2)+'\n')
    print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
