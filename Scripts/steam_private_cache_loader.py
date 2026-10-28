#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read only the explicitly authorized private cache; never decrypt or log it.

The frame token is a MODE SENTINEL, NOT a recovered credential. It is usable only
with Root's --cached-login branch, which must never pass it to any token setter.
Actual native authentication must use genuine Valve cached-login APIs and still
verify logged-on identity and entitlement. This module executes no client/helper.
"""
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import stat

if __package__:
    from .steam_host_credential import pack_credentials
    from .steam_headless_auth_broker import PrivateCredentialFrame
else:
    from steam_host_credential import pack_credentials
    from steam_headless_auth_broker import PrivateCredentialFrame

WORK = Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
RUN = WORK / 'retained/research-steam-native/offline-arm64-f51402a25c384c81b4fd25a76b225f14'
REPORT_SHA = '7485520f23274e48335ca546d9225c3870c3b9a2a741484580cabe13969e11eb'
SUCCESS_RUN = WORK / 'retained/research-steam-native/offline-arm64-5a9e0bc01798438d841eb3f590e4c0af'
SUCCESS_REPORT_SHA = 'cc6ff36384d9d6118ceb2db303d9e1f93e461b8aeac3c3e26117fdff20723fd3'
APPROVED_REFERENCES = {
    RUN / 'report.json': (REPORT_SHA, False),
    SUCCESS_RUN / 'report.json': (SUCCESS_REPORT_SHA, True),
}
IMAGE_SHA = 'b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd'
SENTINEL = 'READY_USE_GENUINE_CACHED_LOGIN'
CACHE_FILES = {'config.vdf', 'local.vdf', 'localconfig.vdf', 'loginusers.vdf', 'roamingconfig.vdf'}


class PrivateCacheError(Exception):
    """Fixed local messages only; never account/cache content or identifiers."""


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    st = os.fstat(fd)
    if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o022:
        os.close(fd)
        raise PrivateCacheError('unsafe_directory')
    return fd


def _read(root, parts, limit):
    fd = _directory(root)
    try:
        for part in parts[:-1]:
            if part in ('', '.', '..') or '/' in part:
                raise PrivateCacheError('unsafe_path')
            new = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = new
            st = os.fstat(fd)
            if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o022:
                raise PrivateCacheError('unsafe_directory')
        if not parts or parts[-1] in ('', '.', '..') or '/' in parts[-1]:
            raise PrivateCacheError('unsafe_path')
        file = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            before = os.fstat(file)
            if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                    or stat.S_IMODE(before.st_mode) & 0o022 or before.st_size > limit):
                raise PrivateCacheError('unsafe_file')
            data = bytearray()
            while len(data) <= limit:
                chunk = os.read(file, min(65536, limit + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            after = os.fstat(file)
            if len(data) > limit or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise PrivateCacheError('unstable_file')
            return bytes(data)
        finally:
            os.close(file)
    finally:
        os.close(fd)


def _kv(data):
    text = data.decode('utf-8-sig')
    tokens = re.findall(r'"((?:[^"\\]|\\.)*)"|([{}])', text)
    if len(tokens) > 100000:
        raise PrivateCacheError('cache_limit')
    tokens = [a if a or not b else b for a, b in tokens]
    index = 0
    def block(depth=0, nested=False):
        nonlocal index
        if depth > 32:
            raise PrivateCacheError('cache_limit')
        output = {}
        while index < len(tokens):
            key = tokens[index]; index += 1
            if key == '}':
                if not nested:
                    raise PrivateCacheError('invalid_cache')
                return output
            if key == '{' or index >= len(tokens) or key in output:
                raise PrivateCacheError('invalid_cache')
            value = tokens[index]; index += 1
            if value == '}':
                raise PrivateCacheError('invalid_cache')
            output[key] = block(depth + 1, True) if value == '{' else value
        if nested:
            raise PrivateCacheError('invalid_cache')
        return output
    return block()


def _entries(node):
    found = []
    for key, value in node.items():
        if key.casefold() == 'connectcache':
            if not isinstance(value, dict):
                raise PrivateCacheError('invalid_cache')
            found.extend(value.items())
        elif isinstance(value, dict):
            found.extend(_entries(value))
    return found


@dataclass(frozen=True)
class CachedLoginInput:
    safe: dict
    handoff: PrivateCredentialFrame = field(repr=False)

    def close(self):
        self.handoff.clear()


def _load(run, work, report_sha, image_sha, *, cancel=None, require_native_success=False):
    """Internal fixture seam. Public entry point fixes every production binding."""
    run = Path(run); work = Path(work)
    if (not run.is_absolute() or run.is_symlink() or run.resolve() != run
            or not run.is_relative_to(work) or work.resolve() != work):
        raise PrivateCacheError('unsafe_root')
    # Verify every ancestor beneath the marked private work root without aliases.
    for directory in [work, *list(run.parents)[:len(run.relative_to(work).parts) - 1], run]:
        fd = _directory(directory); os.close(fd)
    if stat.S_IMODE(run.stat().st_mode) != 0o700 or stat.S_IMODE(work.stat().st_mode) != 0o700:
        raise PrivateCacheError('unsafe_root')
    marker = _read(work, ('.ready-external-workspace',), 256)
    if marker != b'ready project work for thread01a17e79\n':
        raise PrivateCacheError('unsafe_root')
    raw_report = _read(run, ('report.json',), 4 * 1024 * 1024)
    if _sha(raw_report) != report_sha:
        raise PrivateCacheError('report_mismatch')
    report = json.loads(raw_report)
    auth = report.get('steamKitAuthorization')
    namespace = report.get('ipcAdapter', {}).get('namespace')
    if (not isinstance(auth, dict) or auth.get('authorized') is not True
            or auth.get('ownershipTicketReceived') is not True
            or report.get('librarySHA256') != image_sha or report.get('libraryUnchanged') is not True
            or not isinstance(namespace, str) or re.fullmatch('[0-9a-f]{32}', namespace) is None):
        raise PrivateCacheError('unbound_authorization')
    observations = report.get('observations', [])
    reference_native_success = (report.get('accountAuthenticated') is True
        and report.get('existingSteamProcessesUnchanged') is True
        and isinstance(observations, list)
        and any(isinstance(v, dict) and v.get('authenticatedIdentityMatches') is True
                and v.get('genuineSubscriptionObserved') is True for v in observations)
        and any(isinstance(v, dict) and v.get('authenticated') is True
                and v.get('genuineSubscriptionObserved') is True for v in observations))
    if require_native_success and not reference_native_success:
        raise PrivateCacheError('unverified_native_reference')
    client = run / 'state/client'
    fd = _directory(run / 'state'); os.close(fd)
    fd = _directory(client); os.close(fd)
    candidates = []
    for folder, dirs, files in os.walk(client, followlinks=False):
        if len(Path(folder).relative_to(client).parts) > 16:
            raise PrivateCacheError('cache_limit')
        if any((Path(folder) / n).is_symlink() for n in dirs):
            raise PrivateCacheError('unsafe_path')
        dirs[:] = [n for n in dirs if n not in {'logs', 'appcache', 'steamapps', 'htmlcache'}]
        for name in files:
            if name not in CACHE_FILES:
                continue
            relative = (Path(folder) / name).relative_to(run)
            data = _read(run, relative.parts, 4 * 1024 * 1024)
            for account, blob in _entries(_kv(data)):
                if (not re.fullmatch('[A-Za-z0-9_]{1,64}', account) or not isinstance(blob, str)
                        or len(blob) < 32 or len(blob) % 2 or re.fullmatch('[0-9A-Fa-f]+', blob) is None):
                    raise PrivateCacheError('invalid_cache_entry')
                candidates.append((account, _sha(data)))
    if len(candidates) != 1:
        raise PrivateCacheError('ambiguous_or_missing_cache')
    account, config_sha = candidates[0]
    # Shared encoder validates authoritative identifiers. No JWT parsing, no cache
    # decryption and no claim that the sentinel is a SteamKit refresh token.
    try:
        packed = pack_credentials({'username': account, 'refresh_token': SENTINEL,
            'steamID': auth.get('steamID'), 'appID': auth.get('appID')})
    except (ValueError, TypeError, OverflowError):
        raise PrivateCacheError('invalid_authoritative_identity') from None
    frame = PrivateCredentialFrame(packed, cancel)
    del packed
    return CachedLoginInput({'cacheRoot': str(run / 'state'), 'reportSHA256': report_sha,
        'configSourceSHA256': config_sha, 'valveImageSHA256': image_sha,
        'namespaceSHA256': _sha(namespace.encode()), 'singleCacheEntry': True,
        'retainedSteamKitPreflightAuthorized': True, 'freshSteamKitPreflightPerformed': False,
        'referenceNativeAuthenticationVerified': reference_native_success,
        'cachedNativeAuthenticationVerified': False, 'requiresCachedLoginMode': True,
        'sentinelIsCredential': False}, frame)


def load_private_cached_login(*, cancel=None, reference_report=None):
    try:
        if cancel is not None and cancel.is_set():
            raise PrivateCacheError('cancelled')
        reference = RUN / 'report.json' if reference_report is None else Path(reference_report)
        if reference not in APPROVED_REFERENCES:
            raise PrivateCacheError('unapproved_reference')
        report_sha, require_native_success = APPROVED_REFERENCES[reference]
        context = _load(reference.parent, WORK, report_sha, IMAGE_SHA, cancel=cancel,
                        require_native_success=require_native_success)
        if cancel is not None and cancel.is_set():
            context.close()
            raise PrivateCacheError('cancelled')
        return context
    except PrivateCacheError:
        raise
    except (OSError, ValueError, UnicodeError, TypeError, AttributeError):
        raise PrivateCacheError('private_cache_unavailable') from None
