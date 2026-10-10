// This derivative reads one frame at a time, preserving the frame after startup ACK.
import Darwin
import Foundation

enum MacPrivateInput {
  static let maximumFrameBytes = 131_072
  static func readLine(descriptor: Int32, maximum: Int, deadline: ContinuousClock.Instant) throws -> Data {
    guard maximum > 0, maximum <= maximumFrameBytes else { throw HelperError.invalidArgs("private input bound invalid") }
    var bytes = Data()
    while ContinuousClock.now < deadline {
      var input = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let result = poll(&input, 1, 10)
      if result < 0 && errno == EINTR { continue }
      guard result >= 0, input.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw HelperError.invalidArgs("private input unavailable") }
      if result == 0 { continue }
      var byte: UInt8 = 0
      let count = Darwin.read(descriptor, &byte, 1)
      if count < 0 && errno == EINTR { continue }
      guard count == 1 else { throw HelperError.invalidArgs("private input incomplete") }
      bytes.append(byte)
      guard bytes.count <= maximum else { throw HelperError.invalidArgs("private input exceeds bound") }
      if byte == 10 { return bytes }
    }
    throw HelperError.invalidArgs("private input deadline exceeded")
  }
}

struct MacOrdinaryFillFrame: Codable {
  let schemaVersion: Int
  let kind: String
  let nonce: String
  let applicationTarget: MacApplicationTarget
  let x: Double
  let y: Double
  let value: String
  static func decode(_ bytes: Data, nonce: String, target: MacApplicationTarget, x: Double, y: Double) throws -> Self {
    do {
      guard bytes.count <= MacPrivateInput.maximumFrameBytes, bytes.last == 10 else { throw HelperError.invalidArgs("invalid private fill frame") }
      let frame = try JSONDecoder().decode(Self.self, from: Data(bytes.dropLast()))
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      var encoded = try encoder.encode(frame); encoded.append(10)
      guard encoded == bytes, frame.schemaVersion == 1, frame.kind == "ordinaryFill", frame.nonce == nonce,
        UUID(uuidString: nonce)?.uuidString.lowercased() == nonce,
        try encoder.encode(frame.applicationTarget) == encoder.encode(target), frame.x == x, frame.y == y,
        x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000,
        frame.value.utf8.count <= 65_536, frame.value.utf16.count <= 16_384, !frame.value.contains("\0") else {
        throw HelperError.invalidArgs("invalid private fill frame")
      }
      return frame
    } catch { throw HelperError.invalidArgs("invalid private fill frame") }
  }
}
