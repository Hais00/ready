#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build/test the ownership preflight without accounts or network authorization.

Restores the *already verified* project SDK cache to an external copy only.
Source projects and exact cached NuGet inputs are copied outside the checkout;
all build, cache, temporary and test output remains on the marked work volume.
Never runs store_bootstrap, downloads a newer SDK, or replaces the current helper.
"""
import base64
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
WORK = Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
sys.path.insert(0, str(ROOT / 'Scripts'))
import store_sdk_cache as sdk_cache

DECISION_SOURCE = r'''
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using SteamKit2;
using SteamKit2.Authentication;
static class OwnershipDecisionFixture
{
 static void Check(bool condition,string name,Dictionary<string,bool> checks){if(!condition)throw new Exception(name);checks[name]=true;}
 static uint ID(string value){using var doc=JsonDocument.Parse("{\"options\":{\"gameID\":"+value+"}}");return GameOwnershipPreflight.AppID(doc.RootElement);}
 static async Task<int> Main(){
  var checks=new Dictionary<string,bool>();var ticket=Encoding.UTF8.GetBytes("fixture bytes, not a Steam ticket");
  var accepted=GameOwnershipPreflight.Decide(123,EResult.OK,123,ticket,76561198000000001UL);
  Check(accepted.Authorized&&accepted.TicketSHA256?.Length==64&&accepted.SteamID=="76561198000000001","synthetic-ok-shape-only",checks);
  foreach(var result in new[]{EResult.AccessDenied,EResult.Fail,EResult.InvalidParam,EResult.NoConnection}){
   var denied=GameOwnershipPreflight.Decide(123,result,123,ticket,76561198000000001UL);
   Check(!denied.Authorized&&denied.SteamID==null&&denied.TicketSHA256==null,"deny-"+result,checks);
  }
  Check(!GameOwnershipPreflight.Decide(123,EResult.OK,456,ticket,76561198000000001UL).Authorized,"wrong-app-denied",checks);
  Check(!GameOwnershipPreflight.Decide(123,EResult.OK,123,Array.Empty<byte>(),76561198000000001UL).Authorized,"empty-ticket-denied",checks);
  Check(!GameOwnershipPreflight.Decide(123,EResult.OK,123,null,76561198000000001UL).Authorized,"missing-ticket-denied",checks);
  Check(!GameOwnershipPreflight.Decide(123,EResult.OK,123,ticket,null).Authorized,"missing-steamID-denied",checks);
  Check(!GameOwnershipPreflight.Decide(123,EResult.OK,123,ticket,0).Authorized,"zero-steamID-denied",checks);
  Check(ID("123")==123&&ID("\"4294967294\"")==uint.MaxValue-1,"uint-input-boundaries",checks);
  Check(!GameOwnershipPreflight.Decide(uint.MaxValue,EResult.OK,uint.MaxValue,ticket,76561198000000001UL).Authorized,"reserved-app-denied",checks);
  foreach(var value in new[]{"0","-1","4294967295","\"4294967295\"","4294967296","1.5","null","true","\"+123\"","\" 123\"","\"123suffix\""}){
   bool rejected=false;try{ID(value);}catch(Exception e){rejected=e.Message=="invalid_game_id";}
   Check(rejected,"invalid-id-"+value,checks);
  }
  const string secret="fixture-secret-never-serialize";
  var login=SteamLoginPolicy.CreateLogOnDetails("fixture_account",secret);
  Check(login.ShouldRememberPassword&&login.Username=="fixture_account"&&login.AccessToken==secret,"persistent-auth-requires-remember-password-protocol-flag",checks);
  var deniedLogin=SteamSafeFailure.Create(new Exception("steam_login_failed"),SteamOperationStage.LogOn,EResult.InvalidPassword);
  Check(deniedLogin.code=="steam_login_failed"&&deniedLogin.stage=="logon"&&deniedLogin.steamResult=="InvalidPassword","safe-logon-failure-stage-and-result",checks);
  var deniedOwnership=SteamSafeFailure.Create(new Exception("not_authorized"),SteamOperationStage.OwnershipTicket,EResult.AccessDenied);
  Check(deniedOwnership.code=="not_authorized"&&deniedOwnership.stage=="ownership_ticket"&&deniedOwnership.steamResult=="AccessDenied","safe-ownership-denial-diagnostics",checks);
  var arbitrary=SteamSafeFailure.Create(new Exception(secret),(SteamOperationStage)999,(EResult)int.MaxValue);
  string safe=JsonSerializer.Serialize(arbitrary);
  Check(!safe.Contains(secret)&&arbitrary.code=="steam_error"&&arbitrary.stage=="request"&&arbitrary.steamResult=="Unknown","unknown-exception-stage-result-cannot-leak",checks);
  var timeout=SteamSafeFailure.Create(new OperationCanceledException(secret),SteamOperationStage.LogOn,null);
  Check(timeout.code=="timeout"&&timeout.stage=="logon"&&timeout.steamResult==null&&!JsonSerializer.Serialize(timeout).Contains(secret),"safe-logon-timeout",checks);
  Check(SteamSafeFailure.ResultName(EResult.FileNotFound)=="Unknown","unapproved-defined-EResult-redacted",checks);
  foreach(var result in new[]{EResult.Expired,EResult.FileNotFound,EResult.Fail,(EResult)int.MaxValue}){
   var failure=SteamSafeFailure.Create(new AuthenticationException(secret,result),SteamOperationStage.QRAuthentication,null);
   string expected=result==EResult.Expired?"Expired":result==EResult.Fail?"Fail":"Unknown";
   Check(failure.code=="steam_error"&&failure.stage=="qr_authentication"&&failure.steamResult==expected&&
    !JsonSerializer.Serialize(failure).Contains(secret),"safe-QR-authentication-exception-result-"+(int)result,checks);
  }
  var precedence=SteamSafeFailure.Create(new AuthenticationException(secret,EResult.Expired),SteamOperationStage.QRAuthentication,EResult.AccessDenied);
  Check(precedence.steamResult=="AccessDenied"&&!JsonSerializer.Serialize(precedence).Contains(secret),"explicit-result-precedes-authentication-exception",checks);
  var noResult=SteamSafeFailure.Create(new InvalidOperationException(secret),SteamOperationStage.QRAuthentication,null);
  Check(noResult.steamResult==null&&noResult.stage=="qr_authentication"&&!JsonSerializer.Serialize(noResult).Contains(secret),"QR-non-authentication-exception-does-not-invent-result",checks);
  Check(Enum.GetValues<SteamOperationStage>().Select(SteamSafeFailure.StageName).Distinct().Count()==15,"stage-enum-allowlist-complete",checks);
  var facts=new SteamOwnershipFacts{ResponseReceived=true};facts.Observe(123,123,ticket,76561198000000001UL);facts.DecisionAuthorized=true;
  var postTicket=SteamSafeFailure.Create(new DllNotFoundException(secret),SteamOperationStage.OwnershipDecision,EResult.OK,facts);
  Check(postTicket.exceptionKind=="DllNotFoundException"&&postTicket.stage=="ownership_decision"&&postTicket.steamResult=="OK"&&
   postTicket.ownershipResponseReceived==true&&postTicket.ownershipAppMatched==true&&postTicket.ownershipTicketNonEmpty==true&&
   postTicket.ownershipSteamIDPresent==true&&postTicket.ownershipDecisionAuthorized==true&&!JsonSerializer.Serialize(postTicket).Contains(secret),"post-ticket-factual-booleans-kind-no-secret",checks);
  Check(deniedLogin.ownershipResponseReceived==null&&deniedLogin.ownershipDecisionAuthorized==null,"non-ownership-facts-remain-unobserved",checks);
  foreach(var failStage in SteamOwnershipCleanup.Stages){
   var cleanupFacts=new SteamOwnershipFacts();var visited=new List<SteamOperationStage>();
   var failure=await SteamOwnershipCleanup.Run(stage=>{visited.Add(stage);if(stage==failStage)throw new DllNotFoundException(secret);return Task.CompletedTask;},cleanupFacts);
   Check(failure?.Stage==failStage&&cleanupFacts.CleanupFailureStage==failStage&&cleanupFacts.CleanupExceptionKind=="DllNotFoundException"&&
    visited.SequenceEqual(SteamOwnershipCleanup.Stages),"cleanup-failure-retained-and-all-steps-attempted-"+SteamSafeFailure.StageName(failStage),checks);
  }
  var multipleFacts=new SteamOwnershipFacts();var multipleVisited=new List<SteamOperationStage>();
  var multiple=await SteamOwnershipCleanup.Run(stage=>{multipleVisited.Add(stage);throw new IOException(secret);},multipleFacts);
  Check(multiple?.Stage==SteamOperationStage.OwnershipClearTicket&&multipleVisited.Count==5&&multipleFacts.CleanupExceptionKind=="IOException","first-cleanup-failure-preserved-without-skipping-rest",checks);
  foreach(var error in new Exception[]{new CryptographicException(secret),new InvalidOperationException(secret),new Exception(secret)}){
   var failure=SteamSafeFailure.Create(error,SteamOperationStage.OwnershipPump,EResult.OK,multipleFacts);
   Check(failure.exceptionKind==error.GetType().Name&&failure.cleanupFailureStage=="ownership_clear_ticket"&&failure.cleanupExceptionKind=="IOException"&&
    !JsonSerializer.Serialize(failure).Contains(secret),"safe-exception-kind-"+error.GetType().Name,checks);
  }
  var promise=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);promise.SetResult(true);
  bool directRejected=false,poolRejected=false;
  try{promise.Task.RunSynchronously();}catch(InvalidOperationException){directRejected=true;}
  try{await Task.Run(()=>promise.Task.RunSynchronously());}catch(InvalidOperationException){poolRejected=true;}
  Check(directRejected&&poolRejected,"promise-RunSynchronously-invalid-even-on-TaskRun",checks);
  Check(promise.Task.GetAwaiter().GetResult(),"started-task-GetAwaiter-cleanup-positive",checks);
  using(var closeBudget=new CancellationTokenSource(TimeSpan.FromMilliseconds(50))){
   var never=new TaskCompletionSource<bool>();bool bounded=false;
   try{never.Task.WaitAsync(closeBudget.Token).GetAwaiter().GetResult();}catch(OperationCanceledException){bounded=true;}
   Check(bounded,"cleanup-promise-independent-cancellation-budget",checks);
  }
  Console.WriteLine(JsonSerializer.Serialize(new{fixtureOnly=true,passed=true,checks,checkCount=checks.Count,steamClientCreated=false,networkAuthorization=false}));return 0;
 }
}
'''


def sha(path, algorithm='sha256'):
    with path.open('rb') as stream: return hashlib.file_digest(stream, algorithm).hexdigest()


def tree(root):
    result = {}
    for p in sorted(root.rglob('*')):
        if p.is_symlink(): result[str(p.relative_to(root))] = {'target': os.readlink(p)}
        elif p.is_file(): result[str(p.relative_to(root))] = {'sha256': sha(p), 'mode': p.stat().st_mode & 0o777}
    return result


def run(command, env, directory, *, input=None, timeout=180):
    process = subprocess.run(list(map(str, command)), env=env, cwd=directory, input=input, text=True, capture_output=True, timeout=timeout)
    if process.returncode: raise RuntimeError('Isolated command failed: ' + process.stdout[-7000:] + process.stderr[-1500:])
    return process.stdout


def main():
    assert (WORK / '.ready-external-workspace').read_text().strip() == 'ready project work for thread01a17e79'
    build = Path(tempfile.mkdtemp(prefix='steam-ownership-', dir=WORK / 'build')); build.chmod(0o700)
    (build / '.ready-steam-ownership-build').write_text('isolated source build; no real authorization\n')
    tools = ROOT / 'Runtime/Tools/StoreBridge'
    original_tools_before = tree(tools / 'dotnet')
    original_helper_before = tree(ROOT / 'StoreBridge/SteamBridge/bin/Release/net10.0')
    sdk = build / 'dotnet'; sdk.mkdir(mode=0o700)
    # Use the existing archive verifier without the constructor/restore methods
    # that are deliberately restricted to modifying the project's normal SDK.
    # Here load() only reads the original source/manifest/archive hashes; the
    # verifier materializes into this newly owned external destination.
    cache = sdk_cache.SDKCache.__new__(sdk_cache.SDKCache)
    cache.sdk = sdk; cache.source = tools / 'source.json'; cache.cache = tools / 'sdk-cache'; cache.manifest = cache.cache / 'manifest.json'
    manifest = cache.load()
    if shutil.disk_usage(build).free < manifest['uncompressedFileBytes'] + 512 * 1024 * 1024: raise OSError('External reserve insufficient')
    for name in ('dotnet', 'host', 'shared', 'LICENSE.txt', 'ThirdPartyNotices.txt'):
        source = tools / 'dotnet' / name; target = sdk / name
        if source.is_dir(): shutil.copytree(source, target, symlinks=True)
        else: shutil.copy2(source, target)
    cache.verify_archive(manifest, sdk)
    source = build / 'source'; project = source / 'StoreBridge/SteamBridge'; project.mkdir(parents=True)
    for source in [*sorted((ROOT / 'StoreBridge/SteamBridge').glob('*.cs')), ROOT / 'StoreBridge/SteamBridge/SteamBridge.csproj']: shutil.copy2(source, project / source.name)
    vendor = source / 'Vendor/steamkit'; vendor.parent.mkdir(parents=True)
    shutil.copytree(ROOT / 'Vendor/steamkit', vendor, ignore=shutil.ignore_patterns('bin', 'obj', '.git'))
    patch_path=ROOT/'Scripts/steamkit_websocket_close.patch'
    patch_lock=json.loads((ROOT/'Scripts/steamkit_websocket_close.lock.json').read_text())
    patch_source=vendor/patch_lock['path']; original_patch_source=ROOT/'Vendor/steamkit'/patch_lock['path']
    if sha(patch_path)!=patch_lock['patchSHA256'] or sha(patch_source)!=patch_lock['baseSHA256']:
        raise ValueError('Pinned SteamKit patch input mismatch')
    (build/'WebSocketContext.original.cs.txt').write_bytes(patch_source.read_bytes())
    shutil.copy2(patch_path,build/patch_path.name)
    run(['git','apply','--check',patch_path],env=dict(os.environ),directory=vendor)
    run(['git','apply',patch_path],env=dict(os.environ),directory=vendor)
    if sha(patch_source)!=patch_lock['patchedSHA256'] or sha(original_patch_source)!=patch_lock['baseSHA256']:
        raise ValueError('SteamKit copied-source patch output mismatch')
    (build/'steamkit-patch-receipt.json').write_text(json.dumps(patch_lock,indent=2)+'\n')
    source_inputs = tree(source)
    package_sources = {}
    for assets in [ROOT / 'StoreBridge/SteamBridge/obj/project.assets.json', ROOT / 'Vendor/steamkit/SteamKit2/SteamKit2/obj/project.assets.json']:
        document = json.loads(assets.read_text()); package_root = Path(next(iter(document['packageFolders'])))
        for library in document['libraries'].values():
            if library['type'] == 'package': package_sources[library['path']] = (package_root / library['path'], library.get('sha512'))
    packages = build / 'nuget'; packages.mkdir(mode=0o700); package_receipts = {}
    for relative, (original, expected) in package_sources.items():
        archives = list(original.glob('*.nupkg'))
        if len(archives) != 1: raise ValueError('Exact already cached NuGet archive missing')
        archive_hash = base64.b64encode(bytes.fromhex(sha(archives[0], 'sha512'))).decode()
        raw_checksum = Path(str(archives[0]) + '.sha512').read_text().strip()
        metadata = json.loads((original / '.nupkg.metadata').read_text())
        if archive_hash != raw_checksum or (expected and metadata.get('contentHash') != expected):
            raise ValueError('Cached NuGet raw archive/content identity mismatch')
        target = packages / relative; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(original, target, symlinks=True)
        if tree(original) != tree(target): raise ValueError('NuGet copy changed')
        package_receipts[relative] = {'archiveSHA512Base64': archive_hash, 'assetsContentHash': expected, 'tree': tree(target)}
    config = build / 'NuGet.Config'; config.write_text('<configuration><packageSources><clear /></packageSources></configuration>\n')
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(('DYLD_', 'STEAM', 'Steam', 'SB_', 'READY_')): env.pop(key)
    env.update({'TMPDIR': str(WORK / 'tmp') + '/', 'DOTNET_ROOT': str(sdk), 'DOTNET_CLI_HOME': str(build / 'home'),
                'NUGET_PACKAGES': str(packages), 'NUGET_HTTP_CACHE_PATH': str(build / 'http-cache'),
                'NUGET_PLUGINS_CACHE_PATH': str(build / 'plugins-cache'), 'XDG_CACHE_HOME': str(build / 'cache'),
                'DOTNET_CLI_TELEMETRY_OPTOUT': '1', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1',
                'DOTNET_GENERATE_ASPNET_CERTIFICATE': 'false', 'DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE': 'true',
                'DOTNET_EnableDiagnostics': '0', 'MSBUILDDISABLENODEREUSE': '1', 'DOTNET_MULTILEVEL_LOOKUP': '0'})
    common = [sdk / 'dotnet', 'build', project / 'SteamBridge.csproj', '-c', 'Release', '--nologo', '--configfile', config,
              '-p:TargetFrameworks=net10.0', '-p:NuGetAudit=false', '-p:UseSharedCompilation=false', '-nodeReuse:false']
    command = [*common, '-o', build / 'output']
    output = run(command, env, build); (build / 'build.log').write_text(output)
    dll = build / 'output/ReadySteamBridge.dll'; assert dll.is_file()
    # Compile the exact production decision helper into a distinct test program.
    # No fake decision operation or arbitrary result input is added to the real protocol.
    (project / 'OwnershipDecisionFixture.cs').write_text(DECISION_SOURCE)
    fixture_command = [*common, '-p:StartupObject=OwnershipDecisionFixture', '-o', build / 'decision-output']
    output = run(fixture_command, env, build); (build / 'decision-build.log').write_text(output)
    network_guard = ['sandbox-exec', '-p', '(version 1)(allow default)(deny network*)']
    decision = json.loads(run([*network_guard, sdk / 'dotnet', build / 'decision-output/ReadySteamBridge.dll'], env, build))
    assert decision['fixtureOnly'] and decision['passed'] and not decision['steamClientCreated']
    checks = {'decision-fixtures': True}
    # Exercise the same production SHA256/decision code with the broker's exact
    # minimal environment, not the richer SDK build environment.
    broker_source = ROOT / 'Scripts/steam_headless_auth_broker.py'
    broker_env = None
    for node in ast.walk(ast.parse(broker_source.read_text())):
        if isinstance(node, ast.FunctionDef) and node.name == '_request':
            for statement in node.body:
                if isinstance(statement, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'env' for t in statement.targets):
                    broker_env = ast.literal_eval(statement.value)
    if not isinstance(broker_env, dict) or broker_env.get('PATH') != '/usr/bin:/bin': raise ValueError('Broker environment contract missing')
    minimal_decision = json.loads(run([*network_guard, sdk / 'dotnet', build / 'decision-output/ReadySteamBridge.dll'], broker_env, build))
    assert minimal_decision == decision
    checks['positive-decision-hash-under-exact-broker-environment'] = True
    token_marker = 'fixture-secret-must-never-be-output'
    invalids = [None, {}, {'gameID': '0'}, {'gameID': '-1'}, {'gameID': '4294967296'}, {'gameID': ' 123'}, {'gameID': '+123'}, {'gameID': '123abc'}, {'gameID': None}, {'gameID': []}, {'gameID': 1.5}]
    for index, options in enumerate(invalids):
        request = {'operation': 'authorize_game', 'options': options, 'credentials': {'username': token_marker, 'refresh_token': token_marker}}
        process = subprocess.run([*network_guard, str(sdk / 'dotnet'), str(dll)], env=env, cwd=build,
                                 input=json.dumps(request) + '\n', text=True, capture_output=True, timeout=15)
        assert process.returncode == 1 and token_marker not in process.stdout + process.stderr
        response = json.loads(process.stdout); assert response['type'] == 'error' and response['code'] == 'invalid_game_id' and response['stage'] == 'request' and response['steamResult'] is None
        checks['invalid-protocol-game-id-' + str(index)] = True
    for index, credentials in enumerate([None, {}, {'username': 'fixture-only'}, {'username': ' ', 'refresh_token': token_marker}]):
        request = {'operation': 'authorize_game', 'options': {'gameID': 123}, 'credentials': credentials}
        process = subprocess.run([*network_guard, str(sdk / 'dotnet'), str(dll)], env=env, cwd=build,
                                 input=json.dumps(request) + '\n', text=True, capture_output=True, timeout=15)
        assert process.returncode == 1 and token_marker not in process.stdout + process.stderr
        response = json.loads(process.stdout); assert response['code'] == 'authentication_required' and response['stage'] == 'request' and response['steamResult'] is None
        checks['invalid-protocol-credential-' + str(index)] = True
    smoke = json.loads(run([*network_guard, sdk / 'dotnet', dll], env, build, input='{"operation":"self_test"}\n'))
    assert smoke['type'] == 'result' and smoke['helper'] == 'SteamKit2'; checks['existing-self-test-retained'] = True
    assert tree(tools / 'dotnet') == original_tools_before; checks['original-dotnet-runtime-unchanged'] = True
    assert tree(ROOT / 'StoreBridge/SteamBridge/bin/Release/net10.0') == original_helper_before; checks['original-current-helper-unchanged'] = True
    assert (project / 'Program.cs').read_bytes() == (ROOT / 'StoreBridge/SteamBridge/Program.cs').read_bytes()
    assert sha(original_patch_source)==patch_lock['baseSHA256'];checks['vendored-upstream-source-unchanged']=True
    licenses=build/'output/Licenses';licenses.mkdir(exist_ok=True)
    shutil.copy2(vendor/'LICENSE',licenses/'SteamKit-LGPL-2.1.txt')
    closure={str(p.relative_to(build/'output')):sha(p) for p in sorted((build/'output').rglob('*')) if p.is_file()}
    closure_sha=hashlib.sha256(json.dumps(closure,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    report = {'schema': 1, 'fixtureOnly': True, 'passed': all(checks.values()), 'checks': checks, 'checkCount': len(checks),
              'decisionFixtures': decision, 'minimalBrokerEnvironmentDecision': minimal_decision,
              'brokerEnvironment': broker_env, 'brokerSourceSHA256': sha(broker_source),
              'buildRoot': str(build), 'helperPath': str(dll), 'helperSHA256': sha(dll),
              'programSourceSHA256': sha(ROOT / 'StoreBridge/SteamBridge/Program.cs'), 'testSourceSHA256': sha(Path(__file__)),
              'steamKitSourcePatch':patch_lock,'outputFileHashes':closure,'outputClosureSHA256':closure_sha,
              'sdkSource': json.loads((tools / 'source.json').read_text()), 'sdkArchiveSHA256': manifest['archiveSHA256'],
              'commands': [command, fixture_command], 'sourceInputs': source_inputs, 'nugetInputArchives': {key: {k: v for k, v in value.items() if k != 'tree'} for key, value in package_receipts.items()},
              'realAccountAuthentication': False, 'genuineOwnershipVerified': False, 'nativeSteamLaunched': False, 'currentHelperReplaced': False}
    path = ROOT / 'Evidence/steam-ownership-preflight-fixtures.json'; path.write_text(json.dumps(report, indent=2, default=str) + '\n')
    print(json.dumps({k: report[k] for k in ['schema','fixtureOnly','passed','checkCount','decisionFixtures','buildRoot','helperPath','helperSHA256','outputClosureSHA256','programSourceSHA256','realAccountAuthentication','genuineOwnershipVerified','currentHelperReplaced']}, indent=2))


if __name__ == '__main__': main()
