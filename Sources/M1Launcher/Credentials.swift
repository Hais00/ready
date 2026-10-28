import CryptoKit
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LauncherCore
import Security

enum CredentialVault {
  static func query(profile: UUID, store: Store, stateRoot: URL? = nil) -> [String: Any] {
    var service = "app.ready.launcher.\(store.rawValue)"
    if let stateRoot {
      let root = stateRoot.standardizedFileURL.resolvingSymlinksInPath().path
      let original = LauncherPaths().root.standardizedFileURL.resolvingSymlinksInPath().path
      if root != original {
        service +=
          ".data." + SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
      }
    }
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: profile.uuidString,
    ]
  }
  static func save(_ data: Data, profile: UUID, store: Store, stateRoot: URL? = nil) throws {
    let q = query(profile: profile, store: store, stateRoot: stateRoot)
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
  static func load(profile: UUID, store: Store, stateRoot: URL? = nil) -> Data? {
    var q = query(profile: profile, store: store, stateRoot: stateRoot)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }
  static func remove(profile: UUID, store: Store, stateRoot: URL? = nil) {
    SecItemDelete(query(profile: profile, store: store, stateRoot: stateRoot) as CFDictionary)
  }
}
