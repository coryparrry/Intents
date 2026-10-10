import SwiftUI
import IntentsAutomationCore

struct AppAutomationDateInput: View {
    let name: String
    @Binding var rawInput: String?
    private var input: AutomationDateInput? {
        rawInput.flatMap { try? JSONDecoder().decode(AutomationDateInput.self, from: Data($0.utf8)) }
    }
    private var date: Date? {
        guard let text = input?.value else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: text)
    }
    var body: some View {
        if let date, let input {
            DatePicker(name, selection: Binding(get: { date }, set: { save($0, zone: input.timeZone) }), displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, TimeZone(identifier: input.timeZone) ?? .gmt)
            TextField("Time zone", text: Binding(get: { input.timeZone }, set: { save(date, zone: $0) }))
                .help("For example, Europe/London or UTC. The selected instant and time zone are retained in this check.")
        } else {
            Button("Choose " + name) { save(Date(), zone: TimeZone.current.identifier) }
        }
    }
    private func save(_ date: Date, zone: String) {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Retain invalid edits for the existing validation message; they never enable Run.
        let value = AutomationDateInput(value: formatter.string(from: date), timeZone: zone)
        rawInput = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}
