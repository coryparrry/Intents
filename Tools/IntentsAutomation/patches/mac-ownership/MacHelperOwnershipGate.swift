import Darwin
import Foundation

/// Private helper ABI v1: no command dispatch before an exact parent acknowledgement.
enum MacHelperOwnershipGate {
  struct Probe: Encodable {
    let scope = "startup-ownership-only"
    let uiInteracted = false
    let identity: Identity
  }
  struct Identity: Codable, Equatable {
    var pid: Int32
    var startIdentity: String
  }
  struct Message: Codable, Equatable {
    var schemaVersion = 1
    var kind: String
    var nonce: String
    var identity: Identity
  }
  static func ownIdentity() throws -> Identity {
    var info = proc_bsdinfo()
    let pid = getpid(), size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_start_tvsec > 0,
      info.pbi_start_tvusec <= 999_999 else { throw HelperError.invalidArgs("helper startup identity unavailable") }
    return Identity(pid: pid, startIdentity: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
  }
  static func frame(_ message: Message) throws -> Data {
    let parts = message.identity.startIdentity.split(separator: ":", omittingEmptySubsequences: false)
    guard message.identity.pid > 0, parts.count == 2,
      let seconds = UInt64(parts[0]), seconds > 0, String(seconds) == parts[0],
      let micros = UInt32(parts[1]), micros <= 999999, String(micros) == parts[1],
      UUID(uuidString: message.nonce)?.uuidString.lowercased() == message.nonce else {
      throw HelperError.invalidArgs("invalid helper startup nonce")
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var bytes = try encoder.encode(message); bytes.append(10)
    guard bytes.count <= 4096 else { throw HelperError.invalidArgs("helper startup frame exceeds bound") }
    return bytes
  }
  static func validate(_ bytes: Data, nonce: String, identity: Identity) throws {
    guard bytes.count <= 4096, bytes.last == 10 else { throw HelperError.invalidArgs("invalid helper acknowledgement frame") }
    let ack = try JSONDecoder().decode(Message.self, from: Data(bytes.dropLast()))
    guard ack.schemaVersion == 1, ack.kind == "ack", ack.nonce == nonce, ack.identity == identity,
      try frame(ack) == bytes else { throw HelperError.invalidArgs("helper acknowledgement does not match startup") }
  }
  @discardableResult
  static func requireAcknowledgement() throws -> Identity {
    guard let nonce = ProcessInfo.processInfo.environment["INTENTS_MAC_HELPER_OWNERSHIP_NONCE"] else {
      throw HelperError.invalidArgs("native-owned helper startup is required; no legacy fallback")
    }
    let identity = try ownIdentity()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    try writeReady(frame(.init(kind: "ready", nonce: nonce, identity: identity)), descriptor: STDOUT_FILENO, deadline: deadline)
    let acknowledgement = try readAcknowledgement(descriptor: STDIN_FILENO, deadline: deadline)
    try validate(acknowledgement, nonce: nonce, identity: identity)
    guard try ownIdentity() == identity else { throw HelperError.invalidArgs("helper identity changed during startup") }
    return identity
  }
  static func writeReady(_ bytes: Data, descriptor: Int32, deadline: ContinuousClock.Instant) throws {
    guard !bytes.isEmpty, bytes.count <= 4096 else { throw HelperError.invalidArgs("helper ready frame exceeds bound") }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw HelperError.invalidArgs("helper ready output unavailable")
    }
    defer { _ = fcntl(descriptor, F_SETFL, flags) }
    var offset = 0
    while ContinuousClock.now < deadline {
      let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
      if count > 0 {
        offset += count
        if offset == bytes.count { return }
      } else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
        throw HelperError.invalidArgs("helper ready output failed")
      }
      var output = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      let polled = poll(&output, 1, 10)
      if polled < 0 && errno == EINTR { continue }
      guard polled >= 0, output.revents & Int16(POLLERR | POLLNVAL | POLLHUP) == 0 else {
        throw HelperError.invalidArgs("helper ready output closed")
      }
    }
    throw HelperError.invalidArgs("helper ready deadline exceeded")
  }
  static func readAcknowledgement(descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Data {
    var acknowledgement = Data()
    while ContinuousClock.now < deadline {
      var input = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let polled = poll(&input, 1, 10)
      if polled < 0 && errno == EINTR { continue }
      guard polled >= 0, input.revents & Int16(POLLERR | POLLNVAL) == 0 else {
        throw HelperError.invalidArgs("helper acknowledgement input failed")
      }
      if polled == 0 { continue }
      var buffer = [UInt8](repeating: 0, count: 4097 - acknowledgement.count)
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw HelperError.invalidArgs("helper acknowledgement missing") }
      acknowledgement.append(contentsOf: buffer.prefix(count))
      guard acknowledgement.count <= 4096 else { throw HelperError.invalidArgs("helper acknowledgement exceeds bound") }
      if acknowledgement.contains(10) {
        return acknowledgement
      }
    }
    throw HelperError.invalidArgs("helper acknowledgement deadline exceeded")
  }
}
