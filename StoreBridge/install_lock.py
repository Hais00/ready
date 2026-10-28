# SPDX-License-Identifier: GPL-3.0-only
"""Process-wide installation leases, independent of account and Wine session locks."""
import contextlib
import dataclasses
import fcntl
import hashlib
import os
import pathlib
import stat
from bridge import BridgeError

from state_paths import state_root
LOCK_ROOT = state_root()/'InstallLocks'


def private_directory(path):
    """Do not follow a profile/cache/lock-directory symlink into another account."""
    try:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError()
        path.chmod(0o700)
        return path
    except (OSError, ValueError):
        raise BridgeError('unsafe_state_path', 'Store state directory must be a private owned directory') from None


def canonical_installation(value):
    try:
        if not isinstance(value, str) or not value or '\0' in value:
            raise ValueError()
        path = pathlib.Path(value).expanduser()
        if not path.is_absolute():
            raise ValueError()
        path = path.resolve()
        if path == pathlib.Path(path.anchor):
            raise ValueError()
        path.mkdir(parents=True, exist_ok=True)
        path = path.resolve(strict=True)
        if not path.is_dir():
            raise ValueError()
        return path
    except (OSError, RuntimeError, ValueError):
        raise BridgeError('invalid_path', 'Choose an absolute game installation directory') from None


def identity(path):
    info = path.stat()
    return info.st_dev, info.st_ino


def _keys(path):
    # The pathname remains stable if a child engine replaces the directory.
    # The inode also catches case/Unicode aliases on insensitive filesystems.
    device, inode = identity(path)
    return ('path:' + str(path), f'inode:{device}:{inode}')


@dataclasses.dataclass(frozen=True)
class InstallationLease:
    identity: tuple
    fds: tuple
    mode: str


@contextlib.contextmanager
def file_lock(filename, mode, busy_code='installation_busy', busy_message='An active game or download is using this installation directory', nonblocking=True):
    fd = None
    try:
        try:
            fd = os.open(filename, os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW, 0o600)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError()
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, mode|(fcntl.LOCK_NB if nonblocking else 0))
        except BlockingIOError:
            raise BridgeError(busy_code, busy_message) from None
        except (OSError, ValueError):
            raise BridgeError('unsafe_state_path', 'Cannot safely lock the installation directory') from None
        yield fd
    finally:
        if fd is not None:
            os.close(fd)


def _lock_path(root, key):
    return root/(hashlib.sha256(os.fsencode(key)).hexdigest()+'.lock')


@contextlib.contextmanager
def installation_lease(path, mode='write'):
    """Protocol v2: symmetric overlapping reader/writer leases.

    L is the original hierarchy, I records writer intent, R records reader roots.
    A short admission gate protects probes and lifetime-lock acquisition. Only
    lifetime fds are inherited; neither the gate nor probes survive admission.
    Persistent zero-byte files are never removed to resolve a stale lock.
    All active participants must use v2; stop v1 downloads during an upgrade.
    """
    if mode not in ('read', 'write'):
        raise ValueError('Installation lease mode must be read or write')
    root = private_directory(LOCK_ROOT)
    initial = identity(path)
    target = set(_keys(path))
    ancestors = {key for parent in path.parents for key in _keys(parent)}
    all_keys = target|ancestors
    legacy = {key: fcntl.LOCK_SH for key in all_keys}
    if mode == 'write':
        legacy.update({key: fcntl.LOCK_EX for key in target})
    with contextlib.ExitStack() as lifetime:
        descriptors = []
        # Blocking only on this brief admission mutex; game/download leases use NB.
        with file_lock(root/'admission.lock', fcntl.LOCK_EX, nonblocking=False):
            if mode == 'write':
                with contextlib.ExitStack() as probes:
                    for key in sorted(all_keys):
                        probes.enter_context(file_lock(_lock_path(root, 'reader:'+key), fcntl.LOCK_EX))
            for key in sorted(legacy):
                descriptors.append(lifetime.enter_context(file_lock(_lock_path(root,key),legacy[key])))
            if mode == 'read':
                with contextlib.ExitStack() as probes:
                    for key in sorted(target):
                        probes.enter_context(file_lock(_lock_path(root,'intent:'+key),fcntl.LOCK_EX))
            prefix, keys = ('intent:', all_keys) if mode == 'write' else ('reader:', target)
            for key in sorted(keys):
                descriptors.append(lifetime.enter_context(file_lock(_lock_path(root,prefix+key),fcntl.LOCK_SH)))
            verify_installation(path, initial)
        yield InstallationLease(initial, tuple(descriptors), mode)


def verify_installation(path, expected):
    try:
        if path.resolve(strict=True) != path or identity(path) != expected or not path.is_dir():
            raise ValueError()
    except (OSError, RuntimeError, ValueError):
        raise BridgeError('installation_changed', 'Installation directory changed while the download was running') from None
