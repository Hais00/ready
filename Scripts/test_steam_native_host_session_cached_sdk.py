#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Opt-in genuine host-lifetime/SDK check with the approved private test cache.

No game, QR, normal Steam state, plaintext cache recovery, or ownership emulator.
This is a local research driver, not the launcher credentials or deployment path.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
from steam_private_cache_loader import load_private_cached_login, SUCCESS_RUN
from test_steam_native_host import ROOT, WORK, processes, save, sha

CLIENT_SHA = 'b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd'
SDK_SHA = '2cbe2533e09d1561051f417d7b8c784481a2efdc4fc9d1274704ee8a7ef50cb1'
DISCOVERY = WORK / 'retained/research-steam-native/discovery-mock-0e6c0e88bf534830b4d3f21183660926'
APP_ID = 1091500


def checked(path, expected):
    path = Path(path)
    if path.is_symlink() or path.resolve(strict=True) != path:
        raise ValueError('Asset alias rejected')
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or sha(path) != expected:
        raise ValueError('Unverified local asset')
    return path


def tree_hashes(root):
    output = {}
    for item in root.rglob('*'):
        info = item.lstat()
        if info.st_uid != os.getuid() or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise ValueError('Unsafe private cache tree')
        if stat.S_ISREG(info.st_mode):
            output[str(item.relative_to(root))] = sha(item)
    return output


