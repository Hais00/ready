#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a separate service candidate offline; test real compiled state/protocol.

No helper selector, runtime provider, vault or account is changed. Every build
input/output lives on the already authorized, marked external project volume.
"""
import hashlib,json,os,pathlib,selectors,subprocess,sys,time,uuid
sys.dont_write_bytecode=True
import store_steam_tools as tools
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')

def sha(path):return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def run():
    if WORK.resolve()!=WORK or WORK.stat().st_uid!=os.getuid() or WORK.stat().st_mode&0o077 or (WORK/'.ready-external-workspace').read_text()!='ready project work for thread01a17e79\n':raise ValueError('Owned marked work root required')
    sdk=WORK/'build/steam-ownership-88k0vbem/dotnet'
    result=tools.build(workspace=WORK/'build',sdk_root=sdk,tools_store=WORK/'retained/steam-service-candidates')
    build=pathlib.Path(result['buildRoot']);version=pathlib.Path(result['versionRoot'])
    project=build/'fixture';project.mkdir(mode=0o700)
    fixture=ROOT/'Synthetic/PersistentSteamServiceChecks.cs'
    tools.copy_file(fixture,project/fixture.name)
    original=build/'source/StoreBridge/SteamBridge'
    (project/'Checks.csproj').write_text(f'''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><InvariantGlobalization>true</InvariantGlobalization><StartupObject>PersistentSteamServiceChecks</StartupObject></PropertyGroup><ItemGroup><Compile Include="{original}/Program.cs"/><Compile Include="{original}/PersistentSteamService.cs"/><Compile Include="{original}/SteamCatalogMetadata.cs"/><Compile Include="{original}/SteamOwnedGamesCatalog.cs"/><ProjectReference Include="{build}/source/Vendor/steamkit/SteamKit2/SteamKit2/SteamKit2.csproj"/></ItemGroup></Project>\n''')
    env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM','SB_'))}
    env.update(DOTNET_ROOT=str(sdk),DOTNET_CLI_HOME=str(build/'home'),NUGET_PACKAGES=str(build/'nuget'),DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_EnableDiagnostics='0',TMPDIR=str(WORK/'tmp')+'/',MSBUILDDISABLENODEREUSE='1',DOTNET_MULTILEVEL_LOOKUP='0')
    output=build/'fixture-output'
    command=[str(sdk/'dotnet'),'build',str(project/'Checks.csproj'),'-c','Release','--nologo','--configfile',str(build/'NuGet.Config'),'-p:TargetFrameworks=net10.0','-p:NuGetAudit=false','-p:UseSharedCompilation=false','-nodeReuse:false','-o',str(output)]
    compiled=subprocess.run(command,env=env,capture_output=True,text=True,timeout=180)
    (build/'fixture-build.log').write_text(compiled.stdout+compiled.stderr)
    if compiled.returncode:raise RuntimeError('Persistent service fixture compilation failed; private build log retained')
    guarded=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)']
    runtime=version/'dotnet/dotnet';env['DOTNET_ROOT']=str(version/'dotnet')
    check=subprocess.run([*guarded,str(runtime),str(output/'Checks.dll')],env=env,capture_output=True,text=True,timeout=45)
    (build/'fixture-stdout.json').write_text(check.stdout);(build/'fixture-stderr.log').write_text(check.stderr)
    if check.returncode:raise RuntimeError('Persistent service offline checks failed; private fixture diagnostics retained')
    report=json.loads(check.stdout)
    report['fakeTransportSteamClientCreated']=report.pop('steamClientCreated')
    report['actualAdapterCreatedWithoutConnection']=True
    # Actual adapter is instantiated, callback pump starts, but snapshot/shutdown
    # must not allocate a Steam network connection under network-deny.
    dll=version/'SteamBridge/ReadySteamBridge.dll'
    process=subprocess.Popen([*guarded,str(runtime),str(dll),'--service'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,text=True)
    profile=str(uuid.uuid4());generation=str(uuid.uuid4())
    def request(operation):
        request_id=str(uuid.uuid4());process.stdin.write(json.dumps(dict(id=request_id,profileID=profile,profileGeneration=generation,operation=operation))+'\n');process.stdin.flush();return request_id
    snapshot=request('snapshot');selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
    records=[];deadline=time.monotonic()+20
    try:
        while time.monotonic()<deadline:
            if not selector.select(.1):continue
            line=process.stdout.readline()
            if not line:raise RuntimeError('Service closed before offline snapshot')
            event=json.loads(line);records.append(event)
            if event.get('id')==snapshot and event.get('type')=='result':break
        else:raise RuntimeError('Offline service snapshot deadline')
        assert records[-1]['state']=='offline' and 'authenticate'in records[-1]['capabilities']
        request('shutdown')
        stdout,stderr=process.communicate(timeout=20)
        records.extend(json.loads(line)for line in stdout.splitlines())
        assert process.returncode==0
    finally:
        selector.close()
        if process.poll()is None:process.kill();process.wait()
    report['checks']['actual-adapter-offline-snapshot-shutdown-network-denied']=True
    report['checkCount']=len(report['checks'])
    one_shot=subprocess.run([*guarded,str(runtime),str(dll)],input='{"operation":"self_test"}\n',env=env,capture_output=True,text=True,timeout=20)
    assert one_shot.returncode==0 and json.loads(one_shot.stdout)['type']=='result'
    report['checks']['one-shot-self-test-backward-compatible']=True;report['checkCount']=len(report['checks'])
    report.update(candidate=result,sourceHashes={str(p.relative_to(ROOT)):sha(p)for p in [ROOT/'StoreBridge/SteamBridge/Program.cs',ROOT/'StoreBridge/SteamBridge/PersistentSteamService.cs',ROOT/'StoreBridge/SteamBridge/SteamCatalogMetadata.cs',ROOT/'StoreBridge/SteamBridge/SteamOwnedGamesCatalog.cs',ROOT/'Scripts/store_steam_tools.py',fixture,pathlib.Path(__file__)]},actualServiceNetworkDenied=True,oneShotBackwardCompatible=True,realAuthenticationAttempted=False)
    target=ROOT/'Evidence/steam-persistent-service-tests.json';target.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':run()
