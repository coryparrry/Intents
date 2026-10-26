import Foundation

/// A display projection keeps archived durations distinct from measured timeline positions.
struct WorkflowTraceNode: Identifiable {
    var id: String
    var parentID: String?
    var kind: EvaluationWorkflowSpanKind
    var title: String
    var startMilliseconds: Double?
    var durationMilliseconds: Double?
    var outcome: String
    var errorMessage: String?
    var metadata: [String: String] = [:]

    var hasIssue: Bool { ["failed", "error", "rejected", "cancelled"].contains(outcome) }
    var endMilliseconds: Double? {
        guard let startMilliseconds, let durationMilliseconds else { return nil }
        let end = startMilliseconds + durationMilliseconds
        return end.isFinite ? end : nil
    }

    /// Uses span token metadata first, falling back to attributable sample, judge, or legacy evaluation-turn usage; otherwise nil.
    func usage(in result: EvaluationSampleResult, measured: Bool) -> EvaluationUsage? {
        if let input = metadata["inputTokens"].flatMap(Int.init), let output = metadata["outputTokens"].flatMap(Int.init) {
            return EvaluationUsage(inputTokens: input, cachedInputTokens: Int(metadata["cachedInputTokens"] ?? "0") ?? 0,
                outputTokens: output, reasoningTokens: Int(metadata["reasoningTokens"] ?? "0") ?? 0)
        }
        if kind == .judge { return result.judgeUsage }
        if kind == .sample, !(result.status == .error && result.usage.totalTokens == 0) { return result.usage }
        // A failed result stores session usage, which can include preceding setup turns.
        // It cannot stand in for usage of the failed generation itself.
        if !measured, kind == .generation, metadata["role"] == nil, result.errorCategory == nil {
            return result.featureTrace?.conversation?.turns.last(where: { $0.kind == .evaluation })?.usage
        }
        return nil
    }
}

struct WorkflowTracePresentation {
    struct Row: Identifiable {
        let node: WorkflowTraceNode
        let depth: Int
        let hasChildren: Bool
        var id: String { node.id }
    }

    let nodes: [WorkflowTraceNode]
    let hasMeasuredOffsets: Bool
    let extentMilliseconds: Double

    /// Projects measured spans or legacy durations, adds untimed built-in tool records, and removes duplicate node identities.
    init(result: EvaluationSampleResult) {
        hasMeasuredOffsets = !(result.workflowTrace?.spans.isEmpty ?? true)
        var projected: [WorkflowTraceNode]
        if let trace = result.workflowTrace, !trace.spans.isEmpty {
            projected = trace.spans.map { span in
                WorkflowTraceNode(
                    id: span.id.uuidString, parentID: span.parentID?.uuidString,
                    kind: span.kind, title: span.title,
                    startMilliseconds: Self.validTime(span.startOffsetMilliseconds),
                    durationMilliseconds: Self.validTime(span.durationMilliseconds),
                    outcome: span.status.rawValue, errorMessage: span.errorMessage,
                    metadata: span.metadata
                )
            }
        } else {
            projected = Self.legacyNodes(result)
        }
        // Built-in tool transcript entries expose content, but no execution timestamps or outcome.
        let sampleID = projected.first(where: { $0.kind == .sample })?.id
        for (index, call) in (result.featureTrace?.builtinToolCalls ?? []).enumerated() {
            projected.append(WorkflowTraceNode(
                id: "builtin-\(index)-\(call.id)", parentID: sampleID,
                kind: .tool, title: call.toolName, outcome: "recorded",
                metadata: ["toolSource": "built-in", "callID": call.id,
                           "timing": "Not exposed by the framework", "scope": "Sample transcript; generating turn not recorded"]
            ))
        }
        var seen = Set<String>()
        nodes = projected.filter { seen.insert($0.id).inserted }
        extentMilliseconds = max(nodes.compactMap(\.endMilliseconds).max() ?? 0, 1)
    }

