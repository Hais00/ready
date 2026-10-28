# SPDX-License-Identifier: GPL-3.0-only
"""Pure bounded private-pipe encoder. No I/O, JWT decoding or authentication.

The caller supplies explicit SteamID/AppID from the genuine authorization path
and closes its private pipe writer after these bytes to signal EOF. Never log
the input dictionary or returned bytes.
"""
import struct


def _identifier(value, bits):
    if isinstance(value, bool): raise ValueError('Invalid identifier')
    if isinstance(value, str):
        if not value or not value.isascii() or not value.isdecimal(): raise ValueError('Invalid identifier')
        value = int(value)
    if not isinstance(value, int) or not 0 < value < (1 << bits): raise ValueError('Invalid identifier')
    return value


def pack_credentials(source):
    """Flat username/refresh_token/steamID/appID dict -> bounded RDYAUTH1 bytes.

    No JWT parsing or account lookup. Passing structural validation does not
    authenticate an identity or authorize a game. Never log source/returned bytes.
    """
    if not isinstance(source, dict): raise ValueError('Credential source must be an object')
    account, token = source.get('username'), source.get('refresh_token')
    if not isinstance(account, str) or not 1 <= len(account) <= 64 or not account.isascii() or any(not (ch.isalnum() or ch == '_') for ch in account):
        raise ValueError('Invalid account structure')
    if not isinstance(token, str) or not 1 <= len(token) <= 8192 or any(not 33 <= ord(ch) <= 126 for ch in token):
        raise ValueError('Invalid token structure')
    steam_id = _identifier(source.get('steamID'), 64); app_id = _identifier(source.get('appID'), 32)
    if steam_id >> 56 != 1 or (steam_id >> 52) & 15 != 1 or (steam_id >> 32) & 0xfffff != 1 or steam_id & 0xffffffff == 0:
        raise ValueError('Invalid individual identity structure')
    account_bytes, token_bytes = account.encode('ascii'), token.encode('ascii')
    return b'RDYAUTH1' + struct.pack('>IIQI', len(account_bytes), len(token_bytes), steam_id, app_id) + account_bytes + token_bytes

