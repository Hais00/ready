// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Anonymous descriptor handoff to our native session keeper. The receiver
/// acknowledges admission, not authentication or successful game execution.
final class SteamSessionLeaseTransport {
  enum Failure: Error { case alreadyUsed, invalidDescriptor, system(Int32), deadline, rejected }
  let childInput: FileHandle
  private let socket: Int32
  private var used = false
  private let lock = NSLock()

  init() throws {
    var pair = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Failure.system(errno) }
    var moved = [Int32]()
    do {
      for fd in pair {
        let value = fcntl(fd, F_DUPFD_CLOEXEC, 10)
        guard value >= 0 else { throw Failure.system(errno) }
        moved.append(value)
      }
      let flags = fcntl(moved[0], F_GETFL)
      guard flags >= 0, fcntl(moved[0], F_SETFL, flags | O_NONBLOCK) == 0,
        fcntl(moved[0], F_SETNOSIGPIPE, 1) == 0 else { throw Failure.system(errno) }
    } catch {
      for fd in moved { close(fd) }
      for fd in pair { close(fd) }
      throw error
    }
    for fd in pair { close(fd) }
    socket = moved[0]
    childInput = FileHandle(fileDescriptor: moved[1], closeOnDealloc: true)
  }
  deinit { close(socket); try? childInput.close() }

  /// Call only after Process.run has duplicated childInput onto keeper stdin.
  func childDidSpawn() { try? childInput.close() }

  /// Consumes healthReadFD on every path. The prefix lease is only borrowed:
  /// closing its inherited references must never explicitly LOCK_UN it.
  func transfer(prefixLease: FileHandle, healthReadFD: Int32, timeout: TimeInterval = 3) throws {
    defer { close(healthReadFD) }
    lock.lock(); let repeated = used; used = true; lock.unlock()
    guard !repeated else { throw Failure.alreadyUsed }
    guard healthReadFD >= 3, prefixLease.fileDescriptor >= 0, timeout > 0, timeout <= 10 else {
      throw Failure.invalidDescriptor
    }
    var prefix = stat(), health = stat()
    let flags = fcntl(healthReadFD, F_GETFL)
    guard fstat(prefixLease.fileDescriptor, &prefix) == 0, fstat(healthReadFD, &health) == 0,
      prefix.st_uid == getuid(), health.st_uid == getuid(),
      prefix.st_mode & S_IFMT == S_IFREG, health.st_mode & S_IFMT == S_IFIFO,
      flags >= 0, flags & O_ACCMODE == O_RDONLY else { throw Failure.invalidDescriptor }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    func wait(_ events: Int16) throws {
      while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw Failure.deadline }
        let milliseconds = Int32(min(100, max(1, (deadline - now) / 1_000_000)))
        var descriptor = pollfd(fd: socket, events: events, revents: 0)
        let result = Darwin.poll(&descriptor, 1, milliseconds)
        if result < 0 && errno == EINTR { continue }
        guard result >= 0 else { throw Failure.system(errno) }
        if result > 0 {
          guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw Failure.rejected }
          if descriptor.revents & (events | Int16(POLLHUP | POLLERR)) != 0 { return }
        }
      }
    }
    // Darwin CMSG alignment is four bytes, including on ARM64. Use the imported
    // header layout rather than Linux's size_t/alignment assumptions.
    let alignment = MemoryLayout<cmsghdr>.alignment
    func aligned(_ value: Int) -> Int { (value + alignment - 1) & ~(alignment - 1) }
    let offset = aligned(MemoryLayout<cmsghdr>.size)
    let length = offset + 2 * MemoryLayout<Int32>.size
    let control = UnsafeMutableRawPointer.allocate(byteCount: aligned(length), alignment: alignment)
    defer { control.deallocate() }
    control.initializeMemory(as: UInt8.self, repeating: 0, count: aligned(length))
    control.storeBytes(of: cmsghdr(cmsg_len: socklen_t(length), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS), as: cmsghdr.self)
    control.advanced(by: offset).storeBytes(of: prefixLease.fileDescriptor, as: Int32.self)
    control.advanced(by: offset + MemoryLayout<Int32>.size).storeBytes(of: healthReadFD, as: Int32.self)
    let frame = Array("RDYSLF1\0".utf8)
    try frame.withUnsafeBytes { bytes in
      var vector = iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), iov_len: bytes.count)
      try withUnsafeMutablePointer(to: &vector) { pointer in
        var message = msghdr()
        message.msg_iov = pointer; message.msg_iovlen = 1
        message.msg_control = control; message.msg_controllen = socklen_t(aligned(length))
        while true {
          let count = sendmsg(socket, &message, 0)
          if count < 0 && errno == EINTR { continue }
          if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { try wait(Int16(POLLOUT)); continue }
          guard count == frame.count else { throw Failure.rejected }
          break // Exactly one successful sendmsg; never resend ancillary FDs.
        }
      }
    }
    guard shutdown(socket, SHUT_WR) == 0 else { throw Failure.system(errno) }
    let expected = Array("RDYACK1\0".utf8)
    var received = [UInt8]()
    var storage = [UInt8](repeating: 0, count: 9)
    while true {
      try wait(Int16(POLLIN))
      let count = Darwin.read(socket, &storage, storage.count)
      if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      guard count >= 0 else { throw Failure.system(errno) }
      if count == 0 { break }
      received.append(contentsOf: storage.prefix(count))
      guard received.count <= expected.count else { throw Failure.rejected }
    }
    guard received == expected else { throw Failure.rejected }
  }
}
