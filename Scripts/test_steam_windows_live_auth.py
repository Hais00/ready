#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""One QR, then automatically test prepared PE64/PE32 genuine Steam hosts.

No game launch or full Steam UI. All stages run in one bounded in-memory session
without waiting for model/tool round trips between authorizations and workers.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

sys.dont_write_bytecode=True
from test_steam_native_host import ROOT,WORK,LiveStatus,save,sha,processes
from steam_headless_auth_broker import beginQR,BrokerError
from steam_windows_authenticated_host import load_prepared,run_with_authorized_context

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared',type=Path,action='append',required=True)
    parser.add_argument('--live-ui',type=Path,required=True)
    args=parser.parse_args()
    if processes():raise RuntimeError('Full Steam client is open; no process was stopped')
    states=[load_prepared(path)for path in args.prepared]
    if len(states)>2 or len({x['appID']for x in states})!=1:raise ValueError('One game and at most two prepared architectures required')
    app_id=states[0]['appID']
    root=WORK/'retained/windows-live-auth';root.mkdir(mode=0o700,exist_ok=True)
    run=root/('session-'+uuid.uuid4().hex);run.mkdir(mode=0o700)
    helper=WORK/'build/steam-ownership-88k0vbem/output/ReadySteamBridge.dll'
    host=helper.parent.parent/'dotnet/dotnet'
    if sha(helper)!='f127cc65ee2aca9703584e21967a6742dacbcd354ed666eae73a402b4cb05698'or sha(helper.parent/'SteamKit2.dll')!='32aab21e6a6faa11bf6844e5d72ed8ccc7d3155c8b59079b7ba0286d4f81f272':raise ValueError('Pinned source-fixed helper closure required')
    cancel=threading.Event();stop=threading.Event();live=LiveStatus(run)
    live.write('starting','Preparazione delle verifiche Windows. Un solo accesso per entrambe le architetture.')
    frontend=args.live_ui.resolve(strict=True)
    if not frontend.is_relative_to(WORK)or frontend.stat().st_uid!=os.getuid():raise ValueError('Owned frontend required')
    environment={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','STEAM','Steam','SB_','M1L_','READY_'))}
    with(run/'frontend-stdout.log').open('w')as out,(run/'frontend-stderr.log').open('w')as err:
        ui=subprocess.Popen([str(frontend),'--data-root',str(run/'frontend-data'),'--steam-auth-status',str(live.path)],cwd=run,env=dict(environment,READY_RUNTIME_ROOT=str(ROOT/'Runtime')),stdin=subprocess.DEVNULL,stdout=out,stderr=err)
    threading.Thread(target=live.watch_cancel,args=(cancel,stop,ui),daemon=True).start()
    deadline=time.monotonic()+12;ready=False
    while ui.poll()is None and time.monotonic()<deadline:
        try:
            ack=json.loads((run/'live-ui-ready.json').read_text())
            if ack=={'schema':1,'generation':live.generation,'pid':ui.pid}:ready=True;break
        except(FileNotFoundError,ValueError):pass
        time.sleep(.1)
    if not ready:stop.set();raise RuntimeError('Live diagnostic card is not ready; no authentication request sent')
    images=[]
    def qr(url):
        image=run/('qr-'+str(uuid.uuid4())+'.png')
        subprocess.run(['/usr/bin/swift',str(ROOT/'Scripts/steam_auth_qr.swift'),str(image)],input=url.encode(),env=dict(environment,SWIFT_MODULECACHE_PATH=str(WORK/'cache/swift-module-cache')),capture_output=True,check=True,timeout=20)
        images.append(image);live.write('qr','Scansiona dall’app Steam. Le due verifiche partiranno automaticamente.',image.name)
        print(json.dumps({'type':'qr','liveStatus':str(live.path)}),flush=True)
    def phase(value):
        live.write(value,{'authenticating':'Richiesta di accesso Steam…','authentication_complete':'Accesso ricevuto.','authorizing_game':'Verifica della licenza…','authorized':'Licenza confermata. Avvio del controllo Windows…'}.get(value))
        if value=='authentication_complete':
            for image in images:image.unlink(missing_ok=True)
        print(json.dumps({'type':'phase','phase':value}),flush=True)
    results=[];session=None;failure=None
    try:
        session=beginQR([str(host),str(helper)],qr,cancel=cancel,onPhase=phase,ttl=600)
        expected_id=None
        for prepared,state in zip(args.prepared,states):
            context=session.authorize_game([str(host),str(helper)],app_id,onPhase=phase,expectedSteamID=expected_id)
            expected_id=context.safe.steamID
            architecture=state['architecture']
            live.write('starting_native',f'Verifica del backend Steam Windows {architecture} bit sotto Wine…')
            result=run_with_authorized_context(prepared,context,cancel=cancel)
            results.append(result)
            print(json.dumps({'type':'windows_backend_result','architecture':architecture,'authenticated':result['actualBackendAuthenticated'],'cancelled':result['cancelled']}),flush=True)
            if cancel.is_set():break
    except BrokerError as error:
        failure=error.diagnostic()
        print(json.dumps({'type':'authorization_failure','diagnostic':failure}),flush=True)
    finally:
        if session:session.close()
        stop.set()
        for image in images:image.unlink(missing_ok=True)
    passed=len(results)==len(states)and all(x['actualBackendAuthenticated']for x in results)
    report={'schema':1,'kind':'automatic-two-architecture-genuine-steam-auth','allBackendsAuthenticated':passed,'newQRFlowCount':1,'results':results,'failure':failure,'cancelled':cancel.is_set(),'gameLaunchVerified':False,'sourceSHA256':sha(Path(__file__)),'helperSHA256':sha(helper),'steamKitSHA256':sha(helper.parent/'SteamKit2.dll'),'preparationSHA256':[sha(x)for x in args.prepared]}
    save(run/'report.json',report)
    if cancel.is_set():live.write('cancelled','Prova annullata.')
    elif passed:live.write('completed','Autenticazione e licenza confermate nei backend Windows a 32 e 64 bit. Avvio dei giochi ancora da verificare.')
    else:live.write('failed','Controlli conclusi; uno dei backend Windows richiede ancora una correzione.')
    print(json.dumps({'passed':passed,'report':str(run/'report.json')}),flush=True)
    return 0 if passed else 1

if __name__=='__main__':raise SystemExit(main())
