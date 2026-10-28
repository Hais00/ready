#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Public Vulkan property-chain compiler for PE64 and explicit PE32 controls.

Pure Wine installations only. Fresh UUID prefixes, matching pure PE32 bootstrap,
individual process per query, actual Wine Unix-call faults retained per case.
No Apple evaluation files, feature overrides, upstream patches, or UI actions.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import signal
import tempfile
import resource
import uuid

from runtime_vulkan_properties_probe import ROOT, HEADERS, digest, observations

ENTRY = ROOT/'Scripts/runtime_vulkan_properties_windows_probe.c'
SHARED = ROOT/'Scripts/runtime_vulkan_properties_probe.c'
OUTPUT = ROOT/'Build/VulkanPropertiesWindows'


def compile_probe(wine, bits=64):
    output = OUTPUT if bits == 64 else OUTPUT/'pe32'
    output.mkdir(parents=True, exist_ok=True)
    headers = wine/'include/wine/windows'
    crt = ROOT/'Vendor/wine/include/msvcrt'
    libraries = wine/'lib/wine'/('x86_64-windows'if bits==64 else'i386-windows')
    for path in (headers/'windows.h', libraries/'libkernel32.a', libraries/'libucrtbase.a'):
        assert path.is_file(), str(path)
    subprocess.run(['/opt/homebrew/opt/llvm/bin/clang', '--target='+('x86_64-windows'if bits==64 else'i686-windows'),
                    '--no-default-config', '-D_UCRT', '-ffreestanding', '-fno-builtin',
                    '-fno-stack-protector', '-fshort-wchar', '-O0', '-g',
                    '-I', str(headers), '-I', str(crt), '-I', str(HEADERS),
                    '-c', str(ENTRY), '-o', str(output/'probe.obj')], check=True, cwd=ROOT)
    temporary = output/'probe.exe.pending'
    subprocess.run(['/opt/homebrew/opt/lld/bin/lld-link', '/entry:mainCRTStartup',
                    '/subsystem:console', '/machine:'+('x64'if bits==64 else'x86'), '/nodefaultlib', str(output/'probe.obj'),
                    str(libraries/'libkernel32.a'), str(libraries/'libucrtbase.a'),
                    '/out:'+str(temporary)], check=True, cwd=ROOT)
    executable = output/'probe.exe'
    temporary.replace(executable)
    return executable, {'windowsHeaderSHA256': digest(headers/'windows.h'),
                        'crtHeaderSHA256': digest(crt/'stdio.h'),
                        'kernelImportArchiveSHA256': digest(libraries/'libkernel32.a'),
                        'ucrtImportArchiveSHA256': digest(libraries/'libucrtbase.a')}


def bounded(value, maximum=22000):
    if len(value) <= maximum:
        return value
    return value[:3000]+'\n[diagnostic log truncated; retained start/end]\n'+value[-(maximum-3000):]


def execute_wine(command, env, timeout):
    # A wineserver or Wine service can inherit stdout/stderr. Waiting
    # for pipe EOF then misclassifies a completed PE query as a hang. Wait only
    # for our process and read file-backed diagnostics instead.
    began=time.monotonic()
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process=subprocess.Popen(list(map(str,command)),cwd=ROOT,env=env,
            stdin=subprocess.DEVNULL,stdout=out,stderr=err,start_new_session=True,
            preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_CORE,(0,0)))
        timed_out=False
        try:process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out=True;os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=5)
        out.seek(0);err.seek(0)
        stdout=out.read().decode(errors='replace');stderr=err.read().decode(errors='replace')
    return {'exitCode':process.returncode,'pid':process.pid,'timeout':timed_out,
        'seconds':round(time.monotonic()-began,4),'stdout':stdout,'stderr':stderr,
        'observations':observations(stdout)}


