import Foundation

/// Shared with Swift intake and copied into the owned Apple host unchanged.
/// Accepts absolute timestamps at whole-second or millisecond precision.
public enum AutomationDateCodec {
    /// Returns canonical UTC milliseconds only when they retain the exact stored instant.
    public static func encode(_ date: Date) throws -> String {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800 else { throw invalidOutput() }
        let milliseconds = (seconds * 1000).rounded()
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let text = formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
        guard let restored = try? decode(value: text, timeZone: "UTC"), restored == date else { throw invalidOutput() }
        return text
    }
    private static func invalidOutput() -> EncodingError {
        .invalidValue("Date", .init(codingPath: [], debugDescription: "Date result cannot be represented exactly by the supported millisecond timestamp codec"))
    }
    public static func decode(value: String, timeZone: String) throws -> Date {
        func invalid() -> DecodingError {
            .dataCorrupted(.init(codingPath: [], debugDescription: "Date requires a valid calendar timestamp, explicit offset and time zone; at most three fractional digits are supported"))
        }
        guard value.utf8.count <= 128, timeZone.utf8.count <= 128, TimeZone(identifier: timeZone) != nil else { throw invalid() }
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.([0-9]{1,3}))?(Z|[+-][0-9]{2}:[0-9]{2})$"#
        let expression = try NSRegularExpression(pattern: pattern), string = value as NSString
        guard let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: string.length)), match.range.length == string.length else { throw invalid() }
        let fraction = match.range(at: 1).location == NSNotFound ? nil : string.substring(with: match.range(at: 1))
        let suffix = string.substring(with: match.range(at: 2))
        let offset: Int
        if suffix == "Z" { offset = 0 }
        else {
            let parts = suffix.dropFirst().split(separator: ":")
            guard let hour = Int(parts[0]), let minute = Int(parts[1]), minute < 60, hour * 60 + minute <= 18 * 60,
                  suffix != "-00:00" else { throw invalid() }
            offset = (suffix.first == "-" ? -1 : 1) * (hour * 3600 + minute * 60)
        }
        guard let zone = TimeZone(secondsFromGMT: offset) else { throw invalid() }
        let formatter = ISO8601DateFormatter(); formatter.timeZone = zone
        formatter.formatOptions = fraction == nil ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { throw invalid() }
        let expected = String(value.prefix(19)) + (fraction.map { "." + $0.padding(toLength: 3, withPad: "0", startingAt: 0) } ?? "") + (offset == 0 ? "Z" : suffix)
        guard formatter.string(from: date) == expected else { throw invalid() }
        return date
    }
}
