# SPDX-License-Identifier: GPL-3.0-only
"""Build the explicit static product before compiling any standalone Swift probe.

Building only an executable can refresh LauncherCore.swiftmodule without replacing
an old libLauncherCore.a. Linking that pair corrupts value-type layouts. Never
prefer a leftover archive merely because its pathname exists.
"""
import pathlib
import subprocess

ROOT=pathlib.Path(__file__).resolve().parents[1]

def prepare_core():
    result=subprocess.run(['swift','build','--product','LauncherCore','--jobs','2'],cwd=ROOT,capture_output=True,text=True)
    if result.returncode:
        raise RuntimeError('Failed to build the explicit LauncherCore static product:\n'+result.stderr[-4000:])
    products=pathlib.Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=ROOT,text=True).strip())
    modules=products if (products/'LauncherCore.swiftmodule').exists() else products/'Modules'
    archive=products/'libLauncherCore.a'
    if not archive.is_file():raise RuntimeError('The explicit static LauncherCore product was not emitted')
    module=modules/'LauncherCore.swiftmodule'
    # Only imported compiler modules carry the value-type layout. Xcode can
    # rewrite ABI reports/source-info metadata independently after archiving.
    importable=list(module.glob('*.swiftmodule')) if module.is_dir() else [module]
    if not importable:raise RuntimeError('No importable LauncherCore Swift module was emitted')
    newest=max(p.stat().st_mtime_ns for p in importable)
    if archive.stat().st_mtime_ns<newest:
        raise RuntimeError('Refusing a static archive older than its Swift module')
    return products,modules,archive
