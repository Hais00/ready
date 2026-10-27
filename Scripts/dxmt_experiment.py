#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare/query an isolated DXMT runtime. Never changes Runtime/Sets or upstream source."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import time
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen
from urllib.parse import urlsplit
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT = ROOT / 'Runtime/DXMTExperiment'
LOCK = ROOT / 'DXMTIntegration/dxmt.lock.json'
CORE_DLLS = ('d3d10core.dll', 'd3d11.dll', 'dxgi.dll', 'winemetal.dll')


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def confined(path: Path) -> Path:
    path = path.expanduser().resolve()
    if path == EXPERIMENT.resolve() or not path.is_relative_to(EXPERIMENT.resolve()):
        raise ValueError('Mutable destination must be a child of Runtime/DXMTExperiment')
    return path


class PrivateRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        result = super().redirect_request(req, fp, code, msg, headers, newurl)
        if result:
            result.remove_header('Authorization')
            result.remove_header('Cookie')
        return result


def fetch(lock: dict) -> None:
    """Recover the exact official artifact, never an unpinned latest download."""
    downloads = EXPERIMENT / 'Downloads'
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / 'dxmt-ci.zip'
    if not archive.exists() or sha256(archive) != lock['artifactArchiveSHA256']:
        env = os.environ.copy()
        env['GIT_TERMINAL_PROMPT'] = '0'
        result = subprocess.run(['git', 'credential', 'fill'], input='protocol=https\nhost=github.com\n\n', text=True, capture_output=True, env=env, check=True)
        credential = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        token = credential.get('password')
        if not token:
            raise RuntimeError('GitHub authentication unavailable')
        url = f"https://api.github.com/repos/3Shain/dxmt/actions/artifacts/{lock['artifactID']}/zip"
        if urlsplit(url).hostname != 'api.github.com':
            raise ValueError('Unexpected authenticated host')
        request = Request(url, headers={'User-Agent': 'ready-dxmt-integration', 'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json'})
        temporary = archive.with_suffix('.partial')
        try:
            with build_opener(PrivateRedirect()).open(request, timeout=120) as response, temporary.open('wb') as output:
                shutil.copyfileobj(response, output)
            if sha256(temporary) != lock['artifactArchiveSHA256']:
                raise RuntimeError('Official CI artifact checksum mismatch')
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    artifact = EXPERIMENT / 'Artifact'
    artifact.mkdir(exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            name = Path(member.filename)
            if name.is_absolute() or '..' in name.parts or (member.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('Unsafe CI archive member')
        source.extractall(artifact)
    packed = artifact / f"dxmt-{lock['sourceCommit']}.tar.gz"
    if sha256(packed) != lock['payloadArchiveSHA256']:
        raise RuntimeError('Payload checksum mismatch')
    with tarfile.open(packed) as source:
        source.extractall(EXPERIMENT / 'Payload', filter='data')
    print(json.dumps({'artifactVerified': True, 'sourceCommit': lock['sourceCommit']}))


def payload(lock: dict) -> Path:
    base = EXPERIMENT / 'Payload' / lock['sourceCommit']
    manifest = lock['selectedPayloadFiles']
    for relative, digest in manifest.items():
        candidate = base / relative
        if sha256(candidate) != digest:
            raise RuntimeError(f'Payload checksum mismatch: {relative}')
    return base


def prepare(lock: dict, wine_root: Path, destination: Path) -> None:
    source = wine_root.resolve()
    destination = confined(destination)
    if not (source / 'bin/wine').is_file() or not (source / 'lib/wine/x86_64-unix/ntdll.so').is_file():
        raise ValueError('Wine installation with x86_64 Unix modules required')
    if destination.exists():
        raise ValueError('Destination already exists; prepare a fresh isolated snapshot')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # APFS clone only: no fallback to a potentially multi-gigabyte full copy.
    subprocess.run(['cp', '-cR', str(source), str(destination)], check=True)
    base = payload(lock)
    for arch in ('x86_64', 'i386'):
        target = destination / 'lib/wine' / (arch + '-windows')
        if not target.is_dir():
            if arch == 'i386':
                continue
            raise ValueError('Missing x86_64 Wine builtin directory')
        for name in CORE_DLLS:
            shutil.copy2(base / (arch + '-windows') / name, target / name)
    shutil.copy2(base / 'x86_64-unix/winemetal.so', destination / 'lib/wine/x86_64-unix/winemetal.so')
    prepared = {'schema': 1, 'sourceCommit': lock['sourceCommit'], 'license': lock['license'], 'wineSource': str(source), 'wineRoot': str(destination), 'builtinOverrides': 'd3d11,dxgi,d3d10core,winemetal=b', 'selectedPayloadFiles': lock['selectedPayloadFiles'], 'verifiedAPIs': [], 'upstreamSourceModified': False}
    (destination / 'dxmt-prepared.json').write_text(json.dumps(prepared, indent=2) + '\n')
    print(json.dumps(prepared))


def environment(engine: Path, prefix: Path) -> dict:
    engine, prefix = confined(engine), confined(prefix)
    env = os.environ.copy()
    libraries = [engine / 'lib/wine/x86_64-unix', ROOT / 'Runtime/wine-deps/lib', ROOT / 'Runtime/vulkan-sdk-1.4.366/lib']
    env.update(WINEPREFIX=str(prefix), WINEDEBUG='-all', WINEDLLOVERRIDES='d3d11,dxgi,d3d10core,winemetal=b', DXMT_LOG_PATH='none', DXMT_SHADER_CACHE_PATH=str(prefix / 'dxmt-cache'), DYLD_LIBRARY_PATH=':'.join(map(str, libraries)))
    env['DYLD_FALLBACK_LIBRARY_PATH'] = env['DYLD_LIBRARY_PATH']
    return env


def probe(lock: dict, engine: Path, prefix: Path, timeout: float, shader: bool = False, trace_modules: bool = False) -> None:
    engine, prefix = confined(engine), confined(prefix)
    env = environment(engine, prefix)
    for relative, digest in lock['selectedPayloadFiles'].items():
        installed = engine / 'lib/wine' / relative
        if relative.startswith('i386-') and not installed.exists():
            continue
        if sha256(installed) != digest:
            raise ValueError('Installed core DXMT payload differs from locked official artifact')
    executable = ROOT / 'Runtime/Probes/runtime_windows_probe.exe'
    tag = 'dxmt-device'
    if shader:
        executable = EXPERIMENT / 'dxmt_shader_probe.exe'
        obj = EXPERIMENT / 'shader-probe.obj'
        command = ['/opt/homebrew/opt/llvm/bin/clang', '--target=x86_64-windows', '--no-default-config', '-ffreestanding', '-fno-builtin', '-fshort-wchar', '-O2', '-I', str(engine / 'include/wine/windows'), '-I', str(ROOT / 'Vendor/wine/include/msvcrt'), '-c', str(ROOT / 'DXMTIntegration/dxmt_shader_probe.c'), '-o', str(obj)]
        subprocess.run(command, check=True)
        subprocess.run(['/opt/homebrew/opt/lld/bin/lld-link', '/entry:mainCRTStartup', '/subsystem:console', '/machine:x64', '/nodefaultlib', str(obj), str(ROOT / 'Runtime/Probes/kernel32.lib'), '/out:' + str(executable)], check=True)
        tag = 'dxmt-shader'
    if not executable.is_file():
        raise ValueError('Build the original Ready runtime_windows_probe.exe first')
    if trace_modules:
        env['WINEDEBUG'] = '+loaddll'
        env['DYLD_PRINT_LIBRARIES'] = '1'
    evidence = ROOT / 'Evidence'
    started = time.monotonic()
    with (evidence / (tag + '.log')).open('wb') as log:
        process = subprocess.Popen([str(engine / 'bin/wine'), str(executable), 'dx11'], env=env, stdout=subprocess.PIPE, stderr=log, start_new_session=True)
        try:
            output = process.communicate(timeout=timeout)[0]
            status = process.returncode
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                output = process.communicate(timeout=10)[0]
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output = process.communicate()[0]
            status = 124
        finally:
            subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    (evidence / (tag + '.stdout.txt')).write_bytes(output)
    observations = []
    for line in output.decode(errors='replace').splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict) and value.get('api') == 'dx11':
                observations.append(value)
        except ValueError:
            pass
    observation = observations[-1] if observations else {}
    try:
        level = int(observation.get('featureLevel', '0'), 0)
    except (ValueError, TypeError):
        level = 0
    passed = status == 0 and level >= 0xb000 and (observation.get('shaderRasterizationVerified') is True if shader else observation.get('deviceCreated') is True and observation.get('gpuBufferReadbackVerified') is True)
    result = {'schema': 1, 'sourceCommit': lock['sourceCommit'], 'engine': str(engine), 'prefix': str(prefix), 'seconds': round(time.monotonic() - started, 3), 'exitCode': status, 'observation': observation, 'passed': passed, 'verifiedAPIs': ['d3d11'] if passed else [], 'presentationVerified': False, 'shaderRasterizationVerified': passed if shader else False, 'corePayloadHashesVerified': True, 'probeExecutableSHA256': sha256(executable), 'gameCompatibilityVerified': False, 'upstreamSourceModified': False}
    (evidence / (tag + '-result.json')).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    if not passed:
        raise SystemExit(3)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('fetch')
    staging = commands.add_parser('prepare')
    staging.add_argument('--wine-root', required=True, type=Path)
    staging.add_argument('--output', required=True, type=Path)
    for name in ('probe', 'shader-probe'):
        testing = commands.add_parser(name)
        testing.add_argument('--wine-root', required=True, type=Path)
        testing.add_argument('--prefix', required=True, type=Path)
        testing.add_argument('--timeout', type=float, default=180)
        testing.add_argument('--trace-modules', action='store_true')
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    if args.command == 'fetch':
        fetch(lock)
    elif args.command == 'prepare':
        prepare(lock, args.wine_root, args.output)
    elif args.command in ('probe', 'shader-probe'):
        probe(lock, args.wine_root, args.prefix, args.timeout, shader=args.command == 'shader-probe', trace_modules=args.trace_modules)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Never print HTTP redirect locations, credential helper output, or tokens.
        print(json.dumps({'error': type(error).__name__, 'message': str(error) if not isinstance(error, subprocess.SubprocessError) else 'Subprocess failed'}), file=sys.stderr)
        raise SystemExit(2)
