#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Relocate an owned diagnostic projection and run real synthetic Windows probes.

No account/game, Apple evaluation, activation or live user-data changes. Native
images are observed AND old component/developer roots denied to the Wine child.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time
import uuid
import urllib.request

sys.dont_write_bytecode = True
import runtime_portable_projection as projection
from swift_probe_support import prepare_core
import runtime_dependency_smoke as platform_smoke
ROOT = projection.ROOT

WINAPI_SOURCE = r'''/* SPDX-License-Identifier: GPL-3.0-only */
typedef unsigned long DWORD;typedef void *HANDLE;
#define API __declspec(dllimport)
#define CALL __stdcall
API HANDLE CALL GetStdHandle(DWORD);API int CALL WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
API int CALL ReadFile(HANDLE,void*,DWORD,DWORD*,void*);API int CALL CloseHandle(HANDLE);
API HANDLE CALL CreateFileA(const char*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
API char *CALL GetCommandLineA(void);API DWORD CALL GetCurrentProcessId(void);API void CALL ExitProcess(DWORD);
static int contains(const char*s,const char*n){for(;*s;s++){unsigned i=0;while(n[i]&&s[i]==n[i])i++;if(!n[i])return 1;}return 0;}
static void out(const char*s){DWORD count=0,n=0;while(s[n])n++;WriteFile(GetStdHandle((DWORD)-11),s,n,&count,0);}
void mainCRTStartup(void){
 int reading=contains(GetCommandLineA(),"--read"),ok=1;
 HANDLE f=CreateFileA("C:\\ProgramData\\ReadyProjection\\Saves\\marker.bin",reading?0x80000000:0xc0000000,3,0,reading?3:2,0x80,0);
 const char expected[]="runtime-moved-save-remains";char bytes[sizeof expected];DWORD count=0;
 if(f==(HANDLE)(long long)-1)ok=0;
 else{if(reading){ok=ReadFile(f,bytes,sizeof bytes,&count,0)&&count==sizeof expected;for(unsigned i=0;ok&&i<sizeof expected;i++)if(bytes[i]!=expected[i])ok=0;}
 else ok=WriteFile(f,expected,sizeof expected,&count,0)&&count==sizeof expected;CloseHandle(f);}
 (void)GetCurrentProcessId();out("{\"winapiFileIO\":");out(ok?"true":"false");out(",\"mode\":\"");out(reading?"read":"write");out("\"}\n");ExitProcess(ok?0:1);
}'''


class LowDiskSpace(RuntimeError):
    pass


def ensure_disk(stage):
    free = shutil.disk_usage(ROOT).free
    if free < 512 * 1024 * 1024:
        print('LOW DISK before ' + stage + ': ' + str(free) + ' bytes; no further probe started', flush=True)
        raise LowDiskSpace('Less than512MiB free; coordinate fixture storage before continuing')


def write_report(path, report):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.pending')
    projection.write_private(temporary, projection.json_bytes(report))
    os.replace(temporary, path)


def build_adapter(directory):
    _, modules, archive = prepare_core()
    target = directory / 'ReadyRuntimeProjectionProbe'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(modules),
                    str(ROOT / 'Synthetic/ReadyRuntimeProjectionProbe.swift'), str(archive), '-o', str(target)], check=True)
    return target


def compile_winapi(directory):
    source = directory / 'projection-winapi.c'
    source.write_text(WINAPI_SOURCE)
    outputs = {}
    exports = {'GetStdHandle': 4, 'WriteFile': 20, 'ReadFile': 20, 'CloseHandle': 4,
               'CreateFileA': 28, 'GetCommandLineA': 0, 'GetCurrentProcessId': 0, 'ExitProcess': 4}
    for bits in (64, 32):
        definition = directory / ('kernel32-' + str(bits) + '.def')
        definition.write_text('LIBRARY KERNEL32.dll\nEXPORTS\n' + '\n'.join(name + ('@' + str(size) if bits == 32 else '') for name, size in exports.items()) + '\n')
        library = directory / ('kernel32-' + str(bits) + '.lib')
        subprocess.run(['/opt/homebrew/opt/llvm/bin/llvm-dlltool', '-m', 'i386:x86-64' if bits == 64 else 'i386', *([] if bits == 64 else ['--kill-at']), '-d', str(definition), '-l', str(library)], check=True)
        obj = directory / ('projection-winapi-' + str(bits) + '.obj')
        subprocess.run(['/opt/homebrew/opt/llvm/bin/clang', '--target=' + ('x86_64' if bits == 64 else 'i686') + '-windows', '--no-default-config', '-ffreestanding', '-fno-builtin', '-fno-stack-protector', '-O2', '-c', str(source), '-o', str(obj)], check=True)
        executable = directory / ('projection-winapi-' + str(bits) + '.exe')
        subprocess.run(['/opt/homebrew/opt/lld/bin/lld-link', '/entry:mainCRTStartup', '/subsystem:console', '/machine:' + ('x64' if bits == 64 else 'x86'), '/nodefaultlib', *([] if bits == 64 else ['/safeseh:no']), str(obj), str(library), '/out:' + str(executable)], check=True)
        outputs[bits] = executable
    return outputs


