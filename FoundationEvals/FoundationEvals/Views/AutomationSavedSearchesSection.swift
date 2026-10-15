import SwiftUI
import IntentsAutomationCore

struct AutomationSavedSearchesSection: View {
    let records: [AutomationUIFailureSearchRecord]
    let busy: Bool
    let onShow: (AutomationUIFailureSearchRecord) -> Void

    var body: some View {
        GroupBox("Saved searches") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(records, id: \.id) { record in
                    AutomationSavedSearchRow(title: record.baseline.plan.execution.operation, busy: busy) {
                        onShow(record)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
}

private struct AutomationSavedSearchRow: View {
    let title: String
    let busy: Bool
    let onShow: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).lineLimit(2)
            }
            Spacer()
            Button("View search", action: onShow).disabled(busy)
        }
    }
}
