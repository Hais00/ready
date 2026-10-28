#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""In-memory SteamKit QR/ownership orchestration; importing never authenticates.

The caller must pin the exact external dotnet/helper and establish readiness and
user intent. This module starts only that explicit command, never a native host.
onQR receives a URL and must return promptly (normally enqueue a UI update).
No inherited environment, Keychain, Steam metadata, token decoding or disk cache.
Mutable handoff/request buffers are cleared; Python immutable JSON/string copies
cannot promise forensic heap erasure. They never enter diagnostics or files here.
"""
from dataclasses import dataclass, field
import fcntl
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import threading
import time
from urllib.parse import urlsplit

if __package__:
    from .steam_host_credential import pack_credentials
else:
    from steam_host_credential import pack_credentials

MAX_FRAME = 64 * 1024
MAX_OUTPUT = 1024 * 1024
MAX_EVENTS = 128
MAX_STDERR = 64 * 1024
HELPER_ERROR_CODES = frozenset({
    "auth_required", "authentication_required", "not_authorized", "steam_error",
    "timeout", "invalid_request", "unsupported_operation", "license_error",
    "invalid_game_id", "disconnected", "steam_login_failed",
})
HELPER_STAGES = frozenset({"request", "connecting", "qr_authentication", "logon",
                           "ownership_ticket", "library", "launch_info", "ownership_response",
                           "ownership_decision", "ownership_clear_ticket", "ownership_logoff",
                           "ownership_cancel", "ownership_disconnect", "ownership_pump", "ownership_complete"})
EXCEPTION_KINDS = frozenset({"AuthenticationException", "OperationCanceledException", "TimeoutException",
    "DllNotFoundException", "EntryPointNotFoundException", "BadImageFormatException", "TypeInitializationException",
    "CryptographicException", "IOException", "ObjectDisposedException", "InvalidOperationException", "ArgumentException",
    "NullReferenceException", "AggregateException", "Exception", "Unknown"})
OWNERSHIP_FACTS = ("ownershipResponseReceived", "ownershipAppMatched", "ownershipTicketNonEmpty",
                   "ownershipSteamIDPresent", "ownershipDecisionAuthorized")
STEAM_RESULTS = frozenset({
    "OK", "Fail", "NoConnection", "InvalidPassword", "LoggedInElsewhere", "InvalidProtocolVer",
    "InvalidParam", "AccessDenied", "Timeout", "AccountNotFound", "InvalidSteamID", "ServiceUnavailable",
    "NotLoggedOn", "Pending", "InsufficientPrivilege", "LimitExceeded", "Revoked", "Expired",
    "DuplicateRequest", "LogonSessionReplaced", "ConnectFailed", "HandshakeFailed", "IOFailure",
    "RemoteDisconnect", "AccountDisabled", "TryAnotherCM", "AlreadyLoggedInElsewhere", "Suspended",
    "Cancelled", "AccountLogonDenied", "InvalidLoginAuthCode", "AccountLogonDeniedNoMail",
    "ExpiredLoginAuthCode", "AccountLockedDown", "AccountLogonDeniedVerifiedEmailRequired",
    "RateLimitExceeded", "AccountLoginDeniedNeedTwoFactor", "AccountLoginDeniedThrottle",
    "TwoFactorCodeMismatch", "Unknown",
})
LOCAL_ERROR_CODES = frozenset({
    "cancelled", "invalid_handoff", "invalid_handoff_target", "handoff_failed",
    "malformed_frame", "invalid_qr", "invalid_helper_command", "request_too_large",
    "stderr_limit", "output_limit", "event_after_terminal", "event_limit",
    "qr_callback_failed", "phase_callback_failed", "unexpected_event", "frame_limit",
    "truncated_frame", "missing_terminal", "helper_error", "helper_exit",
    "helper_io_failed", "invalid_app_id", "invalid_credentials",
    "unexpected_result_fields", "identity_mismatch", "invalid_authorized_identity",
    "session_closed", "session_expired", "session_busy",
})


class BrokerError(Exception):
    """Only a fixed local error code; never helper text or exception payloads."""
    def __init__(self, code, *, phase=None, helper_exit=None, helper_stage=None, steam_result=None,
                 exception_kind=None, ownership_facts=None, cleanup_stage=None, cleanup_kind=None):
        self.code = code if isinstance(code, str) and code in HELPER_ERROR_CODES | LOCAL_ERROR_CODES else "helper_error"
        self.phase = phase if phase in ("auth_begin", "authorize_game", "handoff") else None
        self.helper_exit = helper_exit if type(helper_exit) is int else None
        self.helper_stage = helper_stage if isinstance(helper_stage, str) and helper_stage in HELPER_STAGES else None
        self.steam_result = (steam_result if isinstance(steam_result, str) and steam_result in STEAM_RESULTS
                             else "Unknown" if steam_result is not None else None)
        self.exception_kind = (exception_kind if isinstance(exception_kind, str) and exception_kind in EXCEPTION_KINDS
                               else "Unknown" if exception_kind is not None else None)
        facts = ownership_facts if isinstance(ownership_facts, dict) else {}
        self.ownership_facts = {k: facts[k] for k in OWNERSHIP_FACTS if type(facts.get(k)) is bool}
        self.cleanup_stage = cleanup_stage if isinstance(cleanup_stage, str) and cleanup_stage in HELPER_STAGES else None
        self.cleanup_kind = (cleanup_kind if isinstance(cleanup_kind, str) and cleanup_kind in EXCEPTION_KINDS
                             else "Unknown" if cleanup_kind is not None else None)
        super().__init__(self.code)

    def diagnostic(self):
        safe = {"phase": self.phase, "code": self.code,
                "helperExit": self.helper_exit, "helperStage": self.helper_stage,
                "steamResult": self.steam_result, "secretFree": True}
        safe.update(self.ownership_facts)
        for key, value in (("exceptionKind", self.exception_kind), ("cleanupFailureStage", self.cleanup_stage),
                           ("cleanupExceptionKind", self.cleanup_kind)):
            if value is not None:
                safe[key] = value
        return safe


def _cancelled(cancel):
    return cancel is not None and cancel.is_set()


def _check(deadline, cancel):
    if _cancelled(cancel):
        raise BrokerError("cancelled")
    if time.monotonic() >= deadline:
        raise BrokerError("timeout")


def _wipe(value):
    value[:] = b"\0" * len(value)
    value.clear()


def _discard(value):
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            stack.extend(item.values())
            item.clear()
        elif isinstance(item, list):
            stack.extend(item)
            item.clear()


def _phase(callback, value):
    if callback is None:
        return
    failed = False
    try:
        callback(value)
    except Exception:
        failed = True
    if failed:
        raise BrokerError("phase_callback_failed")


@dataclass(frozen=True)
class SafeAuthorization:
    appID: int
    steamID: int
    authorized: bool = True
    ownershipTicketReceived: bool = True


class PrivateCredentialFrame:
    """Opaque, single-use anonymous-pipe handoff. Never serialize for diagnostics."""
    def __init__(self, frame, cancel=None):
        self._buffer = bytearray(frame)
        self._cancel = cancel

    def __repr__(self):
        return "<PrivateCredentialFrame private>" if self._buffer else "<PrivateCredentialFrame cleared>"

    __str__ = __repr__

    @property
    def cleared(self):
        return not self._buffer

    def clear(self):
        _wipe(self._buffer)

    def write_to(self, writer, *, timeout=3.0, cancel=None):
        """Consume the frame; own/close a validated pipe writer to supply EOF.

        The caller owns worker identity and must provide its new anonymous stdin
        pipe. FIFO type alone cannot authenticate the recipient or prove anonymity.
        Regular files/sockets are rejected without writing. No process is started.
        Bytes already written cannot be retracted: the caller must supervise and
        stop its owned worker on cancellation/error, including during handoff.
        """
        fd = None
        accepted = False
        original_flags = None
        try:
            fd = writer if isinstance(writer, int) and not isinstance(writer, bool) else writer.fileno()
            if not self._buffer or not 0 < timeout <= 30:
                raise BrokerError("invalid_handoff")
            info = os.fstat(fd)
            original_flags = fcntl.fcntl(fd, fcntl.F_GETFL)
            if not stat.S_ISFIFO(info.st_mode) or (original_flags & os.O_ACCMODE) == os.O_RDONLY:
                raise BrokerError("invalid_handoff_target")
            accepted = True
            fcntl.fcntl(fd, fcntl.F_SETFL, original_flags | os.O_NONBLOCK)
            deadline = time.monotonic() + timeout
            with selectors.DefaultSelector() as selector:
                selector.register(fd, selectors.EVENT_WRITE)
                offset = 0
                while offset < len(self._buffer):
                    _check(deadline, self._cancel)
                    _check(deadline, cancel)
                    if not selector.select(min(.05, max(0, deadline - time.monotonic()))):
                        continue
                    try:
                        offset += os.write(fd, memoryview(self._buffer)[offset:])
                    except (BlockingIOError, InterruptedError):
                        continue
            _check(deadline, self._cancel)
            _check(deadline, cancel)
        except BrokerError:
            raise
        except (OSError, ValueError, TypeError, AttributeError):
            raise BrokerError("handoff_failed") from None
        finally:
            self.clear()
            if accepted:
                try:
                    fcntl.fcntl(fd, fcntl.F_SETFL, original_flags)
                except OSError:
                    pass
                try:
                    os.close(fd) if isinstance(writer, int) else writer.close()
                except OSError:
                    pass

    def __del__(self):
        self.clear()


@dataclass(frozen=True)
class AuthorizedContext:
    safe: SafeAuthorization
    handoff: PrivateCredentialFrame = field(repr=False)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate")
        result[key] = value
    return result


def _parse(line):
    bad = False
    try:
        event = json.loads(line.decode("utf-8"), object_pairs_hook=_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        bad = not isinstance(event, dict) or not isinstance(event.get("type"), str)
    except (ValueError, UnicodeError, RecursionError):
        bad = True
    if bad:
        raise BrokerError("malformed_frame")
    return event


def _qr_url(event):
    url = event.get("url")
    if not isinstance(url, str) or not 1 <= len(url) <= 4096 or any(ord(c) < 33 for c in url):
        raise BrokerError("invalid_qr")
    bad = False
    try:
        parsed = urlsplit(url)
        bad = (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
               or parsed.password is not None or parsed.port not in (None, 443))
    except ValueError:
        bad = True
    if bad:
        raise BrokerError("invalid_qr")
    # No invented host allowlist: the exact pinned SteamKit helper is the source
    # of this challenge. The URL is displayed, never opened/fetched by the broker.
    return url


def _command(command):
    if (not isinstance(command, (list, tuple)) or len(command) != 2
            or any(not isinstance(x, str) or "\0" in x or not Path(x).is_absolute() for x in command)):
        raise BrokerError("invalid_helper_command")
    if not all(Path(x).is_file() for x in command) or not os.access(command[0], os.X_OK):
        raise BrokerError("invalid_helper_command")
    return list(command)


def _stop(process):
    # Signal only this owned Popen child; never a stale PGID/global Steam server.
    if process.poll() is None:
        try:
            process.terminate()
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=.5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def _request(command, request, deadline, cancel, onQR=None):
    _check(deadline, cancel)
    payload = bytearray(json.dumps(request, separators=(",", ":"), ensure_ascii=True).encode() + b"\n")
    if len(payload) > MAX_FRAME:
        _wipe(payload)
        raise BrokerError("request_too_large")
    # Prevent inherited loader hooks, tokens, Steam namespace or account settings.
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
           "DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE": "1",
           "DOTNET_NOLOGO": "1", "DOTNET_MULTILEVEL_LOOKUP": "0"}
    process = None
    pending = bytearray()
    terminal = None
    event = None
    success = False
    failure = None
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, close_fds=True)
        with selectors.DefaultSelector() as selector:
            for stream in (process.stdin, process.stdout, process.stderr):
                os.set_blocking(stream.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE, "input")
            selector.register(process.stdout, selectors.EVENT_READ, "output")
            selector.register(process.stderr, selectors.EVENT_READ, "error")
            offset = output_count = stderr_count = event_count = 0
            while selector.get_map() or process.poll() is None:
                _check(deadline, cancel)
                for key, _ in selector.select(min(.05, max(0, deadline - time.monotonic()))):
                    _check(deadline, cancel)
                    stream, channel = key.fileobj, key.data
                    try:
                        if channel == "input":
                            offset += os.write(stream.fileno(), memoryview(payload)[offset:])
                            if offset == len(payload):
                                selector.unregister(stream)
                                stream.close()
                                _wipe(payload)
                            continue
                        chunk = os.read(stream.fileno(), 8192)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not chunk:
                        selector.unregister(stream)
                        stream.close()
                        continue
                    if channel == "error":
                        stderr_count += len(chunk)  # Deliberately discard all text.
                        if stderr_count > MAX_STDERR:
                            raise BrokerError("stderr_limit")
                        continue
                    output_count += len(chunk)
                    if output_count > MAX_OUTPUT:
                        raise BrokerError("output_limit")
                    pending.extend(chunk)
                    while b"\n" in pending:
                        end = pending.index(10)
                        if end > MAX_FRAME:
                            raise BrokerError("frame_limit")
                        line = bytes(pending[:end])
                        del pending[:end + 1]
                        if terminal is not None:
                            raise BrokerError("event_after_terminal")
                        event_count += 1
                        if event_count > MAX_EVENTS:
                            raise BrokerError("event_limit")
                        event = _parse(line)
                        kind = event["type"]
                        if kind in ("result", "error"):
                            terminal = event
                        elif kind == "qr" and onQR is not None:
                            url = _qr_url(event)
                            callback_failed = False
                            try:
                                onQR(url)
                            except Exception:
                                callback_failed = True
                            if callback_failed:
                                raise BrokerError("qr_callback_failed")
                            _check(deadline, cancel)
                        elif kind != "progress":
                            raise BrokerError("unexpected_event")
                    if len(pending) > MAX_FRAME:
                        raise BrokerError("frame_limit")
            _check(deadline, cancel)
            if pending:
                raise BrokerError("truncated_frame")
            if terminal is None:
                raise BrokerError("missing_terminal")
            if terminal["type"] == "error":
                code = terminal.get("code")
                safe_code = code if isinstance(code, str) and code in HELPER_ERROR_CODES else "helper_error"
                raise BrokerError(safe_code, helper_stage=terminal.get("stage"),
                                  steam_result=terminal.get("steamResult"), exception_kind=terminal.get("exceptionKind"),
                                  ownership_facts=terminal, cleanup_stage=terminal.get("cleanupFailureStage"),
                                  cleanup_kind=terminal.get("cleanupExceptionKind"))
            if process.returncode != 0:
                raise BrokerError("helper_exit")
            success = True
            return terminal
    except BrokerError as error:
        failure = error
        error.phase = request["operation"]
        raise
    except (OSError, ValueError, TypeError):
        failure = BrokerError("helper_io_failed", phase=request["operation"])
        raise failure from None
    finally:
        _wipe(payload)
        _wipe(pending)
        if not success:
            _discard(terminal)
            _discard(event)
        if process is not None:
            _stop(process)
            if failure is not None:
                failure.helper_exit = process.returncode
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


def _appid(value):
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise BrokerError("invalid_app_id")
    if isinstance(value, str) and (not 1 <= len(value) <= 10 or not value.isascii() or not value.isdecimal()):
        raise BrokerError("invalid_app_id")
    value = int(value)
    if not 0 < value < (1 << 32):
        raise BrokerError("invalid_app_id")
    return value


def _timeout(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 < value <= 600:
        raise BrokerError("invalid_request")
    return value


def _authorized_context(credentials, result, app, expected_id, cancel, deadline, onPhase):
    frame = None
    source = {}
    try:
        if not set(result) <= {"type", "steamID", "appID", "authorized", "ownershipTicketReceived", "ticketSHA256"}:
            raise BrokerError("unexpected_result_fields")
        if result.get("authorized") is not True or result.get("ownershipTicketReceived") is not True:
            raise BrokerError("not_authorized")
        if _appid(result.get("appID")) != app:
            raise BrokerError("identity_mismatch")
        source = {**credentials, "steamID": result.get("steamID"), "appID": app}
        bad = False
        try:
            packed = pack_credentials(source)
        except (ValueError, TypeError, OverflowError):
            bad = True
        source.clear()
        if bad:
            raise BrokerError("invalid_authorized_identity")
        frame = PrivateCredentialFrame(packed, cancel)
        del packed
        steam_id = int(result["steamID"])
        if expected_id is not None and (isinstance(expected_id, bool) or not isinstance(expected_id, (str, int))
                                        or str(expected_id) != str(steam_id)):
            raise BrokerError("identity_mismatch")
        _check(deadline, cancel)
        _phase(onPhase, "authorized")
        _check(deadline, cancel)
        context = AuthorizedContext(SafeAuthorization(app, steam_id), frame)
        frame = None
        return context
    finally:
        source.clear()
        if frame is not None:
            frame.clear()


class _SessionCancellation:
    def __init__(self, stopped, external):
        self.stopped, self.external = stopped, external

    def is_set(self):
        return self.stopped.is_set() or _cancelled(self.external)


class AuthenticatedSession:
    """Private credentials in this process only; no persistence or auto-retry.

    beginQR performs one explicit authentication. authorize_game requires an
    explicit command on EVERY attempt, so Root can pin a corrected helper first.
    close, cancellation or the <=10-minute deadline drops credential references.
    Already returned handoff frames are separately caller-owned; close those too
    when abandoning a handoff. Python immutable heap copies cannot be scrubbed.
    """
    def __init__(self, credentials, cancel, ttl):
        self._credentials = dict(credentials)
        self._external_cancel = cancel
        self._expires = time.monotonic() + ttl
        self._stop = threading.Event()
        self._cancel = _SessionCancellation(self._stop, cancel)
        self._lock = threading.RLock()
        self._operation = threading.Lock()
        self._reason = "session_closed"
        threading.Thread(target=self._watch, name="ready-auth-session-expiry", daemon=True).start()

    def __repr__(self):
        return "<AuthenticatedSession private closed>" if self.closed else "<AuthenticatedSession private open>"

    __str__ = __repr__

    def _finish(self, reason):
        with self._lock:
            if not self._stop.is_set():
                self._reason = reason
            self._credentials.clear()
            self._stop.set()

    def _watch(self):
        while not self._stop.wait(.05):
            if _cancelled(self._external_cancel):
                self._finish("cancelled")
            elif time.monotonic() >= self._expires:
                self._finish("session_expired")

    def _check_open(self):
        with self._lock:
            if _cancelled(self._external_cancel):
                self._finish("cancelled")
            elif time.monotonic() >= self._expires:
                self._finish("session_expired")
            if self._stop.is_set():
                raise BrokerError(self._reason)

    @property
    def closed(self):
        try:
            self._check_open()
        except BrokerError:
            return True
        return False

    def close(self):
        self._finish("session_closed")

    def __enter__(self):
        self._check_open()
        return self

    def __exit__(self, *_):
        self.close()

    @classmethod
    def beginQR(cls, bridgeCommand, onQR, *, cancel=None, timeout=240.0, ttl=600.0, onPhase=None):
        command = _command(bridgeCommand)
        deadline = time.monotonic() + _timeout(timeout)
        _timeout(ttl)
        if not callable(onQR) or (onPhase is not None and not callable(onPhase)):
            raise BrokerError("invalid_request")
        auth = source = session = None
        credentials = {}
        helper_exit = None
        try:
            _check(deadline, cancel)
            _phase(onPhase, "authenticating")
            auth = _request(command, {"operation": "auth_begin", "options": {}}, deadline, cancel, onQR)
            helper_exit = 0
            source = auth.get("credentials")
            if not isinstance(source, dict) or any(not isinstance(source.get(k), str) or not source[k]
                                                   for k in ("username", "refresh_token")):
                raise BrokerError("invalid_credentials")
            if set(auth) != {"type", "credentials"} or not set(source) <= {"username", "refresh_token", "access_token"}:
                raise BrokerError("unexpected_result_fields")
            credentials = {k: source[k] for k in ("username", "refresh_token")}
            source.clear()
            auth.clear()
            session = cls(credentials, cancel, ttl)
            _phase(onPhase, "authentication_complete")
            _check(deadline, cancel)
            session._check_open()
            return session
        except BrokerError as error:
            if session is not None:
                session.close()
            if error.phase is None:
                error.phase = "auth_begin"
            if error.helper_exit is None:
                error.helper_exit = helper_exit
            raise
        finally:
            credentials.clear()
            _discard(auth)
            _discard(source)

    def authorize_game(self, bridgeCommand, appID, *, timeout=240.0, expectedSteamID=None, onPhase=None):
        if not self._operation.acquire(blocking=False):
            raise BrokerError("session_busy", phase="authorize_game")
        credentials = {}
        result = context = None
        helper_exit = None
        try:
            self._check_open()
            command = _command(bridgeCommand)
            app = _appid(appID)
            deadline = min(self._expires, time.monotonic() + _timeout(timeout))
            if onPhase is not None and not callable(onPhase):
                raise BrokerError("invalid_request")
            with self._lock:
                self._check_open()
                credentials = dict(self._credentials)
            _phase(onPhase, "authorizing_game")
            result = _request(command, {"operation": "authorize_game", "credentials": credentials,
                                       "options": {"gameID": str(app)}}, deadline, self._cancel)
            helper_exit = 0
            context = _authorized_context(credentials, result, app, expectedSteamID,
                                          self._external_cancel, deadline, onPhase)
            self._check_open()
            return context
        except BrokerError as error:
            if context is not None:
                context.handoff.clear()
            if error.phase is None:
                error.phase = "authorize_game"
            if error.helper_exit is None:
                error.helper_exit = helper_exit
            raise
        finally:
            credentials.clear()
            _discard(result)
            self._operation.release()


def beginQR(bridgeCommand, onQR, **options):
    return AuthenticatedSession.beginQR(bridgeCommand, onQR, **options)


def authenticate_and_authorize(bridgeCommand, appID, onQR, *, cancel=None,
                               timeout=240.0, expectedSteamID=None, onPhase=None):
    """Compatible one-shot wrapper; a single total deadline and no retained session.

    For explicit in-memory retry after a helper defect, use beginQR then the
    returned session.authorize_game with the caller's newly pinned exact command.
    No native worker is started by either path.
    """
    command = _command(bridgeCommand)
    app = _appid(appID)
    deadline = time.monotonic() + _timeout(timeout)
    session = beginQR(command, onQR, cancel=cancel, timeout=timeout, onPhase=onPhase)
    try:
        _check(deadline, cancel)
        return session.authorize_game(command, app, timeout=max(.000001, deadline - time.monotonic()),
                                      expectedSteamID=expectedSteamID, onPhase=onPhase)
    finally:
        session.close()
