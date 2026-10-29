#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual installed-runtime probes under denial of original engine locations.

This produces test evidence, never publishes an installation or selects a user
runtime. All compilation, test prefixes and raw evidence use the marked work
volume. Historical projection/controller reports remain unchanged.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
import test_controller_policy_e2e as policy
import test_runtime_projection as projection_test

ROOT = Path(__file__).resolve().parents[1]
PROFILE_A = '11111111-1111-1111-1111-111111111111'
PROFILE_B = '22222222-2222-2222-2222-222222222222'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    policy.write_json(path, value)


def run_command(command, commands, **kwargs):
    command = list(map(str, command))
    subprocess.run(command, check=True, **kwargs)
    commands.append(command)


def build(work, modules, archive):
    directory = work / 'build/installed-runtime-probes'
    directory.mkdir(mode=0o700, exist_ok=True)
    policy.WORK, policy.OUTPUT = work, directory
    importable = sorted((modules / 'LauncherCore.swiftmodule').glob('*.swiftmodule'))
    if not archive.is_file() or archive.read_bytes()[:8] != b'!<arch>\n' or not importable or archive.stat().st_mtime_ns < max(p.stat().st_mtime_ns for p in importable):
        raise RuntimeError('A matching real static Core archive/importable module is required')
    exe, private, dxmt, commands = policy.build_windows()
    cache = work / 'cache/installed-runtime-swift'
    cache.mkdir(mode=0o700, exist_ok=True)
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', cache, '-I', modules]
    harness = directory / 'ReadyInstalledRuntimeProbe'
    run_command([*common, ROOT / 'Sources/M1Launcher/SessionScratchDirectory.swift', ROOT / 'Sources/M1Launcher/SessionManager.swift', ROOT / 'Synthetic/ReadyInstalledRuntimeProbe.swift', archive, '-framework', 'AppKit', '-o', harness], commands)
    adapter = directory / 'ReadyInstalledRuntimeConfigurationProbe'
    run_command([*common, ROOT / 'Synthetic/ReadyInstalledRuntimeConfigurationProbe.swift', archive, '-o', adapter], commands)
    # Two different bytes at the same Windows path prove actual profile isolation.
    original = projection_test.WINAPI_SOURCE
    projection_test.WINAPI_SOURCE = original.replace('const char expected[]="runtime-moved-save-remains";', 'const char a[]="installation-profile-A-marker",b[]="installation-profile-B-marker";const char *expected=contains(GetCommandLineA(),"--profile-b")?b:a;').replace('sizeof expected', 'sizeof a')
    try:
        winapi = projection_test.compile_winapi(directory)
    finally:
        projection_test.WINAPI_SOURCE = original
    # Keep the exact generated C, and bind its bytes alongside the compiler inputs.
    sources = [Path(__file__), ROOT / 'Scripts/test_controller_policy_e2e.py', ROOT / 'Scripts/test_runtime_projection.py', ROOT / 'Scripts/runtime_native_audit.c', ROOT / 'Scripts/runtime_native_renderer_probe.m', ROOT / 'Sources/M1Launcher/SessionScratchDirectory.swift', ROOT / 'Sources/M1Launcher/SessionManager.swift', ROOT / 'Synthetic/ReadyInstalledRuntimeProbe.swift', ROOT / 'Synthetic/ReadyInstalledRuntimeConfigurationProbe.swift', ROOT / 'Scripts/runtime_controller_policy_windows_probe.c', ROOT / 'Scripts/runtime_controller_private_xinput_fixture.c', ROOT / 'Scripts/runtime_vulkan_present.c', ROOT / 'Scripts/runtime_d3d11_present.c']
    for arch in ['x86_64', 'arm64']:
        run_command(['xcrun', 'clang', '-arch', arch, '-mmacosx-version-min=27.0', '-O2', '-dynamiclib', ROOT / 'Scripts/runtime_native_audit.c', '-o', directory / ('audit-' + arch + '.dylib')], commands)
    run_command(['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=27.0', '-O2', '-fobjc-arc', '-I' + str(ROOT / 'Runtime/vulkan-headers-1.4.366/include'), ROOT / 'Scripts/runtime_native_renderer_probe.m', '-framework', 'AppKit', '-framework', 'Metal', '-framework', 'QuartzCore', '-o', directory / 'native-shader-present'], commands)
    inputs = {
        'vulkan-buffer.exe': ROOT / 'Runtime/Probes/runtime_vulkan_probe.exe',
        'vulkan-present.exe': ROOT / 'Runtime/Probes/runtime_vulkan_present.exe',
        'dxmt-shader64.exe': ROOT / 'Runtime/DXMTExperiment/dxmt_shader_probe.exe',
        'dxmt-shader32.exe': ROOT / 'Runtime/Probes/WoW64Shader/runtime_dxmt_shader32.exe',
        'dxmt-present64.exe': ROOT / 'Runtime/Probes/runtime_d3d11_present.exe',
        'dxmt-present32.exe': ROOT / 'Runtime/Probes/runtime_d3d11_present32.exe',
        'vertex.spv': ROOT / 'Runtime/NativeRendererWork/d007c6360f9f8be7e542/probes/vertex.spv',
        'fragment.spv': ROOT / 'Runtime/NativeRendererWork/d007c6360f9f8be7e542/probes/fragment.spv',
    }
    copied = {}
    for name, source in inputs.items():
        target = directory / name
        shutil.copy2(source, target)
        if sha(source) != sha(target):
            raise RuntimeError('Probe copy changed')
        copied[str(source)] = {'destination': str(target), 'sha256': sha(target)}
    artifacts = [harness, adapter, exe, private, dxmt, *winapi.values(), directory / 'projection-winapi.c', directory / 'audit-x86_64.dylib', directory / 'audit-arm64.dylib', directory / 'native-shader-present', *[directory / name for name in inputs]]
    receipt = {'schema': 1, 'fixtureOnly': False, 'commands': commands, 'sources': {str(p.relative_to(ROOT)): sha(p) for p in sources}, 'coreArchive': str(archive), 'coreArchiveSHA256': sha(archive), 'coreModuleHashes': {str(p): sha(p) for p in importable}, 'artifacts': {str(p): sha(p) for p in artifacts}, 'copiedTestArtifacts': copied, 'winapiSourceGeneration': 'projection source with equal-size distinct profile A/B sentinel; generated C retained', 'runtimeComponentsRebuilt': False}
    write(directory / 'build-receipt.json', receipt)
    return directory, receipt


