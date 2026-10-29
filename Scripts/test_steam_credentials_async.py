#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run production credential consumers with private fake services/memory vaults.

Uses an existing, fresh explicit Core archive/module; never starts SwiftPM,
Keychain, a genuine account, native host, game, or production store helper.
"""
import argparse,hashlib,importlib.util,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def fake(name):
 spec=importlib.util.spec_from_file_location('ready_fixture_'+name,ROOT/'Scripts'/name);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m.FAKE
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-products',type=pathlib.Path,required=True);ap.add_argument('--only',choices=['storeClient','accountCoordinator','session','gameAuthorization']);args=ap.parse_args();products=args.core_products.resolve();archive=products/'libLauncherCore.a';modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';m=modules/'LauncherCore.swiftmodule';ms=list(m.glob('*.swiftmodule'))if m.is_dir()else[m]
 if not archive.is_file()or not ms or archive.stat().st_mtime_ns<max(x.stat().st_mtime_ns for x in ms):raise RuntimeError('Refusing stale Core archive/module')
 run=pathlib.Path(tempfile.mkdtemp(prefix='steam-credentials-async-',dir=WORK/'tests'));run.chmod(0o700)
 env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',PYTHONDONTWRITEBYTECODE='1')
 tools=run/'ReadySSOFixtureTools';tools.mkdir();env['READY_STORE_TOOLS_ROOT']=str(tools)
 common=['Credentials.swift','PrivateCredentialFile.swift','StoreClient.swift'];cases=[('storeClient',common,'ReadyStoreClientProbe.swift',None),('accountCoordinator',common+['SteamAccountCoordinator.swift'],'ReadySteamAccountProbe.swift',None),('session',common+['SteamClientSession.swift'],'ReadySteamSessionProbe.swift','test_steam_client_session.py'),('gameAuthorization',common+['SteamClientSession.swift','SteamGameAuthorization.swift'],'ReadySteamGameAuthorizationProbe.swift','test_steam_game_authorization.py')]
 results={};all_hashes={}
 for label,names,probe,fake_name in cases:
  if args.only and label != args.only:continue
  target=run/label;target.mkdir();sources=[ROOT/'Sources/M1Launcher'/n for n in names]+[ROOT/'Synthetic'/probe];hashes={str(p.relative_to(ROOT)):sha(p)for p in sources};all_hashes.update(hashes)
  command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/steam-ui-module-cache'),'-I',str(modules),'-framework','Security',*map(str,sources),str(archive),'-o',str(target/'probe')]
  built=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=120);(target/'compile.log').write_text(built.stdout+built.stderr)
  if built.returncode:raise RuntimeError(label+' compile failed: '+built.stderr[-1800:])
  arguments=[str(target/'probe'),str(ROOT)]
  if fake_name:
   helper=target/'fake.py';helper.write_text(fake(fake_name));helper.chmod(0o600);arguments=[str(target/'probe'),os.sys.executable,str(helper),str(target)]
  result=subprocess.run(arguments,cwd=ROOT,env=env,capture_output=True,text=True,timeout=70);(target/'stdout.json').write_text(result.stdout);(target/'stderr.log').write_text(result.stderr)
  if result.returncode:raise RuntimeError(label+' fixture failed; private diagnostics retained at '+str(target))
  report=json.loads(result.stdout);assert report.get('passed',report.get('allPassed')) is True
  assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in sources}
  retained=target/'report.json';retained.write_text(json.dumps({'passed':True,'checks':report,'sourceHashes':hashes,'fixtureOnly':True,'realKeychainOrAccountOrGameUsed':False},indent=2)+'\n');retained.chmod(0o600)
  results[label]={'passed':True,'report':str(retained),'sha256':sha(retained),'count':report.get('checkCount',len(report)-1)}
 receipt={'passed':True,'cases':results,'sourceHashes':all_hashes,'fixtureOnly':True,'realKeychainOrAccountOrGameUsed':False,'coreArchiveSHA256':sha(archive),'importableModuleSHA256':{p.name:sha(p)for p in ms}};retained=run/'report.json';retained.write_text(json.dumps(receipt,indent=2)+'\n');retained.chmod(0o600)
 pointer={**receipt,'retainedReport':str(retained),'retainedReportSHA256':sha(retained)};(ROOT/'Evidence'/('steam-credential-async-tests'+('-'+args.only if args.only else '')+'.json')).write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
