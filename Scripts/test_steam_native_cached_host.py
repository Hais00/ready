#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Try Valve's own cached login using a copy of our approved private test state.

No QR, plaintext token recovery, normal Steam state or ownership emulation. The
structural frame sentinel is consumed ONLY by --cached-login, which never calls
SetLoginToken/SetLoginInformation. Actual Valve logon/identity/subscription decide.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
import uuid

sys.dont_write_bytecode=True
from test_steam_native_host import ROOT,WORK,LiveStatus,sha,save,processes
from steam_private_cache_loader import load_private_cached_login

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True)
    p.add_argument('--state-fs-shim',type=Path,required=True)
    p.add_argument('--ipc-shim',type=Path,required=True)
    p.add_argument('--live-ui',type=Path,required=True)
    p.add_argument('--reference-report',type=Path)
    p.add_argument('--game-api-probe',type=Path)
    p.add_argument('--game-api-library',type=Path)
    a=p.parse_args()
    if bool(a.game_api_probe)!=bool(a.game_api_library):raise ValueError('Provide both game SDK and owned probe')
    if processes():raise RuntimeError('Close the existing full Steam client before the independence test')
    library=a.library.resolve(strict=True)
    if sha(library)!='b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd':raise ValueError('Unverified native image')
    cancel=threading.Event();stop=threading.Event()
    context=load_private_cached_login(cancel=cancel,reference_report=a.reference_report)if a.reference_report else load_private_cached_login(cancel=cancel)
    preparation=[sys.executable,str(ROOT/'Scripts/test_steam_native_host.py'),'--library',str(library),'--architecture','arm64','--interface','CLIENTENGINE_INTERFACE_VERSION005','--create-user','--local-ipc','--state-fs-shim',str(a.state_fs_shim),'--ipc-shim',str(a.ipc_shim),'--prepare-auth','--app-id','1091500']
    prepared=subprocess.run(preparation,cwd=ROOT,capture_output=True,text=True,check=True,timeout=25)
    summary=json.loads(prepared.stdout.strip().splitlines()[-1]);run=Path(summary['report']).parent
    if not summary['publicNetworkSmokePassed']:raise RuntimeError('Public networking preparation failed; cached frame not delivered')
    record=json.loads((run/'auth-preparation.json').read_text())
    worker=run/'ready-steam-native-probe'
    if sha(worker)!=record['executableSHA256']:raise ValueError('Prepared worker changed')
    cache=Path(context.safe['cacheRoot'])
    # Retain the source state, including its original logs, byte-for-byte.
    # Only our new copied state will be writable by the genuine client.
    file_hashes=[]
    for item in cache.rglob('*'):
        info=item.lstat()
        if info.st_uid!=os.getuid()or not(stat.S_ISDIR(info.st_mode)or stat.S_ISREG(info.st_mode)):raise ValueError('Private cache tree contains an alias or special object')
        if item.is_file():file_hashes.append(sha(item))
    shutil.copytree(cache,run/'state',dirs_exist_ok=True,copy_function=shutil.copy2)
    (run/'state').chmod(0o700)
    copied_hashes=sorted(sha(x)for x in (run/'state').rglob('*')if x.is_file())
    if sorted(file_hashes)!=copied_hashes:raise ValueError('Private state copy mismatch')
    profile=(run/'offline.sb').read_text()
    ports=list(dict.fromkeys(re.findall(r'localhost:(\d+)',profile)))
    prefix=re.search(r'\^/RS([a-f0-9]{16})_',profile)
    if len(ports)!=2 or not prefix:raise ValueError('Prepared IPC policy is not recognized')
    namespace=prefix[1]+uuid.uuid4().hex[16:]
    bundle=next(x for x in library.parents if x.name=='Steam.AppBundle')
    env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','STEAM','Steam','SB_','M1L_','READY_'))}
    env.update(TMPDIR=str(run/'tmp')+'/',XDG_CACHE_HOME=str(run/'state'),READY_STEAM_STATE_FS_LIBRARY=str(a.state_fs_shim.resolve()),READY_STEAM_IPC_LIBRARY=str(a.ipc_shim.resolve()),READY_STEAM_IPC_NAMESPACE=namespace,READY_STEAM_ORIGINAL_STATE_ROOT=str(bundle.parent),READY_STEAM_PRIVATE_STATE_ROOT=str(run/'state/client'),steam_master_ipc_name_override='127.0.0.1:'+ports[0],SteamClientService='127.0.0.1:'+ports[1])
    live=LiveStatus(run);live.write('starting','Verifica dell’accesso privato già approvato. Nessun nuovo QR richiesto.')
    frontend=a.live_ui.resolve(strict=True)
    if frontend.stat().st_uid!=os.getuid()or not frontend.is_relative_to(WORK):raise ValueError('Owned diagnostic frontend required')
    with(run/'frontend-stdout.log').open('w')as out,(run/'frontend-stderr.log').open('w')as err:
        ui=subprocess.Popen([str(frontend),'--data-root',str(run/'frontend-data'),'--steam-auth-status',str(live.path)],cwd=run,env=dict(env,READY_RUNTIME_ROOT=str(ROOT/'Runtime')),stdin=subprocess.DEVNULL,stdout=out,stderr=err)
    threading.Thread(target=live.watch_cancel,args=(cancel,stop,ui),daemon=True).start()
    deadline=time.monotonic()+12;ready=False
    while ui.poll()is None and time.monotonic()<deadline:
        try:
            value=json.loads((run/'live-ui-ready.json').read_text())
            if value=={'schema':1,'generation':live.generation,'pid':ui.pid}:ready=True;break
        except(FileNotFoundError,ValueError):pass
        time.sleep(.1)
    if not ready:context.handoff.clear();raise RuntimeError('Diagnostic frontend was not ready')
    print(json.dumps({'type':'cached_native_attempt','status':str(live.path),'newQRRequired':False}),flush=True)
    live.write('starting_native','Riutilizzo della cache privata tramite le API autentiche Steam…')
    event=run/'cached-events.jsonl';event.touch(mode=0o600)
    env['READY_STEAM_EVENT_FILE']=str(event)
    command=['/usr/bin/sandbox-exec','-f',str(run/'offline.sb'),str(worker),str(library),'CLIENTENGINE_INTERFACE_VERSION005','--create-user','--cached-login']
    private_discovery=None;lookup_adapter=None
    if a.game_api_probe:
        discovery_dir=WORK/'retained/research-steam-native/discovery-mock-67fb9ff8f143403ea8984840c4c40084'
        discovery=discovery_dir/'production.dylib';lookup_adapter=discovery_dir/'redirect.dylib'
        if sha(discovery)!='1ee14f5a41aa46aa7e30549840c9ad903bfa129dd6391ed114d3c6040233a366'or sha(lookup_adapter)!='7b1cd27872af639c2221e5af4dbef7e3a940bfd4093bdbbde579747e59039a26':raise ValueError('Unverified private metadata adapters')
        private_discovery='app.ready.steam.ipctool.'+namespace
        env.update(READY_STEAM_PROBE_HOLD_MS='10000',READY_STEAM_DISCOVERY_LIBRARY=str(discovery),READY_STEAM_DISCOVERY_SERVICE=private_discovery,READY_STEAM_DISCOVERY_SDK=str(a.game_api_library.resolve()))
        host_policy=run/'cached-host-discovery.sb'
        host_policy.write_text(profile+'\n(allow mach-register (global-name '+json.dumps(private_discovery)+'))\n(allow mach-lookup (global-name '+json.dumps(private_discovery)+'))\n(allow file-read* (literal '+json.dumps(str(discovery))+'))\n')
        host_policy.chmod(0o600);command[command.index(str(run/'offline.sb'))]=str(host_policy)
    before=processes();cancelled=False;timed_out=False
    sdk_result=None
    with(run/'cached-stdout.log').open('w')as out,(run/'cached-stderr.log').open('w')as err:
        child=subprocess.Popen(command,cwd=run,env=env,stdin=subprocess.PIPE,stdout=out,stderr=err)
        try:
            context.handoff.write_to(child.stdin,cancel=cancel)
            deadline=time.monotonic()+45
            while child.poll()is None:
                if cancel.is_set():cancelled=True;break
                if time.monotonic()>=deadline:timed_out=True;break
                if a.game_api_probe and sdk_result is None:
                    host_ready=False;discovery_ready=False
                    for line in event.read_text().splitlines():
                        try:item=json.loads(line)
                        except ValueError:continue
                        if item.get('authenticatedIdentityMatches')is True and item.get('genuineSubscriptionObserved')is True:host_ready=True
                        if item.get('privateMachDiscoveryStarted')is True:discovery_ready=True
                    if host_ready and discovery_ready:
                        sdk=a.game_api_library.resolve(strict=True);probe=a.game_api_probe.resolve(strict=True)
                        if sha(sdk)!='2cbe2533e09d1561051f417d7b8c784481a2efdc4fc9d1274704ee8a7ef50cb1'or not probe.is_relative_to(WORK)or probe.stat().st_uid!=os.getuid():raise ValueError('Unverified game SDK or unowned child')
                        own_child=run/'ready-native-game-api-probe';shutil.copy2(probe,own_child)
                        child_policy=run/'game-api-child.sb'
                        child_policy.write_text(profile+'\n(allow process-exec (literal "/usr/bin/env") (literal '+json.dumps(str(own_child))+'))\n(allow mach-lookup (global-name '+json.dumps(private_discovery)+'))\n(allow file-read* (literal '+json.dumps(str(lookup_adapter))+'))\n')
                        child_policy.chmod(0o600)
                        reference=a.reference_report or WORK/'retained/research-steam-native/offline-arm64-f51402a25c384c81b4fd25a76b225f14/report.json'
                        expected_id=str(json.loads(reference.read_text())['steamKitAuthorization']['steamID'])
                        child_env=dict(env,SteamAppId='1091500',SteamGameId='1091500',SteamClientLaunch='1',STEAMID=expected_id,READY_STEAM_GAME_API_PROBE='1',Steam3Master=env['steam_master_ipc_name_override'])
                        argv=['/usr/bin/sandbox-exec','-f',str(child_policy),'/usr/bin/env','DYLD_PRINT_LIBRARIES=1','DYLD_LIBRARY_PATH='+str(library.parent),'DYLD_INSERT_LIBRARIES='+str(a.state_fs_shim.resolve())+':'+str(a.ipc_shim.resolve())+':'+str(lookup_adapter),str(own_child),'--allow-sdk-execution','--library',str(sdk),'--code-root',str(sdk.parent),'--expected-sha256',sha(sdk),'--mode','init-flat','--callback-ms','250']
                        live.write('starting_native','Backend autenticato. Verifica della vera API Steam del gioco…')
                        sdk_run=subprocess.run(argv,cwd=run,env=child_env,capture_output=True,text=True,timeout=12)
                        sdk_result={'exitCode':sdk_run.returncode,'events':[],'sdkSHA256':sha(sdk),'ownProbeSHA256':sha(own_child),'sandboxSHA256':sha(child_policy),'stderrBytes':len(sdk_run.stderr.encode())}
                        sdk_result['startupAdaptersObserved']={'stateFS':str(a.state_fs_shim.resolve())in sdk_run.stderr,'ipcNamespace':str(a.ipc_shim.resolve())in sdk_run.stderr,'privateMachLookup':str(lookup_adapter)in sdk_run.stderr}
                        for line in sdk_run.stdout.splitlines():
                            try:sdk_result['events'].append(json.loads(line))
                            except ValueError:pass
                        save(run/'game-api-result.json',sdk_result)
                time.sleep(.1)
        finally:
            context.handoff.clear()
            if child.poll()is None:child.kill();child.wait()
    observations=[]
    for line in event.read_text().splitlines():
        try:observations.append(json.loads(line))
        except ValueError:pass
    authenticated=any(x.get('authenticated')is True for x in observations)
    subscribed=any(x.get('genuineSubscriptionObserved')is True for x in observations)
    after=processes()
    report={'schema':1,'kind':'genuine-native-private-cached-login','exitCode':child.returncode,'cancelled':cancelled,'timedOut':timed_out,'observations':observations,'cacheSource':context.safe,'sourceCachePreserved':sorted(file_hashes)==sorted(sha(x)for x in cache.rglob('*')if x.is_file()),'copiedStateFileCount':len(file_hashes),'librarySHA256':sha(library),'preparedWorkerSHA256':sha(worker),'cachedDriverSHA256':sha(Path(__file__)),'sandboxSHA256':sha(run/'offline.sb'),'eventsSHA256':sha(event),'priorGenuinePreflightReused':True,'freshSteamKitPreflight':False,'accountAuthenticated':authenticated,'genuineSubscriptionObserved':subscribed,'gameCompatibilityVerified':False,'SteamProcessesBefore':before,'SteamProcessesAfter':after,'existingSteamProcessesUnchanged':before==after}
    report['gameSDKProbe']=sdk_result
    save(run/'cached-report.json',report)
    if cancelled:live.write('cancelled','Verifica annullata.')
    elif authenticated and subscribed:live.write('completed','Backend nativo autenticato e licenza confermata. L’avvio del gioco resta da verificare.')
    else:live.write('failed','La cache è stata verificata; l’accesso del backend nativo richiede ancora una correzione.')
    stop.set()
    print(json.dumps({'exitCode':child.returncode,'accountAuthenticated':authenticated,'genuineSubscriptionObserved':subscribed,'newQRRequired':False,'report':str(run/'cached-report.json')}),flush=True)
    return 0 if authenticated and subscribed else 1

if __name__=='__main__':raise SystemExit(main())
