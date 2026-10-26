import SwiftUI

struct ProductionBatchOutcomeSummary: View {
    let job: ProductionJob
    let report: ProductionReport?
    let isRunning: Bool
    let detailedReport: () -> Void

    private var attention: Int { guard let report else { return 0 }; return report.counts.errors + report.counts.unscored + report.counts.uncertain }
    private var mark: WorkspaceStatusMark.State {
        if isRunning { return .running }
        guard let report else { return .idle }
        if report.counts.failed > 0 { return .failed }
        if attention > 0 || report.phase != "completed" || report.exitCode != 0 { return .attention }
        return .passed
    }
    private var headline: String {
        if isRunning { return "Collecting responses" }
        guard let report else { return "Loading results…" }
        if report.phase != "completed" { return "This batch is \(report.phase)" }
        if report.counts.failed > 0 { return "Some responses failed their checks" }
        if attention > 0 { return "Some responses need attention" }
        return report.exitCode == 0 ? "All responses passed their checks" : "Some release checks need attention"
    }

    /// Presents batch identity and audited outcome counts using the native report components.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.createdAt, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text(job.name).font(.largeTitle.weight(.bold)).lineLimit(2)
                    }
                    Spacer(minLength: 16)
                    WorkspacePill(isRunning ? "Running" : report?.phase.capitalized ?? "Loading", color: .secondary)
                }
                WorkspaceFlowLayout(spacing: 16, lineSpacing: 6) {
                    WorkspaceMetaLabel("\(job.plannedCount.formatted()) responses", symbol: "text.bubble")
                    WorkspaceMetaLabel("\(job.configuration.targets.count) targets", symbol: "desktopcomputer")
                    WorkspaceMetaLabel("\(job.configuration.repetitions) trials", symbol: "repeat")
                    Button("Detailed report", action: detailedReport).buttonStyle(.link)
                }.font(.callout).foregroundStyle(.secondary)
            }
            if let report {
                HStack(alignment: .center, spacing: 32) {
                    HStack(alignment: .top, spacing: 14) {
                        WorkspaceStatusMark(state: mark, size: 30)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(headline).font(.title2.weight(.semibold))
                            Text(isRunning ? "Saved responses appear below while this batch runs." : "Select a response below to read it and see its outcome.")
                                .font(.callout).foregroundStyle(.secondary)
                            WorkspaceProportionBar(segments: [
                                .init(count: report.counts.passed, color: WorkspaceStyle.success),
                                .init(count: report.counts.failed, color: WorkspaceStyle.failure),
                                .init(count: attention, color: WorkspaceStyle.warning),
                                .init(count: max(0, report.planned - report.completed), color: Color.secondary.opacity(0.25))
                            ], height: 6).frame(maxWidth: 320).padding(.top, 8)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .top, spacing: 30) {
                        WorkspaceFigure(title: "Passed", value: report.counts.passed.formatted())
                        WorkspaceFigure(title: "Failed", value: report.counts.failed.formatted())
                        if attention > 0 { WorkspaceFigure(title: "To review", value: attention.formatted()) }
                        WorkspaceFigure(title: "Collected", value: "\(report.completed)/\(report.planned)")
                    }.fixedSize()
                }.padding(24).workspaceSurface()
            }
        }
    }
}
