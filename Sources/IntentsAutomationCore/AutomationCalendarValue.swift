import Foundation
import IntentsAutomationDateCodec

extension AutomationCalendarInput {
    var taggedValue: AutomationValue {
        var fields: [String: AutomationValue] = ["components": .object(components.mapValues(AutomationValue.integer))]
        if let calendar {
            var context: [String: AutomationValue] = ["identifier": .text(calendar.identifier), "timeZone": .text(calendar.timeZone),
                "firstWeekday": .integer(String(calendar.firstWeekday)), "minimumDaysInFirstWeek": .integer(String(calendar.minimumDaysInFirstWeek))]
            if let locale = calendar.locale { context["locale"] = .text(locale) }
            fields["calendar"] = .object(context)
        }
        if let timeZone { fields["timeZone"] = .text(timeZone) }
        if let isLeapMonth { fields["isLeapMonth"] = .bool(isLeapMonth) }
        return .object(fields)
    }
    init(taggedValue: AutomationValue) throws {
        try taggedValue.validate()
        func invalid() -> AutomationContractError { .invalidPlan("Calendar components do not match the declared native codec") }
        guard case .object(let fields) = taggedValue, Set(fields.keys).isSubset(of: ["components", "calendar", "timeZone", "isLeapMonth"]),
              case .object(let components) = fields["components"] else { throw invalid() }
        var numbers: [String: String] = [:]
        for (key, value) in components { guard case .integer(let text) = value else { throw invalid() }; numbers[key] = text }
        var context: Context?
        if let value = fields["calendar"] {
            guard case .object(let calendar) = value, Set(calendar.keys).isSubset(of: ["identifier", "timeZone", "firstWeekday", "minimumDaysInFirstWeek", "locale"]),
                  case .text(let id) = calendar["identifier"], case .text(let zone) = calendar["timeZone"],
                  case .integer(let weekdayText) = calendar["firstWeekday"], let weekday = Int(weekdayText), String(weekday) == weekdayText,
                  case .integer(let daysText) = calendar["minimumDaysInFirstWeek"], let days = Int(daysText), String(days) == daysText else { throw invalid() }
            var locale: String?
            if let value = calendar["locale"] { guard case .text(let text) = value else { throw invalid() }; locale = text }
            context = .init(identifier: id, timeZone: zone, firstWeekday: weekday, minimumDaysInFirstWeek: days, locale: locale)
        }
        var zone: String?, leap: Bool?
        if let value = fields["timeZone"] { guard case .text(let text) = value else { throw invalid() }; zone = text }
        if let value = fields["isLeapMonth"] { guard case .bool(let flag) = value else { throw invalid() }; leap = flag }
        self.init(components: numbers, calendar: context, timeZone: zone, isLeapMonth: leap); _ = try dateComponents()
    }
}
