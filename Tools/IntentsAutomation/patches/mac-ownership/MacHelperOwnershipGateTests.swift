import XCTest
import Darwin
@testable import AgentDeviceMacOSHelper

final class MacHelperOwnershipGateTests: XCTestCase {
  let nonce = "12345678-1234-1234-1234-123456789abc"
  let identity = MacHelperOwnershipGate.Identity(pid: 42, startIdentity: "100:0")
  func testCanonicalAcknowledgementBindsNonceAndKernelIdentity() throws {
    let bytes = try MacHelperOwnershipGate.frame(.init(kind: "ack", nonce: nonce, identity: identity))
    try MacHelperOwnershipGate.validate(bytes, nonce: nonce, identity: identity)
    XCTAssertThrowsError(try MacHelperOwnershipGate.validate(bytes, nonce: nonce, identity: .init(pid: 43, startIdentity: "100:0")))
    XCTAssertThrowsError(try MacHelperOwnershipGate.validate(bytes, nonce: nonce, identity: .init(pid: 42, startIdentity: "101:0")))
    XCTAssertThrowsError(try MacHelperOwnershipGate.validate(bytes, nonce: "aaaaaaaa-1234-1234-1234-123456789abc", identity: identity))
  }
  func testReadySchemaWhitespaceAndOversizeCannotAcknowledge() throws {
    let ready = try MacHelperOwnershipGate.frame(.init(kind: "ready", nonce: nonce, identity: identity))
    XCTAssertThrowsError(try MacHelperOwnershipGate.validate(ready, nonce: nonce, identity: identity))
    let ack = try MacHelperOwnershipGate.frame(.init(kind: "ack", nonce: nonce, identity: identity))
    XCTAssertThrowsError(try MacHelperOwnershipGate.validate(Data(" ".utf8) + ack, nonce: nonce, identity: identity))
    XCTAssertThrowsError(try MacHelperOwnershipGate.validate(ack + ack, nonce: nonce, identity: identity))
    XCTAssertThrowsError(try MacHelperOwnershipGate.validate(Data(repeating: 10, count: 4097), nonce: nonce, identity: identity))
  }
  func testStrictSchemaAndIdentityEncoding() throws {
    let ack = try MacHelperOwnershipGate.frame(.init(kind: "ack", nonce: nonce, identity: identity))
    for raw in [String(decoding: ack, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                String(decoding: ack, as: UTF8.self).replacingOccurrences(of: "{\"identity\"", with: "{\"extra\":1,\"identity\""),
                String(decoding: ack, as: UTF8.self).replacingOccurrences(of: "\"kind\":\"ack\"", with: "\"kind\":\"ack\",\"kind\":\"ack\"")] {
      XCTAssertThrowsError(try MacHelperOwnershipGate.validate(Data(raw.utf8), nonce: nonce, identity: identity))
    }
    XCTAssertThrowsError(try MacHelperOwnershipGate.validate(Data(ack.dropLast()), nonce: nonce, identity: identity))
    for start in ["0:0", "01:0", "1:1000000", "1:00", "1", "-1:0"] {
      XCTAssertThrowsError(try MacHelperOwnershipGate.frame(.init(kind: "ack", nonce: nonce, identity: .init(pid: 42, startIdentity: start))))
    }
    XCTAssertThrowsError(try MacHelperOwnershipGate.frame(.init(kind: "ack", nonce: "bad", identity: identity)))
  }
  func withPipe(_ body: (Int32, Int32) throws -> Void) throws {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&descriptors), 0)
    defer { close(descriptors[0]); close(descriptors[1]) }
    try body(descriptors[0], descriptors[1])
  }
  func testStalledOutputHonoursDeadlineAndRestoresFlags() throws {
    try withPipe { _, output in
      let flags = fcntl(output, F_GETFL)
      XCTAssertEqual(fcntl(output, F_SETFL, flags | O_NONBLOCK), 0)
      let padding = Data(repeating: 1, count: 4096)
      while padding.withUnsafeBytes({ Darwin.write(output, $0.baseAddress, $0.count) }) > 0 {}
      XCTAssertEqual(errno, EAGAIN)
      XCTAssertEqual(fcntl(output, F_SETFL, flags), 0)
      let start = ContinuousClock.now
      XCTAssertThrowsError(try MacHelperOwnershipGate.writeReady(padding, descriptor: output, deadline: start.advanced(by: .milliseconds(30))))
      XCTAssertLessThan(start.duration(to: .now), .seconds(1))
      XCTAssertEqual(fcntl(output, F_GETFL) & O_NONBLOCK, flags & O_NONBLOCK)
    }
  }
  func testInputTimeoutOversizeAndInvalidDescriptor() throws {
    try withPipe { input, output in
      XCTAssertThrowsError(try MacHelperOwnershipGate.readAcknowledgement(descriptor: input, deadline: .now.advanced(by: .milliseconds(30))))
      let oversized = Data(repeating: 1, count: 4097)
      XCTAssertEqual(oversized.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }, oversized.count)
      XCTAssertThrowsError(try MacHelperOwnershipGate.readAcknowledgement(descriptor: input, deadline: .now.advanced(by: .seconds(1))))
    }
    XCTAssertThrowsError(try MacHelperOwnershipGate.readAcknowledgement(descriptor: -1, deadline: .now.advanced(by: .milliseconds(30))))
  }
  func testInputEOFAndFragmentedAcknowledgement() throws {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&descriptors), 0)
    close(descriptors[1])
    defer { close(descriptors[0]) }
    XCTAssertThrowsError(try MacHelperOwnershipGate.readAcknowledgement(descriptor: descriptors[0], deadline: .now.advanced(by: .seconds(1))))
    let ack = try MacHelperOwnershipGate.frame(.init(kind: "ack", nonce: nonce, identity: identity))
    try withPipe { input, output in
      let first = ack.prefix(20), rest = ack.dropFirst(20)
      XCTAssertEqual(first.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }, first.count)
      let writer = DispatchGroup(); writer.enter()
      DispatchQueue.global().async {
        usleep(20_000)
        _ = rest.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
        writer.leave()
      }
      defer { writer.wait() }
      let received = try MacHelperOwnershipGate.readAcknowledgement(descriptor: input, deadline: .now.advanced(by: .seconds(1)))
      XCTAssertEqual(received, ack)
      try MacHelperOwnershipGate.validate(received, nonce: nonce, identity: identity)
    }
  }
}
