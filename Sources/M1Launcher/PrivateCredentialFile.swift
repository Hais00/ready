// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Optional Steam-only storage selected by the explicit persistent policy.
/// Construction performs no I/O; selection never reads/migrates Keychain data.
/// Files protect against other users, not another process running as this UID.
final class PrivateCredentialFile {
  enum Failure: Error { case unsafeRoot, unsafeDirectory, unsafeFile, invalidCredential, unavailable }
  static let maximumBytes = 64 * 1024
  private let stateRoot: URL
  init(stateRoot: URL) { self.stateRoot = stateRoot }

  func load(profile: UUID) throws -> Data? {
    try CredentialVault.serialized {
      try withDirectory(create: false) { directory -> Data? in
        let name = filename(profile)
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw Failure.unsafeFile }
        defer { close(descriptor) }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0 else { throw Failure.unavailable }
        try Self.validateFileMetadata(before)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = Darwin.read(descriptor, &buffer, buffer.count)
          if count < 0 && errno == EINTR { continue }
          guard count >= 0 else { throw Failure.unavailable }
          if count == 0 { break }
          data.append(contentsOf: buffer.prefix(count))
          guard data.count <= Self.maximumBytes else { throw Failure.unsafeFile }
        }
        guard fstat(descriptor, &after) == 0, Self.unchanged(before, after),
          sameEntry(directory, name, after), data.count == Int(after.st_size) else { throw Failure.unsafeFile }
        try Self.validate(data)
        return data
      } ?? nil
    }
  }

  func save(_ data: Data, profile: UUID) throws {
    try CredentialVault.serialized {
      // An invalid incoming payload must not create a directory or touch an old file.
      try Self.validate(data)
      _ = try withDirectory(create: true) { directory in
        let name = filename(profile), previous = try existing(directory, name)
        let temporary = ".ready-steam-credential-" + UUID().uuidString.lowercased()
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        var created = stat(), published = false
        guard fstat(descriptor, &created) == 0 else { close(descriptor); throw Failure.unavailable }
        defer {
          close(descriptor)
          if !published && sameEntry(directory, temporary, created) { _ = unlinkat(directory, temporary, 0) }
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw Failure.unavailable }
        try data.withUnsafeBytes { bytes in
          var offset = 0
          while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.unavailable }; offset += count
          }
        }
        var complete = stat()
        guard fsync(descriptor) == 0, fstat(descriptor, &complete) == 0 else { throw Failure.unavailable }
        try Self.validateFileMetadata(complete)
        guard complete.st_size == data.count, sameEntry(directory, temporary, complete),
          try targetUnchanged(directory, name, previous) else { throw Failure.unsafeFile }
        guard renameat(directory, temporary, directory, name) == 0 else { throw Failure.unavailable }
        published = true
        guard fsync(directory) == 0 else { throw Failure.unavailable }
      }
    }
  }

  func remove(profile: UUID) throws {
    try CredentialVault.serialized {
      _ = try withDirectory(create: false) { directory in
        let name = filename(profile)
        guard let entry = try existing(directory, name) else { return }
        guard sameEntry(directory, name, entry), unlinkat(directory, name, 0) == 0 else { throw Failure.unsafeFile }
        guard fsync(directory) == 0 else { throw Failure.unavailable }
      }
    }
  }

  private func filename(_ profile: UUID) -> String { profile.uuidString.lowercased() + "-steam.json" }
  private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T? {
    let root = try openRoot(); defer { close(root) }
    var directory = openat(root, "Credentials", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if directory < 0 && errno == ENOENT {
      guard create else { return nil }
      guard mkdirat(root, "Credentials", 0o700) == 0 || errno == EEXIST else { throw Failure.unavailable }
      directory = openat(root, "Credentials", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fsync(root) == 0 else { if directory >= 0 { close(directory) }; throw Failure.unavailable }
    }
    guard directory >= 0 else { throw Failure.unsafeDirectory }; defer { close(directory) }
    var info = stat()
    guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { throw Failure.unsafeDirectory }
    guard sameEntry(root, "Credentials", info) else { throw Failure.unsafeDirectory }
    return try body(directory)
  }
  private func openRoot() throws -> Int32 {
    let path = stateRoot.path
    guard stateRoot.isFileURL, path.hasPrefix("/"), path != "/", !path.utf8.contains(0),
      stateRoot.standardizedFileURL.path == path else { throw Failure.unsafeRoot }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.unavailable }
    for component in path.split(separator: "/") {
      let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      close(descriptor)
      guard next >= 0 else { throw Failure.unsafeRoot }; descriptor = next
    }
    var info = stat(), actual = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
      info.st_mode & 0o7777 == 0o700, fcntl(descriptor, F_GETPATH, &actual) == 0,
      String(validatingUTF8: actual) == path else { close(descriptor); throw Failure.unsafeRoot }
    return descriptor
  }
  private func existing(_ directory: Int32, _ name: String) throws -> stat? {
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if descriptor < 0 { if errno == ENOENT { return nil }; throw Failure.unsafeFile }
    defer { close(descriptor) }
    var value = stat(); guard fstat(descriptor, &value) == 0 else { throw Failure.unavailable }
    try Self.validateFileMetadata(value)
    guard sameEntry(directory, name, value) else { throw Failure.unsafeFile }
    return value
  }
  private func targetUnchanged(_ directory: Int32, _ name: String, _ previous: stat?) throws -> Bool {
    let current = try existing(directory, name)
    if let previous, let current { return Self.unchanged(previous, current) }
    return previous == nil && current == nil
  }
  private func sameEntry(_ directory: Int32, _ name: String, _ expected: stat) -> Bool {
    var actual = stat()
    return fstatat(directory, name, &actual, AT_SYMLINK_NOFOLLOW) == 0
      && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
      && actual.st_mode & S_IFMT == expected.st_mode & S_IFMT
  }
  static func validateFileMetadata(_ value: stat) throws {
    guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(),
      value.st_mode & 0o7777 == 0o600, value.st_nlink == 1,
      value.st_size > 0, value.st_size <= maximumBytes else { throw Failure.unsafeFile }
  }
  private static func unchanged(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode
      && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
  private static func validate(_ data: Data) throws {
    guard !data.isEmpty, data.count <= maximumBytes,
      (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
      CredentialVault.steamStatus(data) != .missing else { throw Failure.invalidCredential }
    // Inspect every lexical key, including overwritten duplicate members. This
    // also rejects escaped/case-varied password keys in nested guard extensions.
    let bytes = Array(data); var index = 0
    while index < bytes.count {
      guard bytes[index] == 34 else { index += 1; continue }
      let begin = index; index += 1
      while index < bytes.count {
        if bytes[index] == 92 { index += 2; continue }
        if bytes[index] == 34 { break }; index += 1
      }
      guard index < bytes.count else { throw Failure.invalidCredential }
      let end = index + 1; index = end
      var following = end
      while following < bytes.count && [9, 10, 13, 32].contains(bytes[following]) { following += 1 }
      if following < bytes.count, bytes[following] == 58 {
        guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[begin..<end])) else { throw Failure.invalidCredential }
        let normalized = key.lowercased()
        guard !normalized.contains("password"), !normalized.contains("passphrase") else { throw Failure.invalidCredential }
      }
    }
  }
}
