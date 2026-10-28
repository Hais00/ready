#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Local optional Apple/WineCX overlay evaluation with an owned Windows swapchain probe.

Uses the separate disabled evaluation configuration and a fresh private prefix.
Does not enable consumer play, alter the default runtime, change framebufferOnly,
interact with the desktop UI, or redistribute Apple's separately licensed binaries.
GPU completion counters establish integration; they do not establish pixel output
or direct-to-display on the locked desktop.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def atomic(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    temporary.chmod(0o600)
    temporary.replace(path)


def state_until(path, predicate, process, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            state = json.loads(path.read_text())
            if state.get('failedGPUOverlaySubmissions', 0) or state.get('error'):
                raise AssertionError('Overlay GPU failure: ' + state.get('error', 'unknown'))
            if predicate(state):
                return state
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if process.poll() is not None:
            raise AssertionError(f'Owned swapchain probe exited ({process.returncode}) before required GPU state')
        time.sleep(0.025)
    raise AssertionError('No required actual drawable/GPU state; a locked/occluded presentation path may be unavailable')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--api', choices=['d3d11', 'd3d12'], required=True)
    parser.add_argument('--evaluation-runtime', type=Path, default=ROOT/'Runtime/evaluation-runtime.json')
    parser.add_argument('--exe', type=Path)
    args = parser.parse_args()
    executable = (args.exe or ROOT/f'Runtime/Probes/runtime_{args.api}_present.exe').resolve()
    assert executable.is_file() and executable.parent == (ROOT/'Runtime/Probes').resolve(), 'Use our locally compiled Windows presentation probe'
    config = json.loads(args.evaluation_runtime.read_text())
    policy = config.get('appleOptional', {})
    assert policy.get('evaluationOnly') is True and policy.get('enabledForConsumerPlay') is False
    assert config.get('evaluationModeEnabled') is False and policy.get('enabled') is False, 'The source evaluation configuration must remain disabled'
    assert policy.get('publicRedistributionEnabled') is False and policy.get('applicationBundleInclusionEnabled') is False
    wine = Path(config['engineWineBinaries']['d3dMetal'])
    server = Path(config['engineWineServers']['d3dMetal'])
    pure32 = Path(config['engineBootstrap32Dirs']['d3dMetal'])
    dlls = Path(config['engineDLLs']['d3dMetal'])
    provider_id = config['engineProviderIDs']['d3dMetal']
    provider_root = wine.parent.parent.parent
    manifest = provider_root/'evaluation-manifest.json'
    host = ROOT/'Build/ReadySessionHost'
    overlay = ROOT/'Build/libReadyOverlay.dylib'
    for path in (wine, server, host, overlay, manifest):
        assert path.is_file(), str(path)
    assert pure32.is_dir() and dlls.is_dir()
    default_config = ROOT/'Runtime/runtime.json'
    default_sha = digest(default_config)
    work = ROOT/'Runtime/TestPrefixes'/('apple-overlay-'+args.api+'-'+str(uuid.uuid4()))
    work.mkdir(parents=True, mode=0o700)
    prefix = work/'prefix'
    prefix.mkdir(mode=0o700)
    state_file = work/'overlay-status.json'
    control = work/'control.json'
    log_path = ROOT/f'Evidence/overlay-apple-{args.api}.log'
    report_path = ROOT/f'Evidence/overlay-apple-{args.api}.json'
    report = {'passed': False, 'api': args.api, 'providerID': provider_id,
              'runtimeID': config['runtimeID'], 'evaluationOnly': True,
              'enabledForConsumerPlay': False, 'defaultConfigurationChanged': False,
              'probeSHA256': digest(executable), 'overlaySHA256': digest(overlay),
              'evaluationConfigurationSHA256': digest(args.evaluation_runtime),
              'providerManifestSHA256': digest(manifest),
              'directToDisplayVerified': False, 'fullscreenVerified': False, 'metal4Requested': True,
              'appleEndToEndPixelReadbackVerified': False,
              'note': 'Real WineCX/Apple drawable integration and command-buffer GPU completion only. No desktop/UI observation or arbitrary game compatibility inference.'}
    process = None
    failure = None
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('DYLD_', 'M1L_', 'READY_', 'WINE', 'VK_', 'CX_'))}
    env.update(WINEPREFIX=str(prefix), WINEDEBUG='+loaddll',
               WINEDLLOVERRIDES=config['engineOverrides']['d3dMetal'],
               WINEDLLPATH=config['engineSearchPaths']['d3dMetal'])
    with (work/'prefix.lock').open('a+b') as lease, log_path.open('wb') as log:
        os.fchmod(lease.fileno(), 0o600)
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)

        def spawn(arguments, environment, game=False):
            command = [str(host), '--wine-server', str(server), '--prefix', str(prefix)]
            if game:
                command += ['--installation', str(executable.parent), '--installation-lock-root', str(work/'InstallLocks')]
            return subprocess.Popen(command+['--']+list(map(str, arguments)), stdin=lease,
                                    stdout=log, stderr=log, env=environment)

        try:
            # Match the frozen WineCX's PURE PE32 bootstrap before Wineboot. No
            # shared template or source prefix is used. APFS clones isolate writes.
            wow64 = prefix/'drive_c/windows/syswow64'
            wow64.mkdir(parents=True)
            subprocess.run(['/bin/cp', '-cR', str(pure32)+'/.', str(wow64)], check=True)
            process = spawn([wine, 'wineboot', '-u'], env)
            assert process.wait(timeout=120) == 0, 'WineCX prefix initialization failed'
            system = prefix/'drive_c/windows/system32'
            projected = {}
            for name in ('d3d11.dll', 'd3d12.dll', 'd3d12core.dll', 'dxgi.dll'):
                assert digest(system/name) == digest(dlls/name), 'Prefix builtin does not match frozen Apple provider: '+name
                projected[name] = digest(system/name)
            report['prefixGraphicsDLLSHA256'] = projected
            atomic(control, {'sequence': 1, 'visible': False, 'selection': 0})
            game_env = {**env, 'READY_OVERLAY_LIBRARY': str(overlay),
                        'M1L_CONTROL_FILE': str(control), 'M1L_OVERLAY_STATUS': str(state_file),
                        'MTL_HUD_ENABLED': '0', 'D3DM_MTL4': '1'}
            process = spawn([wine, executable], game_env, game=True)
            idle = state_until(state_file, lambda state: state.get('frameCount', 0) > 0
                               and state.get('injectionSupported') and not state.get('visible'), process)
            assert idle['trackedTextureBytes'] == idle['gpuOverlaySubmissions'] == 0
            assert idle['completedGPUOverlaySubmissions'] == 0
            report['idle'] = idle
            atomic(control, {'sequence': 2, 'visible': True, 'selection': 0})
            shown = state_until(state_file, lambda state: state.get('controlSequence') == 2
                                and state.get('visible') and state.get('trackedTextureBytes', 0) > 0
                                and state.get('completedGPUOverlaySubmissions', 0) >= 3, process)
            report['shown'] = shown
            atomic(control, {'sequence': 3, 'visible': False, 'selection': 0})
            hidden = state_until(state_file, lambda state: state.get('controlSequence') == 3
                                 and not state.get('visible') and state.get('trackedTextureBytes') == 0, process)
            report['hidden'] = hidden
            stable = state_until(state_file, lambda state: state.get('controlSequence') == 3
                                 and state.get('frameCount', 0) >= hidden['frameCount'] + 60
                                 and state.get('completedGPUOverlaySubmissions') == state.get('gpuOverlaySubmissions'), process)
            assert stable['gpuOverlaySubmissions'] == hidden['gpuOverlaySubmissions']
            assert stable['trackedTextureBytes'] == 0 and stable['failedGPUOverlaySubmissions'] == 0
            assert idle['pid'] == shown['pid'] == stable['pid'] and shown['pid'] != process.pid
            report['actualOverlayPaths'] = [name for name, key in [('metal3', 'metal3OverlaySubmissions'), ('metal4', 'metal4OverlaySubmissions')] if stable[key] > 0]
            report['hiddenStable'] = stable
            assert stable['metal3OverlaySubmissions'] + stable['metal4OverlaySubmissions'] == stable['gpuOverlaySubmissions']
            if args.api == 'd3d12':
                assert stable['metal4OverlaySubmissions'] > 0, 'Metal4 was requested but its drawable path was not observed'
            code = process.wait(timeout=90)
            assert code == 0, f'Owned Windows presentation probe failed ({code})'
            observations = []
            for line in log_path.read_text(errors='replace').splitlines():
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        observations.append(value)
                except ValueError:
                    pass
            assert any(value.get('presentedFrames', 0) >= 120 for value in observations), 'No successful Windows swapchain presentation result'
            report['probeObservations'] = observations
            report['passed'] = True
        except Exception as error:
            failure = error
            report['error'] = str(error)
        finally:
            try:
                if process is not None and process.poll() is None:
                    process.terminate()
                subprocess.run([str(server), '-k'], env=env, stdout=log, stderr=log, timeout=10)
                if process is not None:
                    process.wait(timeout=15)
                subprocess.run([str(server), '-w'], env=env, stdout=log, stderr=log, timeout=15, check=True)
                report['exactPrefixCleanupCompleted'] = True
            except Exception as error:
                report['exactPrefixCleanupCompleted'] = False
                report['cleanupError'] = str(error)
                failure = failure or error
                report['passed'] = False
            # CLOSE only, never LOCK_UN on a description shared with the keeper.
    if report.get('exactPrefixCleanupCompleted') and (process is None or process.poll() is not None):
        shutil.rmtree(work)
    else:
        report['preservedScratch'] = str(work)
    report['defaultConfigurationChanged'] = digest(default_config) != default_sha
    if report['defaultConfigurationChanged']:
        report['passed'] = False
        failure = failure or AssertionError('Default runtime configuration changed during evaluation')
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
    if failure is not None:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
