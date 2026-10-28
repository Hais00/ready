#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Production controller-policy/SessionManager E2E with an owned Vulkan fixture.

Requires fresh matching Core module/archive and the rebuilt overlay. Never builds
Wine/DXMT, changes the project configuration or copies/modifies a provider. The
app-local DLL fixture reports disconnected input; it is not a synthetic device
backend and never replaces the production controller modules.
"""
import argparse,fcntl,hashlib,json,os,shutil,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'Runtime/Probes/ControllerPolicy'
RESERVE=512*1024*1024

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def space(extra=0):
    if shutil.disk_usage(ROOT).free<RESERVE+extra:raise RuntimeError('Preserving512MiB reserve for controller policy fixture')
def run(args,**kw):return subprocess.run(list(map(str,args)),check=True,**kw)
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

def cleanup(scratch,servers,remove):
    descriptor=scratch/'cleanup.json'
    if descriptor.exists():
        values=json.loads(descriptor.read_text())
        for raw in values['prefixes']:
            prefix=Path(raw);assert prefix.is_relative_to(scratch/'data/Prefixes')
            env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))};env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all')
            for server in servers:
                subprocess.run([str(server),'-k'],env=env,capture_output=True,timeout=10)
                run([server,'-w'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
    for path in (scratch/'data/Locks').glob('*.lock'):
        with path.open('a+b') as f:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
    assert scratch.parent==ROOT/'Runtime/TestPrefixes' and (scratch/'.ready-controller-policy-test').is_file()
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
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--modules',type=Path,required=True);p.add_argument('--archive',type=Path,required=True);p.add_argument('--keep',action='store_true');p.add_argument('--compile-only',action='store_true');p.add_argument('--run-only',action='store_true',help='Verify and reuse existing binaries; never invoke a compiler');args=p.parse_args()
    space(64*1024*1024)
    # Caller supplies the already refreshed matching product. No implicit SwiftPM rebuild.
    module=args.modules/'LauncherCore.swiftmodule';importable=list(module.glob('*.swiftmodule')) if module.is_dir() else [module]
    assert args.archive.is_file() and all(x.is_file() for x in importable)
    assert args.archive.stat().st_mtime_ns>=max(x.stat().st_mtime_ns for x in importable),'Refusing stale Core archive/module pair'
    build_receipt=ROOT/'Evidence/controller-policy-e2e-build.json'
    if args.run_only:
        build=json.loads(build_receipt.read_text());snapshot=build['compileDriverSnapshot']
        if sha(ROOT/snapshot['path'])!=snapshot['sha256'] or snapshot['sha256']!=build['sources']['Scripts/test_controller_policy_e2e.py']:raise RuntimeError('Original compile-driver snapshot differs')
        for name,expected in build['sources'].items():
            if name!='Scripts/test_controller_policy_e2e.py' and sha(ROOT/name)!=expected:raise RuntimeError('Compiled source input changed: '+name)
        if sha(args.archive)!=build['coreArchiveSHA256'] or {str(x):sha(x) for x in importable}!=build['coreModuleHashes']:raise RuntimeError('Core snapshot differs from compiled harness inputs')
        exe=OUTPUT/'controller-policy.exe';private=OUTPUT/'private-xinput1_4.dll';dxmt_exe=OUTPUT/'controller-policy-dxmt.exe';harness=ROOT/'Build/ReadyControllerPolicyProbe'
        for path,key in [(exe,'windowsProbeSHA256'),(private,'privateAppDLLFixtureSHA256'),(dxmt_exe,'dxmtWindowsProbeSHA256'),(harness,'harnessSHA256')]:
            if sha(path)!=build[key]:raise RuntimeError('Existing binary hash differs: '+str(path))
        # The compiler driver above is retained verbatim. This separately records
        # the orchestration revision; no executable/source compilation is claimed.
        build['runOnlyDriver']={'path':str(Path(__file__).relative_to(ROOT)),'sha256':sha(__file__),'compilersInvoked':False}
        build_receipt.write_text(json.dumps(build,indent=2)+'\n')
        if args.compile_only:print(json.dumps(build,indent=2));return
    else:
        exe,private,dxmt_exe,commands=build_windows();harness=ROOT/'Build/ReadyControllerPolicyProbe'
        command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',str(args.modules),str(ROOT/'Sources/M1Launcher/SessionManager.swift'),str(ROOT/'Synthetic/ReadyControllerPolicyProbe.swift'),str(args.archive),'-framework','AppKit','-o',str(harness)];run(command);commands.append(command)
        source_paths=[Path(__file__),ROOT/'Synthetic/ReadyControllerPolicyProbe.swift',ROOT/'Sources/M1Launcher/SessionManager.swift',ROOT/'Sources/LauncherCore/ControllerInputPolicy.swift',ROOT/'Scripts/runtime_controller_policy_windows_probe.c',ROOT/'Scripts/runtime_controller_private_xinput_fixture.c',ROOT/'Scripts/runtime_vulkan_present.c',ROOT/'Scripts/runtime_d3d11_present.c']
        build={'commands':commands,'sources':{str(x.relative_to(ROOT)):sha(x) for x in source_paths},'coreArchiveSHA256':sha(args.archive),'coreModuleHashes':{str(x):sha(x) for x in importable},'harnessSHA256':sha(harness),'windowsProbeSHA256':sha(exe),'privateAppDLLFixtureSHA256':sha(private),'dxmtWindowsProbeSHA256':sha(dxmt_exe),'testControllerDeviceBackendUsed':False,'privateDisconnectedAppDLLFixture':True};snapshots=ROOT/'Build/ControllerPolicyE2EInputs';snapshots.mkdir(exist_ok=True);snapshot=snapshots/('compile-driver-'+sha(__file__)+'.py');snapshot.write_bytes(Path(__file__).read_bytes());build['compileDriverSnapshot']={'path':str(snapshot.relative_to(ROOT)),'sha256':sha(snapshot)};(ROOT/'Evidence/controller-policy-e2e-build.json').write_text(json.dumps(build,indent=2)+'\n')
        if args.compile_only:print(json.dumps(build,indent=2));return
    space(192*1024*1024)
    candidate=ROOT/'Runtime/candidate-xinput-v2.json';cfg=json.loads(candidate.read_text());cap=cfg['overlayInputCapture'];provider=cap['providers']['base'];wine_root=Path(provider['wineRoot']);server=Path(cfg['wineServer']);servers=sorted({server,*map(Path,cfg.get('engineWineServers',{}).values())});overlay=ROOT/'Build/libReadyOverlay.dylib'
    immutable=[ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json',candidate,Path(cap['manifestPath']),overlay]
    for item in cap['providers'].values():
        root=Path(item['wineRoot']);immutable.extend([root/'bin/wine',root/'bin/ready-wine',root/'bin/wineserver',*[root/'lib/wine'/key for key in item['payloadHashes']]])
    dxmt_root=Path(cap['providers']['dxmt']['wineRoot']);immutable.extend([dxmt_root/'lib/wine/x86_64-unix/winemetal.so',dxmt_root/'lib/wine/x86_64-unix/winemac.so'])
    before={str(x):sha(x) for x in immutable}
    scratch=ROOT/'Runtime/TestPrefixes'/('controller-policy-'+uuid.uuid4().hex);scratch.mkdir();(scratch/'.ready-controller-policy-test').write_text('Owned production-provider controller policy fixture\n');game=scratch/'game';game.mkdir();shutil.copy2(exe,game/exe.name);game_dxmt=scratch/'game-dxmt';game_dxmt.mkdir();shutil.copy2(dxmt_exe,game_dxmt/dxmt_exe.name);passed=False;process=None
    try:
        env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))}
        process=subprocess.Popen([str(harness),str(ROOT),str(scratch),str(candidate),str(game/exe.name),str(private),str(game_dxmt/dxmt_exe.name)],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        started=time.monotonic();deadline=started+420;timeline=[];minimum_free=shutil.disk_usage(ROOT).free;sampler=None;sampled=False
        while True:
            try:stdout,stderr=process.communicate(timeout=1);break
            except subprocess.TimeoutExpired:
                free=shutil.disk_usage(ROOT).free;minimum_free=min(minimum_free,free);elapsed=time.monotonic()-started;phase=phase_snapshot(scratch,process.pid)
                point={'elapsedSeconds':round(elapsed,3),'freeBytes':free,'minimumFreeBytes':minimum_free,**phase};timeline.append(point)
                if not sampled and elapsed>=4 and phase['phase']=='unresolved-prelaunch' and free>=RESERVE+64*1024*1024:
                    sampled=True;sample_file=scratch/'harness-stack.sample.txt'
                    try:sampler=subprocess.Popen(['/usr/bin/sample',str(process.pid),'1','10','-file',str(sample_file)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    except OSError:sampler=None
                sample_file=scratch/'harness-stack.sample.txt'
                if sample_file.is_file():
                    text=sample_file.read_text(errors='replace')
                    if 'WindowsBuiltinBootstrap' in text:point.update(phase='WindowsBuiltinBootstrap',phaseEvidence='actual harness sampled stack')
                (scratch/'telemetry.json').write_text(json.dumps({'timeline':timeline,'elapsedSeconds':round(elapsed,3),'minimumFreeBytes':minimum_free},indent=2)+'\n')
                if time.monotonic()>deadline or free<RESERVE:
                    reason='disk-reserve' if free<RESERVE else 'watchdog-420-seconds'
                    guard={'reason':reason,'elapsedSeconds':round(elapsed,3),'freeBytes':free,'reserveBytes':RESERVE,'minimumFreeBytes':minimum_free,'phase':point,'softwareFailure':False,'prefixCreated':True}
                    (ROOT/'Evidence/controller-policy-e2e-guard.json').write_text(json.dumps(guard,indent=2)+'\n')
                    process.terminate();raise RuntimeError('Controller policy fixture stopped: '+reason+' after '+str(round(elapsed,3))+' seconds')
        (ROOT/'Evidence/controller-policy-e2e.log').write_text(stdout+'\n'+stderr)
        report={'returncode':process.returncode,'candidateSHA256':sha(candidate),'overlaySHA256':sha(overlay),'productionModuleHashesBefore':before,'productionControllerDLLsUsed':True,'testControllerDeviceBackendUsed':False,'physicalControllerVerified':False,'defaultModified':False,'passed':False,'buildReceiptSHA256':sha(build_receipt),'runOnlyDriver':build.get('runOnlyDriver')}
        if process.returncode==0:report.update(json.loads(stdout));passed=report.get('passed') is True
        # Preserve each private session log before cleanup, with its original receipt hash.
        for case in report.get('cases',[]):
            original=Path(case['log']);target=ROOT/'Evidence'/('controller-policy-e2e-'+case['case']+'.log');shutil.copy2(original,target);case['retainedLog']=str(target.relative_to(ROOT));assert sha(target)==case['logSHA256']
        after={str(x):sha(x) for x in immutable};report['productionModuleHashesAfter']=after;report['immutableInputsUnchanged']=before==after
        if before!=after:passed=False;report['passed']=False
        (ROOT/'Evidence/controller-policy-e2e.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
        if not passed:raise RuntimeError('Production controller-policy E2E failed; inspect private log')
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        if 'sampler' in locals() and sampler is not None and sampler.poll() is None:
            sampler.terminate()
            try:sampler.wait(timeout=3)
            except subprocess.TimeoutExpired:sampler.kill();sampler.wait()
        # Retain private logs even if a stage fails, then free the stopped owned prefix.
        for source in (scratch/'data/Logs').glob('*.log'):
            target=ROOT/'Evidence'/('controller-policy-e2e-retained-'+source.name);shutil.copy2(source,target)
        if (scratch/'telemetry.json').is_file():shutil.copy2(scratch/'telemetry.json',ROOT/'Evidence/controller-policy-e2e-telemetry.json')
        if (scratch/'harness-stack.sample.txt').is_file():shutil.copy2(scratch/'harness-stack.sample.txt',ROOT/'Evidence/controller-policy-e2e-harness-stack.sample.txt')
        if (scratch/'progress.json').is_file():shutil.copy2(scratch/'progress.json',ROOT/'Evidence/controller-policy-e2e-partial.json')
        cleanup(scratch,servers,remove=not args.keep)
if __name__=='__main__':main()
