#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline factory, lifecycle and fixed-synthetic-invalid API controls with signed Valve DLLs.

No GameNative host execution, real account/session input, or game launch;
synthetic offline API controls are explicit. No client spoofing or modification of client/game/provider binaries.
"""
import argparse,hashlib,json,os,shutil,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
RESEARCH=WORK/'retained/research-steam-windows'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def ps():
    text=subprocess.check_output(['/bin/ps','-axo','pid,ppid,comm'],text=True)
    rows=[]
    for line in text.splitlines()[1:]:
        values=line.strip().split(None,2)
        if len(values)==3:rows.append({'pid':int(values[0]),'ppid':int(values[1]),'executable':values[2]})
    return rows

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--create-user',action='store_true');parser.add_argument('--invalid-auth',action='store_true');parser.add_argument('--public-shutdown',action='store_true');args=parser.parse_args();args.create_user=args.create_user or args.invalid_auth
    assert (WORK/'.ready-external-workspace').is_file() and (RESEARCH/'.ready-steam-windows-research').is_file()
    auth=json.load(open(RESEARCH/'authenticode-verification.json'));assert auth['allVerified'] and len(auth['files'])==6
    for entry in auth['files']:
        if sha(entry['file'])!=entry['sha256'] or entry['returncode']!=0:raise RuntimeError('Unverified or changed Valve file')
    build_index=json.load(open(RESEARCH/'current-factory-build.json'));build_receipt=Path(build_index['buildReceipt']);assert sha(build_receipt)==build_index['buildReceiptSHA256'];build=json.load(open(build_receipt));control_exe=next(Path(p) for p in build['artifacts'] if Path(p).name=='ready-steam-sandbox-controls')
    for p,h in build['artifacts'].items():assert sha(p)==h
    for p,h in build['sources'].items():assert sha(ROOT/p)==h
    cfg=json.load(open(ROOT/'Runtime/runtime.json'));wine=Path(cfg['wineBinary']);server=Path(cfg['wineServer']);base=Path(cfg['immutableRuntimeSet']);wine_root=wine.parent.parent
    immutable=[ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json',wine,server,*map(Path,build['artifacts']),*[Path(x['file']) for x in auth['files']]];before={str(p):sha(p) for p in immutable}
    runroot=RESEARCH/(('invalid-auth-run-' if args.invalid_auth else 'bootstrap-run-' if args.create_user else 'factory-run-')+uuid.uuid4().hex);runroot.mkdir(mode=0o700);(runroot/'.owned-windows-factory-run').write_text('Synthetic research only; never real credentials, games or GameNative host\n');prefix=runroot/'prefix';prefix.mkdir(mode=0o700);tmp=WORK/'tmp'
    st=prefix.stat();serverdir=Path('/private/tmp')/('.wine-'+str(os.getuid()))/('server-'+format(st.st_dev,'x')+'-'+format(st.st_ino,'x'));serverdir.parent.mkdir(mode=0o700,exist_ok=True)
    if serverdir.exists():raise RuntimeError('New prefix server IPC path unexpectedly exists')
    serverdir.mkdir(mode=0o700)
    user=Path.home();steam_paths=[user/'Library/Application Support/Steam',user/'.steam',user/'.local/share/Steam',user/'Library/Caches/com.valvesoftware.Steam',user/'Library/Preferences/com.valvesoftware.steam.plist',Path('/Applications/Steam.app')]
    # Read whitelist: own isolated prefix/tmp/probe, only the selected three Valve
    # DLLs for each architecture, current Wine modules/dependencies, and OS files.
    allowed_dirs=[prefix,tmp,serverdir,wine_root,base/'dependency-root',base/'vulkan',Path('/System'),Path('/usr/lib'),Path('/usr/libexec'),Path('/usr/share'),Path('/Library/Apple'),Path('/Library/Fonts'),Path('/Library/Preferences'),Path('/private/var/db/oah'),Path('/private/var/db/timezone'),Path('/dev')]
    input_files=[Path(x['file']) for x in auth['files']]+list(map(Path,build['artifacts']))
    patterns=' '.join('(subpath '+json.dumps(str(p))+')' for p in allowed_dirs)+' '+' '.join('(literal '+json.dumps(str(p))+')' for p in input_files)
    executables=[wine,server,wine_root/'lib/wine/x86_64-unix/wine',Path('/bin/cat'),Path('/usr/bin/stat'),Path('/usr/bin/curl'),control_exe]
    execution=' '.join('(literal '+json.dumps(str(p))+')' for p in executables)
    writes=' '.join('(subpath '+json.dumps(str(p))+')' for p in [prefix,tmp,runroot,serverdir])
    denied=[Path('/Users'),Path('/Volumes'),Path('/private/var/root'),Path('/Library/Keychains'),Path('/private/var/folders'),Path('/private/tmp'),Path('/tmp'),Path('/opt/homebrew'),Path('/usr/local')]
    profile='(version 1)\n(allow default)\n(deny network*)\n(deny appleevent-send)\n'
    profile+='(deny file-read* '+' '.join('(subpath '+json.dumps(str(p))+')' for p in denied)+')\n'
    profile+='(allow file-read* '+patterns+')\n(allow file-read-metadata)\n'
    profile+='(deny file-write*)\n(allow file-write* '+writes+' (literal "/dev/null"))\n'
    profile+='(deny process-exec)\n(allow process-exec '+execution+')\n'
    profile+='(deny file-read* '+' '.join('(subpath '+json.dumps(str(p))+')' for p in steam_paths)+')\n'
    sock=str(serverdir/'socket')
    profile+='(allow network-bind network-inbound network-outbound (local unix-socket (path-literal '+json.dumps(sock)+')) (remote unix-socket (path-literal '+json.dumps(sock)+')))\n'
    sandbox=runroot/'offline-factory.sb';sandbox.write_text(profile)
    env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_','VK_','CX_')) and not k.lower().startswith('steam')};env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d;steamclient,steamclient64=n',DYLD_LIBRARY_PATH=str(base/'vulkan')+':'+str(base/'dependency-root/lib'),TMPDIR=str(tmp)+'/',XDG_CACHE_HOME=str(runroot/'cache'))
    if args.create_user:env['steam_master_ipc_name_override']='ReadyAuth-'+uuid.uuid4().hex[:24]
    source_snapshot=runroot/'source-snapshot';source_snapshot.mkdir();source_hashes={}
    for name in ['steam_windows_factory_research.py','steam_windows_factory_probe.c','steam_windows_build_factory_probe.py','steam_windows_sandbox_controls.c','steam_windows_login_abi.h','steam_windows_login_abi.py']:
        target=source_snapshot/name;shutil.copy2(ROOT/'Scripts'/name,target);source_hashes[name]=sha(target)
    baseline=ps();controls=[];report={'schema':1,'scope':'genuine Valve disconnected user bootstrap Windows32/64 under Wine' if args.create_user else 'genuine Valve factory-only Windows32/64 under Wine','createUserRequested':args.create_user,'invalidSyntheticAuthRequested':args.invalid_auth,'publicShutdownRequested':args.public_shutdown,'realAccountAuthenticationAttempted':False,'privateIPCNamespace':env.get('steam_master_ipc_name_override'),'runroot':str(runroot),'passed':False,'credentialsRead':False,'authenticationAttempted':args.invalid_auth,'closedHelperExecuted':False,'gameLaunchAttempted':False,'genuineAuthenticatedHostVerified':False,'factoryObjectsAreNotLoginProof':True,'privateABIRecord':str(RESEARCH/'valve-export-user-abi-plan.json'),'privateABIRecordSHA256':sha(RESEARCH/'valve-export-user-abi-plan.json'),'baselineSteamProcesses':[r for r in baseline if 'steam' in Path(r['executable']).name.lower()],'sourceSnapshot':str(source_snapshot),'sourceHashes':source_hashes,'buildReceipt':str(build_receipt),'buildReceiptSHA256':sha(build_receipt),'beforeHashes':before,'controls':controls,'tests':[]}
    def execute(label,command,timeout=25):
        start=time.monotonic();process=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(sandbox),*map(str,command)],env=env,cwd=prefix,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        observed={};prior={x['pid'] for x in baseline};output='';error=''
        while True:
            for item in ps():
                if item['pid'] not in prior and (item['ppid']==process.pid or item['pid']==process.pid or item['ppid'] in observed):observed[item['pid']]=item
            try:output,error=process.communicate(timeout=0.2);break
            except subprocess.TimeoutExpired:
                if time.monotonic()-start>timeout:
                    process.kill();output,error=process.communicate();report.setdefault('timedOutStages',[]).append({'stage':label,'timeoutSeconds':timeout,'seconds':round(time.monotonic()-start,3)});break
        report.setdefault('observedProcesses',{})[label]=list(observed.values())
        (runroot/(label+'.stdout')).write_text(output);(runroot/(label+'.stderr')).write_text(error)
        return subprocess.CompletedProcess(command,process.returncode,output,error),round(time.monotonic()-start,3)
    def stop_exact(label):
        killed=subprocess.run([str(server),'-k'],env=env,capture_output=True,text=True,timeout=10)
        waited=subprocess.run([str(server),'-w'],env=env,capture_output=True,text=True,timeout=20)
        record={'stage':label,'killReturncode':killed.returncode,'waitReturncode':waited.returncode,'stderr':(killed.stderr+waited.stderr)[:1200]};report.setdefault('exactServerStops',[]).append(record)
        if killed.returncode not in (0,1) or waited.returncode or waited.stderr:raise RuntimeError('Exact prefix server stop failed: '+label)
    try:
        positive=tmp/('ready-factory-control-'+uuid.uuid4().hex);positive.write_text('READY_SANDBOX_CONTROL\n')
        control,seconds=execute('positive-cat',['/bin/cat',positive],10);positive.unlink()
        if control.returncode or control.stdout!='READY_SANDBOX_CONTROL\n':raise RuntimeError('OS startup positive control failed')
        controls.append({'control':'positive-file-read','returncode':control.returncode,'seconds':seconds})
        control,seconds=execute('positive-curl-version',['/usr/bin/curl','--version'],10)
        if control.returncode or not control.stdout.startswith('curl '):raise RuntimeError('Network control executable did not reach main')
        controls.append({'control':'positive-curl-startup','returncode':control.returncode,'seconds':seconds})
        forbidden=runroot/'forbidden-sentinel';forbidden.write_text('CONTROL: must not be read in child\n')
        # It is intentionally outside the read whitelist, although parent owns it.
        for name,command in [('deny-extra-file',['/bin/cat',forbidden]),('deny-exec',['/usr/bin/true']),('deny-network',['/usr/bin/curl','--head','--max-time','2','https://store.steampowered.com/'])]:
            run,seconds=execute(name,command,10)
            if run.returncode==0 or run.returncode<0:raise RuntimeError('Sandbox control failed before meaningful denial: '+name)
            controls.append({'control':name,'returncode':run.returncode,'seconds':seconds,'stderr':run.stderr[:1500]})
        # Static-only paths are never allowed by this execution sandbox.
        run,seconds=execute('deny-closed-helper-read',['/bin/cat',RESEARCH/'binaries/steam.exe'],10)
        if run.returncode==0 or run.returncode<0:raise RuntimeError('Closed helper read control did not reach meaningful denial')
        controls.append({'control':'closed-helper-unreadable','returncode':run.returncode})
        outside=RESEARCH/('denied-write-control-'+uuid.uuid4().hex);control,seconds=execute('native-negative-controls',[control_exe,forbidden,outside],10)
        if control.returncode or outside.exists() or not json.loads(control.stdout).get('allDenied'):raise RuntimeError('Native sandbox negative controls failed')
        controls.append({'control':'direct-syscall-read-write-loopback-exec','returncode':control.returncode,'observation':json.loads(control.stdout),'seconds':seconds})
        wow=prefix/'drive_c/windows/syswow64';wow.mkdir(parents=True);shutil.copytree(Path(cfg['builtin32Directory']),wow,dirs_exist_ok=True,symlinks=True)
        boot,seconds=execute('wineboot',[wine,'wineboot','-u'],180)
        report['boot']={'returncode':boot.returncode,'seconds':seconds}
        stop_exact('completed-stage')
        if boot.returncode:raise RuntimeError('New isolated Wine bootstrap failed')
        for bits in [64,32]:
            client=RESEARCH/('valve-client'+str(bits))/('steamclient64.dll' if bits==64 else 'steamclient.dll');program=next(Path(p) for p in build['artifacts'] if Path(p).name=='ready-steam-factory'+str(bits)+'.exe');env['READY_STEAM_WINDOWS_CLIENT_DLL']='Z:'+str(client).replace('/','\\')
            event=prefix/('ready-steam-events-'+str(bits)+'.json');env['READY_STEAM_WINDOWS_EVENT_FILE']='Z:'+str(event).replace('/','\\')
            result,seconds=execute('factory-'+str(bits),[wine,program,*(['--invalid-auth'] if args.invalid_auth else ['--create-user'] if args.create_user else []),*(['--public-shutdown'] if args.public_shutdown else [])],25)
            retained_event=runroot/('events-'+str(bits)+'.json')
            if event.is_file():shutil.copy2(event,retained_event);retained_event.chmod(0o600)
            records=[]
            if retained_event.exists():
                for line in retained_event.read_text().splitlines():
                    try:records.append(json.loads(line))
                    except ValueError:pass
            observation={}
            for item in records:
                if item.get('stage') in ('factory-ready','factory-only','factory-user-offline','synthetic-auth-result','public-shutdown-returned'):observation.update(item)
            report['tests'].append({'bits':bits,'returncode':result.returncode,'seconds':seconds,'observation':observation,'privateRecords':records,'privateEvent':str(retained_event),'privateEventSHA256':sha(retained_event) if retained_event.exists() else None,'stdout':str(runroot/('factory-'+str(bits)+'.stdout')),'stderr':str(runroot/('factory-'+str(bits)+'.stderr'))})
            stop_exact('completed-stage')
            if observation.get('visibleWindowsAfter',0)>observation.get('visibleWindowsBefore',0) or observation.get('steamUILoaded'):raise RuntimeError('A new client UI was observed')
        if args.create_user:report['disconnectedUserBootstrapPassed']=len(report['tests'])==2 and all(all(t['observation'].get(k) for k in ['userLifecycleExports','userCreated','releaseUserCalled','pipeReleaseSucceeded']) for t in report['tests'])
        if args.invalid_auth:report['offlineInvalidAuthShapePassed']=len(report['tests'])==2 and all(t['observation'].get('loggedOn') is False and t['observation'].get('identityInvalid') and t['observation'].get('hiddenIdentityReturnMatches') and t['observation'].get('callbackStructGuardsValid') and t['observation'].get('callbackCount')==t['observation'].get('callbackFreeCount') and t['observation'].get('publicApps009') and t['observation'].get('invalidApp0Subscribed') is False for t in report['tests'])
        report['passed']=(not args.invalid_auth or report['offlineInvalidAuthShapePassed']) and (not args.create_user or report['disconnectedUserBootstrapPassed']) and len(report['tests'])==2 and all(t['returncode']==0 and t['observation'].get('moduleLoaded') and all(t['observation'].get(k) for k in ['factoryExport','clientEngine005','steamClient023','clientPathMatchesRequest','tier0FromSelectedDirectory','vstdlibFromSelectedDirectory']) for t in report['tests'])
    except Exception as error:report['error']=type(error).__name__+': '+str(error)
    finally:
        stop_exact('final-cleanup')
        report['afterHashes']={str(p):sha(p) for p in immutable};report['immutableInputsUnchanged']=report['afterHashes']==before;report['steamProcessesAfter']=[r for r in ps() if 'steam' in Path(r['executable']).name.lower()];report['sandboxSHA256']=sha(sandbox);report['authenticodeReceiptSHA256']=sha(RESEARCH/'authenticode-verification.json');report['exactPrefixStopped']=all(x['killReturncode'] in (0,1) and x['waitReturncode']==0 for x in report['exactServerStops'])
        report['existingSteamProcessesUnchanged']=report['steamProcessesAfter']==report['baselineSteamProcesses']
        report['passed']=report['passed'] and report['immutableInputsUnchanged'] and report['existingSteamProcessesUnchanged'] and report['exactPrefixStopped']
        if prefix.exists():shutil.rmtree(prefix)
        report['prefixRemoved']=not prefix.exists();report['isolatedServerIPC']=str(serverdir)
        if serverdir.exists():shutil.rmtree(serverdir)
        report['serverIPCRemoved']=not serverdir.exists();(runroot/'report.json').write_text(json.dumps(report,indent=2)+'\n');summary={'retainedReport':str(runroot/'report.json'),'retainedReportSHA256':sha(runroot/'report.json'),'passed':report['passed'],'authenticationAttempted':args.invalid_auth,'genuineAuthenticatedHostVerified':False,'closedHelperExecuted':False,'credentialsRead':False};(ROOT/'Evidence'/('steam-windows-invalid-auth.json' if args.invalid_auth else 'steam-windows-bootstrap.json' if args.create_user else 'steam-windows-factory.json')).write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
