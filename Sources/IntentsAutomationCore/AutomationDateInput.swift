import Foundation
import IntentsAutomationDateCodec

/// An absolute timestamp with the explicitly chosen calendar context retained in the frozen input.
public struct AutomationDateInput: Codable, Equatable, Sendable {
    public var value: String
    public var timeZone: String
    public init(value: String, timeZone: String) { self.value = value; self.timeZone = timeZone }
    public var taggedValue: AutomationValue { .date(value, timeZone: timeZone) }
    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 4096,
              let fields = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String],
              Set(fields.keys) == ["value", "timeZone"], let value = fields["value"], let zone = fields["timeZone"],
              value.utf8.count <= 128 else { throw AutomationContractError.invalidPlan("Choose a date and time zone") }
        let input = Self(value: value, timeZone: zone); _ = try AutomationDateCodec.decode(value: value, timeZone: zone); return input
    }
    public func encoded() throws -> String {
        _ = try AutomationDateCodec.decode(value: value, timeZone: timeZone)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
