#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build pinned public WineCX separately from the default upstream Wine runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
from urllib.request import Request, urlopen

import runtime_build

ROOT = Path(__file__).resolve().parents[1]
COMMIT = '9f3f6447844add700bc0dde650e4f398fd5f69ab'
VERSION = '11.19'
TAG = 'winecx-' + VERSION + '-' + COMMIT[:12]
SOURCE = ROOT / 'Runtime' / (TAG + '-source')
BUILD = ROOT / 'Runtime' / ('build-' + TAG)
INSTALL = ROOT / 'Runtime' / TAG
LOCK = ROOT / 'Scripts/runtime_winecx.lock.json'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch():
    archive = ROOT / 'Runtime' / (TAG + '.tar.gz')
    url = 'https://codeload.github.com/dappermint/winecx/tar.gz/' + COMMIT
    expected = json.loads(LOCK.read_text()) if LOCK.exists() else None
    if not archive.exists():
        temporary = archive.with_suffix('.partial')
        with urlopen(Request(url, headers={'User-Agent': 'ready-open-runtime-build'}), timeout=180) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output)
        temporary.rename(archive)
    sha = digest(archive)
    if expected and (expected['sourceCommit'] != COMMIT or expected['archiveSHA256'] != sha):
        raise RuntimeError('Pinned WineCX source archive mismatch')
    if not SOURCE.exists():
        staging = SOURCE.with_name(SOURCE.name + '.staging'); staging.mkdir()
        with tarfile.open(archive) as packed:
            packed.extractall(staging, filter='data')
        roots = list(staging.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise RuntimeError('Unexpected public WineCX archive layout')
        roots[0].rename(SOURCE); staging.rmdir()
    if (SOURCE / 'VERSION').read_text().strip() != 'Wine version ' + VERSION:
        raise RuntimeError('WineCX source version differs from the declared version')
    license_text = (SOURCE / 'LICENSE').read_text()
    if 'GNU Lesser General Public License' not in license_text:
        raise RuntimeError('Expected public Wine LGPL license missing')
    lock = {'schema': 1, 'repository': 'https://github.com/dappermint/winecx', 'sourceCommit': COMMIT,
            'sourceBranchAtSelection': 'wine1119', 'wineVersion': VERSION, 'selectedAt': '2026-10-28',
            'archiveURL': url, 'archiveSHA256': sha, 'license': 'LGPL-2.1-or-later',
            'licenseSHA256': digest(SOURCE / 'LICENSE'), 'upstreamSourceModified': False,
            'purpose': 'Optional Apple-compatible Wine provider; upstream Wine 11.20 remains the default'}
    audited = ['dlls/winemac.drv/d3dmetal.c', 'dlls/winemac.drv/d3dmetal_objc.h', 'dlls/winemac.drv/d3dmetal_objc.m',
               'dlls/winemac.drv/macdrv.h', 'dlls/ntdll/loader.c', 'dlls/ntdll/unix/loader.c',
               'dlls/ntdll/unix/unix_private.h', 'dlls/ntdll/unix/signal_x86_64.c']
    lock['bridgeFileLicenses'] = {}
    for relative in audited:
        path = SOURCE / relative; header = path.read_text()[:5000]
        if 'GNU Lesser General Public' not in header or 'version 2.1' not in header or 'any later version' not in header:
            raise RuntimeError('Expected explicit per-file LGPL grant missing: ' + relative)
        lock['bridgeFileLicenses'][relative] = {'license': 'LGPL-2.1-or-later', 'sha256': digest(path),
            'copyright': [line.strip(' *') for line in header.splitlines()[:12] if 'Copyright' in line]}
    forbidden = [str(path.relative_to(SOURCE)) for path in SOURCE.rglob('*') if path.is_file() and
                 (path.suffix in ['.dylib', '.metallib'] or '.framework/' in str(path.relative_to(SOURCE)) or path.name in ['Metal.h', 'AppKit.h', 'libd3dshared.dylib'])]
    if forbidden:
        raise RuntimeError('Unexpected native Apple/library payload in source archive; inspect it before proceeding')
    lock['applePayloadOrSDKHeaderPathsFound'] = forbidden
    lock['systemSDKHeadersRedistributed'] = False
    LOCK.write_text(json.dumps(lock, indent=2) + '\n')
    print(json.dumps(lock, indent=2), flush=True)


def environment():
    short = runtime_build.short_root()
    env = dict(os.environ)
    env['PATH'] = '/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin'
    deps = short / 'Runtime/wine-deps/lib'
    vulkan = short / 'Runtime/vulkan-sdk-1.4.366'
    env.update(CC='/usr/bin/clang -arch x86_64', CXX='/usr/bin/clang++ -arch x86_64',
               CROSSCC='/opt/homebrew/opt/llvm/bin/clang', CROSSCXX='/opt/homebrew/opt/llvm/bin/clang++',
               CFLAGS='-O2 -g0', CXXFLAGS='-O2 -g0',
               LDFLAGS=f'-L{vulkan}/lib -L{deps} -Wl,-rpath,{vulkan}/lib -Wl,-rpath,{deps}',
               DYLD_LIBRARY_PATH=str(vulkan / 'lib') + ':' + str(deps),
               VULKAN_LIBS=f'-L{vulkan}/lib -lvulkan',
               ac_cv_lib_soname_freetype='libfreetype.6.dylib', ac_cv_lib_soname_gnutls='libgnutls.30.dylib', ac_cv_lib_soname_vulkan='libvulkan.1.dylib')
    headers = short / 'Runtime/dependency-headers'
    freetype = sorted((headers / 'freetype').glob('*/include/freetype2'))
    gnutls = sorted((headers / 'gnutls').glob('*/include'))
    if not freetype or not gnutls:
        raise RuntimeError('Run runtime_fetch.py --dependency-headers first')
    env.update(FREETYPE_CFLAGS='-I' + str(freetype[-1]), FREETYPE_LIBS=f'-L{deps} -lfreetype',
               GNUTLS_CFLAGS='-I' + str(gnutls[-1]), GNUTLS_LIBS=f'-L{deps} -lgnutls')
    return env


def configure():
    if not SOURCE.exists():
        raise RuntimeError('Fetch the pinned LGPL source first')
    BUILD.mkdir(exist_ok=True)
    short = runtime_build.short_root()
    options = ['../' + SOURCE.name + '/configure', '--prefix=' + str(short / 'Runtime' / TAG),
        '--host=x86_64-apple-darwin', '--build=x86_64-apple-darwin', '--enable-win64', '--enable-archs=x86_64,i386',
        '--disable-tests', '--with-vulkan', '--with-gnutls', '--with-freetype', '--without-x', '--without-gstreamer',
        '--without-dbus', '--without-pulse', '--without-alsa', '--without-cups', '--without-sane', '--without-gphoto',
        '--without-usb', '--without-krb5', '--without-oss', '--without-sdl']
    subprocess.run(options, cwd=BUILD, env=environment(), check=True)


def build(jobs):
    env = environment()
    flags = ['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0', 'CXXFLAGS=-O2 -g0',
             'i386_CFLAGS=-O2 -g0', 'x86_64_CFLAGS=-O2 -g0', 'i386_CXXFLAGS=-O2 -g0', 'x86_64_CXXFLAGS=-O2 -g0']
    subprocess.run(['/opt/homebrew/bin/gmake', '-j' + str(jobs), *flags], cwd=BUILD, env=env, check=True)
    subprocess.run(['/opt/homebrew/bin/gmake', 'install', *flags], cwd=BUILD, env=env, check=True)
    version = subprocess.check_output([str(INSTALL / 'bin/wine'), '--version'], env=env, text=True).strip()
    result = {'source': json.loads(LOCK.read_text()), 'reportedVersion': version, 'install': str(INSTALL),
              'buildFlags': ['x86_64-macOS', 'x86_64-PE', 'i386-PE', 'O2', 'g0', 'explicit-sonames'],
              'appleProprietaryFilesIncluded': False, 'dx12Verified': False}
    (ROOT / 'Evidence/runtime-winecx-build.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['fetch', 'configure', 'build'])
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    {'fetch': fetch, 'configure': configure, 'build': lambda: build(args.jobs)}[args.command]()
