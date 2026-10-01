import SwiftUI

struct WorkflowTraceView: View {
    let run: EvaluationRun
    @State private var sampleID: UUID?

    private var sample: EvaluationSampleResult? {
        run.results.first(where: { $0.id == sampleID }) ?? run.results.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("WORKFLOW TRACE")
                            .font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                        Text(run.suiteName).font(.title2.weight(.semibold)).lineLimit(1)
                        Text("\(run.execution?.modelDisplayName ?? run.environment.model) · \(run.scoringMode.title)")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 10)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        Text("\(run.results.count) / \(run.plannedResultCount) samples")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let sample {
                    HStack(spacing: 24) {
                        TraceSummaryMetric(title: "Outcome", value: sample.status.rawValue.capitalized,
                            color: sample.status == .passed ? .green : sample.status == .unscored ? .secondary : .red)
                        TraceSummaryMetric(title: "Workflow", value: WorkflowTracePresentation.duration(
                            sample.workflowTrace?.spans.first(where: { $0.kind == .sample })?.durationMilliseconds))
                        TraceSummaryMetric(title: "Subject request", value: WorkflowTracePresentation.duration(sample.durationMilliseconds))
                        TraceSummaryMetric(title: "Subject tokens", value: sample.usage.totalTokens == 0 && sample.status == .error
                            ? "Unavailable" : sample.usage.totalTokens.formatted())
                        TraceSummaryMetric(title: "First content", value: WorkflowTracePresentation.duration(sample.featureTrace?.firstContentMilliseconds))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Case", selection: Binding(get: { sample.id }, set: { sampleID = $0 })) {
                        ForEach(run.results) { result in
                            Text("\(result.caseName) · repetition \(result.repetition)").tag(result.id)
                        }
                    }
                    .accessibilityIdentifier("Trace case")
                    .frame(maxWidth: 560)
                }
            }
            .padding(20)
            Divider()
            if let sample {
                WorkflowSampleInspector(result: sample, run: run)
                    .id(sample.id)
            } else {
                ContentUnavailableView("No recorded samples", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("This run ended before a sample was saved."))
            }
        }
    }
}

private struct TraceSummaryMetric: View {
    let title: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WorkflowSampleInspector: View {
    let result: EvaluationSampleResult
    let run: EvaluationRun
    private let trace: WorkflowTracePresentation
    @State private var selection: String?
    @State private var collapsed: Set<String> = []

    init(result: EvaluationSampleResult, run: EvaluationRun) {
        self.result = result
        self.run = run
        self.trace = WorkflowTracePresentation(result: result)
    }

    private var selected: WorkflowTraceNode? {
        trace.nodes.first(where: { $0.id == selection }) ?? trace.nodes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("\(trace.nodes.count) spans", systemImage: "point.3.connected.trianglepath.dotted")
                    .fontWeight(.medium)
                Text("·").foregroundStyle(.tertiary)
                Text(trace.hasMeasuredOffsets ? "App-observed timing" : "Saved durations")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Expand all spans", systemImage: "arrow.up.left.and.arrow.down.right") { collapsed.removeAll() }
                    .labelStyle(.iconOnly)
                Button("Collapse all spans", systemImage: "arrow.down.right.and.arrow.up.left") {
                    collapsed = Set(trace.nodes.map(\.id))
                    selection = trace.visibleRows(collapsed: collapsed).first?.id
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 10)
            if !trace.hasMeasuredOffsets {
                Text("Start offsets were not recorded for this saved sample. Durations are shown without timeline placement.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            HSplitView {
                WorkflowWaterfall(trace: trace, selection: $selection, collapsed: $collapsed)
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                if let selected {
                    WorkflowSpanDetail(node: selected, result: result, run: run, trace: trace)
                        .frame(minWidth: 250, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
                }
            }
        }
        .onAppear { selection = trace.nodes.first?.id }
    }
}

private struct WorkflowWaterfall: View {
    let trace: WorkflowTracePresentation
    @Binding var selection: String?
    @Binding var collapsed: Set<String>
    @FocusState private var isFocused: Bool
    private var rows: [WorkflowTracePresentation.Row] { trace.visibleRows(collapsed: collapsed) }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = max(geometry.size.width, 0)
            let labelWidth = min(240, max(120, viewportWidth * 0.30))
            let durationWidth: CGFloat = 65
            let startWidth: CGFloat = 80
            let timelineWidth = max(1, viewportWidth - labelWidth - durationWidth - startWidth - 32)
            let scale = WorkflowTimelineScale(
                boundaries: trace.nodes.flatMap { [$0.startMilliseconds, $0.endMilliseconds].compactMap { $0 } },
                extent: trace.extentMilliseconds, width: timelineWidth)
            VStack(alignment: .leading, spacing: 0) {
                if trace.hasMeasuredOffsets {
                    Text("Expanded time scale · Short steps spaced apart · Exact durations shown")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Span").frame(width: labelWidth, alignment: .leading)
                        Text("Start").padding(.trailing, 8).frame(width: startWidth, alignment: .trailing)
                        TraceTimeAxis(scale: scale, available: trace.hasMeasuredOffsets)
                            .frame(width: timelineWidth, height: 28)
                        Text("Duration").frame(width: durationWidth, alignment: .trailing)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.25))
                    Divider()
                    ScrollViewReader { proxy in
                        List(selection: $selection) {
                            ForEach(rows) { row in
                                HStack(spacing: 0) {
                                    spanLabel(row).frame(width: labelWidth, alignment: .leading)
                                    Text(row.node.startMilliseconds.map { "+" + WorkflowTracePresentation.duration($0) } ?? "—")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.trailing, 8)
                                        .frame(width: startWidth, alignment: .trailing)
                                    TraceDurationBar(node: row.node, scale: scale)
                                        .frame(width: timelineWidth, height: 34)
                                    Text(WorkflowTracePresentation.duration(row.node.durationMilliseconds))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: durationWidth, alignment: .trailing)
                                }
                                .tag(row.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowSeparator(.visible)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(row.node.title)
                                .accessibilityIdentifier("Trace span \(row.id)")
                                .accessibilityValue("\(row.node.outcome), \(WorkflowTracePresentation.duration(row.node.durationMilliseconds))")
                            }
                        }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 34)
                        .accessibilityIdentifier("Workflow spans")
                        .focusable()
                        .focusEffectDisabled()
                        .focused($isFocused)
                        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
                        .overlay {
                            Rectangle().strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .onChange(of: selection) { _, selected in
                            if let selected { proxy.scrollTo(selected) }
                        }
                        .onKeyPress(.downArrow) {
                            moveSelection(by: 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveSelection(by: -1)
                            return .handled
                        }
                        .onKeyPress(.rightArrow) {
                            guard let selection else { return .ignored }
                            collapsed.remove(selection)
                            return .handled
                        }
                        .onKeyPress(.leftArrow) {
                            guard let selection, let row = rows.first(where: { $0.id == selection }) else { return .ignored }
                            if row.hasChildren && !collapsed.contains(selection) { collapsed.insert(selection) }
                            else { self.selection = row.node.parentID ?? selection }
                            return .handled
                        }
                    }
                }
                .frame(width: viewportWidth)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex(where: { $0.id == selection }) ?? 0
        selection = rows[min(max(current + offset, 0), rows.count - 1)].id
    }

