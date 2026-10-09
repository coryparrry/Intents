import Foundation

/// Preserves relative as well as absolute components; it never invents a calendar or time zone.
public struct AutomationCalendarInput: Codable, Equatable, Sendable {
    public struct Context: Codable, Equatable, Sendable {
        public var identifier: String
        public var timeZone: String
        public var firstWeekday: Int
        public var minimumDaysInFirstWeek: Int
        public var locale: String?
        public init(identifier: String, timeZone: String, firstWeekday: Int, minimumDaysInFirstWeek: Int, locale: String? = nil) {
            self.identifier = identifier; self.timeZone = timeZone; self.firstWeekday = firstWeekday; self.minimumDaysInFirstWeek = minimumDaysInFirstWeek; self.locale = locale
        }
        func calendar() throws -> Calendar {
            let id: Calendar.Identifier
            switch identifier { case "gregorian": id = .gregorian; case "iso8601": id = .iso8601; default: throw AutomationCalendarInput.invalid() }
            guard timeZone.utf8.count <= 128, let zone = TimeZone(identifier: timeZone), (1...7).contains(firstWeekday), (1...7).contains(minimumDaysInFirstWeek) else { throw AutomationCalendarInput.invalid() }
            if let locale {
                guard locale.utf8.count <= 128, locale.isEmpty || Locale.availableIdentifiers.contains(locale), Locale(identifier: locale).identifier == locale else { throw AutomationCalendarInput.invalid() }
            }
            var calendar = Calendar(identifier: id); calendar.locale = locale.map(Locale.init(identifier:)); calendar.timeZone = zone
            calendar.firstWeekday = firstWeekday; calendar.minimumDaysInFirstWeek = minimumDaysInFirstWeek
            return calendar
        }
    }
    public var components: [String: String]
    public var calendar: Context?
    public var timeZone: String?
    public var isLeapMonth: Bool?
    public init(components: [String: String], calendar: Context? = nil, timeZone: String? = nil, isLeapMonth: Bool? = nil) {
        self.components = components; self.calendar = calendar; self.timeZone = timeZone; self.isLeapMonth = isLeapMonth
    }
    private static let fields: [String: Calendar.Component] = [
        "era": .era, "year": .year, "month": .month, "day": .day, "hour": .hour, "minute": .minute, "second": .second,
        "nanosecond": .nanosecond, "weekday": .weekday, "weekdayOrdinal": .weekdayOrdinal, "quarter": .quarter,
        "weekOfMonth": .weekOfMonth, "weekOfYear": .weekOfYear, "yearForWeekOfYear": .yearForWeekOfYear, "dayOfYear": .dayOfYear,
    ]
    public func dateComponents() throws -> DateComponents {
        guard components.count <= Self.fields.count, Set(components.keys).isSubset(of: Set(Self.fields.keys)) else { throw Self.invalid() }
        var value = DateComponents()
        for (name, text) in components {
            guard text.count <= 20, let number = Int(text), String(number) == text, number != Int.max, let field = Self.fields[name] else { throw Self.invalid() }
            value.setValue(number, for: field)
            guard value.value(for: field) == number else { throw Self.invalid() }
        }
        if let calendar { value.calendar = try calendar.calendar() }
        if let timeZone {
            guard timeZone.utf8.count <= 128, let zone = TimeZone(identifier: timeZone),
                  value.calendar.map({ $0.timeZone == zone }) ?? true else { throw Self.invalid() }
            value.timeZone = zone
        }
        value.isLeapMonth = isLeapMonth
        return value
    }
    public static func encode(_ value: DateComponents) throws -> Self {
        var components: [String: String] = [:]
        for (name, field) in fields { if let number = value.value(for: field) { components[name] = String(number) } }
        var context: Context?
        if let calendar = value.calendar {
            let id: String
            switch calendar.identifier { case .gregorian: id = "gregorian"; case .iso8601: id = "iso8601"; default: throw invalid() }
            context = .init(identifier: id, timeZone: calendar.timeZone.identifier, firstWeekday: calendar.firstWeekday, minimumDaysInFirstWeek: calendar.minimumDaysInFirstWeek, locale: calendar.locale?.identifier)
        }
        let input = Self(components: components, calendar: context, timeZone: value.timeZone?.identifier, isLeapMonth: value.isLeapMonth)
        guard try input.dateComponents() == value else { throw invalid() }
        return input
    }
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 4096, let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["components", "calendar", "timeZone", "isLeapMonth"]), fields["components"] != nil,
              !fields.values.contains(where: { $0 is NSNull }) else { throw invalid() }
        if let calendar = fields["calendar"] {
            guard let context = calendar as? [String: Any], Set(context.keys).isSubset(of: ["identifier", "timeZone", "firstWeekday", "minimumDaysInFirstWeek", "locale"]), Set(["identifier", "timeZone", "firstWeekday", "minimumDaysInFirstWeek"]).isSubset(of: Set(context.keys)), !context.values.contains(where: { $0 is NSNull }) else { throw invalid() }
        }
        let input = try JSONDecoder().decode(Self.self, from: data); _ = try input.dateComponents(); return input
    }
    private static func invalid() -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported calendar components or context; quoted exact components and explicit supported calendar settings are required")) }
}