    /// Flattens the trace hierarchy around collapsed nodes while keeping orphaned and cyclic imports inspectable.
    func visibleRows(collapsed: Set<String>) -> [Row] {
        let knownIDs = Set(nodes.map(\.id))
        var children: [String: [WorkflowTraceNode]] = [:]
        var roots: [WorkflowTraceNode] = []
        for node in nodes {
            if let parent = node.parentID, parent != node.id, knownIDs.contains(parent) {
                children[parent, default: []].append(node)
            } else {
                roots.append(node)
            }
        }
        var visited = Set<String>()
        var rows: [Row] = []
        /// Visits each node once, preserving descendant structure even when an ancestor hides its rows.
        func visit(_ node: WorkflowTraceNode, depth: Int, visible: Bool) {
            guard visited.insert(node.id).inserted else { return }
            let descendants = children[node.id] ?? []
            if visible { rows.append(Row(node: node, depth: depth, hasChildren: !descendants.isEmpty)) }
            for child in descendants {
                visit(child, depth: depth + 1, visible: visible && !collapsed.contains(node.id))
            }
        }
        for root in roots { visit(root, depth: 0, visible: true) }
        // Damaged imports with cycles still remain inspectable and cannot recurse forever.
        for node in nodes where !visited.contains(node.id) { visit(node, depth: 0, visible: true) }
        return rows
    }

    /// Formats valid durations in milliseconds or seconds and uses a dash for absent or invalid measurements.
    static func duration(_ value: Double?) -> String {
        guard let value = value.flatMap(validTime) else { return "—" }
        if value >= 1_000 { return "\((value / 1_000).formatted(.number.precision(.fractionLength(2)))) s" }
        return "\(value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))) ms"
    }

    /// Accepts only finite, nonnegative timeline values.
    private static func validTime(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }

    /// Projects legacy durations and tool records without inventing start offsets or assigning tools to an unknown generation turn.
    private static func legacyNodes(_ result: EvaluationSampleResult) -> [WorkflowTraceNode] {
        var nodes = [WorkflowTraceNode(
            id: "sample", kind: .sample, title: result.caseName,
            outcome: result.status.rawValue, errorMessage: result.errorMessage,
            metadata: ["timing": "Start offsets were not recorded"]
        )]
        if let preparation = result.timing?.preparationMilliseconds {
            nodes.append(WorkflowTraceNode(id: "preparation", parentID: "sample", kind: .preparation,
                title: "Prepare input", durationMilliseconds: validTime(preparation), outcome: "recorded"))
        }
        nodes.append(WorkflowTraceNode(id: "generation", parentID: "sample", kind: .generation,
            title: result.timing?.generationMilliseconds == nil ? "Subject request" : "Generate response",
            durationMilliseconds: validTime(result.timing?.generationMilliseconds ?? result.durationMilliseconds),
            outcome: result.errorCategory == nil ? "recorded" : "failed", errorMessage: result.errorMessage))
        for call in result.featureTrace?.customToolCalls ?? [] {
            nodes.append(WorkflowTraceNode(id: call.id.uuidString, parentID: "sample", kind: .tool,
                title: call.toolName, durationMilliseconds: validTime(call.durationMilliseconds),
                outcome: call.outcome.rawValue, errorMessage: call.errorDescription,
                metadata: ["toolSource": "custom", "callID": call.id.uuidString, "toolName": call.toolName,
                           "scope": "Sample; generating turn not recorded"]))
        }
        for call in result.toolCalls ?? [] {
            nodes.append(WorkflowTraceNode(id: "reference-\(call.callIndex)", parentID: "sample", kind: .tool,
                title: call.toolName, durationMilliseconds: call.durationMilliseconds.flatMap(validTime),
                outcome: call.outcome, metadata: ["toolSource": "reference", "callIndex": String(call.callIndex),
                    "outputCharacters": String(call.outputCharacterCount), "matchedFiles": call.matchedFiles.joined(separator: ", "),
                    "scope": "Sample; generating turn not recorded"]))
        }
        if let scoring = result.timing?.scoringMilliseconds {
            nodes.append(WorkflowTraceNode(id: "scoring", parentID: "sample", kind: .scoring,
                title: "Score response", durationMilliseconds: validTime(scoring), outcome: result.status.rawValue))
        }
        if let judge = result.judgeDurationMilliseconds {
            nodes.append(WorkflowTraceNode(id: "judge", parentID: nodes.contains(where: { $0.id == "scoring" }) ? "scoring" : "sample",
                kind: .judge, title: "AI judge", durationMilliseconds: validTime(judge),
                outcome: result.judgeErrorCategory == nil ? "recorded" : "failed", errorMessage: result.judgeErrorMessage))
        }
        return nodes
    }
}