def build_audit(directory):
    path = directory / 'libProjectionNativeAudit.dylib'
    subprocess.run(['xcrun', 'clang', '-arch', 'x86_64', '-mmacosx-version-min=14.0', '-O2', '-dynamiclib', str(ROOT / 'Scripts/runtime_native_audit.c'), '-o', str(path)], check=True)
    return path


def sandbox_profile(directory):
    denied = [ROOT / 'Runtime/Sets', ROOT / 'Runtime/Providers', ROOT / 'Runtime/SourceDependencies',
              ROOT / 'Runtime/Probes', ROOT / 'Runtime/DXMTExperiment', ROOT / 'Runtime/wine-11.20',
              ROOT / 'Runtime/wine-deps', ROOT / 'Runtime/vulkan-sdk-1.4.366',
              ROOT / 'Runtime/mesa-x64-26.3.0-rc2', ROOT / 'Runtime/mesa-26.3.0-rc2',
              Path('/opt/homebrew'), Path('/usr/local'), Path('/tmp/ready-runtime-501'), Path('/private/tmp/ready-runtime-501')]
    text = '(version 1)\n(allow default)\n(deny file-read*\n' + ''.join('  (subpath ' + json.dumps(str(p)) + ')\n' for p in denied) + ')\n'
    path = directory / 'deny-original-runtime.sb'
    path.write_text(text)
    original = json.loads((ROOT / 'Runtime/runtime.json').read_text())['immutableRuntimeSet']
    command = ['/usr/bin/sandbox-exec', '-f', str(path), '/bin/cat', str(Path(original) / 'source-generation.json')]
    result = subprocess.run(command, capture_output=True, timeout=15)
    if result.returncode == 0 or b'Operation not permitted' not in result.stderr:
        raise RuntimeError('Old-root sandbox denial was not established')
    return path, list(map(str, denied))


def resolve(adapter, root, data, game='base', initial=False):
    command = [str(adapter), str(root / 'runtime.json'), '--data-root', str(data), '--game', game]
    if initial:
        command.append('--initial')
    value = json.loads(subprocess.check_output(command, text=True, timeout=30))
    config = value['configuration']
    if 'pathFormat' in config or not Path(config['wine']).is_relative_to(root):
        raise RuntimeError('Production resolver did not resolve the relocated configuration')
    return value


def clean_environment(prefix, config, audit, images, engine='base'):
    env = {key: value for key, value in os.environ.items() if not key.startswith(('WINE', 'DYLD_', 'READY_', 'M1L_', 'CX_APPLEGPTK', 'VK_'))}
    env.update(WINEPREFIX=str(prefix), WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=d',
               READY_NATIVE_AUDIT_LIBRARY=str(audit), READY_NATIVE_AUDIT_LOG=str(images),
               DXMT_LOG_PATH='none', DXMT_SHADER_CACHE_PATH=str(prefix / 'dxmt-cache'),
               MESA_SHADER_CACHE_DIR=str(prefix / 'mesa-cache'), XDG_CACHE_HOME=str(prefix / '.cache'))
    if engine == 'dxmt':
        env['WINEDLLOVERRIDES'] = config['engineOverrides']['dxmtMetal'] + ';mscoree,mshtml=d'
        env['WINEDLLPATH'] = config['engineSearchPaths']['dxmtMetal']
    return env


