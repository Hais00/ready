#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Private Windows RDYAUTH1 parser and PUBLIC SYNTHETIC ONLY offline auth controls.

No GameNative host execution, real account/session input, or game launch;
synthetic offline API controls are explicit. No client spoofing or modification of client/game/provider binaries.
"""
import argparse,hashlib,json,os,shutil,struct,subprocess,threading,time,uuid
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
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--include-synthetic-auth',action='store_true');parser.add_argument('--deadline-only',action='store_true');parser.add_argument('--changed-controls-only',action='store_true');parser.add_argument('--auth-only',action='store_true');parser.add_argument('--architecture',choices=['32','64']);args=parser.parse_args();args.create_user=True;args.invalid_auth=False;args.public_shutdown=False
    assert (WORK/'.ready-external-workspace').is_file() and (RESEARCH/'.ready-steam-windows-research').is_file()
    auth=json.load(open(RESEARCH/'authenticode-verification.json'));assert auth['allVerified'] and len(auth['files'])==6
    for entry in auth['files']:
        if sha(entry['file'])!=entry['sha256'] or entry['returncode']!=0:raise RuntimeError('Unverified or changed Valve file')
    build_index=json.load(open(RESEARCH/'current-factory-build.json'));build_receipt=Path(build_index['buildReceipt']);assert sha(build_receipt)==build_index['buildReceiptSHA256'];build=json.load(open(build_receipt));control_exe=next(Path(p) for p in build['artifacts'] if Path(p).name=='ready-steam-sandbox-controls')
    for p,h in build['artifacts'].items():assert sha(p)==h
    for p,h in build['sources'].items():assert sha(ROOT/p)==h
    cfg=json.load(open(ROOT/'Runtime/runtime.json'));wine=Path(cfg['wineBinary']);server=Path(cfg['wineServer']);base=Path(cfg['immutableRuntimeSet']);wine_root=wine.parent.parent
    immutable=[ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json',wine,server,*map(Path,build['artifacts']),*[Path(x['file']) for x in auth['files']]];before={str(p):sha(p) for p in immutable}
    runroot=RESEARCH/('credential-run-'+uuid.uuid4().hex);runroot.mkdir(mode=0o700);(runroot/'.owned-windows-factory-run').write_text('Synthetic research only; never real credentials, games or GameNative host\n');prefix=runroot/'prefix';prefix.mkdir(mode=0o700);tmp=WORK/'tmp'
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
    for name in ['steam_windows_factory_research.py','steam_windows_factory_probe.c','steam_windows_build_factory_probe.py','steam_windows_sandbox_controls.c','steam_windows_login_abi.h','steam_windows_login_abi.py','steam_windows_credential.h','steam_windows_auth_research.py']:
        target=source_snapshot/name;shutil.copy2(ROOT/'Scripts'/name,target);source_hashes[name]=sha(target)
    shutil.copy2(ROOT/'Scripts/steam_host_credential.h',source_snapshot/'wire-spec-posix-reference.h')
    baseline=ps();controls=[];report={'schema':1,'scope':'genuine Valve disconnected user bootstrap Windows32/64 under Wine' if args.create_user else 'genuine Valve factory-only Windows32/64 under Wine','createUserRequested':args.create_user,'invalidSyntheticAuthRequested':args.invalid_auth,'publicShutdownRequested':args.public_shutdown,'realAccountAuthenticationAttempted':False,'privateIPCNamespace':env.get('steam_master_ipc_name_override'),'runroot':str(runroot),'passed':False,'credentialsRead':False,'authenticationAttempted':args.invalid_auth,'closedHelperExecuted':False,'gameLaunchAttempted':False,'genuineAuthenticatedHostVerified':False,'factoryObjectsAreNotLoginProof':True,'privateABIRecord':str(RESEARCH/'valve-export-user-abi-plan.json'),'privateABIRecordSHA256':sha(RESEARCH/'valve-export-user-abi-plan.json'),'baselineSteamProcesses':[r for r in baseline if '/Steam.AppBundle/' in r['executable'] or '/Steam.app/' in r['executable']],'sourceSnapshot':str(source_snapshot),'sourceHashes':source_hashes,'publicSyntheticInputsOnly':True,'credentialWireSpecSHA256':sha(ROOT/'Scripts/steam_host_credential.h'),'buildReceipt':str(build_receipt),'buildReceiptSHA256':sha(build_receipt),'beforeHashes':before,'controls':controls,'tests':[]}
    def execute(label,command,timeout=25,input_data=None,hold_open=False,disk_input=None,slow_event=None):
        start=time.monotonic();disk=open(disk_input,'rb') if disk_input else None
        pipe_input=input_data is not None or hold_open or slow_event is not None
        process=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(sandbox),*map(str,command)],env=env,cwd=prefix,stdin=disk if disk else subprocess.PIPE if pipe_input else subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=False)
        held=None;writer=None
        if hold_open or slow_event:
            held=process.stdin;process.stdin=None
            if hold_open:held.write(input_data or b'');held.flush()
            else:
                def send_slow():
                    try:
                        deadline=time.monotonic()+8
                        while not slow_event.exists() and time.monotonic()<deadline:time.sleep(0.01)
                        for chunk,delay in [(input_data[:28],1.1),(input_data[28:40],1.1),(input_data[40:],1.1)]:time.sleep(delay);held.write(chunk);held.flush()
                    except (BrokenPipeError,OSError):pass
                    finally:
                        try:held.close()
                        except (BrokenPipeError,OSError):pass
                writer=threading.Thread(target=send_slow,daemon=True);writer.start()
        timed=False
        try:output,error=process.communicate(input=None if held or disk else input_data,timeout=timeout)
        except subprocess.TimeoutExpired:process.kill();output,error=process.communicate();timed=True
        finally:
            if disk:disk.close()
            if held and not writer:held.close()
            if writer:writer.join(timeout=4)
        output=output.decode(errors='replace');error=error.decode(errors='replace');(runroot/(label+'.stdout')).write_text(output);(runroot/(label+'.stderr')).write_text(error)
        if timed:report.setdefault('timedOutStages',[]).append(label)
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
        def frame(account=b'ready_offline_invalid_account',token=b'ready.invalid.synthetic.token',identity=76561197960265729,app=480):return b'RDYAUTH1'+struct.pack('>IIQI',len(account),len(token),identity,app)+account+token
        public_frame=frame();cases=[('valid',public_frame,0,False,False,False),('empty',b'',4,False,False,False),('bad-magic',b'BADMAGIC'+public_frame[8:],5,False,False,False),('overlong',b'RDYAUTH1'+struct.pack('>IIQI',65,1,76561197960265729,0xffffffff),6,False,False,False),('truncated',public_frame[:-1],4,False,False,False),('invalid-identity',frame(identity=76561197960265728),7,False,False,False),('app-zero',frame(app=0),7,False,False,False),('app-reserved',frame(app=0xffffffff),7,False,False,False),('bad-account',frame(account=b'bad-account'),8,False,False,False),('bad-token',frame(token=b'bad token'),9,False,False,False),('trailing',public_frame+b'X',10,False,False,False),('writer-held',public_frame,2,True,False,False),('regular-file',public_frame,1,False,True,False),('cumulative-deadline',public_frame,2,False,False,True)]
        if args.auth_only:cases=[]
        arches=[int(args.architecture)] if args.architecture else [64,32]
        report['architectures']=arches;report['parserChecksSkipped']=args.auth_only
        if args.changed_controls_only:cases=[case for case in cases if case[0] in ('valid','app-reserved','writer-held','cumulative-deadline')]
        if args.deadline_only:cases=[case for case in cases if case[0] in ('writer-held','cumulative-deadline')]
        report['scope']='Windows private RDYAUTH1 parser and public synthetic offline auth candidate';report['parserCases']=[];report['authCases']=[]
        for bits in arches:
            program=next(Path(p) for p in build['artifacts'] if Path(p).name=='ready-steam-factory'+str(bits)+'.exe');client=RESEARCH/('valve-client'+str(bits))/('steamclient64.dll' if bits==64 else 'steamclient.dll');env['READY_STEAM_WINDOWS_CLIENT_DLL']='Z:'+str(client).replace('/','\\')
            for name,data,status,hold,disk,slow in cases:
                label='parser-'+str(bits)+'-'+name;event=prefix/(label+'.jsonl');env['READY_STEAM_WINDOWS_EVENT_FILE']='Z:'+str(event).replace('/','\\');diskpath=prefix/'public-synthetic-frame.bin'
                if disk:diskpath.write_bytes(data)
                process,seconds=execute(label,[wine,program,'--credential-parse-only'],8,input_data=data,hold_open=hold,disk_input=diskpath if disk else None,slow_event=event if slow else None)
                retained=runroot/(label+'.events.jsonl')
                if event.exists():shutil.copy2(event,retained)
                observations=[]
                if retained.exists():
                    for line in retained.read_text().splitlines():
                        try:observations.append(json.loads(line))
                        except ValueError:pass
                observation=next((x for x in observations if x.get('stage')=='credential-parser'),{})
                passed=observation.get('parseStatus')==status and observation.get('accepted') is (status==0) and (observation.get('credentialBufferWiped') or (status==2 and observation.get('processRAMReclaimedOnExit') and observation.get('parseThreadQuiescent') is False)) and observation.get('ValveLoaded') is False and process.returncode==(0 if status==0 else 2)
                if name in ('writer-held','cumulative-deadline'):passed=passed and 2950<=observation.get('milliseconds',0)<=3500
                report['parserCases'].append({'bits':bits,'case':name,'expectedStatus':status,'returncode':process.returncode,'seconds':seconds,'observation':observation,'event':str(retained),'eventSHA256':sha(retained) if retained.exists() else None,'passed':bool(passed)})
                (runroot/'progress.json').write_text(json.dumps({'bits':bits,'phase':'parser','case':name,'passed':bool(passed)})+'\n')
                if name=='valid' and not passed:raise RuntimeError('Windows anonymous stdin parser positive failed; no auth attempted')
            if args.include_synthetic_auth and all(x['passed'] for x in report['parserCases'] if x['bits']==bits):
                label='bounded-auth-'+str(bits);event=prefix/(label+'.jsonl');env['READY_STEAM_WINDOWS_EVENT_FILE']='Z:'+str(event).replace('/','\\');process,seconds=execute(label,[wine,program,'--authenticate-bounded'],45,input_data=public_frame);retained=runroot/(label+'.events.jsonl')
                if event.exists():shutil.copy2(event,retained)
                observations=[]
                if retained.exists():
                    for line in retained.read_text().splitlines():
                        try:observations.append(json.loads(line))
                        except ValueError:pass
                observation={}
                for item in observations:
                    if item.get('stage') in ('factory-ready','bounded-auth-result','factory-user-offline','public-shutdown-returned'):observation.update(item)
                passed=process.returncode==4 and observation.get('authenticatedReady') is False and observation.get('loggedOn') is False and observation.get('identityMatchesExpected') and observation.get('credentialBufferWipedAfterDispatch') and observation.get('callbackStructGuardsValid') and observation.get('callbackCount')==observation.get('callbackFreeCount') and observation.get('ValveConsoleSuppressed') and observation.get('shutdownIfNoPipes') and observation.get('steamUILoaded') is False and observation.get('visibleWindowsAfter')==0
                report['authCases'].append({'bits':bits,'inputSynthetic':True,'returncode':process.returncode,'seconds':seconds,'observation':observation,'event':str(retained),'eventSHA256':sha(retained) if retained.exists() else None,'passed':bool(passed)});report['authenticationAttempted']=True
            stop_exact('architecture-complete')
        report['parserPassed']=len(report['parserCases'])==len(cases)*len(arches) and all(x['passed'] for x in report['parserCases']);report['syntheticOfflineAuthControlPassed']=len(report['authCases'])==len(arches) and all(x['passed'] for x in report['authCases']) if args.include_synthetic_auth else None;report['passed']=report['parserPassed'] and (not args.include_synthetic_auth or report['syntheticOfflineAuthControlPassed'])
    except Exception as error:report['error']=type(error).__name__+': '+str(error)
    finally:
        stop_exact('final-cleanup')
        report['afterHashes']={str(p):sha(p) for p in immutable};report['immutableInputsUnchanged']=report['afterHashes']==before;report['steamProcessesAfter']=[r for r in ps() if '/Steam.AppBundle/' in r['executable'] or '/Steam.app/' in r['executable']];report['sandboxSHA256']=sha(sandbox);report['authenticodeReceiptSHA256']=sha(RESEARCH/'authenticode-verification.json');report['exactPrefixStopped']=all(x['killReturncode'] in (0,1) and x['waitReturncode']==0 for x in report['exactServerStops'])
        report['existingSteamProcessesUnchanged']=report['steamProcessesAfter']==report['baselineSteamProcesses']
        report['passed']=report['passed'] and report['immutableInputsUnchanged'] and report['existingSteamProcessesUnchanged'] and report['exactPrefixStopped']
        if prefix.exists():shutil.rmtree(prefix)
        report['prefixRemoved']=not prefix.exists();report['isolatedServerIPC']=str(serverdir)
        if serverdir.exists():shutil.rmtree(serverdir)
        report['serverIPCRemoved']=not serverdir.exists();(runroot/'report.json').write_text(json.dumps(report,indent=2)+'\n');summary={'retainedReport':str(runroot/'report.json'),'retainedReportSHA256':sha(runroot/'report.json'),'passed':report['passed'],'authenticationAttempted':report['authenticationAttempted'],'genuineAuthenticatedHostVerified':False,'closedHelperExecuted':False,'credentialsRead':False};(ROOT/'Evidence'/'steam-windows-private-stdin.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