def policy(run, bundle, namespace, ports, assets, executable):
    # Same measured boundary as the earlier native SDK diagnostic. No global
    # Steam service, user-state read, arbitrary loopback, or Keychain grant.
    lines = ['(version 1)', '(allow default)', '(deny network*)', '(deny mach-lookup)',
             '(allow mach-lookup (global-name "com.apple.dyld") (global-name "com.apple.mDNSResponder") (global-name "com.apple.SystemConfiguration.configd") (global-name "com.apple.trustd.agent"))',
             '(allow network-outbound (require-not (remote ip "localhost:*")))',
             '(deny network-outbound (remote unix-socket (path-regex #".*")))',
             '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")) (remote unix-socket (path-literal "/var/run/mDNSResponder")))',
             '(allow network-bind)', '(deny ipc-posix-shm ipc-posix-sem)']
    for letter, operation in [('S', 'ipc-posix-shm'), ('E', 'ipc-posix-sem')]:
        pattern = '^/R' + letter + namespace[:16] + '_' + '[a-f0-9]' * 10 + '$'
        lines.append('(allow ' + operation + ' (ipc-posix-name-regex #' + json.dumps(pattern) + '))')
    for port in ports:
        endpoint = json.dumps('localhost:' + str(port))
        for operation, direction in [('network-bind', 'local'), ('network-inbound', 'local'), ('network-outbound', 'remote')]:
            lines.append('(allow ' + operation + ' (' + direction + ' ip ' + endpoint + '))')
    denied = ['/Users', '/private/var/root', '/Library/Keychains', str(WORK), '/private/var/folders', '/private/tmp', '/tmp', '/opt/homebrew', '/usr/local']
    lines += ['(deny file-read* ' + ' '.join('(subpath ' + json.dumps(x) + ')' for x in denied) + ')',
              '(allow file-read* (subpath ' + json.dumps(str(bundle)) + ') (subpath ' + json.dumps(str(run)) + '))',
              '(allow file-read-metadata)', '(deny file-write*)',
              '(allow file-write* (subpath ' + json.dumps(str(run)) + ') (literal "/dev/null"))',
              '(deny file-map-executable (subpath ' + json.dumps(str(run / 'state')) + '))',
              '(deny process-exec)', '(allow process-exec (literal ' + json.dumps(str(executable)) + '))']
    for asset in assets:
        lines.append('(allow file-read* (literal ' + json.dumps(str(asset)) + '))')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-genuine-cached-sdk', action='store_true', required=True)
    args = parser.parse_args()
    if processes():
        raise RuntimeError('Full Steam client must already be closed')
    proof = json.loads((ROOT / 'Evidence/steam-native-host-session-tests.json').read_text())['productionArtifact']
    host = checked(proof['path'], proof['sha256'])
    receipt = json.loads(checked(proof['buildReceipt'], proof['buildReceiptSHA256']).read_text())
    if any(sha(ROOT / 'Scripts' / name) != digest for name, digest in receipt['sourceHashes'].items()):
        raise ValueError('Production host source changed since fixture validation')
    library = checked(Path.home() / 'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib', CLIENT_SHA)
    sdk = checked(Path('/Volumes/Dati APFS/SteamLibrary/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app/Contents/Frameworks/libsteam_api.dylib'), SDK_SHA)
    fs = checked(WORK / 'tests/steam-composed-shims-zs2ne_lb/steam_native_state_fs.dylib', '0247d1244ff123c694f46edf545585d93af7c746575763006bd08136405ac877')
    ipc = checked(WORK / 'tests/steam-composed-shims-zs2ne_lb/steam_native_ipc_namespace.dylib', 'bc3a48cdc3daed151a97feb1a9426016950b736f1ffeeda85e989d4e258cf69f')
    discovery = checked(DISCOVERY / 'production.dylib', 'f0a1699860c44f5c357cc23a9b3a354ffc965a1ec90f5388bdcc4bc4beeae484')
    lookup = checked(DISCOVERY / 'redirect.dylib', '167e9e7397229b0184c64d6794fdd0d87f3e623622dc1bf9fe73e06c8c7b989b')
    probe = checked(WORK / 'tests/steam-game-api-preparation-knwl1_kx/ready-game-api-probe', '7008203b6dffdc28473d5120d6d1a50f35d83901375883e2c5f6b3d7d0b9a2bf')
    context = load_private_cached_login(reference_report=SUCCESS_RUN / 'report.json')
    source = Path(context.safe['cacheRoot'])
    before_hashes = tree_hashes(source)
    run = Path(tempfile.mkdtemp(prefix='steam-host-session-genuine-', dir=WORK / 'tests'))
    run.chmod(0o700)
    shutil.copytree(source, run / 'state', copy_function=shutil.copy2)
    if tree_hashes(run / 'state') != before_hashes:
        raise ValueError('Private copy differs')
    worker = run / 'ready-steam-native-host-session'
    child_probe = run / 'ready-native-game-api-probe'
    shutil.copy2(host, worker); shutil.copy2(probe, child_probe)
    (run / 'tmp').mkdir(mode=0o700)
    namespace = uuid.uuid4().hex
    service = 'app.ready.steam.ipctool.' + namespace
    sockets = [socket.socket() for _ in range(2)]
    try:
        for s in sockets: s.bind(('127.0.0.1', 0))
        ports = [s.getsockname()[1] for s in sockets]
    finally:
        for s in sockets: s.close()
    bundle = next(x for x in library.parents if x.name == 'Steam.AppBundle')
    assets = [fs, ipc, discovery, lookup, sdk]
    base = policy(run, bundle, namespace, ports, assets, worker)
    host_policy = run / 'host.sb'
    host_policy.write_text(base + '(allow mach-register (global-name ' + json.dumps(service) + '))\n(allow mach-lookup (global-name ' + json.dumps(service) + '))\n')
    child_policy = run / 'child.sb'
    child_policy.write_text(policy(run, bundle, namespace, ports, assets, child_probe) + '(allow mach-lookup (global-name ' + json.dumps(service) + '))\n(allow process-exec (literal "/usr/bin/env"))\n')
    host_policy.chmod(0o600); child_policy.chmod(0o600)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'STEAM', 'Steam', 'SB_', 'M1L_', 'READY_'))}
    env.update(TMPDIR=str(run / 'tmp') + '/', XDG_CACHE_HOME=str(run / 'state'), READY_STEAM_STATE_FS_LIBRARY=str(fs), READY_STEAM_IPC_LIBRARY=str(ipc), READY_STEAM_IPC_NAMESPACE=namespace, READY_STEAM_ORIGINAL_STATE_ROOT=str(bundle.parent), READY_STEAM_PRIVATE_STATE_ROOT=str(run / 'state/client'), steam_master_ipc_name_override='127.0.0.1:' + str(ports[0]), SteamClientService='127.0.0.1:' + str(ports[1]))
    event_path = run / 'host-events.jsonl'
    life_read, life_write = os.pipe()
    events_fd = os.open(event_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    command = ['/usr/bin/sandbox-exec', '-f', str(host_policy), str(worker), '--host-session', '--library', str(library), '--lifeline-fd', str(life_read), '--events-fd', '1', '--mode', 'cached', '--discovery-library', str(discovery), '--discovery-service', service, '--sdk', str(sdk)]
    before = processes(); started = time.monotonic(); sdk_results = []
    child = subprocess.Popen(command, env=env, cwd=run, stdin=subprocess.PIPE, stdout=events_fd, stderr=subprocess.DEVNULL, pass_fds=(life_read,))
    os.close(life_read); os.close(events_fd)
    passed = False
    try:
        context.handoff.write_to(child.stdin)
        ready_at = None
        while child.poll() is None and time.monotonic() - started < 50:
            events = [json.loads(line) for line in event_path.read_text().splitlines()]
            if any(e.get('type') == 'ready' and e.get('authenticated') is True and e.get('identityMatches') is True and e.get('ownedSubscription') is True and e.get('gameID') == APP_ID for e in events):
                ready_at = time.monotonic(); break
            time.sleep(.05)
        if ready_at is None:
            raise RuntimeError('Genuine persistent host did not become ready')
        expected = str(json.loads((SUCCESS_RUN / 'report.json').read_text())['steamKitAuthorization']['steamID'])
        child_env = dict(env, SteamAppId=str(APP_ID), SteamGameId=str(APP_ID), SteamClientLaunch='1', STEAMID=expected, READY_STEAM_GAME_API_PROBE='1', READY_STEAM_DISCOVERY_SERVICE=service, Steam3Master=env['steam_master_ipc_name_override'])
        for minimum_lifetime in (0, 41):
            while time.monotonic() - ready_at < minimum_lifetime and child.poll() is None:
                time.sleep(.1)
            if child.poll() is not None:
                raise RuntimeError('Persistent host exited before its lifeline closed')
            argv = ['/usr/bin/sandbox-exec', '-f', str(child_policy), '/usr/bin/env', 'DYLD_PRINT_LIBRARIES=1', 'DYLD_LIBRARY_PATH=' + str(library.parent), 'DYLD_INSERT_LIBRARIES=' + ':'.join(map(str, [fs, ipc, lookup])), str(child_probe), '--allow-sdk-execution', '--library', str(sdk), '--code-root', str(sdk.parent), '--expected-sha256', SDK_SHA, '--mode', 'init-flat', '--callback-ms', '250']
            result = subprocess.run(argv, env=child_env, cwd=run, capture_output=True, text=True, timeout=12)
            observed = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            adapters = all(str(x) in result.stderr for x in (fs, ipc, lookup))
            success = result.returncode == 0 and adapters and any(e.get('apiInitialized') is True and e.get('shutdownCalled') is True and e.get('restartCalled') is False for e in observed) and any(e.get('gameAPIContextAuthenticated') is True and e.get('genuineUserLoggedOn') is True and e.get('identityMatches') is True and e.get('ownedSubscriptionObserved') is True for e in observed)
            sdk_results.append({'passed': success, 'secondsAfterReady': round(time.monotonic() - ready_at, 3), 'exitCode': result.returncode, 'startupAdaptersObserved': adapters, 'events': observed})
            if not success:
                raise RuntimeError('Genuine SDK authentication check failed')
        passed = True
    finally:
        context.close()
        os.close(life_write)
        try: exit_code = child.wait(timeout=4)
        except subprocess.TimeoutExpired:
            child.terminate()
            try: exit_code = child.wait(timeout=3)
            except subprocess.TimeoutExpired: child.kill(); exit_code = child.wait(timeout=3)
        report = {'schema': 1, 'kind': 'genuine-native-host-session-cached-sdk', 'passed': passed and exit_code == 42 and processes() == before and tree_hashes(source) == before_hashes, 'fixtureOnly': False, 'freshSteamKitPreflight': False, 'newQRRequired': False, 'sourceCachePreserved': tree_hashes(source) == before_hashes, 'genuineSDKChecks': sdk_results, 'hostExitCode': exit_code, 'lifelineClosedByParent': True, 'fullSteamProcessesUnchanged': processes() == before, 'gameExecuted': False, 'driverSHA256': sha(Path(__file__)), 'hostSHA256': sha(worker), 'clientSHA256': sha(library), 'sdkSHA256': sha(sdk), 'hostEventsSHA256': sha(event_path), 'hostPolicySHA256': sha(host_policy), 'childPolicySHA256': sha(child_policy)}
        save(run / 'report.json', report)
        print(json.dumps({'passed': report['passed'], 'report': str(run / 'report.json'), 'reportSHA256': sha(run / 'report.json'), 'sdkChecks': len(sdk_results), 'hostExitCode': exit_code}), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