    @ViewBuilder
    private func spanLabel(_ row: WorkflowTracePresentation.Row) -> some View {
        if row.hasChildren {
            Button {
                selection = row.id
                if collapsed.contains(row.id) { collapsed.remove(row.id) }
                else { collapsed.insert(row.id) }
            } label: {
                spanLabelContent(row)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(collapsed.contains(row.id) ? "Expand" : "Collapse") \(row.node.title)")
        } else {
            spanLabelContent(row)
        }
    }

    private func spanLabelContent(_ row: WorkflowTracePresentation.Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12)
                .opacity(row.hasChildren ? 1 : 0)
                .accessibilityHidden(true)
            Image(systemName: row.node.symbol).font(.system(size: 11))
                .foregroundStyle(row.node.color).frame(width: 12)
            Text(row.node.title).font(.system(size: 12, weight: row.depth == 0 ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
                .help(row.node.title)
        }
        .padding(.leading, CGFloat(min(row.depth, 8)) * 12)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .contentShape(Rectangle())
    }

}

private struct TraceTimeAxis: View {
    let scale: WorkflowTimelineScale
    let available: Bool
    var body: some View {
        GeometryReader { geometry in
            if available {
                let divisions = geometry.size.width >= 320 ? 4 : geometry.size.width >= 160 ? 2 : geometry.size.width >= 90 ? 1 : 0
                ForEach(0...divisions, id: \.self) { tick in
                    let fraction = Double(tick) / Double(max(1, divisions))
                    Text(WorkflowTracePresentation.duration(scale.time(at: geometry.size.width * fraction)))
                        .font(.system(size: 9).monospacedDigit())
                        .fixedSize()
                        .position(x: max(15, min(geometry.size.width - 20, geometry.size.width * fraction)), y: 14)
                }
            } else {
                Text("Timeline unavailable").font(.caption2).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct TraceDurationBar: View {
    let node: WorkflowTraceNode
    let scale: WorkflowTimelineScale
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ForEach(0..<5) { tick in
                    Rectangle().fill(.quaternary).frame(width: 1)
                        .offset(x: geometry.size.width * CGFloat(tick) / 4)
                }
                if let start = node.startMilliseconds, let end = node.endMilliseconds {
                    let interval = WorkflowTimelineInterval(start: start, end: end, scale: scale)
                    SolidTimelineBar(
                        width: interval.displayWidth, offset: interval.displayOffset,
                        color: node.color.opacity(node.kind == .sample ? 0.60 : 0.85)
                    )
                } else {
                    Text("Not recorded").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

extension WorkflowTraceNode {
    var color: Color {
        if outcome == "cancelled" { return .orange }
        if hasIssue { return .red }
        return switch kind {
        case .sample: .indigo
        case .preparation: .teal
        case .generation: .blue
        case .scoring: .purple
        case .judge: .pink
        case .tool: .green
        case .httpRequest: .orange
        }
    }
    var symbol: String {
        if outcome == "cancelled" { return "stop.circle" }
        if hasIssue { return "exclamationmark.circle" }
        return switch kind {
        case .sample: "point.3.connected.trianglepath.dotted"
        case .preparation: "text.alignleft"
        case .generation: "sparkles"
        case .scoring: "checkmark.seal"
        case .judge: "scale.3d"
        case .tool: "wrench.and.screwdriver"
        case .httpRequest: "network"
        }
    }
}