def check_images(images, root, audit):
    if not images.is_file():
        raise RuntimeError('Native image audit missing')
    records = [json.loads(line) for line in images.read_text().splitlines()]
    unexpected = []
    component_images = []
    for record in records:
        value = record['path']
        if value.startswith(('/System/', '/usr/lib/', '/Library/Apple/')):
            continue
        path = Path(value).resolve()
        if path == audit.resolve():
            continue
        if not path.is_relative_to(root / 'components'):
            unexpected.append(value)
        else:
            component_images.append(str(path.relative_to(root)))
    if not component_images or unexpected:
        raise RuntimeError('Unexpected or missing relocated native images: ' + repr(unexpected))
    if not any(value.endswith('/wine/bin/wine') for value in component_images):
        raise RuntimeError('Actual canonical Wine executable not observed')
    return {'recordCount': len(records), 'componentImages': sorted(set(component_images)), 'unexpectedNonSystemImages': unexpected}


def run_wine(name, root, config, prefix, executable, arguments, audit, sandbox, proof, engine='base', icd=None, expected=None, timeout=150, wine_debug=None, required_trace=None):
    ensure_disk(name)
    images = proof / (name + '.images.jsonl')
    env = clean_environment(prefix, config, audit, images, engine)
    if wine_debug is not None:
        env['WINEDEBUG'] = wine_debug
    if icd:
        env.update(VK_DRIVER_FILES=icd, VK_ICD_FILENAMES=icd)
    wrapper = config['wine'] if engine == 'base' else config['engineWineBinaries']['dxmtMetal']
    command = ['/usr/bin/sandbox-exec', '-f', str(sandbox), wrapper, str(executable), *arguments]
    started = time.monotonic()
    print(name + ': running actual Wine under old-root denial', flush=True)
    try:
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        for label, content in [('stdout', error.stdout), ('stderr', error.stderr)]:
            if isinstance(content, bytes):
                content = content.decode(errors='replace')
            (proof / (name + '.' + label + '.log')).write_text(content or '')
        raise
    (proof / (name + '.stdout.log')).write_text(result.stdout)
    (proof / (name + '.stderr.log')).write_text(result.stderr)
    observations = []
    for line in result.stdout.splitlines():
        try:
            observations.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    if result.returncode or (expected and not any(expected(x) for x in observations)) or (required_trace and not required_trace(result.stderr)):
        raise RuntimeError('Relocated synthetic probe failed: ' + name + ' exit=' + str(result.returncode))
    images_report = check_images(images, root, audit)
    print(name + ': passed; native images=' + str(images_report['recordCount']), flush=True)
    return {'passed': True, 'exitCode': result.returncode, 'seconds': round(time.monotonic() - started, 3),
            'observations': observations, 'imageAudit': str(images),
            'requiredTraceVerified': True if required_trace else None, **images_report}


def boot(name, root, resolved, audit, sandbox, proof, engine='base'):
    config = resolved['configuration']
    prefix = Path(resolved['prefix'])
    target = prefix / 'drive_c/windows/syswow64'
    target.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/bin/cp', '-cR', config['builtin32Directory'] + '/.', str(target)], check=True)
    return run_wine(name, root, config, prefix, 'wineboot', ['-u'], audit, sandbox, proof, engine=engine, timeout=180)