def summarize_report(report, native_path=None):
    contexts=[value for provider in report['providers'].values() for value in provider['drivers'].values()]
    trials=[trial for context in contexts for trial in context['tests'].values()]
    report['queryCount']=len(trials)
    report['allQueriesVerified']=bool(trials) and all(trial['queryVerified'] for trial in trials) and all(not context.get('inventoryFailed') for context in contexts)
    report['allLoaderTracesVerified']=bool(contexts) and all(context['loaderTraceVerified'] for context in contexts)
    report['allPrefixesStopped']=all(provider.get('exactPrefixCleanupCompleted') for provider in report['providers'].values())
    if native_path and native_path.exists():
        native=json.loads(native_path.read_text())
        comparisons={}
        for provider_name,provider in report['providers'].items():
            for driver,context in provider['drivers'].items():
                native_inventory=[value for value in native['drivers'][driver]['inventory']['observations'] if value.get('stage')=='inventory'][-1]
                windows_inventory=[value for value in context['inventory']['observations'] if value.get('stage')=='inventory']
                if windows_inventory:
                    sizes=lambda data:{case['name']:(case['sType'],case['size']) for case in data['cases']}
                    comparisons[provider_name+'/'+driver]=sizes(native_inventory)==sizes(windows_inventory[-1])
        report['sourcePropertySTypeAndSizeMatchNative']=comparisons
        report['nativeComparisonEvidenceSHA256']=digest(native_path)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=['both', 'wine', 'winecx'], default='both')
    parser.add_argument('--driver', choices=['all', 'kosmic', 'molten'], default='all')
    parser.add_argument('--case', default='all', help='all, base, core, full, or one source property name')
    parser.add_argument('--timeout', type=float, default=25)
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    config = json.loads((ROOT/'Runtime/runtime.json').read_text())
    base = Path(config['wineBinary']).resolve().parent.parent
    pure_cx = Path(json.loads((ROOT/'Evidence/runtime-vkd3d-winecx-open.json').read_text())['wineRoot']).resolve()
    executable, headers = compile_probe(base)
    providers = {'wine': base, 'winecx': pure_cx}
    if args.provider != 'both':
        providers = {args.provider: providers[args.provider]}
    report_path = ROOT/'Evidence/runtime-vulkan-properties-windows.json'
    report = {'schema': 1, 'testType': 'actual-PE64-public-Vulkan-headers-and-pure-Wine-properties2',
              'entrySHA256': digest(ENTRY), 'sharedNativeSourceSHA256': digest(SHARED),
              'executableSHA256': digest(executable), 'headers': headers,
              'hardwareFeatureOverrides': False, 'appleEvaluationUsed': False,
              'runtimeID': config['runtimeID'], 'providers': {}}
    for provider, wine in providers.items():
        assert (wine/'bin/wine').is_file() and (wine/'bin/wineserver').is_file()
        assert not (wine/'lib/external/D3DMetal.framework').exists(), 'Pure Wine root required'
        work = ROOT/'Runtime/TestPrefixes'/('properties-'+provider+'-'+str(uuid.uuid4()))
        work.mkdir(parents=True, mode=0o700)
        prefix = work/'prefix'; prefix.mkdir(mode=0o700)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('VK_', 'VKD3D_', 'DXVK_', 'MESA_', 'MVK_', 'KOSMIC_',
                                      'DYLD_', 'D3DM_', 'CX_', 'WINE', 'READY_', 'M1L_', 'MTL_'))}
        search = str(Path(config['vulkanLibrary']).parent)+':'+str(Path(config['immutableRuntimeSet'])/'dependencies')
        env.update(WINEPREFIX=str(prefix), WINEDEBUG='-all,err+vulkan,warn+vulkan,+seh',
                   WINEDLLOVERRIDES='mscoree,mshtml=d;winemenubuilder.exe=d',
                   DYLD_LIBRARY_PATH=search, DYLD_FALLBACK_LIBRARY_PATH=search)
        version = subprocess.check_output([str(wine/'bin/wine'), '--version'], env=env, text=True).strip()
        item = {'wineRoot': str(wine), 'version': version, 'prefix': str(prefix), 'drivers': {}}
        report['providers'][provider] = item
        try:
            wow64 = prefix/'drive_c/windows/syswow64'; wow64.mkdir(parents=True)
            subprocess.run(['/bin/cp', '-cR', str(wine/'lib/wine/i386-windows')+'/.', str(wow64)], check=True)
            boot = execute_wine([wine/'bin/wine', 'wineboot', '-u'], {**env, 'WINEDEBUG': '-all'}, 120)
            item['boot'] = {key: value for key, value in boot.items() if key != 'observations'}
            item['boot']['stdout'] = bounded(item['boot']['stdout'], 5000)
            item['boot']['stderr'] = bounded(item['boot']['stderr'], 5000)
            if boot['exitCode'] != 0:
                raise RuntimeError('Matching pure Wine prefix bootstrap failed')
            for driver in (['kosmic', 'molten'] if args.driver == 'all' else [args.driver]):
                icd = config['kosmicICD' if driver == 'kosmic' else 'moltenICD']
                query_env = {**env, 'VK_DRIVER_FILES': icd, 'VK_ICD_FILENAMES': icd}
                inventory = execute_wine([wine/'bin/wine', executable],
                                    {**query_env, 'READY_PROPERTIES_CASE': 'list', 'DYLD_PRINT_LIBRARIES': '1'}, args.timeout)
                trace = inventory['stderr']
                inventory['stderr'] = bounded(trace)
                inventory_log = ROOT/f'Evidence/runtime-vulkan-properties-windows-{provider}-{driver}-inventory.log'
                inventory_log.write_text(inventory['stdout']+'\n'+bounded(trace, 65000))
                inventory['stdoutByteCount']=len(inventory['stdout'].encode())
                inventory.pop('stdout')
                inventory['stdoutStoredInRawLog']=True
                inv = [value for value in inventory['observations'] if value.get('stage') == 'inventory']
                driver_result = {'icd': icd, 'inventory': inventory, 'inventoryLog': str(inventory_log),
                                 'appleFrameworkLoaded': 'D3DMetal.framework' in trace,
                                 'loaderTraceVerified': str(Path(config['vulkanLibrary'])) in trace or str(Path(config['vulkanLibrary']).resolve()) in trace,
                                 'relevantNativeImages': [line for line in trace.splitlines() if any(token in line.lower() for token in ('winevulkan','libvulkan','moltenvk','kosmic','d3dmetal'))],
                                 'tests': {}}
                item['drivers'][driver] = driver_result
                assert not driver_result['appleFrameworkLoaded'], 'Unexpected Apple evaluation library in pure control'
                if inventory['exitCode'] != 0 or not inv:
                    driver_result['inventoryFailed'] = True
                    continue
                assert driver_result['loaderTraceVerified'], 'Actual public Vulkan loader path missing from native image trace'
                assert inv[-1]['pointerBytes'] == 8
                modes = ['base', 'core', 'full']+[case['name'] for case in inv[-1]['cases'] if case['supported']]
                if args.case != 'all':
                    modes = [args.case]
                for mode in modes:
                    current_env = {**query_env, 'READY_PROPERTIES_CASE': mode}
                    trial = execute_wine([wine/'bin/wine', executable], current_env, args.timeout)
                    unix_exception = 'vkGetPhysicalDeviceProperties2 Exception' in trial['stderr']
                    after = [value for value in trial['observations'] if value.get('stage') == 'after-query']
                    trial['wineUnixCallException'] = unix_exception
                    trial['queryVerified'] = trial['exitCode'] == 0 and not unix_exception and any(
                        value.get('guardAndHeadersIntact') and value.get('baseMatchesLegacy') for value in after)
                    trial['lastStage'] = trial['observations'][-1].get('stage') if trial['observations'] else None
                    raw = ROOT/f'Evidence/runtime-vulkan-properties-windows-{provider}-{driver}-{mode}.log'
                    raw.write_text(trial['stdout']+'\n'+bounded(trial['stderr']))
                    trial['stdoutByteCount']=len(trial['stdout'].encode())
                    trial.pop('stdout')
                    trial['stdoutStoredInRawLog']=True
                    trial['rawLog'] = str(raw)
                    trial['stderr'] = bounded(trial['stderr'], 9000)
                    driver_result['tests'][mode] = trial
                    print(provider, driver, mode, trial['exitCode'], 'VERIFIED' if trial['queryVerified'] else 'FAULT/UNVERIFIED', flush=True)
                    report_path.write_text(json.dumps(report, indent=2)+'\n')
                    if trial['timeout']:
                        # Stop only this synthetic prefix; do not leave a debugger
                        # or stuck query contaminating subsequent observations.
                        subprocess.run([str(wine/'bin/wineserver'), '-k'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                        subprocess.run([str(wine/'bin/wineserver'), '-w'], env=env, capture_output=True, timeout=15)
        finally:
            try:
                subprocess.run([str(wine/'bin/wineserver'), '-k'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                subprocess.run([str(wine/'bin/wineserver'), '-w'], env=env, capture_output=True, timeout=20, check=True)
                item['exactPrefixCleanupCompleted'] = True
            except Exception as error:
                item['exactPrefixCleanupCompleted'] = False
                item['cleanupError'] = str(error)
            if not args.keep and item.get('exactPrefixCleanupCompleted'):
                shutil.rmtree(work)
            item['scratchRetained'] = args.keep or not item.get('exactPrefixCleanupCompleted')
            report_path.write_text(json.dumps(report, indent=2)+'\n')
    summary = {}
    for provider, item in report['providers'].items():
        summary[provider] = {}
        for driver, values in item['drivers'].items():
            summary[provider][driver] = {mode: trial['queryVerified'] for mode, trial in values['tests'].items()}
    report['summary'] = summary
    summarize_report(report, ROOT/'Evidence/runtime-vulkan-properties.json')
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'summary': summary, 'evidence': str(report_path)}, indent=2))


if __name__ == '__main__':
    main()
