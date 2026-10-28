#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build a diagnostic-only Wine signal observer, without modifying Vendor/Apple.

Captures the actual GS slots before Wine restores native TLS and prints a native
backtrace after restoration. This observes failures; it does not repair, emulate,
or replace any Apple function and must never be installed in a live runtime.
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
OUTPUT = ROOT / 'Runtime/wine-native-fault-observer'


def main():
    original = SOURCE.read_text()
    source = original.replace('#include <pthread.h>', '#include <pthread.h>\n#ifdef __APPLE__\n#include <execinfo.h>\n#include <dlfcn.h>\n#endif')
    anchor = '    struct thread_data *data = init_handler( sigcontext );\n    struct xcontext context;\n    EXCEPTION_RECORD rec = { .ExceptionAddress = (void *)RIP_sig(sigcontext) };'
    handler = source.index('static void segv_handler(')
    position = source.find(anchor, handler)
    if position < handler or position > handler + 500:
        raise RuntimeError('Wine signal handler ABI anchor changed')
    adapted = r'''#ifdef __APPLE__
    void *ready_fault_gs0, *ready_fault_gs30;
    __asm__ volatile("movq %%gs:0,%0" : "=r"(ready_fault_gs0));
    __asm__ volatile("movq %%gs:0x30,%0" : "=r"(ready_fault_gs30));
#endif
    struct thread_data *data = init_handler( sigcontext );
    struct xcontext context;
    EXCEPTION_RECORD rec = { .ExceptionAddress = (void *)RIP_sig(sigcontext) };
#ifdef __APPLE__
    if ((uintptr_t)rec.ExceptionAddress > 0x700000000000ULL)
    {
        static unsigned ready_fault_count;
        if (__sync_fetch_and_add(&ready_fault_count, 1) < 4)
        {
            void *frames[48];
            int count;
            Dl_info native_symbol = {0};
            dprintf(2, "READY_NATIVE_FAULT rip=%p fault=%p gs0_before=%p gs30_before=%p teb=%p pthread_teb=%p native_pthread=%p\n",
                    rec.ExceptionAddress, siginfo->si_addr, ready_fault_gs0, ready_fault_gs30,
                    data->teb, amd64_thread_data(data)->pthread_teb, pthread_self());
            if (dladdr(rec.ExceptionAddress, &native_symbol))
                dprintf(2, "READY_NATIVE_SYMBOL rip=%p image=%s base=%p symbol=%s symbolAddress=%p\n",
                        rec.ExceptionAddress, native_symbol.dli_fname, native_symbol.dli_fbase,
                        native_symbol.dli_sname ? native_symbol.dli_sname : "?", native_symbol.dli_saddr);
            count = backtrace(frames, 48);
            backtrace_symbols_fd(frames, count, 2);
            dprintf(2, "READY_NATIVE_FAULT_END\n");
        }
    }
#endif'''
    source = source[:position] + adapted + source[position + len(anchor):]
    OUTPUT.mkdir(exist_ok=True)
    path = OUTPUT / 'signal_x86_64.c'; path.write_text(source)
    (ROOT / 'Scripts/runtime_wine_native_fault.patch').write_text(''.join(difflib.unified_diff(original.splitlines(keepends=True), source.splitlines(keepends=True), fromfile='a/dlls/ntdll/unix/signal_x86_64.c', tofile='b/dlls/ntdll/unix/signal_x86_64.c')))
    env = dict(os.environ)
    env['PATH'] = '/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin'
    flags = ['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0', 'i386_CFLAGS=-O2 -g0', 'x86_64_CFLAGS=-O2 -g0']
    target = 'dlls/ntdll/unix/signal_x86_64.o'
    # Force pristine dependency compilation first: another isolated experiment
    # may have used this intermediate, but no active installed Wine is changed.
    (BUILD / target).unlink(missing_ok=True)
    subprocess.run(['/opt/homebrew/bin/gmake', '-j3', *flags, 'dlls/ntdll/ntdll.so'], cwd=BUILD, env=env, check=True)
    dry = subprocess.check_output(['/opt/homebrew/bin/gmake', '-n', '-W', '../../Vendor/wine/dlls/ntdll/unix/signal_x86_64.c', *flags, target], cwd=BUILD, env=env, text=True)
    line = next(line for line in dry.replace('\\\n', ' ').splitlines() if '-c -o ' + target + ' ' in line)
    old = '../../Vendor/wine/dlls/ntdll/unix/signal_x86_64.c'
    command = shlex.split(line)
    if command.count(old) != 1:
        raise RuntimeError('Unexpected Wine native compile command')
    subprocess.run([*[str(path) if item == old else item for item in command], '-I' + str(SOURCE.parent)], cwd=BUILD, env=env, check=True)
    subprocess.run(['/opt/homebrew/bin/gmake', '-j3', *flags, 'dlls/ntdll/ntdll.so'], cwd=BUILD, env=env, check=True)
    binary = OUTPUT / 'ntdll.so'; shutil.copy2(BUILD / 'dlls/ntdll/ntdll.so', binary)
    result = {'diagnosticOnly': True, 'vendorSourceUnmodified': True, 'proprietaryFilesModified': False,
              'sourceSHA256': hashlib.sha256(path.read_bytes()).hexdigest(), 'moduleSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'license': 'LGPL-2.1-or-later'}
    (ROOT / 'Evidence/runtime-native-fault-observer.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