def run_resource_checks(root, after, dxmt, audit, sandbox, proof, report, tls_servers):
    config = after['configuration']
    # Additional probes exercise lazy-loaded compiler, presentation,
    # certificate/trust and font resources AFTER the whole-root move.
    # Original14 setup is separate; this function runs only the13 new checks.
    report['additionalProbeScope'] = {
        'PE32ShaderRasterizationClaimed': False,
        'presentationFramesAreNotPerformanceMeasurement': True,
        'directToDisplayClaimed': False,
        'DXMTFullscreenRequestedWithoutWindowedFallback': True,
        'VulkanMode': 'existing compiled960x600 window; no fullscreen claim',
        'certificateValidationBypassUsed': False,
    }
    def extra_probe(name, source, prefix, arguments, expected, engine='base', icd=None, wine_debug=None, required_trace=None):
        if not source.is_file():
            report.setdefault('skippedChecks', []).append(name + ': existing probe unavailable')
            return
        ensure_disk(name)
        expected_hash = projection.sha(source)
        copied = proof / source.name
        shutil.copy2(source, copied)
        if projection.sha(copied) != expected_hash or projection.sha(source) != expected_hash:
            raise RuntimeError('Existing probe bytes changed while copying: ' + name)
        try:
            result = run_wine(name, root, config, prefix, copied, arguments, audit, sandbox, proof,
                              engine=engine, icd=icd, expected=expected, wine_debug=wine_debug, required_trace=required_trace)
            result['existingProbeSHA256'] = expected_hash
            report['tests'][name] = result
        except LowDiskSpace:
            raise
        except Exception as error:
            # Preserve real failures and continue independent new checks.
            # Never lower the requested600 frames or fullscreen request.
            failure = {'passed': False, 'error': str(error), 'existingProbeSHA256': expected_hash}
            stdout = proof / (name + '.stdout.log')
            if stdout.is_file():
                observations = []
                for line in stdout.read_text().splitlines():
                    try: observations.append(json.loads(line))
                    except ValueError: pass
                failure['observations'] = observations
            try:
                failure.update(check_images(proof / (name + '.images.jsonl'), root, audit))
            except Exception as audit_error:
                failure['nativeImageAuditError'] = str(audit_error)
            report['tests'][name] = failure
            print(name + ': FAILED; original observations retained, no capability/fullscreen fallback', flush=True)
        finally:
            if projection.sha(source) != expected_hash:
                raise RuntimeError('Original existing probe modified: ' + name)
            # Exact owned prefix only, including cleanup after a failed
            # or timed-out presentation check before its independent peer.
            server = config['wineServer'] if engine == 'base' else config['engineWineServers']['dxmtMetal']
            environment = clean_environment(prefix, config, audit, proof / (name + '.cleanup.images.jsonl'), engine)
            environment.pop('READY_NATIVE_AUDIT_LIBRARY', None)
            environment.pop('READY_NATIVE_AUDIT_LOG', None)
            for option in ('-k', '-w'):
                stopped = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(sandbox), server, option], env=environment, capture_output=True, timeout=20)
                if stopped.returncode not in ((0, 1) if option == '-k' else (0,)):
                    raise RuntimeError('Exact owned prefix cleanup failed after ' + name)
    shader = ROOT / 'Runtime/DXMTExperiment/dxmt_shader_probe.exe'
    extra_probe('movedDXMTShaderReadback64', shader, Path(dxmt['prefix']), [],
                lambda x: x.get('shaderRasterizationVerified') is True and x.get('centerCorrect') is True and x.get('cornerCorrect') is True, engine='dxmt')
    for bits in (64, 32):
        present = ROOT / 'Runtime/Probes' / ('runtime_d3d11_present' + ('32' if bits == 32 else '') + '.exe')
        extra_probe('movedDXMTPresent600-' + str(bits), present, Path(dxmt['prefix']), ['--fullscreen'],
                    lambda x: x.get('presentedFrames') == 600 and x.get('fullscreenRequested') is True and x.get('directToDisplayVerified') is False, engine='dxmt')
    present = ROOT / 'Runtime/Probes/runtime_vulkan_present.exe'
    for label, key in [('kosmic', 'kosmicICD'), ('molten', 'moltenICD')]:
        extra_probe('movedVulkanPresent600-' + label, present, Path(after['prefix']), [],
                    lambda x: x.get('presentedFrames') == 600 and x.get('directToDisplayVerified') is False, icd=config[key])
    platform_probes = [(bits, ROOT / 'Runtime/Probes' / ('runtime_platform_probe' + ('32' if bits == 32 else '') + '.exe')) for bits in (64, 32)]
    if any(path.is_file() for _, path in platform_probes):
        # Native control distinguishes endpoint/connectivity problems;
        # it never supplies a certificate bypass to the Windows probe.
        try:
            with urllib.request.urlopen('https://example.com/', timeout=30) as response:
                content = response.read(1048576)
                report['nativeHTTPSControl'] = {'status': response.status, 'exampleMarkerPresent': b'Example Domain' in content}
        except Exception as control_error:
            report['nativeHTTPSControl'] = {'error': str(control_error)}
        tls_server = platform_smoke.server(proof)
        tls_servers.append(tls_server)
        invalid_url = 'https://127.0.0.1:' + str(tls_server.server_address[1]) + '/'
        for bits, platform_probe in platform_probes:
            stem = 'movedPlatform' + str(bits)
            extra_probe(stem + '-https', platform_probe, Path(after['prefix']), ['--tls', '--url=https://example.com/'],
                        lambda x: x.get('httpsVerified') is True and x.get('status') == 200 and x.get('exampleMarkerPresent') is True and x.get('certificateValidationBypassUsed') is False,
                        wine_debug='+winhttp,+secur32')
            extra_probe(stem + '-certificateReject', platform_probe, Path(after['prefix']), ['--tls', '--url=' + invalid_url, '--expect-secure-failure'],
                        lambda x: x.get('secureFailureRejected') is True and x.get('certificateValidationBypassUsed') is False,
                        wine_debug='+winhttp,+secur32', required_trace=lambda text: any('cert verify failed: ' + str(code) in text for code in (12045, 12175)))
            for mode in ('gdi', 'dwrite'):
                extra_probe(stem + '-' + mode, platform_probe, Path(after['prefix']), ['--' + mode],
                            lambda x: x.get('glyphRasterVerified') is True and x.get('nonzeroAlphaSamples', 0) > 0)
    else:
        report.setdefault('skippedChecks', []).append('Moved platform64/32 TLS/font probes unavailable')


