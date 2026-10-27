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

LOCK_ROOT = pathlib.Path.home()/'Library/Application Support/M1Launcher/InstallLocks'


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


@contextlib.contextmanager
def file_lock(filename, mode, busy_code='installation_busy', busy_message='Another download or update is using this installation directory'):
    fd = None
    try:
        try:
            fd = os.open(filename, os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW, 0o600)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError()
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, mode|fcntl.LOCK_NB)
        except BlockingIOError:
            raise BridgeError(busy_code, busy_message) from None
        except (OSError, ValueError):
            raise BridgeError('unsafe_state_path', 'Cannot safely lock the installation directory') from None
        yield fd
    finally:
        if fd is not None:
            os.close(fd)


@contextlib.contextmanager
def installation_lease(path):
    """Reject overlapping installs; distinct sibling games can run concurrently.

    A target has exclusive locks; ancestors have shared locks. This also protects
    nested installation targets. Persistent zero-byte files are not busy markers:
    flock ownership disappears when all holders die. Never unlink lock files.
    The downloader inherits fds, keeping its lease if the bridge itself crashes.
    """
    root = private_directory(LOCK_ROOT)
    initial = identity(path)
    modes = {}
    for parent in path.parents:
        for key in _keys(parent):
            modes[key] = fcntl.LOCK_SH
    for key in _keys(path):
        modes[key] = fcntl.LOCK_EX
    with contextlib.ExitStack() as stack:
        descriptors = []
        for key in sorted(modes):
            filename = root/(hashlib.sha256(os.fsencode(key)).hexdigest()+'.lock')
            descriptors.append(stack.enter_context(file_lock(filename, modes[key])))
        verify_installation(path, initial)
        yield InstallationLease(initial, tuple(descriptors))


def verify_installation(path, expected):
    try:
        if path.resolve(strict=True) != path or identity(path) != expected or not path.is_dir():
            raise ValueError()
    except (OSError, RuntimeError, ValueError):
        raise BridgeError('installation_changed', 'Installation directory changed while the download was running') from None
