import Foundation
#if canImport(IntentsAutomationDateCodec)
import IntentsAutomationDateCodec
#endif

struct HostPlan: Decodable {
    let schemaVersion: Int
    let runID: String
    let attemptID: String
    let segmentID: String
    let leaseGeneration: Int
    let bundleID: String
    let productDigest: String
    let productDigestVersion: Int?
    let operations: [HostOperation]
}
struct HostOperation: Decodable {
    enum Kind: String, Decodable { case invoke, query }
    let id: String
    let kind: Kind
    let typeID: String
    let parameters: [String: HostInput]
    let resultCodec: String?
    let queryText: String?
    let queryIDs: [String]?
    let properties: [String: String]?
    let parameterCodecs: [String: String]?
}
struct HostInput: Codable, Equatable {
    let timeZone: String?
    let items: [HostInput]?
    let kind: String
    let value: String?
    let boolValue: Bool?
    let typeId: String?
    let properties: [String: HostInput]?
    var file: AutomationIntentFileMetadata? = nil
}
enum HostDateCodec {
    static func encode(_ date: Date) throws -> HostValue {
        HostValue(kind: "date", value: try AutomationDateCodec.encode(date), timeZone: "UTC")
    }
    static func decode(_ input: HostInput) throws -> Date {
        guard input.kind == "date", let text = input.value, text.utf8.count <= 128,
              let zone = input.timeZone, zone.utf8.count <= 128, TimeZone(identifier: zone) != nil,
              input.items == nil, input.boolValue == nil, input.typeId == nil, input.properties == nil else { throw invalid() }
        return try AutomationDateCodec.decode(value: text, timeZone: zone)
    }
    private static func invalid() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Date requires an absolute timestamp and valid time zone"))
    }
}
struct HostValue: Codable, Equatable {
    let kind: String
    var value: String?
    var boolValue: Bool?
    var typeId: String?
    var properties: [String: HostValue]?
    var items: [HostValue]?
    var timeZone: String?
    var file: AutomationIntentFileMetadata?
    var fileData: Data? = nil
    enum CodingKeys: String, CodingKey { case kind, value, boolValue, typeId, properties, items, timeZone, file }
}

enum HostArrayCodec {
    static func items(_ input: HostInput, elementKind: String) throws -> [HostInput] {
        guard input.kind == "array", input.value == nil, input.boolValue == nil, input.typeId == nil,
              input.timeZone == nil, input.properties == nil, let items = input.items, items.count <= 1000,
              items.allSatisfy({ item in
                  item.kind == elementKind && item.items == nil && item.typeId == nil && item.properties == nil && (item.value?.utf16.count ?? 0) <= 32768 &&
                  (elementKind == "date" || item.timeZone == nil) &&
                  (elementKind == "bool" ? item.boolValue != nil && item.value == nil : item.boolValue == nil && item.value != nil)
              }) else { throw invalid() }
        return items
    }
    static func texts(_ input: HostInput) throws -> [String] { try items(input, elementKind: "text").map { $0.value! } }
    static func bools(_ input: HostInput) throws -> [Bool] { try items(input, elementKind: "bool").map { $0.boolValue! } }
    static func integers(_ input: HostInput) throws -> [Int64] {
        try items(input, elementKind: "integer").map { guard $0.value!.count <= 128, $0.value!.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil, let value = Int64($0.value!) else { throw invalid() }; return value }
    }
    static func encodeIntegers(_ values: [Int]) throws -> HostValue {
        guard values.count <= 1000 else { throw invalid() }
        return HostValue(kind: "array", items: try values.map { value in
            guard let canonical = Int64(exactly: value) else { throw invalid() }
            return HostValue(kind: "integer", value: String(canonical))
        })
    }
    static func decimals(_ input: HostInput) throws -> [Double] {
        try items(input, elementKind: "decimal").map { guard $0.value!.count <= 256, $0.value!.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil, let value = Double($0.value!), value.isFinite else { throw invalid() }; return value }
    }
    static func dates(_ input: HostInput) throws -> [Date] { try items(input, elementKind: "date").map(HostDateCodec.decode) }
    private static func invalid() -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "Collection does not match its frozen element codec")) }
}