def resume_resource_checks(args):
    # Only resume the marked, already bootstrapped fixture stopped by our disk
    # guard. Do not reconstruct prefixes, rerun the14 baseline, or touch user data.
    if args.static_only or args.adapter is None or not args.resume_report_sha256 or not args.projection_manifest_sha256:
        raise RuntimeError('Resume requires adapter plus explicit prior-report and projection-manifest SHA256')
    previous_bytes = args.resume_report.read_bytes()
    previous_hash = hashlib.sha256(previous_bytes).hexdigest()
    if previous_hash != args.resume_report_sha256:
        raise RuntimeError('Prior stopped report hash changed')
    previous = json.loads(previous_bytes)
    if previous.get('diagnosticOnly') is not True or previous.get('binaryDistributionApproved') is not False or previous.get('sourceAndProjectionBytesUnchanged') is not True or '512MiB' not in previous.get('error', ''):
        raise RuntimeError('Only an unchanged diagnostic disk-stopped fixture may resume')
    root = Path(previous['projectionRoot']).resolve(strict=True)
    proof = Path(previous['proofDirectory']).resolve(strict=True)
    data = proof / 'data'
    parent = projection.PARENT.resolve(strict=True)
    for directory in (root, proof, data):
        info = os.lstat(directory)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError('Resume directories must be real owned directories')
    if root.parent != parent or proof.parent != parent or not proof.name.startswith('.proof-'):
        raise RuntimeError('Resume scope must stay in the marked TestProjections fixture')
    marker = data / '.ready-runtime-projection-test'
    marker_info = os.lstat(marker)
    if not stat.S_ISREG(marker_info.st_mode) or marker_info.st_uid != os.getuid():
        raise RuntimeError('Owned fixture marker missing')
    manifest_hash = projection.sha(root / 'projection-manifest.json')
    if manifest_hash != args.projection_manifest_sha256:
        raise RuntimeError('Projection manifest differs from caller binding')
    original = projection.verify_projection(root, verify_originals=True)
    if previous['sourceConfigurationSHA256'] != original['source']['configurationSHA256']:
        raise RuntimeError('Original configuration differs from stopped run')
    adapter = args.adapter.resolve(strict=True)
    if not adapter.is_file():
        raise RuntimeError('Existing resolver adapter required; resume does not build')
    resolved = json.loads(subprocess.check_output([str(adapter), str(root / 'runtime.json')], text=True, timeout=30))
    config = resolved['configuration']
    if not Path(config['wine']).is_relative_to(root) or 'pathFormat' in config:
        raise RuntimeError('Resolver did not bind to the moved projection')
    audit = proof / 'libProjectionNativeAudit.dylib'
    if projection.sha(audit) != previous['testAuditSHA256']:
        raise RuntimeError('Native audit library changed since stopped run')
    contexts = {}
    for game in ('base', 'dxmt'):
        key = game + '-' + hashlib.sha256(game.encode()).hexdigest()
        prefix = data / 'Prefixes/11111111-1111-1111-1111-111111111111' / key
        if prefix.resolve(strict=True) != prefix or not prefix.is_dir():
            raise RuntimeError('Exact initialized fixture prefix missing')
        for required in ('system.reg', 'user.reg', '.ready/folders.reg', 'drive_c/windows/system32/kernel32.dll'):
            if not (prefix / required).is_file():
                raise RuntimeError('Resume requires complete prior Wineboot, not prefix reconstruction')
        folder = prefix / 'drive_c/ProgramData/ReadyProjection/Saves'
        target = folder.resolve(strict=True)
        if not target.is_relative_to(data) or not target.is_dir():
            raise RuntimeError('Persistent save binding leaves owned fixture')
        server = Path(config['wineServer'] if game == 'base' else config['engineWineServers']['dxmtMetal']).resolve(strict=True)
        if server.name != 'wineserver' or not server.is_relative_to(root / 'components') or not server.is_file() or not os.access(server, os.X_OK):
            raise RuntimeError('Exact projected server missing')
        contexts[game] = {'configuration': config, 'prefix': str(prefix), 'server': str(server), 'persistentSaveFolder': str(target)}
    saved = Path(contexts['base']['persistentSaveFolder']) / 'marker.bin'
    if saved.read_bytes() != b'runtime-moved-save-remains\0':
        raise RuntimeError('Stopped fixture synthetic save bytes changed')
    saved_hash = projection.sha(saved)
    before_image = proof / ('stopped-report-' + previous_hash[:16] + '-' + uuid.uuid4().hex + '.json')
    projection.write_private(before_image, previous_bytes)
    sandbox_directory = proof / ('resource-resume-' + uuid.uuid4().hex)
    sandbox_directory.mkdir(mode=0o700)
    sandbox, denied = sandbox_profile(sandbox_directory)
    binding = {'sourceReportSHA256': previous_hash, 'sourceReportBeforeImage': str(before_image),
               'projectionManifestSHA256': manifest_hash, 'sourceConfigurationSHA256': previous['sourceConfigurationSHA256'],
               'prefixServers': {game: {'prefix': value['prefix'], 'server': value['server']} for game, value in contexts.items()}}
    projection.write_private(sandbox_directory / '.ready-owned-resource-resume.json', projection.json_bytes(binding))
    historical = ROOT / 'Evidence/runtime-projection-tests.json'
    report = {'passed': False, 'diagnosticOnly': True, 'binaryDistributionApproved': False,
              'resumedOnlyAdditionalResources': True, 'resumeBindings': binding,
              'sourceConfigurationSHA256': previous['sourceConfigurationSHA256'], 'projectionManifestSHA256': manifest_hash,
              'projectionRoot': str(root), 'proofDirectory': str(proof), 'minimumMacOS': original['minimumMacOS'],
              'blockers': original['blockers'], 'deniedOriginalAndDeveloperRoots': denied, 'testAuditSHA256': projection.sha(audit),
              'historicalBaseRelocationReportSHA256': projection.sha(historical), 'tests': {},
              'sourceAndProjectionBytesUnchanged': False}
    tls_servers = []
    passed = False
    try:
        ensure_disk('resource resume')
        run_resource_checks(root, contexts['base'], contexts['dxmt'], audit, sandbox, proof, report, tls_servers)
        if projection.sha(saved) != saved_hash:
            raise RuntimeError('Resource probes changed the existing persistent save marker')
        report['passed'] = len(report['tests']) == 13 and all(value.get('passed') is True for value in report['tests'].values())
        passed = report['passed']
        if not passed:
            raise RuntimeError('Moved-root resource scope incomplete or failed; raw observations retained')
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        for server in tls_servers:
            server.shutdown(); server.server_close()
        cleanup_ok = True
        for context in contexts.values():
            environment = {key: value for key, value in os.environ.items() if not key.startswith(('WINE', 'DYLD_', 'READY_', 'M1L_', 'CX_APPLEGPTK'))}
            environment.update(WINEPREFIX=context['prefix'], WINEDEBUG='-all')
            try:
                subprocess.run([context['server'], '-k'], env=environment, capture_output=True, timeout=10)
                subprocess.run([context['server'], '-w'], env=environment, capture_output=True, timeout=20, check=True)
            except Exception:
                cleanup_ok = False
        try:
            projection.verify_projection(root, verify_originals=True)
            if projection.sha(root / 'projection-manifest.json') != manifest_hash or projection.sha(before_image) != previous_hash:
                raise RuntimeError('Resume manifest or historical report bytes changed')
            report['sourceAndProjectionBytesUnchanged'] = True
        except Exception as verify_error:
            report['byteVerificationError'] = str(verify_error)
            report['passed'] = False
        if passed and cleanup_ok:
            if data.is_symlink() or data.resolve(strict=True) != proof / 'data':
                raise RuntimeError('Fixture cleanup root changed')
            shutil.rmtree(data)
        report['ownedPrefixFixturesRemoved'] = passed and cleanup_ok
        if not cleanup_ok:
            report['passed'] = False
        write_report(args.output, report)
        print(json.dumps({'passed': report['passed'], 'newResourceChecks': len(report['tests']), 'resumedWithoutBaselineOrBoot': True,
                          'projectionRoot': str(root), 'report': str(args.output), 'error': report.get('error')}, indent=2), flush=True)
        if not cleanup_ok or not report['sourceAndProjectionBytesUnchanged']:
            raise RuntimeError('Exact fixture cleanup or byte-preservation verification failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--projection', type=Path)
    parser.add_argument('--static-only', action='store_true')
    parser.add_argument('--resume-report', type=Path, help='Resume only new resource checks from an owned disk-stopped fixture')
    parser.add_argument('--resume-report-sha256')
    parser.add_argument('--projection-manifest-sha256')
    parser.add_argument('--adapter', type=Path, help='Use an already compiled standalone production-resolver adapter')
    parser.add_argument('--output', type=Path, default=ROOT / 'Evidence/runtime-projection-tests.json')
    args = parser.parse_args()
    if args.resume_report is not None:
        if '--output' not in sys.argv:
            args.output = ROOT / 'Evidence/runtime-projection-resource-tests.json'
        resume_resource_checks(args)
        return
    root = args.projection.resolve(strict=True) if args.projection else projection.create_projection('Projection A with spaces ' + uuid.uuid4().hex)
    if root.parent != projection.PARENT.resolve():
        raise RuntimeError('Only owned TestProjections may be moved by this diagnostic test')
    original = projection.verify_projection(root, verify_originals=True)
    proof = projection.PARENT / ('.proof-' + uuid.uuid4().hex)
    proof.mkdir(mode=0o700)
    report = {'passed': False, 'diagnosticOnly': True, 'binaryDistributionApproved': False,
              'sourceConfigurationSHA256': original['source']['configurationSHA256'], 'minimumMacOS': original['minimumMacOS'],
              'blockers': original['blockers'], 'tests': {}, 'proofDirectory': str(proof), 'sourceAndProjectionBytesUnchanged': False}
    data = proof / 'data'; data.mkdir(mode=0o700)
    projection.write_private(data / '.ready-runtime-projection-test', b'Owned synthetic save/profile/prefix fixture only\n')
    active = []
    tls_servers = []
    passed = False
    try:
        report['tests']['staticInitialInventory'] = {'passed': True}
        if not args.static_only:
            adapter = args.adapter.resolve(strict=True) if args.adapter else build_adapter(proof)
            executables = compile_winapi(proof)
            audit = build_audit(proof)
            sandbox, denied = sandbox_profile(proof)
            report['deniedOriginalAndDeveloperRoots'] = denied
            report['testAuditSHA256'] = projection.sha(audit)
            before = resolve(adapter, root, data, initial=True)
            active.append((before['configuration']['wineServer'], before['prefix']))
            report['tests']['initialRootWineboot'] = boot('initial-boot', root, before, audit, sandbox, proof)
            for bits in (64, 32):
                report['tests']['initialRootWinAPI' + str(bits)] = run_wine('initial-winapi-' + str(bits), root, before['configuration'], Path(before['prefix']), executables[bits], [], audit, sandbox, proof, expected=lambda x: x.get('winapiFileIO') is True)
            saved = Path(before['persistentSaveFolder']) / 'marker.bin'
            save_hash = projection.sha(saved)
        previous_root = root
        relocated = root.with_name('Moved projection B with spaces ' + uuid.uuid4().hex)
        if relocated.exists():
            raise RuntimeError('Relocation destination must be new')
        root.rename(relocated)
        root = relocated
        projection.verify_projection(root, verify_originals=True)
        report['tests']['wholeRootMovedWithSameBytes'] = {'passed': True, 'oldRootAbsent': not previous_root.exists()}
        if not args.static_only:
            active.clear()
            after = resolve(adapter, root, data)
            if Path(after['persistentSaveFolder']) != Path(before['persistentSaveFolder']) or projection.sha(saved) != save_hash:
                raise RuntimeError('Moving runtime changed per-game/per-profile persistent save data')
            active.append((after['configuration']['wineServer'], after['prefix']))
            report['tests']['movedRootWineboot'] = boot('moved-boot', root, after, audit, sandbox, proof)
            for bits in (64, 32):
                report['tests']['movedRootWinAPI' + str(bits)] = run_wine('moved-winapi-' + str(bits), root, after['configuration'], Path(after['prefix']), executables[bits], ['--read'], audit, sandbox, proof, expected=lambda x: x.get('winapiFileIO') is True and x.get('mode') == 'read')
            if projection.sha(saved) != save_hash:
                raise RuntimeError('Read-only moved-root WinAPI check changed persistent save bytes')
            report['tests']['persistentSaveBindingSurvivesRuntimeMove'] = {'passed': True}
            config = after['configuration']
            gpu = ROOT / 'Runtime/Probes/runtime_vulkan_probe.exe'
            if gpu.is_file():
                copied = proof / gpu.name; shutil.copy2(gpu, copied)
                for label, key in [('kosmic', 'kosmicICD'), ('molten', 'moltenICD')]:
                    report['tests']['movedVulkan-' + label] = run_wine('moved-vulkan-' + label, root, config, Path(after['prefix']), copied, [], audit, sandbox, proof, icd=config[key], expected=lambda x: x.get('readbackVerified') is True)
            else:
                report.setdefault('skippedChecks', []).append('Vulkan readback probes unavailable')
            dxmt = resolve(adapter, root, data, game='dxmt', initial=True)
            active.append((config['engineWineServers']['dxmtMetal'], dxmt['prefix']))
            report['tests']['movedDXMTWineboot'] = boot('moved-dxmt-boot', root, dxmt, audit, sandbox, proof, engine='dxmt')
            for bits in (64, 32):
                gpu = ROOT / 'Runtime/Probes' / ('runtime_windows_probe' + ('32' if bits == 32 else '') + '.exe')
                if gpu.is_file():
                    copied = proof / gpu.name; shutil.copy2(gpu, copied)
                    report['tests']['movedDXMTBuffer' + str(bits)] = run_wine('moved-dxmt-buffer-' + str(bits), root, config, Path(dxmt['prefix']), copied, ['dx11'], audit, sandbox, proof, engine='dxmt', expected=lambda x: x.get('gpuBufferReadbackVerified') is True)
                else:
                    report.setdefault('skippedChecks', []).append('DXMT buffer' + str(bits) + ' unavailable')
            run_resource_checks(root, after, dxmt, audit, sandbox, proof, report, tls_servers)
        projection.verify_projection(root, verify_originals=True)
        report['sourceAndProjectionBytesUnchanged'] = True
        report['projectionRoot'] = str(root)
        report['staticOnly'] = args.static_only
        report['passed'] = all(value.get('passed') is True for value in report['tests'].values())
        passed = report['passed']
        if not passed:
            raise RuntimeError('One or more moved-root resource probes failed; observations retained')
    except Exception as error:
        report['error'] = str(error)
        report['projectionRoot'] = str(root)
        raise
    finally:
        for tls_server in tls_servers:
            tls_server.shutdown(); tls_server.server_close()
        try:
            projection.verify_projection(root, verify_originals=True)
            report['sourceAndProjectionBytesUnchanged'] = True
        except Exception as verify_error:
            report['sourceAndProjectionBytesUnchanged'] = False
            report['passed'] = False
            report['byteVerificationError'] = str(verify_error)
        cleanup_ok = True
        for server, prefix in active:
            env = {k: v for k, v in os.environ.items() if not k.startswith(('WINE', 'DYLD_', 'READY_', 'M1L_', 'CX_APPLEGPTK'))}
            env.update(WINEPREFIX=prefix, WINEDEBUG='-all')
            try:
                subprocess.run([server, '-k'], env=env, capture_output=True, timeout=10)
                subprocess.run([server, '-w'], env=env, capture_output=True, timeout=20, check=True)
            except Exception:
                cleanup_ok = False
        if passed and cleanup_ok:
            shutil.rmtree(data)
        report['ownedPrefixFixturesRemoved'] = passed and cleanup_ok
        if not cleanup_ok:
            report['passed'] = False
        write_report(args.output, report)
        print(json.dumps({'passed': report['passed'], 'projectionRoot': report.get('projectionRoot'),
                          'checks': list(report['tests']), 'diagnosticOnly': True, 'binaryDistributionApproved': False,
                          'error': report.get('error'), 'report': str(args.output)}, indent=2), flush=True)
        if not cleanup_ok:
            raise RuntimeError('Exact-prefix cleanup incomplete; owned fixture retained')
        if not report['sourceAndProjectionBytesUnchanged']:
            raise RuntimeError('Original or projected bytes changed; diagnostic verification failed')


if __name__ == '__main__':
    main()
