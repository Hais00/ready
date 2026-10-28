#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Opt-in genuine SDK test through the actual Swift host supervisor.

Uses only the already approved private test cache, never normal Steam state.
No game, new QR, fresh SteamKit preflight or plaintext credential recovery.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
from test_steam_native_host_session_cached_sdk import checked, tree_hashes, policy, CLIENT_SHA, SDK_SHA, DISCOVERY, APP_ID
from steam_private_cache_loader import load_private_cached_login, SUCCESS_RUN
from test_steam_native_host import ROOT, WORK, processes, save, sha


def lines(path):
    # A writer may be between write() and its trailing newline.
    return [json.loads(part) for part in path.read_bytes().split(b'\n')[:-1]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-genuine-cached-sdk', action='store_true', required=True)
    parser.parse_args()
    if processes(): raise RuntimeError('Full Steam client must already be closed')
    proof = json.loads((ROOT / 'Evidence/steam-native-host-session-tests.json').read_text())['productionArtifact']
    host = checked(proof['path'], proof['sha256'])
    receipt = json.loads(checked(proof['buildReceipt'], proof['buildReceiptSHA256']).read_text())
    if any(sha(ROOT / 'Scripts' / name) != digest for name, digest in receipt['sourceHashes'].items()):
        raise ValueError('Host build does not bind the current sources')
    library = checked(Path.home() / 'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib', CLIENT_SHA)
    sdk = checked(Path('/Volumes/Dati APFS/SteamLibrary/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app/Contents/Frameworks/libsteam_api.dylib'), SDK_SHA)
    fs = checked(WORK / 'tests/steam-state-fs-fixture-faaup4ff/build/libReadySteamStateFS.dylib', 'b27736a5c6627d4988786d84654029d25ae5be81e3d451fc3c6e09e908cd2a8c')
    ipc = checked(WORK / 'tests/steam-composed-shims-zs2ne_lb/steam_native_ipc_namespace.dylib', 'bc3a48cdc3daed151a97feb1a9426016950b736f1ffeeda85e989d4e258cf69f')
    discovery = checked(DISCOVERY / 'production.dylib', 'f0a1699860c44f5c357cc23a9b3a354ffc965a1ec90f5388bdcc4bc4beeae484')
    lookup = checked(DISCOVERY / 'redirect.dylib', '167e9e7397229b0184c64d6794fdd0d87f3e623622dc1bf9fe73e06c8c7b989b')
    sdk_probe = checked(WORK / 'tests/steam-game-api-preparation-knwl1_kx/ready-game-api-probe', '7008203b6dffdc28473d5120d6d1a50f35d83901375883e2c5f6b3d7d0b9a2bf')
    run = Path(tempfile.mkdtemp(prefix='steam-swift-host-genuine-', dir=WORK / 'tests')); run.chmod(0o700)
    copied_probe = run / 'ready-native-game-api-probe'
    shutil.copy2(sdk_probe, copied_probe); sdk_probe = copied_probe
    sources = [ROOT / 'Sources/M1Launcher/SteamNativeHostProcess.swift', ROOT / 'Synthetic/ReadySteamNativeGenuineHostProbe.swift', Path(__file__), ROOT / 'Scripts/test_steam_native_host_session_cached_sdk.py']
    source_hashes = {str(p.relative_to(ROOT)): sha(p) for p in sources}
    executable = run / 'ReadySteamNativeGenuineHostProbe'
    env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'READY_', 'STEAM', 'Steam', 'SB_'))}
    env.update(TMPDIR=str(WORK / 'tmp') + '/', CLANG_MODULE_CACHE_PATH=str(WORK / 'cache/clang-steam-supervisor'))
    built = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(WORK / 'cache/swift-steam-host-supervisor'), str(sources[0]), str(sources[1]), '-o', str(executable)], env=env, capture_output=True, text=True, timeout=120)
    (run / 'build.log').write_text(built.stdout + built.stderr)
    if built.returncode: raise RuntimeError('Own Swift wrapper compilation failed')
    assets = {'host': host, 'library': library, 'discoveryLibrary': discovery, 'sdk': sdk, 'fsAdapter': fs, 'ipcAdapter': ipc, 'lookupAdapter': lookup}
    manifest = run / 'binding.json'
    save(manifest, {'schema': 1, 'kind': 'ready-steam-native-host-binding-v1', 'fixtureOnly': False, 'assets': {key: {'path': str(path), 'sha256': sha(path)} for key, path in assets.items()}, 'extraFiles': []})
    context = load_private_cached_login(reference_report=SUCCESS_RUN / 'report.json')
    source = Path(context.safe['cacheRoot']); hashes = tree_hashes(source)
    state = run / 'profile'; shutil.copytree(source, state, copy_function=shutil.copy2); state.chmod(0o700)
    if tree_hashes(state) != hashes: raise ValueError('Private cache copy differs')
    profile = str(uuid.uuid4()); events = run / 'wrapper-events.jsonl'
    life_read, life_write = os.pipe()
    descriptor = os.open(events, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    arguments = [str(executable), '--binding', str(manifest), '--binding-sha256', sha(manifest), '--profile', profile, '--state-root', str(state), '--lifeline-fd', str(life_read)]
    before = processes(); started = time.monotonic(); results = []; passed = False
    wrapper = subprocess.Popen(arguments, env=env, cwd=run, stdin=subprocess.PIPE, stdout=descriptor, stderr=subprocess.DEVNULL, pass_fds=(life_read,))
    os.close(life_read); os.close(descriptor)
    try:
        context.handoff.write_to(wrapper.stdin)
        ready = None
        while wrapper.poll() is None and time.monotonic() - started < 55:
            ready = next((e for e in lines(events) if e.get('type') == 'ready'), None)
            if ready: break
            time.sleep(.05)
        if not ready: raise RuntimeError('Actual Swift supervisor never reached ready')
        ready_at = time.monotonic()
        if not all(ready.get(key) is True for key in ('authenticated', 'identityMatches', 'ownedSubscription')) or ready.get('fixtureOnly') is not False or ready.get('gameID') != APP_ID:
            raise RuntimeError('Genuine ready result incomplete')
        namespace = ready['namespace']; service = ready['privateName']
        ports = [int(ready[key].split(':')[-1]) for key in ('masterEndpoint', 'serviceEndpoint')]
        bundle = next(p for p in library.parents if p.name == 'Steam.AppBundle')
        child_policy = run / 'sdk-child.sb'
        child_policy.write_text(policy(run, bundle, namespace, ports, list(assets.values()), sdk_probe) + '(allow process-exec (literal "/usr/bin/env"))\n(allow mach-lookup (global-name ' + json.dumps(service) + '))\n'); child_policy.chmod(0o600)
        expected = str(json.loads((SUCCESS_RUN / 'report.json').read_text())['steamKitAuthorization']['steamID'])
        child_env = dict(env, SteamAppId=str(APP_ID), SteamGameId=str(APP_ID), SteamClientLaunch='1', STEAMID=expected, READY_STEAM_GAME_API_PROBE='1', READY_STEAM_STATE_FS_LIBRARY=str(fs), READY_STEAM_IPC_LIBRARY=str(ipc), READY_STEAM_IPC_NAMESPACE=namespace, READY_STEAM_ORIGINAL_STATE_ROOT=str(bundle.parent), READY_STEAM_PRIVATE_STATE_ROOT=str(state / 'client'), READY_STEAM_DISCOVERY_SERVICE=service, XDG_CACHE_HOME=str(state / 'cache'), Steam3Master=ready['masterEndpoint'], steam_master_ipc_name_override=ready['masterEndpoint'], SteamClientService=ready['serviceEndpoint'])
        for lifetime in (0, 41):
            while time.monotonic() - ready_at < lifetime and wrapper.poll() is None: time.sleep(.1)
            if wrapper.poll() is not None: raise RuntimeError('Actual Swift supervisor exited early')
            command = ['/usr/bin/sandbox-exec', '-f', str(child_policy), '/usr/bin/env', 'DYLD_PRINT_LIBRARIES=1', 'DYLD_LIBRARY_PATH=' + str(library.parent), 'DYLD_INSERT_LIBRARIES=' + ':'.join(map(str, [fs, ipc, lookup])), str(sdk_probe), '--allow-sdk-execution', '--library', str(sdk), '--code-root', str(sdk.parent), '--expected-sha256', SDK_SHA, '--mode', 'init-flat', '--callback-ms', '250']
            probe = subprocess.run(command, env=child_env, cwd=run, capture_output=True, text=True, timeout=12)
            output = [json.loads(line) for line in probe.stdout.splitlines() if line.startswith('{')]
            adapters = all(str(p) in probe.stderr for p in (fs, ipc, lookup))
            success = probe.returncode == 0 and adapters and any(e.get('apiInitialized') is True and e.get('shutdownCalled') is True and e.get('restartCalled') is False for e in output) and any(e.get('gameAPIContextAuthenticated') is True and e.get('identityMatches') is True and e.get('ownedSubscriptionObserved') is True for e in output)
            results.append({'passed': success, 'secondsAfterReady': round(time.monotonic() - ready_at, 3), 'exitCode': probe.returncode, 'startupAdaptersObserved': adapters, 'events': output})
            if not success: raise RuntimeError('SDK failed against the actual Swift-supervised host')
        passed = True
    finally:
        context.close(); os.close(life_write)
        try: code = wrapper.wait(timeout=10)
        except subprocess.TimeoutExpired:
            wrapper.terminate()
            try: code = wrapper.wait(timeout=3)
            except subprocess.TimeoutExpired: wrapper.kill(); code = wrapper.wait(timeout=3)
        terminal = next((e for e in lines(events) if e.get('type') == 'wrapper_exit'), {})
        verified = passed and code == 0 and terminal.get('hostCode') == 42 and terminal.get('cancelled') is True and terminal.get('invalidEvents') is False and processes() == before and tree_hashes(source) == hashes
        report = {'schema': 1, 'kind': 'genuine-native-swift-supervisor-cached-sdk', 'passed': verified, 'fixtureOnly': False, 'newQRRequired': False, 'freshSteamKitPreflight': False, 'sourceCachePreserved': tree_hashes(source) == hashes, 'fullSteamProcessesUnchanged': processes() == before, 'gameExecuted': False, 'genuineSDKChecks': results, 'wrapperExitCode': code, 'supervisedHostExit': terminal, 'sourceHashes': source_hashes, 'sourcesUnchanged': source_hashes == {str(p.relative_to(ROOT)): sha(p) for p in sources}, 'hostSHA256': sha(host), 'clientSHA256': CLIENT_SHA, 'sdkSHA256': SDK_SHA, 'bindingSHA256': sha(manifest), 'wrapperSHA256': sha(executable)}
        save(run / 'report.json', report)
        print(json.dumps({'passed': verified, 'report': str(run / 'report.json'), 'sha256': sha(run / 'report.json'), 'sdkChecks': len(results), 'wrapperExitCode': code}), flush=True)
    return 0 if verified else 1


if __name__ == '__main__': raise SystemExit(main())
