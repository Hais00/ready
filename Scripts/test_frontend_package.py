#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify a relocated frontend app headlessly, without accounts or engine execution."""
import argparse
import hashlib
import json
import os
import pathlib
import shlex
import shutil
import stat
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def check(app, installed_runtime=None):
    checks = []
    with tempfile.TemporaryDirectory(prefix='ready-frontend-relocation-') as raw:
        temporary = pathlib.Path(raw).resolve()
        relocated = temporary / 'Different Folder/ready.app'
        relocated.parent.mkdir()
        shutil.copytree(app, relocated)
        code = relocated / 'Contents/Resources/ReadySupport'
        executable = relocated / 'Contents/MacOS/ready'
        data = temporary / 'isolated-data'
        cwd = temporary / 'unrelated-working-directory'
        cwd.mkdir()
        environment = {k: v for k, v in os.environ.items() if k not in ('READY_PROJECT_ROOT', 'READY_RUNTIME_ROOT', 'READY_DATA_ROOT')}
        environment['PYTHONDONTWRITEBYTECODE'] = '1'
        manifest = json.loads((code / 'frontend-package.json').read_text())
        assert not manifest['externalRuntimeIncluded'] and not manifest['proprietaryAppleFilesIncluded']
        assert manifest['wholeApplicationRedistributionApproved'] is False
        for item in manifest['files']:
            path = code / item['path']
            assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'], item['path']
        assert not (relocated / 'Contents/Resources/development-root.txt').exists()
        assert not any((code / name).exists() for name in ('Runtime', 'Vendor', 'Evidence', 'StoreBridge/Dependencies'))
        native = {path.relative_to(relocated).as_posix() for path in relocated.rglob('*') if path.is_file() and path.read_bytes()[:4] in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')}
        assert native == {'Contents/MacOS/ready', 'Contents/Resources/ReadySupport/Build/ReadySessionHost', 'Contents/Resources/ReadySupport/Build/libReadyOverlay.dylib', 'Contents/Resources/ReadySupport/Build/libReadyHostedGame.dylib'}, native
        assert {'Sources/ReadyHostedView/include/ReadyHostedView.h', 'Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h', 'NativeEmbedding/ReadyHostedGameShim.m', 'Scripts/build_hosted_game_shim.sh'}.issubset({item['path'] for item in manifest['files']})
        checks.append('owned payload hashes, hosted-view/shim corresponding sources and exact four-native-file inventory')
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(relocated)], check=True, capture_output=True)
        checks.append('relocated app signature verified')

        def probe(env):
            result = subprocess.run([str(executable), '--frontend-self-test', '--data-root', str(data)], cwd=cwd, env=env, capture_output=True, text=True, check=True, timeout=30)
            return json.loads(result.stdout)

        report = probe(environment)
        assert report['bundledFrontend'] and report['frontendSupportAvailable']
        assert pathlib.Path(report['codeRoot']).resolve() == code
        assert pathlib.Path(report['runtimeRoot']) == data / 'Runtimes'
        assert not report['runtimeConfigurationAvailable'] and not data.exists()
        checks.append('relocated frontend uses bundled code and reports absent external runtime without writes')
        external = temporary / 'external-runtime'
        external.mkdir()
        (external / 'runtime.json').write_text('{"engineDLLs":{}}\n')
        overridden = {**environment, 'READY_RUNTIME_ROOT': str(external)}
        report = probe(overridden)
        assert report['runtimeConfigurationAvailable'] and pathlib.Path(report['runtimeConfiguration']).resolve() == external / 'runtime.json'
        assert not data.exists()
        checks.append('explicit external runtime root selected without state writes')
        def location_action(action, value=None, target=data, env=environment, succeeds=True):
            command = [str(executable), action]
            if value is not None:
                command.append(str(value))
            command += ['--data-root', str(target)]
            result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=30)
            assert (result.returncode == 0) == succeeds, (command, result.returncode, result.stderr)
            return json.loads(result.stdout) if succeeds else result

        report = location_action('--set-runtime-root', external)
        pointer = data / 'Runtimes/external-runtime-location.json'
        assert report['runtimeLocationOrigin'] == 'saved' and pathlib.Path(report['runtimeRoot']) == external
        assert not (data / 'Runtimes/runtime.json').exists()
        assert json.loads(pointer.read_text())['root'] == str(external)
        assert stat.S_IMODE(pointer.stat().st_mode) == 0o600 and pointer.stat().st_uid == os.getuid()
        assert stat.S_IMODE(data.stat().st_mode) == stat.S_IMODE((data / 'Runtimes').stat().st_mode) == 0o700
        assert probe(environment)['runtimeLocationOrigin'] == 'saved'
        checks.append('explicit scoped selection persists privately across launches without creating runtime.json')
        second = temporary / 'second-runtime'
        second.mkdir()
        (second / 'runtime.json').write_text('{"engineDLLs":{}}\n')
        report = location_action('--set-runtime-root', second)
        assert pathlib.Path(report['runtimeRoot']) == second
        report = location_action('--restore-runtime-root')
        assert pathlib.Path(report['runtimeRoot']) == external
        report = location_action('--reset-runtime-root')
        assert report['runtimeLocationOrigin'] == 'application-data' and not pointer.exists()
        report = location_action('--restore-runtime-root')
        assert pathlib.Path(report['runtimeRoot']) == external
        backups = list((data / 'Runtimes/RuntimeLocationHistory').glob('*.json'))
        assert len(backups) >= 5 and all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in backups)
        checks.append('selection change, reset and previous-location restore retain private history')
        report = probe({**environment, 'READY_RUNTIME_ROOT': str(second)})
        assert report['runtimeLocationOrigin'] == 'environment' and pathlib.Path(report['runtimeRoot']).resolve() == second
        assert pathlib.Path(probe(environment)['runtimeRoot']) == external
        checks.append('environment location overrides saved location without modifying it')
        symlink_wine = temporary / 'symlink-wine-runtime'
        symlink_wine.mkdir()
        (symlink_wine / 'wine').symlink_to('/usr/bin/true')
        (symlink_wine / 'runtime.json').write_text(json.dumps({'engineDLLs': {}, 'wine': str(symlink_wine / 'wine')}))
        report = location_action('--set-runtime-root', symlink_wine)
        assert pathlib.Path(report['runtimeRoot']) == symlink_wine
        report = location_action('--restore-runtime-root')
        assert pathlib.Path(report['runtimeRoot']) == external
        before = pointer.read_bytes()
        malformed = temporary / 'malformed-runtime'
        malformed.mkdir()
        (malformed / 'runtime.json').write_text('{broken json')
        declared_missing = temporary / 'missing-wine-runtime'
        declared_missing.mkdir()
        (declared_missing / 'runtime.json').write_text(json.dumps({'engineDLLs': {}, 'wine': str(temporary / 'missing-wine')}))
        declared_directory = temporary / 'directory-wine-runtime'
        declared_directory.mkdir()
        (declared_directory / 'runtime.json').write_text(json.dumps({'engineDLLs': {}, 'wine': str(external)}))
        alias = temporary / 'runtime-alias'
        alias.symlink_to(external, target_is_directory=True)
        for invalid in ('/', 'relative-runtime', temporary / 'missing-runtime', malformed, declared_missing, declared_directory, alias, str(external) + '/../external-runtime'):
            location_action('--set-runtime-root', invalid, succeeds=False)
            assert pointer.read_bytes() == before
        result = subprocess.run([str(executable), '--set-runtime-root', str(external)], cwd=cwd, env=environment, capture_output=True, timeout=30)
        assert result.returncode != 0 and pointer.read_bytes() == before
        checks.append('invalid root, relative, missing, malformed, missing or directory Wine and symlink roots rejected; final Wine symlink to regular executable accepted')
        outside = temporary / 'outside-data'
        outside.mkdir(mode=0o700)
        linked_data = temporary / 'linked-data'
        linked_data.symlink_to(outside, target_is_directory=True)
        location_action('--set-runtime-root', external, target=linked_data, succeeds=False)
        assert not list(outside.iterdir())
        unsafe = temporary / 'unsafe-data'
        unsafe.mkdir(mode=0o755)
        location_action('--set-runtime-root', external, target=unsafe, succeeds=False)
        assert not list(unsafe.iterdir())
        linked_runtime_data = temporary / 'linked-runtime-data'
        linked_runtime_data.mkdir(mode=0o700)
        (linked_runtime_data / 'Runtimes').symlink_to(outside, target_is_directory=True)
        location_action('--set-runtime-root', external, target=linked_runtime_data, succeeds=False)
        assert not list(outside.iterdir())
        pointer_data = temporary / 'linked-pointer-data'
        (pointer_data / 'Runtimes').mkdir(parents=True, mode=0o700)
        pointer_data.chmod(0o700)
        sentinel = outside / 'untouched.json'
        sentinel.write_text('untouched')
        (pointer_data / 'Runtimes/external-runtime-location.json').symlink_to(sentinel)
        location_action('--set-runtime-root', external, target=pointer_data, succeeds=False)
        assert sentinel.read_text() == 'untouched'
        unowned = next((p for p in temporary.parents if p != pathlib.Path('/') and p.stat().st_uid != os.getuid() and not os.access(p, os.W_OK) and p.resolve() == p), None)
        assert unowned is not None, 'Ownership negative fixture requires a nonwritable existing ancestor'
        location_action('--set-runtime-root', external, target=unowned, succeeds=False)
        checks.append('unowned, unsafe permissions and symlink data/runtime/pointer paths rejected without external writes')
        corrupt_data = temporary / 'corrupt-pointer-data'
        location_action('--set-runtime-root', external, target=corrupt_data)
        corrupt_pointer = corrupt_data / 'Runtimes/external-runtime-location.json'
        corrupt_pointer.write_text('{broken owned pointer')
        corrupt_pointer.chmod(0o600)
        report = location_action('--reset-runtime-root', target=corrupt_data)
        assert report['runtimeLocationOrigin'] == 'application-data' and not corrupt_pointer.exists()
        snapshots = [json.loads(p.read_text()) for p in (corrupt_data / 'Runtimes/RuntimeLocationHistory').glob('*.json')]
        assert any(snapshot.get('originalBytes') for snapshot in snapshots)
        checks.append('reset recovers a corrupt owned pointer while retaining its original bytes')
        portable = temporary / 'Portable Runtime A'
        (portable / 'bin').mkdir(parents=True)
        never_run = temporary / 'validation-must-not-execute-wine'
        wine = portable / 'bin/wine'
        wine.write_text('#!/bin/sh\ntouch ' + shlex.quote(str(never_run)) + '\n')
        wine.chmod(0o700)
        portable_bytes = json.dumps({'pathFormat': 'runtime-relative-v1', 'wine': 'bin/wine', 'engineDLLs': {}}).encode()
        (portable / 'runtime.json').write_bytes(portable_bytes)
        portable_data = temporary / 'portable-selection-data'
        report = location_action('--set-runtime-root', portable, target=portable_data)
        assert pathlib.Path(report['runtimeRoot']) == portable and not never_run.exists()
        moved_portable = temporary / 'Portable Runtime B moved with spaces'
        portable.rename(moved_portable)
        report = location_action('--set-runtime-root', moved_portable, target=portable_data)
        assert pathlib.Path(report['runtimeRoot']) == moved_portable
        assert (moved_portable / 'runtime.json').read_bytes() == portable_bytes and not never_run.exists()
        portable_pointer = portable_data / 'Runtimes/external-runtime-location.json'
        previous_pointer = portable_pointer.read_bytes()
        unknown_format = temporary / 'unknown-path-format-runtime'
        unknown_format.mkdir()
        (unknown_format / 'runtime.json').write_text(json.dumps({'pathFormat': 'unknown-future-format', 'engineDLLs': {}}))
        location_action('--set-runtime-root', unknown_format, target=portable_data, succeeds=False)
        assert portable_pointer.read_bytes() == previous_pointer
        checks.append('versioned relative runtime remains selectable after a real move without rewriting it or executing Wine; unknown format preserves pointer')
        user_config = data / 'Runtimes/runtime.json'
        user_config.write_text('{"engineDLLs":{},"runtimeID":"owned-user-config-sentinel"}\n')
        original_config = user_config.read_bytes()
        location_action('--set-runtime-root', second)
        assert user_config.read_bytes() == original_config
        assert pathlib.Path(probe(environment)['runtimeConfiguration']) == user_config
        report = probe(overridden)
        assert pathlib.Path(report['runtimeConfiguration']) == data / 'Runtimes/runtime.json'
        checks.append('per-user runtime configuration takes precedence and selection never overwrites it')
        result = subprocess.run(['python3', str(code / 'StoreBridge/supervisor.py'), str(code / 'StoreBridge/bridge.py')], input='{"operation":"capabilities"}\n', cwd=cwd, env={**environment, 'READY_DATA_ROOT': str(data)}, capture_output=True, text=True, check=True, timeout=30)
        assert any(json.loads(line).get('protocolVersion') == 1 for line in result.stdout.splitlines())
        checks.append('bundled Python bridge capabilities through supervisor, no account request')
        locator = 'import sys,json;sys.path.insert(0,sys.argv[1]);import runtime_paths as p;print(json.dumps([str(p.tools_root()),str(p.tool_payload("SteamBridge/ReadySteamBridge.dll","StoreBridge/SteamBridge/bin/Release/net10.0/ReadySteamBridge.dll"))]))'
        result = subprocess.run(['python3', '-c', locator, str(code / 'StoreBridge')], env={**overridden, 'READY_DATA_ROOT': str(data)}, cwd=cwd, check=True, capture_output=True, text=True)
        paths = json.loads(result.stdout)
        assert pathlib.Path(paths[0]) == external / 'Tools/StoreBridge'
        assert pathlib.Path(paths[1]) == external / 'Tools/StoreBridge/SteamBridge/ReadySteamBridge.dll'
        checks.append('store tools and compiled helper stay under explicit external runtime')
        if installed_runtime is not None:
            installed_runtime = installed_runtime.resolve()
            config = installed_runtime / 'runtime.json'
            original = hashlib.sha256(config.read_bytes()).hexdigest()
            fresh_data = temporary / 'actual-central-runtime-selection'
            report = location_action('--set-runtime-root', installed_runtime, target=fresh_data)
            assert report['runtimeLocationOrigin'] == 'saved' and pathlib.Path(report['runtimeRoot']).resolve() == installed_runtime
            assert report['runtimeConfigurationAvailable'] and pathlib.Path(report['runtimeConfiguration']).resolve() == config
            assert hashlib.sha256(config.read_bytes()).hexdigest() == original
            checks.append('actual existing central runtime selected and decoded through saved pointer with original configuration untouched')
    return {'passed': True, 'scope': 'headless relocated frontend only; no real GPU, game, account, or full-runtime validation', 'checks': checks}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, default=ROOT / 'Build/ready.app')
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--external-runtime', type=pathlib.Path, help='Optionally validate an existing central root read-only using an isolated pointer')
    args = parser.parse_args()
    report = check(args.app, args.external_runtime)
    text = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text, end='')