enum HostURLCodec {
    static func decode(_ input: HostInput) throws -> URL {
        guard input.kind == "object", input.value == nil, input.boolValue == nil, input.items == nil, input.typeId == nil, input.timeZone == nil,
              let properties = input.properties, Set(properties.keys) == ["url"], let field = properties["url"],
              field.kind == "text", let text = field.value, field.boolValue == nil, field.items == nil,
              field.typeId == nil, field.timeZone == nil, field.properties == nil else { throw invalid() }
        return try AutomationURLReference(text).url()
    }
    static func encode(_ url: URL) throws -> HostValue {
        let reference = try AutomationURLReference.encode(url)
        return .init(kind: "object", properties: ["url": .init(kind: "text", value: reference.absoluteString)])
    }
    private static func invalid() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "URL requires its exact frozen URL-reference field"))
    }
}

enum HostDurationCodec {
    static func decode(_ input: HostInput) throws -> Duration {
        guard input.kind == "object", input.value == nil, input.boolValue == nil, input.items == nil, input.typeId == nil, input.timeZone == nil,
              let properties = input.properties, Set(properties.keys) == ["seconds", "attoseconds"] else { throw invalid() }
        func integer(_ name: String) throws -> String {
            guard let field = properties[name], field.kind == "integer", let value = field.value,
                  field.boolValue == nil, field.items == nil, field.typeId == nil, field.timeZone == nil, field.properties == nil else { throw invalid() }
            return value
        }
        return try AutomationDurationInput(seconds: integer("seconds"), attoseconds: integer("attoseconds")).duration()
    }
    static func encode(_ duration: Duration) throws -> HostValue {
        let input = try AutomationDurationInput.encode(duration)
        return HostValue(kind: "object", properties: ["seconds": .init(kind: "integer", value: input.seconds), "attoseconds": .init(kind: "integer", value: input.attoseconds)])
    }
    private static func invalid() -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "Duration requires exact frozen integer components")) }
}

/// Conservative JSON budget, checked before allocating encoded result attachments.
enum HostValueBudget {
    static func boundedErrorDescription(_ text: String) -> String {
        String(decoding: text.utf8.prefix(4096), as: UTF8.self)
    }
    static func validate(_ values: [HostValue]) throws {
        var remaining = 900_000, nodes = 4000
        func visit(_ value: HostValue, depth: Int) throws {
            guard depth <= 16, nodes > 0 else { throw invalid() }
            nodes -= 1; remaining -= 256
            for text in [value.kind, value.value, value.typeId, value.timeZone].compactMap({ $0 }) {
                guard text.utf16.count <= 32768 else { throw invalid() }
                remaining -= 6 * text.utf16.count
            }
            guard remaining >= 0, (value.items?.count ?? 0) <= 1000, (value.properties?.count ?? 0) <= 50 else { throw invalid() }
            for item in value.items ?? [] { try visit(item, depth: depth + 1) }
            for (key, item) in value.properties ?? [:] {
                guard key.utf16.count <= 256 else { throw invalid() }
                remaining -= 6 * key.utf16.count; try visit(item, depth: depth + 1)
            }
        }
        for value in values { try visit(value, depth: 0) }
    }
    private static func invalid() -> EncodingError { .invalidValue("Host result", .init(codingPath: [], debugDescription: "Host result exceeds its bounded evidence budget")) }
}

/// Core's decimal wire uses bounded plain strings; Double's normal description may use exponents.
enum HostDecimalCodec {
    static func encode(_ value: Double) throws -> String {
        guard value.isFinite else { throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Nonfinite decimal")) }
        let raw = String(value), negative = raw.hasPrefix("-")
        let magnitude = negative ? String(raw.dropFirst()) : raw
        let parts = magnitude.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        var output = magnitude
        if parts.count == 2 {
            guard let exponent = Int(parts[1]), (-400...400).contains(exponent) else { throw invalid(value) }
            let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            let digits = mantissa.joined(), position = mantissa[0].count + exponent
            if position <= 0 { output = "0." + String(repeating: "0", count: -position) + digits }
            else if position >= digits.count { output = digits + String(repeating: "0", count: position - digits.count) }
            else { output = String(digits.prefix(position)) + "." + String(digits.dropFirst(position)) }
        }
        if negative { output = "-" + output }
        guard output.count <= 256, output.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil else { throw invalid(value) }
        return output
    }
    private static func invalid(_ value: Double) -> EncodingError {
        .invalidValue(value, .init(codingPath: [], debugDescription: "Decimal exceeds the bounded plain wire representation"))
    }
}

private enum HostStructuredCodec {
    static func object(_ input: HostInput?) throws -> [String: HostInput] {
        guard let input, input.kind == "object", input.value == nil, input.boolValue == nil, input.items == nil, input.timeZone == nil,
              input.typeId == nil, let fields = input.properties, fields.count <= 50 else { throw invalid() }
        return fields
    }
    static func text(_ input: HostInput?, kind: String = "text") throws -> String {
        guard let input, input.kind == kind, let value = input.value, input.boolValue == nil, input.items == nil, input.properties == nil,
              input.typeId == nil, input.timeZone == nil else { throw invalid() }; return value
    }
    static func bool(_ input: HostInput?) throws -> Bool {
        guard let input, input.kind == "bool", let value = input.boolValue, input.value == nil, input.items == nil, input.properties == nil,
              input.typeId == nil, input.timeZone == nil else { throw invalid() }; return value
    }
    static func invalid() -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "Structured value does not match its frozen native codec")) }
}

