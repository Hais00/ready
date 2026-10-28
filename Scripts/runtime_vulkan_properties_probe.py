#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read-only x86_64/Rosetta Properties2 isolation using the frozen public Vulkan stack.

Queries vkd3d-proton's advertised property-chain gates, full reverse-prepend chain,
base/core chains, and each supported single structure. No Wine, Apple evaluation
provider, feature overrides, VkDevice, surfaces, or UI automation are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT/'Scripts/runtime_vulkan_properties_probe.c'
VENDOR_SOURCE = ROOT/'Vendor/vkd3d-proton/libs/vkd3d/device.c'
HEADERS = ROOT/'Runtime/vulkan-headers-1.4.366/include'
BINARY = ROOT/'Build/ReadyVulkanPropertiesProbe'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observations(text):
    result = []
    for line in text.splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                result.append(value)
        except ValueError:
            pass
    return result


def execute(command, env, timeout):
    began = time.monotonic()
    process = subprocess.Popen(list(map(str, command)), cwd=ROOT, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True,
                               preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate(timeout=5)
    return {'exitCode': process.returncode, 'pid': process.pid, 'timeout': timed_out,
            'seconds': round(time.monotonic()-began, 4), 'stdout': stdout,
            'stderr': stderr, 'observations': observations(stdout)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', choices=['all', 'kosmic', 'molten'], default='all')
    parser.add_argument('--case', default='all', help='all, full, core, base, or source property field name')
    parser.add_argument('--runtime', type=Path, default=ROOT/'Runtime/runtime.json')
    parser.add_argument('--timeout', type=float, default=15)
    args = parser.parse_args()
    config = json.loads(args.runtime.read_text())
    loader = Path(config['vulkanLibrary']).resolve()
    assert loader.is_file()
    # Refuse silent chain drift: the checked-in typed table must reproduce every
    # Properties2 prepend in the actual downloaded v3.0.1 source, in source order.
    vendor = VENDOR_SOURCE.read_text()
    begin = vendor.index('static void vkd3d_physical_device_info_init(')
    end = vendor.index('VK_CALL(vkGetPhysicalDeviceProperties2', begin)
    chain_order = re.findall(r'vk_prepend_struct\(&info->properties2,\s*&(?:info->)?(\w+)\);', vendor[begin:end])
    table = re.search(r'static const PropertyCase cases\[\]\s*=\s*\{(.*?)\n\};', SOURCE.read_text(), re.S).group(1)
    actual_order = re.findall(r'\bC\(\s*(\w+)\s*,', table)
    assert chain_order == actual_order and len(chain_order) == 31, 'Probe table no longer matches actual vkd3d source prepend order'
    c_types=dict(re.findall(r'\bC\(\s*(\w+)\s*,[^,]+,\s*(VK_STRUCTURE_TYPE_\w+)',table))
    for field in chain_order:
        assigned=re.findall(r'(?:info->)?'+field+r'\.sType\s*=\s*(VK_STRUCTURE_TYPE_\w+)',vendor[begin:end])
        assert assigned and c_types[field]==assigned[-1], 'Probe sType differs from the actual source: '+field
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-std=c11', '-O0', '-g',
                    '-fno-omit-frame-pointer', '-Wall', '-Wextra', '-Werror',
                    '-mmacosx-version-min=14.0', '-I', str(HEADERS), str(SOURCE),
                    '-o', str(BINARY)], cwd=ROOT, check=True)
    report = {'schema': 1, 'testType': 'native-x86_64-Rosetta-read-only-vulkan-properties2',
              'probeSHA256': digest(SOURCE), 'binarySHA256': digest(BINARY),
              'vkd3dSource': json.loads((ROOT/'Vendor/vkd3d-proton.source.json').read_text()),
              'vkd3dDeviceSourceSHA256': digest(VENDOR_SOURCE),
              'headersSource': json.loads((ROOT/'Runtime/vulkan-headers-1.4.366.artifact.json').read_text()),
              'vulkanHeaderSHA256': digest(HEADERS/'vulkan/vulkan_core.h'),
              'loaderPath': str(loader), 'loaderSHA256': digest(loader),
              'sourcePrependOrder': chain_order, 'sourceSTypeAssignmentsVerified': True,
              'advertisedFeaturesModified': False,
              'wineUsed': False, 'appleEvaluationUsed': False, 'drivers': {}}
    evidence = ROOT/'Evidence/runtime-vulkan-properties.json'
    debug_count = 0
    for driver in (['kosmic', 'molten'] if args.driver == 'all' else [args.driver]):
        icd = Path(config['kosmicICD' if driver == 'kosmic' else 'moltenICD']).resolve()
        assert icd.is_file()
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('VK_', 'VKD3D_', 'DXVK_', 'MESA_', 'MVK_', 'KOSMIC_',
                                      'DYLD_', 'D3DM_', 'CX_', 'WINE', 'READY_', 'M1L_', 'MTL_'))}
        search = str(loader.parent)+':'+str(Path(config['immutableRuntimeSet'])/'dependencies')
        env.update(VK_DRIVER_FILES=str(icd), VK_ICD_FILENAMES=str(icd),
                   DYLD_LIBRARY_PATH=search, DYLD_FALLBACK_LIBRARY_PATH=search)
        inventory = execute([BINARY, loader, 'list'], env, args.timeout)
        result = {'icdPath': str(icd), 'icdSHA256': digest(icd), 'inventory': inventory,
                  'tests': {}, 'nativePropertiesQueriesPassed': False}
        report['drivers'][driver] = result
        if inventory['exitCode'] == 0:
            data = inventory['observations'][-1]
            assert data['translated'] is True and data['pointerBytes'] == 8, 'Expected actual x86_64/Rosetta process'
            modes = ['base', 'core', 'full']+[case['name'] for case in data['cases'] if case['supported']]
            if args.case != 'all':
                modes = [args.case]
            for mode in modes:
                trial = execute([BINARY, loader, mode], env, args.timeout)
                raw = ROOT/f'Evidence/runtime-vulkan-properties-{driver}-{mode}.log'
                raw.write_text(trial['stdout']+'\n'+trial['stderr'])
                trial['rawLog'] = str(raw)
                result['tests'][mode] = trial
                print(driver, mode, trial['exitCode'], flush=True)
                # On an actual signal, collect a real native debugger backtrace.
                # At most three failures are repeated under LLDB, limiting output.
                if trial['exitCode'] < 0 and not trial['timeout'] and debug_count < 3:
                    debug_count += 1
                    debugger = execute(['/usr/bin/xcrun', 'lldb', '--no-lldbinit', '--batch',
                                        '-o', 'run', '-o', 'thread backtrace -c 12 all',
                                        '-o', 'image lookup -a $pc', '-o', 'quit', '--',
                                        BINARY, loader, mode], env, max(30, args.timeout))
                    debug_log = ROOT/f'Evidence/runtime-vulkan-properties-{driver}-{mode}-lldb.log'
                    debug_log.write_text(debugger['stdout']+'\n'+debugger['stderr'])
                    trial['debuggerLog'] = str(debug_log)
                    trial['debuggerExitCode'] = debugger['exitCode']
                evidence.write_text(json.dumps(report, indent=2)+'\n')
            result['nativePropertiesQueriesPassed'] = all(
                trial['exitCode'] == 0 and any(value.get('returned') and value.get('guardAndHeadersIntact')
                                              for value in trial['observations'])
                for trial in result['tests'].values())
        evidence.write_text(json.dumps(report, indent=2)+'\n')
    report['allNativeQueriesPassed'] = all(value['nativePropertiesQueriesPassed'] for value in report['drivers'].values())
    report['interpretation'] = ('These native property chains returned intact. This narrows the observed Wine failure to the Wine/Windows chain or Unix interop path; it does not prove which Wine component is wrong.'
                                if report['allNativeQueriesPassed'] else
                                'A native query did not pass. Inspect its case, guards, and real native backtrace before attributing the Wine failure.')
    evidence.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'allNativeQueriesPassed': report['allNativeQueriesPassed'],
                      'drivers': {name: {'queries': len(value['tests']), 'passed': value['nativePropertiesQueriesPassed']} for name, value in report['drivers'].items()},
                      'evidence': str(evidence)}, indent=2))


if __name__ == '__main__':
    main()