def verify_build(directory):
    receipt = json.loads((directory / 'build-receipt.json').read_text())
    for name, expected in receipt['sources'].items():
        if sha(ROOT / name) != expected:
            raise RuntimeError('Compiled test source changed: ' + name)
    for name, expected in {**receipt['artifacts'], **receipt['coreModuleHashes'], receipt['coreArchive']: receipt['coreArchiveSHA256']}.items():
        if sha(name) != expected:
            raise RuntimeError('Compiled probe/Core changed: ' + name)
    return receipt


def observed(stdout):
    records = []
    for line in stdout.splitlines():
        try:
            records.append(json.loads(line))
        except ValueError:
            pass
    return records


def guarded_run(command, env, evidence, label, timeout=240):
    print(label + ': actual process started', flush=True)
    start = time.monotonic()
    process = subprocess.Popen(list(map(str, command)), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        while True:
            try:
                stdout, stderr = process.communicate(timeout=1)
                break
            except subprocess.TimeoutExpired:
                policy.space()
                if time.monotonic() - start > timeout:
                    raise RuntimeError(label + ' watchdog exceeded')
        (evidence / (label + '.stdout.log')).write_text(stdout)
        (evidence / (label + '.stderr.log')).write_text(stderr)
        if process.returncode:
            raise RuntimeError(label + ' exited ' + str(process.returncode) + '; retained stderr/stdout')
        return stdout, {'passed': True, 'exitCode': 0, 'elapsedSeconds': round(time.monotonic() - start, 3), 'stdoutSHA256': sha(evidence / (label + '.stdout.log')), 'stderrSHA256': sha(evidence / (label + '.stderr.log'))}
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate(timeout=10)
            (evidence / (label + '.stdout.log')).write_text(stdout)
            (evidence / (label + '.stderr.log')).write_text(stderr)


def check_mappings(paths, candidate, extra=()):
    component_images, unexpected = set(), []
    for value in paths:
        if value.startswith(('/System/', '/usr/lib/', '/Library/Apple/')) or value == '/usr/libexec/rosetta/runtime':
            continue
        path = Path(value).resolve()
        if path in extra:
            continue
        if path.is_relative_to(candidate / 'components'):
            component_images.add(str(path.relative_to(candidate)))
        else:
            unexpected.append(value)
    if unexpected or not component_images:
        raise RuntimeError('Unexpected/missing installed native images: ' + repr(unexpected))
    return {'componentImages': sorted(component_images), 'unexpectedNonSystemImages': []}


def execute(candidate, plan_path, transaction, work, build_dir, extra_denied, output):
    build_receipt = verify_build(build_dir)
    run_id = uuid.uuid4().hex
    scratch = work / 'tests' / ('installed-runtime-' + run_id)
    evidence = work / 'retained' / ('installed-runtime-' + run_id)
    scratch.mkdir(mode=0o700)
    evidence.mkdir(mode=0o700)
    # Preserve the exact tested build inputs before another run can regenerate
    # the shared probe cache. Original paths remain historical in the receipt.
    retained_inputs = evidence / 'compiled-inputs'
    retained_inputs.mkdir(mode=0o700)
    input_bindings = []
    inputs = {**build_receipt['artifacts'], **build_receipt['coreModuleHashes'],
              build_receipt['coreArchive']: build_receipt['coreArchiveSHA256'],
              **{str(ROOT / name): digest for name, digest in build_receipt['sources'].items()}}
    for name, digest in inputs.items():
        source = Path(name)
        target = retained_inputs / (digest + '-' + source.name)
        if not target.exists():
            shutil.copy2(source, target)
        if sha(target) != digest:
            raise RuntimeError('Retained compiled input differs: ' + name)
        input_bindings.append({'originalPath': name, 'retainedPath': str(target), 'sha256': digest})
    write(retained_inputs / 'bindings.json', input_bindings)
    shutil.copy2(build_dir / 'build-receipt.json', evidence / 'build-receipt.json')
    marker = scratch / '.ready-controller-policy-test'
    marker.write_text('Owned production-policy installation fixture\n')
    marker.chmod(0o600)
    (scratch / '.ready-runtime-projection-test').write_text('Owned installed-runtime isolation fixture\n')
    policy.WORK = work
    # Static validation and candidate fingerprint are supplied by the layout
    # recipe, independently of the probes. Its full output is retained.
    import runtime_install_layout as layout
    plan = json.loads(plan_path.read_text())
    static_before = layout.validate(candidate, plan)
    write(evidence / 'static-before.json', static_before)
    # The legacy alias points at the checkout itself. Deny its engine subtree,
    # not the whole checkout: the production keeper/overlay remain test inputs.
    denied = [ROOT / 'Runtime/Sets', ROOT / 'Runtime/Providers', ROOT / 'Runtime/SourceDependencies', ROOT / 'Runtime/Probes', ROOT / 'Runtime/DXMTExperiment', ROOT / 'Runtime/wine-11.20', ROOT / 'Runtime/wine-deps', ROOT / 'Runtime/vulkan-sdk-1.4.366', ROOT / 'Runtime/mesa-x64-26.3.0-rc2', ROOT / 'Runtime/mesa-26.3.0-rc2', ROOT / 'Runtime/NativeRendererWork', ROOT / 'Vendor', Path('/opt/homebrew'), Path('/usr/local'), Path('/tmp/ready-runtime-501/Runtime/gptk-wine-base-3.0-3'), Path('/private/tmp/ready-runtime-501/Runtime/gptk-wine-base-3.0-3'), *extra_denied]
    sandbox = evidence / 'deny-originals.sb'
    sandbox.write_text('(version 1)\n(allow default)\n(deny file-read*\n' + ''.join(' (subpath ' + json.dumps(str(p.resolve())) + ')\n' for p in denied) + ')\n')
    raw = json.loads((ROOT / 'Runtime/runtime.json').read_text())
    control_paths = [Path(raw['wine']), Path(raw['nativeVulkanLibrary']), Path('/opt/homebrew/opt/llvm/bin/clang').resolve()]
    controls = []
    for path in control_paths:
        result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(sandbox), '/bin/cat', str(path)], capture_output=True, timeout=15)
        if result.returncode == 0 or b'Operation not permitted' not in result.stderr:
            raise RuntimeError('Original-root sandbox denial was not established: ' + str(path))
        controls.append({'path': str(path), 'denied': True})
    env = {k: v for k, v in os.environ.items() if not k.startswith(('WINE', 'DYLD_', 'READY_', 'M1L_', 'VK_', 'CX_'))}
    env.update(TMPDIR=str(work / 'tmp') + '/', XDG_CACHE_HOME=str(scratch / 'cache'), MESA_SHADER_CACHE_DIR=str(scratch / 'mesa-cache'))
    # Cleanup paths come from the declared installation, never from source
    # providers or an arbitrary error log. Validate before any child is started.
    raw_candidate = json.loads((candidate / 'runtime.json').read_text())
    servers = []
    for relative in {raw_candidate['wineServer'], *raw_candidate.get('engineWineServers', {}).values()}:
        path = (candidate / relative).resolve(strict=True)
        if not path.is_relative_to(candidate / 'components') or path.name != 'wineserver':
            raise RuntimeError('Invalid installed wineserver cleanup binding')
        servers.append(path)
    prefixes = []
    report = {'schema': 1, 'kind': 'ready-installed-runtime-proof', 'passed': False, 'fixtureOnly': False, 'physicalControllerVerified': False, 'commercialGameVerified': False, 'directDisplayVerified': False, 'candidate': str(candidate), 'staticValidation': static_before, 'buildReceipt': str(evidence / 'build-receipt.json'), 'buildReceiptSHA256': sha(evidence / 'build-receipt.json'), 'retainedCompiledInputs': str(retained_inputs / 'bindings.json'), 'sandboxDenialControls': controls, 'deniedRoots': list(map(str, denied)), 'tests': {}}
    overlay = (ROOT / 'Build/libReadyOverlay.dylib').resolve()
    try:
        game = scratch / 'game'; game.mkdir()
        game_dxmt = scratch / 'game-dxmt'; game_dxmt.mkdir()
        for source, target in [(build_dir / 'controller-policy.exe', game / 'controller-policy.exe'), (build_dir / 'controller-policy-dxmt.exe', game_dxmt / 'controller-policy-dxmt.exe')]:
            shutil.copy2(source, target)
        command = ['/usr/bin/sandbox-exec', '-f', sandbox, build_dir / 'ReadyInstalledRuntimeProbe', ROOT, scratch, candidate / 'runtime.json', game / 'controller-policy.exe', build_dir / 'private-xinput1_4.dll', game_dxmt / 'controller-policy-dxmt.exe', work]
        stdout, result = guarded_run(command, env, evidence, 'production-policy-five-cases', timeout=600)
        cases = json.loads(stdout)
        if not cases.get('passed') or len(cases['cases']) != 5:
            raise RuntimeError('All five production policy cases are required')
        result.update(passed=False, rawHarnessPassed=True, cases=cases['cases'])
        report['tests']['production-policy-five-cases'] = result
        for case in cases['cases']:
            source = Path(case['log']); target = evidence / (case['case'] + '.session.log'); shutil.copy2(source, target)
            if sha(target) != case['logSHA256']:
                raise RuntimeError('Session log changed while retaining evidence')
            case['retainedLog'] = str(target)
        for case in cases['cases']:
            case['imageAudit'] = check_mappings(case['nativeImageMappings'], candidate, (overlay,))
        result['passed'] = True
        # Production resolver/PrefixManager, not a Python path approximation.
        contexts = {}
        for name, profile, game_id in [('A', PROFILE_A, 'installed-save'), ('B', PROFILE_B, 'installed-save'), ('dxmt', PROFILE_A, 'installed-dxmt')]:
            command = [build_dir / 'ReadyInstalledRuntimeConfigurationProbe', candidate / 'runtime.json', '--data-root', scratch, '--profile', profile, '--game', game_id, '--initial']
            if name == 'dxmt':
                command.append('--dxmt')
            value = json.loads(subprocess.check_output(list(map(str, command)), env=env, text=True, timeout=30))
            contexts[name] = value
            prefixes.append(Path(value['prefix']))
        config = contexts['A']['configuration']
        audit = build_dir / 'audit-x86_64.dylib'

        def wine(label, context, executable, arguments=(), engine='base', icd=None, expected=None):
            prefix = Path(context['prefix'])
            configuration = context['configuration']
            process_env = projection_test.clean_environment(prefix, configuration, audit, evidence / (label + '.images.jsonl'), engine)
            process_env.update(TMPDIR=env['TMPDIR'], XDG_CACHE_HOME=str(scratch / 'cache'))
            if icd:
                process_env.update(VK_DRIVER_FILES=icd, VK_ICD_FILENAMES=icd)
            wrapper = configuration['wine'] if engine == 'base' else configuration['engineWineBinaries']['dxmtMetal']
            stdout, result = guarded_run(['/usr/bin/sandbox-exec', '-f', sandbox, wrapper, executable, *arguments], process_env, evidence, label)
            observations = observed(stdout)
            if expected and not any(expected(x) for x in observations):
                raise RuntimeError(label + ' actual observation was missing/incorrect')
            images = evidence / (label + '.images.jsonl')
            if not images.is_file():
                raise RuntimeError('Actual native-image observer did not run')
            result.update(observations=observations, imagesSHA256=sha(images), imageAudit=check_mappings([json.loads(line)['path'] for line in images.read_text().splitlines()], candidate, (audit.resolve(),)))
            report['tests'][label] = result

        for name in ['A', 'B']:
            context = contexts[name]
            wine('wineboot-' + name, context, 'wineboot', ['-u'])
            flags = [] if name == 'A' else ['--profile-b']
            wine('save-write64-' + name, context, build_dir / 'projection-winapi-64.exe', flags, expected=lambda x: x.get('winapiFileIO') is True and x.get('mode') == 'write')
            wine('save-read32-' + name, context, build_dir / 'projection-winapi-32.exe', ['--read', *flags], expected=lambda x: x.get('winapiFileIO') is True and x.get('mode') == 'read')
        wine('profile-A-still-private', contexts['A'], build_dir / 'projection-winapi-64.exe', ['--read'], expected=lambda x: x.get('winapiFileIO') is True)
        if contexts['A']['persistentSaveFolder'] == contexts['B']['persistentSaveFolder']:
            raise RuntimeError('Profile save bindings overlap')
        for label, key in [('kosmic', 'kosmicICD'), ('molten', 'moltenICD')]:
            wine('vulkan-buffer-' + label, contexts['A'], build_dir / 'vulkan-buffer.exe', icd=config[key], expected=lambda x: x.get('readbackVerified') is True)
            wine('vulkan-present-' + label, contexts['A'], build_dir / 'vulkan-present.exe', icd=config[key], expected=lambda x: x.get('presentedFrames', 0) >= 600)
        wine('wineboot-dxmt', contexts['dxmt'], 'wineboot', ['-u'], engine='dxmt')
        for bits in [64, 32]:
            wine('dxmt-shader-' + str(bits), contexts['dxmt'], build_dir / ('dxmt-shader' + str(bits) + '.exe'), engine='dxmt', expected=lambda x: x.get('shaderRasterizationVerified') is True and x.get('centerCorrect') is True and x.get('cornerCorrect') is True)
            wine('dxmt-present-' + str(bits), contexts['dxmt'], build_dir / ('dxmt-present' + str(bits) + '.exe'), ['--fullscreen'], engine='dxmt', expected=lambda x: x.get('presentedFrames') == 600 and x.get('fullscreenRequested') is True and x.get('directToDisplayVerified') is False)
        native_images = evidence / 'native.images.jsonl'
        native_env = {**env, 'VK_DRIVER_FILES': config['kosmicNativeICD'], 'VK_ICD_FILENAMES': config['kosmicNativeICD']}
        # Set the observer after sandbox-exec starts. Its platform-binary launch
        # strips inherited DYLD variables; passing assignments to env preserves
        # the sandbox while injecting only our owned test observer into the probe.
        stdout, native_result = guarded_run(['/usr/bin/sandbox-exec', '-f', sandbox, '/usr/bin/env', 'DYLD_INSERT_LIBRARIES=' + str(build_dir / 'audit-arm64.dylib'), 'READY_NATIVE_AUDIT_LOG=' + str(native_images), build_dir / 'native-shader-present', config['nativeVulkanLibrary'], build_dir / 'vertex.spv', build_dir / 'fragment.spv'], native_env, evidence, 'native-arm64-shader-present')
        observations = observed(stdout)
        if not any(x.get('nativeARM64') is True and x.get('shaderRasterizationVerified') is True and x.get('presentedFrames') == 60 for x in observations):
            raise RuntimeError('Native ARM64 shader/readback/presentation not observed')
        native_result.update(observations=observations, imagesSHA256=sha(native_images), imageAudit=check_mappings([json.loads(line)['path'] for line in native_images.read_text().splitlines()], candidate, ((build_dir / 'audit-arm64.dylib').resolve(), (build_dir / 'native-shader-present').resolve())))
        report['tests']['native-arm64-shader-present'] = native_result
        static_after = layout.validate(candidate, plan)
        if static_after != static_before:
            raise RuntimeError('Installed candidate changed during execution')
        fingerprint = static_before['candidateTreeFingerprint']
        report.update(passed=True, candidateUnchanged=True, staticValidationAfter=static_after, testControllerDeviceBackendUsed=False,
                      verificationKind='actual-runtime', actualRuntimeExecuted=True, transaction=transaction,
                      planSHA256=sha(plan_path), planObjectFingerprintSHA256=layout.fingerprint(plan), candidateFingerprintSHA256=fingerprint,
                      candidateFingerprintBefore=fingerprint, candidateFingerprintAfter=static_after['candidateTreeFingerprint'],
                      testControllerBackendUsed=False,
                      checks={name: {'passed': True} for name in ['configResolved', 'windowsWinAPI64', 'windowsWinAPI32', 'controllerAuto', 'controllerOff', 'nativeARM64Readback', 'profileSaveIsolation', 'DXMTShader32', 'DXMTShader64', 'VulkanKosmicReadbackPresent', 'VulkanMoltenReadbackPresent']})
    except Exception as error:
        report['error'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        # Stop only this test's exact prefixes. Retain failure data for diagnosis.
        try:
            for prefix in prefixes:
                if not prefix.resolve().is_relative_to(scratch / 'Prefixes'):
                    raise RuntimeError('Extra-prefix cleanup escaped owned test data')
                process_env = {**env, 'WINEPREFIX': str(prefix), 'WINEDEBUG': '-all'}
                for server in servers:
                    subprocess.run([str(server), '-k'], env=process_env, capture_output=True, timeout=10)
                    subprocess.run([str(server), '-w'], env=process_env, check=True, capture_output=True, timeout=20)
            policy.cleanup(scratch, servers, remove=report['passed'])
            report['prefixCleanupVerified'] = True
        except Exception as error:
            report.update(passed=False, cleanupError=str(error), prefixCleanupVerified=False)
            raise
        finally:
            report['retained'] = str(evidence)
            report['evidenceFiles'] = [{'path': str(path), 'sha256': sha(path)} for path in sorted(evidence.rglob('*')) if path.is_file() and path.name != 'report.json']
            write(evidence / 'report.json', report)
            if output:
                policy.small_summary(output, {'passed': report['passed'], 'fixtureOnly': False, 'retainedReport': str(evidence / 'report.json'), 'retainedReportSHA256': sha(evidence / 'report.json'), 'tests': list(report['tests']), 'physicalControllerVerified': False})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-root', type=Path, required=True)
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--transaction')
    parser.add_argument('--modules', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--run-only', action='store_true')
    parser.add_argument('--deny', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    work = policy.owned_work_root(args.work_root)
    policy.WORK = work
    os.environ.update(TMPDIR=str(work / 'tmp') + '/', CLANG_MODULE_CACHE_PATH=str(work / 'cache/clang'), SWIFT_MODULECACHE_PATH=str(work / 'cache/swift'))
    directory = work / 'build/installed-runtime-probes'
    if not args.run_only:
        if not args.modules or not args.archive:
            parser.error('--modules and --archive are required for compilation')
        directory, receipt = build(work, args.modules.resolve(), args.archive.resolve())
        print(json.dumps({'compiled': True, 'receipt': str(directory / 'build-receipt.json')}), flush=True)
    if not args.compile_only:
        if not args.candidate or not args.plan or not args.transaction:
            parser.error('--candidate, --plan and --transaction are required for execution')
        if str(uuid.UUID(args.transaction)) != args.transaction:
            parser.error('A canonical transaction UUID is required')
        report = execute(args.candidate.resolve(strict=True), args.plan.resolve(strict=True), args.transaction, work, directory, args.deny, args.output)
        print(json.dumps({'passed': report['passed'], 'tests': len(report['tests']), 'retained': report['retained']}))


if __name__ == '__main__':
    main()