enum HostCalendarCodec {
    static func decode(_ input: HostInput) throws -> DateComponents {
        let fields = try HostStructuredCodec.object(input)
        guard Set(fields.keys).isSubset(of: ["components", "calendar", "timeZone", "isLeapMonth"]) else { throw HostStructuredCodec.invalid() }
        let components = try HostStructuredCodec.object(fields["components"])
        var numbers: [String: String] = [:]
        for (name, value) in components { numbers[name] = try HostStructuredCodec.text(value, kind: "integer") }
        var context: AutomationCalendarInput.Context?
        if let calendar = fields["calendar"] {
            let values = try HostStructuredCodec.object(calendar)
            let weekdayText = try HostStructuredCodec.text(values["firstWeekday"], kind: "integer"), daysText = try HostStructuredCodec.text(values["minimumDaysInFirstWeek"], kind: "integer")
            guard Set(values.keys).isSubset(of: ["identifier", "timeZone", "firstWeekday", "minimumDaysInFirstWeek", "locale"]),
                  let weekday = Int(weekdayText), String(weekday) == weekdayText, let days = Int(daysText), String(days) == daysText else { throw HostStructuredCodec.invalid() }
            context = .init(identifier: try HostStructuredCodec.text(values["identifier"]), timeZone: try HostStructuredCodec.text(values["timeZone"]), firstWeekday: weekday, minimumDaysInFirstWeek: days, locale: try values["locale"].map { try HostStructuredCodec.text($0) })
        }
        let zone = try fields["timeZone"].map { try HostStructuredCodec.text($0) }
        let leap = try fields["isLeapMonth"].map { try HostStructuredCodec.bool($0) }
        return try AutomationCalendarInput(components: numbers, calendar: context, timeZone: zone, isLeapMonth: leap).dateComponents()
    }
    static func encode(_ value: DateComponents) throws -> HostValue {
        let input = try AutomationCalendarInput.encode(value)
        var fields: [String: HostValue] = ["components": .init(kind: "object", properties: input.components.mapValues { .init(kind: "integer", value: $0) })]
        if let context = input.calendar {
            var values: [String: HostValue] = ["identifier": .init(kind: "text", value: context.identifier), "timeZone": .init(kind: "text", value: context.timeZone),
                "firstWeekday": .init(kind: "integer", value: String(context.firstWeekday)), "minimumDaysInFirstWeek": .init(kind: "integer", value: String(context.minimumDaysInFirstWeek))]
            if let locale = context.locale { values["locale"] = .init(kind: "text", value: locale) }
            fields["calendar"] = .init(kind: "object", properties: values)
        }
        if let zone = input.timeZone { fields["timeZone"] = .init(kind: "text", value: zone) }
        if let leap = input.isLeapMonth { fields["isLeapMonth"] = .init(kind: "bool", boolValue: leap) }
        return .init(kind: "object", properties: fields)
    }
}

enum HostIntentFileCodec {
    static func decode(_ input: HostInput) throws -> (Data, AutomationIntentFileMetadata) {
        guard input.kind == "intentFile", input.boolValue == nil, input.typeId == nil, input.properties == nil,
              input.items == nil, input.timeZone == nil, let encoded = input.value, encoded.utf8.count <= 10924,
              let metadata = input.file, let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded else { throw invalid() }
        try metadata.verify(data); return (data, metadata)
    }
    static func encode(data: Data, filename: String, typeIdentifier: String?, operationID: String) throws -> HostValue {
        guard operationID.utf8.count <= 256, operationID.range(of: #"^[A-Za-z0-9_.:-]+\z"#, options: .regularExpression) != nil else { throw invalid() }
        return .init(kind: "intentFile", value: "intents-file-" + operationID,
            file: try .init(filename: filename, typeIdentifier: typeIdentifier, data: data), fileData: data)
    }
    private static func invalid() -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "File transport input does not match its frozen codec")) }
}
