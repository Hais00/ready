#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Experimental Wine TLS compatibility hook, only for an isolated Apple test.

The public WineCX source stores the native pthread TLS base in TEB.Reserved5[0].
Modern Wine keeps it in private thread data instead. This experiment restores
that explicit compatibility field without changing the modern syscall path.
It is not evidence that the proprietary runtime is compatible.
"""
import difflib
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Vendor/wine/dlls/ntdll/unix/signal_x86_64.c'
BUILD = ROOT / 'Runtime/build-wine-11.20'
OUTPUT = ROOT / 'Runtime/wine-ready-apple-adapter'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    original = SOURCE.read_text()
    anchor = '    thread_data->pthread_teb = mac_thread_gsbase();'
    if original.count(anchor) != 1:
        raise RuntimeError('Wine thread-init ABI anchor changed')
    patched = original.replace(anchor, anchor + '\n    /* Explicit legacy TLS-base field used by the public WineCX bridge ABI. */\n    C_ASSERT(FIELD_OFFSET(TEB, SavedPriorityState) == 0x1768);\n    teb->SavedPriorityState = thread_data->pthread_teb;')
    OUTPUT.mkdir(exist_ok=True)
    adapted = OUTPUT / 'signal_x86_64.c'; adapted.write_text(patched)
    (ROOT / 'Scripts/runtime_wine_apple_teb.patch').write_text(''.join(difflib.unified_diff(original.splitlines(keepends=True), patched.splitlines(keepends=True), fromfile='a/dlls/ntdll/unix/signal_x86_64.c', tofile='b/dlls/ntdll/unix/signal_x86_64.c')))
    env = dict(os.environ)
    env['PATH'] = '/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin'
    flags = ['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0', 'i386_CFLAGS=-O2 -g0', 'x86_64_CFLAGS=-O2 -g0']
    subprocess.run(['/opt/homebrew/bin/gmake', '-j3', *flags, 'dlls/ntdll/ntdll.so'], cwd=BUILD, env=env, check=True)
    target = 'dlls/ntdll/unix/signal_x86_64.o'
    dry = subprocess.check_output(['/opt/homebrew/bin/gmake', '-n', '-W', '../../Vendor/wine/dlls/ntdll/unix/signal_x86_64.c', *flags, target], cwd=BUILD, env=env, text=True)
    line = next(line for line in dry.replace('\\\n', ' ').splitlines() if '-c -o ' + target + ' ' in line)
    command = shlex.split(line)
    old = '../../Vendor/wine/dlls/ntdll/unix/signal_x86_64.c'
    if command.count(old) != 1:
        raise RuntimeError('Unexpected ntdll compile command')
    subprocess.run([*[str(adapted) if item == old else item for item in command], '-I' + str(SOURCE.parent)], cwd=BUILD, env=env, check=True)
    subprocess.run(['/opt/homebrew/bin/gmake', '-j3', *flags, 'dlls/ntdll/ntdll.so'], cwd=BUILD, env=env, check=True)
    binary = BUILD / 'dlls/ntdll/ntdll.so'
    shutil.copy2(binary, OUTPUT / 'ntdll.so')
    record = {'wineVersion': '11.20', 'referenceSource': 'https://github.com/3Shain/winecx/blob/376ab830de1a4bbea9d78e45db9813fc44cef0e0/dlls/ntdll/unix/signal_x86_64.c', 'originalSourceSHA256': sha(SOURCE), 'adaptedSourceSHA256': sha(adapted), 'moduleSHA256': sha(binary), 'experimental': True, 'vendorSourceUnmodified': True, 'license': 'LGPL-2.1-or-later'}
    (ROOT / 'Evidence/runtime-apple-teb-adapter.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
