#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real production-policy sessions; heavy work is confined to a marked work volume.

No SwiftPM, provider/default modifications, fake controller device, or skipped
Wine initialization. A disconnected app-local DLL is solely a loader fixture.
"""
import argparse,fcntl,hashlib,json,os,shutil,stat,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WORK=None
OUTPUT=None
RESERVE=512*1024*1024
PRIMARY_RESERVE=256*1024*1024
SUMMARY_LIMIT=8*1024*1024

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def primary_space(extra=0):
    if shutil.disk_usage(ROOT).free<PRIMARY_RESERVE+extra:raise RuntimeError('Preserving256MiB primary-volume reserve for small summaries')
def space(extra=0):
    if WORK is None or shutil.disk_usage(WORK).free<RESERVE+extra:raise RuntimeError('Preserving512MiB work-volume reserve')
    primary_space()
def write_json(path,value):
    data=(json.dumps(value,indent=2)+'\n').encode();path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    temp=path.with_name(path.name+'.writing');temp.write_bytes(data);os.replace(temp,path)
def small_summary(path,value):
    data=(json.dumps(value,indent=2)+'\n').encode()
    if len(data)>SUMMARY_LIMIT:raise RuntimeError('Primary evidence summary exceeds8MiB budget')
    primary_space(len(data));write_json(path,value)
def owned_work_root(path):
    if not path.is_absolute() or path.is_symlink():raise RuntimeError('An explicit canonical work root is required')
    root=path.resolve();marker=root/'.ready-external-workspace'
    for item,kind in [(root,stat.S_ISDIR),(marker,stat.S_ISREG)]:
        info=item.lstat()
        if not kind(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:raise RuntimeError('Work root and marker must be private and owned')
    if root.stat().st_dev==ROOT.stat().st_dev:raise RuntimeError('This low-primary-space E2E requires the authorized separate volume')
    for name in ['tmp','build','tests','cache','retained']:
        child=root/name
        if child.is_symlink():raise RuntimeError('Workspace child cannot be a symlink')
        child.mkdir(mode=0o700,exist_ok=True)
    return root

def run(args,**kwargs):return subprocess.run(list(map(str,args)),check=True,**kwargs)

def build_windows():
    space(32*1024*1024);OUTPUT.mkdir(parents=True,exist_ok=True)
    cc='/opt/homebrew/opt/llvm/bin/clang';dt='/opt/homebrew/opt/llvm/bin/llvm-dlltool';link='/opt/homebrew/opt/lld/bin/lld-link';commands=[]
    libraries={
      'kernel':('KERNEL32.dll',['GetModuleHandleW','GetCommandLineW','LoadLibraryA','GetProcAddress','ExitProcess','GetEnvironmentVariableA','GetModuleFileNameA','GetModuleHandleA','GetStdHandle','WriteFile','CreateThread','Sleep']),
      'user':('USER32.dll',['RegisterClassW','CreateWindowExW','DefWindowProcW','ShowWindow','UpdateWindow','PeekMessageW','TranslateMessage','DispatchMessageW','DestroyWindow','PostQuitMessage','GetClientRect']),
      'crt':('msvcrt.dll',['printf','calloc','free','strcmp'])}
    for name,(dll,exports) in libraries.items():
        definition=OUTPUT/(name+'.def');definition.write_text('LIBRARY '+dll+'\nEXPORTS\n'+'\n'.join(exports)+'\n');command=[dt,'-m','i386:x86-64','-d',str(definition),'-l',str(OUTPUT/(name+'.lib'))];run(command);commands.append(command)
    common=[cc,'--target=x86_64-windows','--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2']
    source=ROOT/'Scripts/runtime_controller_policy_windows_probe.c';obj=OUTPUT/'controller-policy.obj';exe=OUTPUT/'controller-policy.exe'
    command=[*common,'-I'+str(ROOT/'Runtime/vulkan-headers-1.4.366/include'),'-c',str(source),'-o',str(obj)];run(command);commands.append(command)
    command=[link,'/timestamp:0','/entry:mainCRTStartup','/subsystem:console','/machine:x64','/nodefaultlib',str(obj),*[str(OUTPUT/(n+'.lib')) for n in libraries],'/out:'+str(exe)];run(command);commands.append(command)
    dxmt_obj=OUTPUT/'controller-policy-dxmt.obj';dxmt_exe=OUTPUT/'controller-policy-dxmt.exe'
    command=[*common,'-DREADY_CONTROLLER_DXMT','-c',str(source),'-o',str(dxmt_obj)];run(command);commands.append(command)
    command=[link,'/timestamp:0','/entry:mainCRTStartup','/subsystem:console','/machine:x64','/nodefaultlib',str(dxmt_obj),*[str(OUTPUT/(n+'.lib')) for n in libraries],'/out:'+str(dxmt_exe)];run(command);commands.append(command)
    source=ROOT/'Scripts/runtime_controller_private_xinput_fixture.c';obj=OUTPUT/'private-input.obj';private=OUTPUT/'private-xinput1_4.dll'
    command=[*common,'-I'+str(ROOT/'Runtime/wine-11.20/include/wine/windows'),'-I'+str(ROOT/'Vendor/wine/include/msvcrt'),'-c',str(source),'-o',str(obj)];run(command);commands.append(command)
    command=[link,'/timestamp:0','/dll','/entry:DllMain','/machine:x64','/nodefaultlib',str(obj),'/out:'+str(private)];run(command);commands.append(command)
    return exe,private,dxmt_exe,commands

def owned_regular(path,max_bytes=65536):
    info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_size>max_bytes:raise RuntimeError('Owned regular metadata required: '+str(path))
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        opened=os.fstat(fd)
        if (opened.st_dev,opened.st_ino)!=(info.st_dev,info.st_ino):raise RuntimeError('Metadata changed during open')
        return os.read(fd,max_bytes+1)
    finally:os.close(fd)

def confined_directory(path,parent,missing_ok=False):
    if not path.is_absolute() or '..' in path.parts or path==parent or not path.is_relative_to(parent):raise RuntimeError('Path escaped cleanup parent')
    info=parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or parent.resolve(strict=True)!=parent:raise RuntimeError('Cleanup parent is not canonical/owned')
    current=parent
    for part in path.relative_to(parent).parts:
        current=current/part
        try:info=current.lstat()
        except FileNotFoundError:
            if missing_ok:return None
            raise
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid():raise RuntimeError('Cleanup directory is not owned or follows a link: '+str(current))
    if path.resolve(strict=True)!=path:raise RuntimeError('Cleanup path is not canonical')
    return path

def cleanup(scratch,servers,remove):
    if WORK is None:raise RuntimeError('No owned work root')
    owned_regular(WORK/'.ready-external-workspace')
    tests=WORK/'tests'
    if scratch.parent!=tests:raise RuntimeError('Scratch must be a direct child of work-root/tests')
    confined_directory(scratch,tests);owned_regular(scratch/'.ready-controller-policy-test')
    descriptor=scratch/'cleanup.json'
    if descriptor.exists() or descriptor.is_symlink():
        data=json.loads(owned_regular(descriptor))
        prefix_parent=scratch/'data/Prefixes'
        for raw in data['prefixes']:
            prefix=Path(raw)
            if confined_directory(prefix,prefix_parent,missing_ok=True) is None:continue
            env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))};env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all')
            for server in servers:
                subprocess.run([str(server),'-k'],env=env,capture_output=True,timeout=10)
                run([server,'-w'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
    locks=scratch/'data/Locks'
    if locks.exists() or locks.is_symlink():confined_directory(locks,scratch)
    for path in locks.glob('*.lock'):
        fd=os.open(path,os.O_RDWR|os.O_NOFOLLOW)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid():raise RuntimeError('Unsafe cleanup lease file')
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        finally:os.close(fd)
    if remove:shutil.rmtree(scratch)

def phase_snapshot(scratch,pid):
    """Only exact owned process ancestry/host argv; no ambient environment dump."""
    selected={pid};rows=[]
    try:
        raw=subprocess.check_output(['/bin/ps','-axo','pid,ppid,command'],text=True,timeout=3)
        for line in raw.splitlines()[1:]:
            fields=line.strip().split(None,2)
            if len(fields)==3:rows.append((int(fields[0]),int(fields[1]),fields[2]))
        for _ in range(6):
            selected.update(a for a,b,c in rows if b in selected or (str(scratch) in c and 'ReadySessionHost' in c))
    except Exception:rows=[]
    owned=[{'pid':a,'ppid':b,'command':c} for a,b,c in rows if a in selected]
    commands='\n'.join(r['command'] for r in owned if r['pid']!=pid).lower()
    if 'regedit' in commands:phase='regedit';evidence='actual owned process/host argv'
    elif 'wineboot' in commands:phase='Wineboot';evidence='actual owned process/host argv'
    elif 'controller-policy.exe' in commands or 'controller-policy-dxmt.exe' in commands:phase='Windows game';evidence='actual owned process/host argv'
    else:phase='unresolved-prelaunch';evidence='no initialization/game argv observed'
    markers=[];prefixes=[]
    if (scratch/'cleanup.json').is_file():
        try:prefixes=[Path(p) for p in json.loads((scratch/'cleanup.json').read_text()).get('prefixes',[])]
        except Exception:pass
    for prefix in prefixes:
        if prefix.is_relative_to(scratch/'data/Prefixes') and prefix.is_dir():markers.append({'prefix':str(prefix),'builtin32Manifest':(prefix/'.ready/builtin32.json').is_file(),'runtimeInitialized':(prefix/'.ready/runtime-initialized').is_file(),'dllVersion':(prefix/'.ready/dll-runtime-version').is_file()})
    progress={}
    if (scratch/'progress.json').is_file():
        try:progress=json.loads((scratch/'progress.json').read_text())
        except Exception:pass
    return {'phase':phase,'phaseEvidence':evidence,'ownedProcesses':owned,'markers':markers,'completedCases':[c.get('case') for c in progress.get('cases',[])]}

def main():
    global WORK,OUTPUT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-root',type=Path,required=True);parser.add_argument('--modules',type=Path,required=True);parser.add_argument('--archive',type=Path,required=True)
    parser.add_argument('--keep',action='store_true');parser.add_argument('--compile-only',action='store_true');parser.add_argument('--run-only',action='store_true')
    args=parser.parse_args();WORK=owned_work_root(args.work_root);OUTPUT=WORK/'build/controller-policy-e2e';OUTPUT.mkdir(mode=0o700,exist_ok=True)
    module_cache=WORK/'cache/controller-policy-swift-modules';module_cache.mkdir(exist_ok=True)
    # Do not repurpose HOME. TMPDIR remains short enough for Wine Unix sockets.
    os.environ.update(TMPDIR=str(WORK/'tmp')+'/',XDG_CACHE_HOME=str(WORK/'cache'),CLANG_MODULE_CACHE_PATH=str(module_cache),SWIFT_MODULECACHE_PATH=str(module_cache))
    space(64*1024*1024)
    modules=args.modules.resolve();archive=args.archive.resolve();module=modules/'LauncherCore.swiftmodule';importable=list(module.glob('*.swiftmodule')) if module.is_dir() else [module]
    assert archive.is_file() and importable and all(p.is_file() for p in importable)
    assert archive.stat().st_mtime_ns>=max(p.stat().st_mtime_ns for p in importable),'Core module/archive pair is stale'
    receipt=OUTPUT/'build-receipt.json';harness=OUTPUT/'ReadyControllerPolicyProbe'
    if args.run_only:
        build=json.loads(receipt.read_text())
        for path,expected in build['sources'].items():
            if path!='Scripts/test_controller_policy_e2e.py' and sha(ROOT/path)!=expected:raise RuntimeError('Compiled source changed: '+path)
        if sha(archive)!=build['coreArchiveSHA256'] or {str(p):sha(p) for p in importable}!=build['coreModuleHashes']:raise RuntimeError('Core snapshot changed')
        exe=OUTPUT/'controller-policy.exe';private=OUTPUT/'private-xinput1_4.dll';dxmt_exe=OUTPUT/'controller-policy-dxmt.exe'
        for path,key in [(harness,'harnessSHA256'),(exe,'windowsProbeSHA256'),(private,'privateAppDLLFixtureSHA256'),(dxmt_exe,'dxmtWindowsProbeSHA256')]:
            if sha(path)!=build[key]:raise RuntimeError('Compiled artifact changed: '+str(path))
        snapshot=Path(build['compileDriverSnapshot']['path']);assert sha(snapshot)==build['compileDriverSnapshot']['sha256']==build['sources']['Scripts/test_controller_policy_e2e.py']
        build['runOnlyDriver']={'sha256':sha(__file__),'compilersInvoked':False};write_json(receipt,build)
    else:
        exe,private,dxmt_exe,commands=build_windows()
        command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(module_cache),'-I',str(modules),str(ROOT/'Sources/M1Launcher/SessionManager.swift'),str(ROOT/'Synthetic/ReadyControllerPolicyProbe.swift'),str(archive),'-framework','AppKit','-o',str(harness)]
        run(command);commands.append(command)
        sources=[Path(__file__),ROOT/'Synthetic/ReadyControllerPolicyProbe.swift',ROOT/'Sources/M1Launcher/SessionManager.swift',ROOT/'Sources/LauncherCore/ControllerInputPolicy.swift',ROOT/'Scripts/runtime_controller_policy_windows_probe.c',ROOT/'Scripts/runtime_controller_private_xinput_fixture.c',ROOT/'Scripts/runtime_vulkan_present.c',ROOT/'Scripts/runtime_d3d11_present.c']
        snapshot=OUTPUT/('compile-driver-'+sha(__file__)+'.py');snapshot.write_bytes(Path(__file__).read_bytes())
        build={'commands':commands,'sources':{str(p.relative_to(ROOT)):sha(p) for p in sources},'coreArchiveSHA256':sha(archive),'coreModuleHashes':{str(p):sha(p) for p in importable},'harnessSHA256':sha(harness),'windowsProbeSHA256':sha(exe),'privateAppDLLFixtureSHA256':sha(private),'dxmtWindowsProbeSHA256':sha(dxmt_exe),'compileDriverSnapshot':{'path':str(snapshot),'sha256':sha(snapshot)},'workRoot':str(WORK),'testControllerDeviceBackendUsed':False,'privateDisconnectedAppDLLFixture':True}
        write_json(receipt,build)
    small_summary(ROOT/'Evidence/controller-policy-e2e-build.json',build)
    if args.compile_only:print(json.dumps({'compiled':True,'receipt':str(receipt),'harnessSHA256':build['harnessSHA256']}));return
    space(768*1024*1024)
    candidate=ROOT/'Runtime/candidate-xinput-v2.json';cfg=json.loads(candidate.read_text());cap=cfg['overlayInputCapture'];servers=sorted({Path(cfg['wineServer']),*map(Path,cfg.get('engineWineServers',{}).values())});overlay=ROOT/'Build/libReadyOverlay.dylib'
    immutable=[ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json',candidate,Path(cap['manifestPath']),overlay]
    for provider in cap['providers'].values():
        root=Path(provider['wineRoot']);immutable.extend([root/'bin/wine',root/'bin/ready-wine',root/'bin/wineserver',*[root/'lib/wine'/key for key in provider['payloadHashes']]])
    dxmt=Path(cap['providers']['dxmt']['wineRoot']);immutable.extend([dxmt/'lib/wine/x86_64-unix/winemetal.so',dxmt/'lib/wine/x86_64-unix/winemac.so'])
    before={str(p):sha(p) for p in immutable};runid=uuid.uuid4().hex;scratch=WORK/'tests'/('controller-policy-'+runid);scratch.mkdir(mode=0o700);(scratch/'.ready-controller-policy-test').write_text('Owned production-provider policy fixture\n');(scratch/'.ready-controller-policy-test').chmod(0o600)
    retained=WORK/'retained'/('controller-policy-'+runid);retained.mkdir(mode=0o700)
    game=scratch/'game';game.mkdir();shutil.copy2(exe,game/exe.name);game_dxmt=scratch/'game-dxmt';game_dxmt.mkdir();shutil.copy2(dxmt_exe,game_dxmt/dxmt_exe.name)
    process=None;sampler=None;passed=False;report={'passed':False,'physicalControllerVerified':False,'workRoot':str(WORK),'retained':str(retained)}
    started=time.monotonic();timeline=[];min_work=shutil.disk_usage(WORK).free;min_primary=shutil.disk_usage(ROOT).free
    try:
        env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))}
        process=subprocess.Popen([str(harness),str(ROOT),str(scratch),str(candidate),str(game/exe.name),str(private),str(game_dxmt/dxmt_exe.name),str(WORK)],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        deadline=started+600;sampled=False
        while True:
            try:stdout,stderr=process.communicate(timeout=1);break
            except subprocess.TimeoutExpired:
                work_free=shutil.disk_usage(WORK).free;primary_free=shutil.disk_usage(ROOT).free;min_work=min(min_work,work_free);min_primary=min(min_primary,primary_free);elapsed=time.monotonic()-started
                point={'elapsedSeconds':round(elapsed,3),'workFreeBytes':work_free,'primaryFreeBytes':primary_free,'minimumWorkFreeBytes':min_work,'minimumPrimaryFreeBytes':min_primary,**phase_snapshot(scratch,process.pid)};timeline.append(point)
                sample_file=scratch/'harness-stack.sample.txt'
                if not sampled and elapsed>=4 and point['phase']=='unresolved-prelaunch' and work_free>RESERVE+64*1024*1024:
                    sampled=True
                    try:sampler=subprocess.Popen(['/usr/bin/sample',str(process.pid),'1','10','-file',str(sample_file)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    except OSError:sampler=None
                if sample_file.is_file() and 'WindowsBuiltinBootstrap' in sample_file.read_text(errors='replace'):point.update(phase='WindowsBuiltinBootstrap',phaseEvidence='actual sampled harness stack')
                write_json(scratch/'telemetry.json',{'timeline':timeline})
                reason='work-volume-reserve' if work_free<RESERVE else 'primary-volume-reserve' if primary_free<PRIMARY_RESERVE else 'watchdog-600-seconds' if time.monotonic()>deadline else None
                if reason:
                    report.update(stoppedByGuard=reason,elapsedSeconds=round(elapsed,3),phase=point,softwareFailureObserved=False);process.terminate();raise RuntimeError('Controller policy E2E guard: '+reason)
        (retained/'harness.log').write_text(stdout+'\n'+stderr)
        report.update(returncode=process.returncode,candidateSHA256=sha(candidate),overlaySHA256=sha(overlay),productionModuleHashesBefore=before,productionControllerDLLsUsed=True,testControllerDeviceBackendUsed=False,buildReceiptSHA256=sha(receipt))
        if process.returncode==0:report.update(json.loads(stdout));passed=report.get('passed') is True
        for case in report.get('cases',[]):
            original=Path(case['log']);target=retained/(case['case']+'.log');shutil.copy2(original,target);case['retainedLog']=str(target);assert sha(target)==case['logSHA256']
        after={str(p):sha(p) for p in immutable};report.update(productionModuleHashesAfter=after,immutableInputsUnchanged=before==after)
        if before!=after:passed=False;report['passed']=False
        if not passed:raise RuntimeError('Production policy E2E failed; inspect retained external log')
    except Exception as error:
        report['error']=type(error).__name__+': '+str(error);raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        if sampler is not None and sampler.poll() is None:
            sampler.terminate()
            try:sampler.wait(timeout=3)
            except subprocess.TimeoutExpired:sampler.kill();sampler.wait()
        for source in (scratch/'data/Logs').glob('*.log'):shutil.copy2(source,retained/source.name)
        for name in ['telemetry.json','progress.json','harness-stack.sample.txt','cleanup.json']:
            if (scratch/name).is_file():shutil.copy2(scratch/name,retained/name)
        report.update(minimumWorkFreeBytes=min_work,minimumPrimaryFreeBytes=min_primary,elapsedSeconds=round(time.monotonic()-started,3),retained=str(retained))
        write_json(retained/'report.json',report)
        summary={k:v for k,v in report.items() if k not in ['productionModuleHashesBefore','productionModuleHashesAfter','cases']};summary['retainedReport']=str(retained/'report.json');summary['retainedReportSHA256']=sha(retained/'report.json');summary['completedCases']=[c['case'] for c in report.get('cases',[])]
        if 'cases' in report:summary['cases']=report['cases']
        try:small_summary(ROOT/'Evidence/controller-policy-e2e.json',summary)
        finally:cleanup(scratch,servers,remove=not args.keep)
    print(json.dumps({'passed':passed,'completedCases':[c['case'] for c in report.get('cases',[])],'retainedReport':str(retained/'report.json')}))
if __name__=='__main__':main()
