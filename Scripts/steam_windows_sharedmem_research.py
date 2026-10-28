#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline, isolated, two-process genuine Windows Steam IPC experiment.

Private Windows named shared-memory/event IPC, not the native Mac TCP backend.
No credentials, authentication, ownership emulation, UI/client EXE, or game launch.
"""
import hashlib,json,os,shutil,subprocess,time,uuid
from pathlib import Path
from steam_windows_factory_research import ROOT,WORK,RESEARCH,sha,ps

def records(path):
    items=[]
    if path.exists():
        for line in path.read_text().splitlines():
            try:items.append(json.loads(line))
            except ValueError:pass
    return items

def merged(items):
    result={}
    for item in items:
        if item.get('stage') in ('factory-ready','client-connect-offline','factory-user-offline'):result.update(item)
    return result

def main():
    assert (WORK/'.ready-external-workspace').is_file() and not (WORK/'.ready-external-workspace').is_symlink()
    auth=json.loads((RESEARCH/'authenticode-verification.json').read_text());assert auth['allVerified'] and len(auth['files'])==6
    for item in auth['files']:assert item['returncode']==0 and sha(item['file'])==item['sha256']
    index=json.loads((RESEARCH/'current-factory-build.json').read_text());receipt=Path(index['buildReceipt']);assert sha(receipt)==index['buildReceiptSHA256'];build=json.loads(receipt.read_text())
    for path,digest in build['artifacts'].items():assert sha(path)==digest
    cfg=json.loads((ROOT/'Runtime/runtime.json').read_text());wine=Path(cfg['wineBinary']);server=Path(cfg['wineServer']);wine_root=wine.parent.parent;base=Path(cfg['immutableRuntimeSet'])
    run=RESEARCH/('sharedmem-run-'+uuid.uuid4().hex);run.mkdir(mode=0o700);(run/'.owned-windows-sharedmem-run').write_text('No account, token or existing client; only synthetic prefixes\n')
    sources={}
    for name in ['steam_windows_sharedmem_research.py','steam_windows_factory_research.py','steam_windows_factory_probe.c','steam_windows_build_factory_probe.py','steam_windows_sandbox_controls.c']:
        out=run/'source-snapshot'/name;out.parent.mkdir(exist_ok=True);shutil.copy2(ROOT/'Scripts'/name,out);sources[name]=sha(out)
    watched=[ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json',wine,server,*map(Path,build['artifacts']),*[Path(x['file']) for x in auth['files']]];before={str(p):sha(p) for p in watched};baseline=[r for r in ps() if 'steam' in Path(r['executable']).name.lower()]
    report={'schema':1,'scope':'Windows PE32/64 two-process named shared-memory/event IPC under IP deny','transport':'Windows named shared-memory/events via isolated Wine server','passed':False,'authenticationAttempted':False,'credentialsRead':False,'closedHelperExecuted':False,'gameLaunchAttempted':False,'genuineAuthenticatedHostVerified':False,'workingTCPIPCVerified':False,'sourceHashes':sources,'buildReceipt':str(receipt),'buildReceiptSHA256':sha(receipt),'authenticodeReceiptSHA256':sha(RESEARCH/'authenticode-verification.json'),'beforeHashes':before,'baselineSteamProcesses':baseline,'prefixes':{},'tests':[]}
    native=next(Path(p) for p in build['artifacts'] if Path(p).name=='ready-steam-sandbox-controls');contexts=[];children=[]
    def context(label):
        prefix=run/('prefix-'+label);prefix.mkdir(mode=0o700);st=prefix.stat();ipc=Path('/private/tmp')/('.wine-'+str(os.getuid()))/('server-'+format(st.st_dev,'x')+'-'+format(st.st_ino,'x'));ipc.parent.mkdir(mode=0o700,exist_ok=True);assert not ipc.exists();ipc.mkdir(mode=0o700)
        tmp=prefix/'tmp';tmp.mkdir();deny=[Path('/Users'),Path('/Volumes'),Path('/private/var/root'),Path('/Library/Keychains'),Path('/private/var/folders'),Path('/private/tmp'),Path('/tmp'),Path('/opt/homebrew'),Path('/usr/local')]
        reads=[prefix,ipc,wine_root,base/'dependency-root',base/'vulkan'];files=[*[Path(x['file']) for x in auth['files']],*map(Path,build['artifacts'])];executables=[wine,server,wine_root/'lib/wine/x86_64-unix/wine',native]
        filters=lambda kind,paths:' '.join('('+kind+' '+json.dumps(str(p))+')' for p in paths)
        policy='(version 1)\n(allow default)\n(deny network*)\n(deny appleevent-send)\n(deny file-read* '+filters('subpath',deny)+')\n(allow file-read* '+filters('subpath',reads)+' '+filters('literal',files)+')\n(allow file-read-metadata)\n(deny file-write*)\n(allow file-write* '+filters('subpath',[prefix,ipc])+' (literal "/dev/null"))\n(deny process-exec)\n(allow process-exec '+filters('literal',executables)+')\n'
        socket=json.dumps(str(ipc/'socket'));policy+='(allow network-bind network-inbound network-outbound (local unix-socket (path-literal '+socket+')) (remote unix-socket (path-literal '+socket+')))\n'
        sb=run/('offline-'+label+'.sb');sb.write_text(policy)
        env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_','VK_','CX_')) and not k.lower().startswith('steam')};env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d;steamclient,steamclient64=n',TMPDIR=str(tmp)+'/',XDG_CACHE_HOME=str(prefix/'cache'))
        result={'prefix':prefix,'ipc':ipc,'sandbox':sb,'env':env,'label':label};contexts.append(result);report['prefixes'][label]={'path':str(prefix),'IPC':str(ipc),'sandboxSHA256':sha(sb)};return result
    def start(ctx,label,args,event=None,namespace=None):
        env=dict(ctx['env']);env['WINEDEBUG']='-all,+sync,+virtual' if namespace else '-all'
        if namespace:env['steam_master_ipc_name_override']=namespace
        if event:env['READY_STEAM_WINDOWS_EVENT_FILE']='Z:'+str(event).replace('/','\\')
        out=(run/(label+'.stdout')).open('w');err=(run/(label+'.stderr')).open('w');p=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(ctx['sandbox']),*map(str,args)],env=env,cwd=ctx['prefix'],stdout=out,stderr=err);children.append((p,out,err));return p
    def finish(p,label,timeout):
        began=time.monotonic();timed=False
        try:code=p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:p.kill();code=p.wait(timeout=10);timed=True
        return {'returncode':code,'timedOut':timed,'waitSeconds':round(time.monotonic()-began,3),'stdout':str(run/(label+'.stdout')),'stderr':str(run/(label+'.stderr'))}
    def stop(ctx,label):
        a=subprocess.run([str(server),'-k'],env=ctx['env'],capture_output=True,text=True,timeout=10);b=subprocess.run([str(server),'-w'],env=ctx['env'],capture_output=True,text=True,timeout=20);report.setdefault('exactServerStops',[]).append({'prefix':ctx['label'],'stage':label,'killReturncode':a.returncode,'waitReturncode':b.returncode,'stderr':a.stderr+b.stderr});assert a.returncode in (0,1) and b.returncode==0 and not b.stderr
    def event_copy(event,label):
        dst=run/(label+'.events.jsonl')
        if event.exists():shutil.copy2(event,dst);dst.chmod(0o600)
        return {'path':str(dst),'sha256':sha(dst) if dst.exists() else None,'records':records(dst)}
    try:
        a=context('principal');b=context('other-profile')
        sentinel=run/'denied-read';sentinel.write_text('Owned sandbox control; not readable by guest\n')
        for ctx in [a,b]:
            control=run/('denied-write-'+ctx['label']);p=start(ctx,'controls-'+ctx['label'],[native,sentinel,control]);result=finish(p,'controls-'+ctx['label'],10);result['observation']=json.loads(Path(result['stdout']).read_text());assert result['returncode']==0 and result['observation']['allDenied'] and not control.exists();report.setdefault('sandboxControls',[]).append(result)
            wow=ctx['prefix']/'drive_c/windows/syswow64';wow.mkdir(parents=True);shutil.copytree(Path(cfg['builtin32Directory']),wow,dirs_exist_ok=True,symlinks=True)
            p=start(ctx,'boot-'+ctx['label'],[wine,'wineboot','-u']);result=finish(p,'boot-'+ctx['label'],180);report.setdefault('boots',[]).append(result);stop(ctx,'boot');assert result['returncode']==0
        for bits in [64,32]:
            namespace='ReadyWin-'+uuid.uuid4().hex[:24];wrong='ReadyNo-'+uuid.uuid4().hex[:24]
            program=next(Path(p) for p in build['artifacts'] if Path(p).name=='ready-steam-factory'+str(bits)+'.exe');client=RESEARCH/('valve-client'+str(bits))/('steamclient64.dll' if bits==64 else 'steamclient.dll')
            for ctx in [a,b]:ctx['env']['READY_STEAM_WINDOWS_CLIENT_DLL']='Z:'+str(client).replace('/','\\')
            release=a['prefix']/('release-host-'+str(bits));a['env']['READY_STEAM_WINDOWS_RELEASE_FILE']='Z:'+str(release).replace('/','\\');host_event=a['prefix']/('host-'+str(bits)+'.jsonl');host_label='host-'+str(bits);host=start(a,host_label,[wine,program,'--serve-user'],host_event,namespace);began=time.monotonic()
            while not any(x.get('stage')=='user-create-returned' and x.get('userHandle',0)>0 for x in records(host_event)):
                if host.poll() is not None or time.monotonic()-began>30:raise RuntimeError('Private host did not establish a disconnected user')
                time.sleep(0.05)
            host_user=next(x['userHandle'] for x in records(host_event) if x.get('stage')=='user-create-returned');case={'bits':bits,'namespace':namespace,'hostUser':host_user,'clients':[]};report['tests'].append(case)
            for kind,ctx,ns,want in [('positive',a,namespace,True),('other-namespace',a,wrong,False),('other-prefix',b,namespace,False),('positive-after-negatives',a,namespace,True)]:
                assert host.poll() is None;label='client-'+str(bits)+'-'+kind;event=ctx['prefix']/(label+'.jsonl');p=start(ctx,label,[wine,program,'--connect-user'],event,ns);result=finish(p,label,25);bound=event_copy(event,label);observation=merged(bound['records']);result.update(kind=kind,prefix=ctx['label'],namespace=ns,event=bound,observation=observation,expectedConnected=want,hostStayedAlive=host.poll() is None);case['clients'].append(result)
                result['passed']=result['returncode']==0 and not result['timedOut'] and result['hostStayedAlive'] and observation.get('connectedUser') is want and (not want or observation.get('userHandle')==host_user) and (observation.get('pipeReleaseSucceeded') or observation.get('pipeHandle')==0) and not observation.get('steamUILoaded') and observation.get('visibleWindowsAfter')==0
            release.write_text('Release only this synthetic host\n');host_result=finish(host,host_label,25);host_bound=event_copy(host_event,host_label);host_observation=merged(host_bound['records']);case['host']={**host_result,'event':host_bound,'observation':host_observation};case['passed']=all(c['passed'] for c in case['clients']) and host_result['returncode']==0 and host_observation.get('releaseSignalReceived') and host_observation.get('pipeReleaseSucceeded') and not host_observation.get('steamUILoaded') and host_observation.get('visibleWindowsAfter')==0 and host_observation.get('visibleWindowsPeakDuringHostWait')==0
            for ctx in [a,b]:stop(ctx,'architecture-complete')
        report['passed']=len(report['tests'])==2 and all(x['passed'] for x in report['tests'])
    except Exception as error:report['error']=type(error).__name__+': '+str(error)
    finally:
        for p,out,err in children:
            if p.poll() is None:p.kill();p.wait(timeout=10)
            out.close();err.close()
        stopped=True
        for ctx in contexts:
            try:stop(ctx,'final-cleanup')
            except Exception as error:stopped=False;report.setdefault('cleanupErrors',[]).append(str(error))
        report['exactPrefixesStopped']=stopped
        # Preserve even partial private events before removing only our marked scratch.
        for ctx in contexts:
            for event in ctx['prefix'].glob('*.jsonl'):event_copy(event,'retained-'+ctx['label']+'-'+event.stem)
            if stopped:shutil.rmtree(ctx['prefix']);shutil.rmtree(ctx['ipc'],ignore_errors=True)
        report['prefixesAndIPCRemoved']=all(not c['prefix'].exists() and not c['ipc'].exists() for c in contexts);report['afterHashes']={str(p):sha(p) for p in watched};report['immutableInputsUnchanged']=before==report['afterHashes'];report['SteamProcessesAfter']=[r for r in ps() if 'steam' in Path(r['executable']).name.lower()];report['existingSteamProcessesUnchanged']=baseline==report['SteamProcessesAfter'];report['passed']=report['passed'] and report['immutableInputsUnchanged'] and report['existingSteamProcessesUnchanged'] and stopped
        report['namedObjectTraceLines']={}
        for log in run.glob('*.stderr'):
            lines=[x for x in log.read_text(errors='replace').splitlines() if ('ReadyWin-' in x or 'ReadyNo-' in x)];report['namedObjectTraceLines'][log.name]={'count':len(lines),'sample':lines[:20]}
        report['evidenceFileHashes']={str(p.relative_to(run)):sha(p) for p in run.rglob('*') if p.is_file()};path=run/'report.json';path.write_text(json.dumps(report,indent=2)+'\n');summary={'scope':report['scope'],'passed':report['passed'],'retainedReport':str(path),'retainedReportSHA256':sha(path),'authenticationAttempted':False,'genuineAuthenticatedHostVerified':False,'workingTCPIPCVerified':False};(ROOT/'Evidence/steam-windows-sharedmem.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
