// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import LauncherCore
import Security

enum CredentialVault {
  enum Storage: Equatable { case keychain, privateFile }
  static let steamStoragePreference = "readySteamCredentialStorage"
  static func storage(for store: Store, preferences: UserDefaults = .standard) -> Storage {
    store == .steam && preferences.string(forKey: steamStoragePreference) == "privateFile" ? .privateFile : .keychain
  }
  // All real Keychain calls share this serial queue. UI callers use perform;
  // synchronous entry points remain available to existing private workers.
  private static let worker = DispatchQueue(label: "ready.credentials.serial", qos: .userInitiated)
  private static let workerKey = DispatchSpecificKey<Bool>()
  private static let installWorkerKey: Void = { worker.setSpecific(key: workerKey, value: true) }()
  static func perform<T>(_ body: @escaping () -> T, completion: @escaping (T) -> Void) {
    _ = installWorkerKey
    worker.async { let result = body(); DispatchQueue.main.async { completion(result) } }
  }
  static func serialized<T>(_ body: () throws -> T) rethrows -> T {
    _ = installWorkerKey
    if DispatchQueue.getSpecific(key: workerKey) == true { return try body() }
    return try worker.sync(execute: body)
  }

  enum SteamStatus { case missing, expired, available }
  /// One Steam account per profile/data root. Backend/platform is never a key.
  static func steamStatus(_ data: Data?, now: TimeInterval = Date().timeIntervalSince1970) -> SteamStatus {
    guard let data,
      let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let account = value["username"] as? String, (1...64).contains(account.utf8.count),
      account.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
        || (97...122).contains($0) || $0 == 95 }),
      let token = value["refresh_token"] as? String, (1...8192).contains(token.utf8.count),
      token.utf8.allSatisfy({ (33...126).contains($0) })
    else { return .missing }
    // Only an explicitly described REFRESH-token expiry matters. A short-lived
    // access-token expiry must not discard a still valid account or cause a QR.
    if let expiry = value["refresh_token_expires_at_epoch"] as? Double, expiry <= now {
      return .expired
    }
    return .available
  }
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
  static func save(_ data: Data, profile: UUID, store: Store, stateRoot: URL? = nil, preferences: UserDefaults = .standard) throws {
    try serialized {
    if storage(for:store,preferences:preferences) == .privateFile {
      try PrivateCredentialFile(stateRoot:stateRoot ?? LauncherPaths().root).save(data,profile:profile);return
    }
    let q = query(profile: profile, store: store, stateRoot: stateRoot)
    let result = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if result == errSecItemNotFound {
      var insert = q
      insert[kSecValueData as String] = data
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
        throw LauncherError.failed("Impossibile salvare l’accesso nell’archivio account.")
      }
    } else if result != errSecSuccess {
      throw LauncherError.failed("Archivio account non disponibile (\(result)).")
    }
    }
  }
  static func load(profile: UUID, store: Store, stateRoot: URL? = nil, preferences: UserDefaults = .standard) -> Data? {
    serialized {
    if storage(for:store,preferences:preferences) == .privateFile {
      // No Keychain fallback or migration: even a missing/unsafe file stays local.
      return try? PrivateCredentialFile(stateRoot:stateRoot ?? LauncherPaths().root).load(profile:profile)
    }
    var q = query(profile: profile, store: store, stateRoot: stateRoot)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
    }
  }
  static func remove(profile: UUID, store: Store, stateRoot: URL? = nil, preferences: UserDefaults = .standard) {
    serialized {
      if storage(for:store,preferences:preferences) == .privateFile {
        try? PrivateCredentialFile(stateRoot:stateRoot ?? LauncherPaths().root).remove(profile:profile);return
      }
      _ = SecItemDelete(query(profile:profile,store:store,stateRoot:stateRoot) as CFDictionary)
    }
  }
}
