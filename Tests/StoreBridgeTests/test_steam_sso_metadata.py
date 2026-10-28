# SPDX-License-Identifier: GPL-3.0-only
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'StoreBridge'))
import bridge


class SteamSSOMetadata(unittest.TestCase):
    def test_authorization_is_declared_steam_only(self):
        value = bridge.dispatch({'operation': 'capabilities'})
        self.assertIn('authorize_game', value['operations'])
        self.assertEqual(value['operationStores']['authorize_game'], ['steam'])

    def test_safe_rejection_detail_survives_without_arbitrary_fields(self):
        value = bridge.BridgeError('steam_login_failed', 'safe', details={
            'steamResult': 'Expired', 'credentials': 'fixture-private', 'stage': 'untrusted'})
        self.assertEqual(value.details, {'steamResult': 'Expired'})

    def test_unknown_detail_does_not_become_a_login_rejection(self):
        value = bridge.BridgeError('steam_error', 'safe', details={'steamResult': 'fixture-private'})
        self.assertEqual(value.details, {})


if __name__ == '__main__':
    unittest.main()
