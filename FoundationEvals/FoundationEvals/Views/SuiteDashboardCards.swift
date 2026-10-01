import SwiftUI

struct SuiteDashboardCards: View {
    let store: EvaluationStore
    @State private var availableWidth: CGFloat = 1_000

    var body: some View {
        let layout = availableWidth < 780
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            DashboardCard("Evaluation plan", symbol: "chart.bar.xaxis") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(store.plannedSampleCount.formatted())
                        .font(.system(size: 36, weight: .medium))
                        .monospacedDigit()
                    Text("responses planned")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 14)
                HStack(spacing: 4) {
                    ForEach(0..<min(store.draftSuite.cases.count, 40), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.65))
                            .frame(height: 7)
                    }
                }
                .accessibilityHidden(true)
                HStack {
                    Text("\(store.draftSuite.cases.count) test cases")
                    Spacer()
                    Text("\(store.draftSuite.repetitions) repetitions per case")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            DashboardCard("Scoring setup", symbol: "checkmark.seal") {
                Text(store.draftSuite.scoringMode.title)
                    .font(.title2.weight(.medium))
                Spacer(minLength: 10)
                dashboardRow("Model requests", value: "Up to \(store.plannedRequestCount)")
                dashboardRow("Tool calls", value: "Up to \(store.plannedToolCallLimit)")
                dashboardRow("Suite version", value: store.draftSuite.version)
            }
            .frame(maxWidth: .infinity)

            DashboardCard("Model & workspace", symbol: "cpu") {
                Text(store.draftSuite.modelConfiguration.provider.title)
                    .font(.title2.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 10)
                dashboardRow("Saved runs", value: store.runs.count.formatted())
                dashboardRow("Storage", value: "On this Mac")
                dashboardRow("Sessions", value: "Fresh per repetition")
            }
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func dashboardRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: symbol).foregroundStyle(.tertiary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12))
        }
    }
}

struct WorkbenchStatusBar: View {
    let store: EvaluationStore

    private var selectedRun: EvaluationRun? {
        guard case .run(let id) = store.selection else { return nil }
        return store.run(with: id)
    }

    private var caseCount: Int {
        guard let run = selectedRun else { return store.draftSuite.cases.count }
        return run.plannedCases?.count ?? Set(run.results.map(\.caseID)).count
    }

    private var provider: String {
        guard let run = selectedRun else { return store.draftSuite.modelConfiguration.provider.title }
        return run.execution?.configuration.provider.title ?? "Provider not recorded"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(caseCount) case\(caseCount == 1 ? "" : "s")")
            Circle()
                .fill(store.isRunning ? Color.accentColor : Color.secondary)
                .frame(width: 5, height: 5)
            Text(store.isRunning ? "Evaluation in progress" : "\(store.runs.count) saved runs")
            Spacer()
            Text(provider)
            Text("·")
            Text("Local workspace")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
