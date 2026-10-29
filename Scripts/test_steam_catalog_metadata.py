#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile catalog/service sources in private scratch; no selectors/accounts/Steam network."""
import hashlib,json,os,pathlib,subprocess,tempfile,urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-catalog-checks-',dir=WORK/'tests'));run.chmod(0o700)
 sdk=WORK/'build/steam-ownership-88k0vbem/dotnet'
 libraries=WORK/'retained/steam-service-candidates/steambridge-1b3c0bc6d77104853dd42e4d/SteamBridge'
 sources=[*sorted((ROOT/'StoreBridge/SteamBridge').glob('*.cs')),ROOT/'Synthetic/SteamCatalogMetadataChecks.cs',ROOT/'Synthetic/PersistentSteamServiceChecks.cs']
 digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
 inputs={str(p.relative_to(ROOT)):digest(p)for p in sources}
 source=run/'source';source.mkdir(mode=0o700)
 for path in sources:(source/path.name).write_bytes(path.read_bytes())
 refs=''.join(f'<Reference Include="{p.stem}"><HintPath>{p}</HintPath></Reference>'for p in libraries.glob('*.dll')if p.name!='ReadySteamBridge.dll')
 project=source/'Checks.csproj';project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><InvariantGlobalization>true</InvariantGlobalization><StartupObject>SteamCatalogMetadataChecks</StartupObject></PropertyGroup><ItemGroup>'+refs+'</ItemGroup></Project>')
 config=run/'NuGet.Config';config.write_text('<configuration><packageSources><clear /></packageSources></configuration>')
 env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','STEAM','Steam','SB_'))}
 env.update(DOTNET_ROOT=str(sdk),DOTNET_CLI_HOME=str(run/'home'),NUGET_PACKAGES=str(run/'nuget'),DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_EnableDiagnostics='0',MSBUILDDISABLENODEREUSE='1',DOTNET_MULTILEVEL_LOOKUP='0',TMPDIR=str(WORK/'tmp')+'/')
 report={'sourceHashes':inputs,'realAuthenticationAttempted':False,'selectorChanged':False};guard=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)']
 for entry in ['SteamCatalogMetadataChecks','PersistentSteamServiceChecks']:
  output=run/entry
  result=subprocess.run([str(sdk/'dotnet'),'build',str(project),'-c','Release','-t:Rebuild','--nologo','--configfile',str(config),'-p:StartupObject='+entry,'-p:NuGetAudit=false','-p:UseSharedCompilation=false','-nodeReuse:false','-o',str(output)],env=env,capture_output=True,text=True,timeout=90)
  (run/(entry+'.build.log')).write_text(result.stdout+result.stderr)
  if result.returncode:raise RuntimeError('Offline compilation failed: '+str(run/(entry+'.build.log'))+'\n'+result.stdout[-5000:])
  result=subprocess.run([*guard,str(sdk/'dotnet'),str(output/'Checks.dll')],env=env,capture_output=True,text=True,timeout=60)
  (run/(entry+'.stdout.json')).write_text(result.stdout);(run/(entry+'.stderr.log')).write_text(result.stderr)
  if result.returncode:raise RuntimeError('Offline checks failed: '+str(run)+'\n'+result.stderr[-2000:])
  report[entry]=json.loads(result.stdout)
 # Exactly one authorized public catalog request, never an account endpoint.
 request=urllib.request.Request('https://store.steampowered.com/api/appdetails?appids=1091500&l=english',headers={'User-Agent':'ReadyCatalogMetadataCheck/1'})
 with urllib.request.urlopen(request,timeout=15)as response:data=response.read(4*1024*1024+1)
 if len(data)>4*1024*1024:raise ValueError('Public response too large')
 public=run/'public-app-1091500.json';public.write_bytes(data)
 result=subprocess.run([*guard,str(sdk/'dotnet'),str(run/'SteamCatalogMetadataChecks/Checks.dll'),str(public)],env=env,capture_output=True,text=True,timeout=20)
 if result.returncode:raise RuntimeError('Public catalog normalization failed')
 report['publicCatalog']=json.loads(result.stdout);report['publicResponseSHA256']=digest(public)
 assert inputs=={str(p.relative_to(ROOT)):digest(p)for p in sources}
 report['passed']=True;report['report']=str(run/'report.json');(run/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
