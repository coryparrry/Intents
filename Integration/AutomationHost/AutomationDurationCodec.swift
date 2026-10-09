import Foundation

/// Exact canonical Swift Duration components; no floating-point conversion.
public struct AutomationDurationInput: Codable, Equatable, Sendable {
    public var seconds: String
    public var attoseconds: String
    public init(seconds: String, attoseconds: String) { self.seconds = seconds; self.attoseconds = attoseconds }
    public func duration() throws -> Duration {
        func integer(_ text: String) throws -> Int64 {
            guard text.count <= 20, let number = Int64(text), String(number) == text else { throw Self.invalid() }
            return number
        }
        let seconds = try integer(seconds), fraction = try integer(attoseconds)
        guard (-999_999_999_999_999_999...999_999_999_999_999_999).contains(fraction),
              seconds == 0 || (seconds > 0 ? fraction >= 0 : fraction <= 0) else { throw Self.invalid() }
        let value = Duration(secondsComponent: seconds, attosecondsComponent: fraction)
        guard value.components.seconds == seconds, value.components.attoseconds == fraction else { throw Self.invalid() }
        return value
    }
    public static func encode(_ duration: Duration) throws -> Self {
        let total = duration.attoseconds, scale = Int128(1_000_000_000_000_000_000)
        guard let seconds = Int64(exactly: total / scale), let fraction = Int64(exactly: total % scale) else { throw Self.invalid() }
        let input = Self(seconds: String(seconds), attoseconds: String(fraction))
        guard try input.duration() == duration else { throw Self.invalid() }
        return input
    }
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 1024, let fields = try JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(fields.keys) == ["seconds", "attoseconds"], let seconds = fields["seconds"], let fraction = fields["attoseconds"] else { throw Self.invalid() }
        let input = Self(seconds: seconds, attoseconds: fraction); _ = try input.duration(); return input
    }
    private static func invalid() -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "Duration requires exact canonical seconds and attoseconds strings with matching signs")) }
}
