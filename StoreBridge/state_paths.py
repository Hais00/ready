# SPDX-License-Identifier: GPL-3.0-only
"""Owned application data root; independent of source/project/runtime paths."""
import os
import pathlib
import stat
from bridge import BridgeError


def state_root():
    value=os.environ.get('READY_DATA_ROOT')
    path=pathlib.Path(value) if value is not None else pathlib.Path.home()/'Library/Application Support/M1Launcher'
    try:
        if not path.is_absolute() or path==pathlib.Path(path.anchor) or '\0' in str(path):raise ValueError()
        if any(part.is_symlink() for part in (path,*path.parents)):raise ValueError()
        path.mkdir(parents=True,exist_ok=True,mode=0o700)
        info=path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid():raise ValueError()
        path.chmod(0o700)
        if path.resolve(strict=True)!=path:raise ValueError()
        return path
    except (OSError,RuntimeError,ValueError):
        raise BridgeError('invalid_state_root','Application data root must be absolute, owned, private, and contain no symlinks') from None
