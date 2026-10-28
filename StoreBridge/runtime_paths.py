# SPDX-License-Identifier: GPL-3.0-only
"""Read-only locators: bundled source code is separate from external store tools."""
import os
import pathlib

CODE_ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLED = (CODE_ROOT / 'frontend-package.json').is_file()


def runtime_root():
    value = os.environ.get('READY_RUNTIME_ROOT')
    if value:
        path = pathlib.Path(value)
        if not path.is_absolute():
            raise ValueError('READY_RUNTIME_ROOT must be absolute')
        return path
    if BUNDLED:
        data = pathlib.Path(os.environ.get('READY_DATA_ROOT', str(pathlib.Path.home() / 'Library/Application Support/M1Launcher')))
        return data / 'Runtimes'
    return CODE_ROOT / 'Runtime'


def tools_root():
    return runtime_root() / 'Tools/StoreBridge'


def tool_payload(relative, development_relative):
    """Canonical installed tool path, with the historical source-build fallback."""
    target = tools_root() / relative
    if target.exists() or BUNDLED or runtime_root() != CODE_ROOT / 'Runtime':
        return target
    return CODE_ROOT / development_relative
