// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
import Security

enum CredentialVault {
  static func query(profile: UUID, store: Store) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "app.ready.launcher.\(store.rawValue)",
      kSecAttrAccount as String: profile.uuidString,
    ]
  }
  static func save(_ data: Data, profile: UUID, store: Store) throws {
    let q = query(profile: profile, store: store)
    let result = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if result == errSecItemNotFound {
      var insert = q
      insert[kSecValueData as String] = data
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
        throw LauncherError.failed("Impossibile salvare l’account nel Portachiavi.")
      }
    } else if result != errSecSuccess {
      throw LauncherError.failed("Portachiavi non disponibile (\(result)).")
    }
  }
  static func load(profile: UUID, store: Store) -> Data? {
    var q = query(profile: profile, store: store)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }
  static func remove(profile: UUID, store: Store) {
    SecItemDelete(query(profile: profile, store: store) as CFDictionary)
  }
}
