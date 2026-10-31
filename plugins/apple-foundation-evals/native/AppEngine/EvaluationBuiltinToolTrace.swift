import FoundationModels

@available(macOS 27.0, *)
struct EvaluationBuiltinToolTrace: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var toolName: String
    var argumentsJSON: String
    var output: String?

    /// Extracts only recognized vision-tool calls and their matching outputs from a transcript.
    static func visionTools<Entries: Sequence>(
        from entries: Entries
    ) -> [EvaluationBuiltinToolTrace] where Entries.Element == Transcript.Entry {
        tools(from: entries, names: EvaluationVisionToolConfiguration.knownToolNames)
    }

    /// Pairs selected transcript tool calls with later outputs by call ID, retaining bounded arguments and output evidence.
    /// Calls without a matching output remain in the returned trace with nil output.
    static func tools<Entries: Sequence>(
        from entries: Entries,
        names: Set<String>
    ) -> [EvaluationBuiltinToolTrace] where Entries.Element == Transcript.Entry {
        var traces: [EvaluationBuiltinToolTrace] = []
        var indicesByCallID: [String: Int] = [:]

        for entry in entries {
            switch entry {
            case .toolCalls(let calls):
                for call in calls where names.contains(call.toolName) {
                    indicesByCallID[call.id] = traces.count
                    traces.append(
                        EvaluationBuiltinToolTrace(
                            id: call.id,
                            toolName: call.toolName,
                            argumentsJSON: call.arguments.jsonString.boundedVisionEvidence(
                                to: EvaluationCustomToolDefinition.maximumArgumentBytes
                            ),
                            output: nil
                        )
                    )
                }
            case .toolOutput(let toolOutput):
                guard names.contains(toolOutput.toolName),
                      let index = indicesByCallID[toolOutput.id] else { continue }
                let output = toolOutput.segments.compactMap { segment -> String? in
                    switch segment {
                    case .text(let text):
                        text.content
                    case .structure(let structure):
                        structure.content.jsonString
                    case .attachment(let attachment):
                        attachment.label.map { "[Attachment: \($0)]" }
                    @unknown default:
                        "[Unsupported transcript segment]"
                    }
                }.joined(separator: "\n")
                traces[index].output = output.boundedVisionEvidence(
                    to: EvaluationCustomToolDefinition.maximumOutputBytes
                )
            default:
                // Only tool-call and tool-output entries contribute to this trace.
                continue
            }
        }
        return traces
    }

    /// Formats captured calls and available outputs as judge evidence, or returns nil when no calls were captured.
    static func evidenceText(for traces: [EvaluationBuiltinToolTrace]) -> String? {
        guard !traces.isEmpty else { return nil }
        return traces.enumerated().map { index, trace in
            var lines = [
                "Built-in tool call \(index + 1): \(trace.toolName)",
                "Arguments: \(trace.argumentsJSON)"
            ]
            if let output = trace.output {
                lines.append("Output: \(output)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

@available(macOS 27.0, *)
private extension String {
    /// Returns the longest whole-character prefix that fits the UTF-8 byte budget.
    func boundedVisionEvidence(to maximumBytes: Int) -> String {
        guard utf8.count > maximumBytes else { return self }
        var bytes = 0
        return String(prefix { character in
            let count = String(character).utf8.count
            guard bytes + count <= maximumBytes else { return false }
            bytes += count
            return true
        })
    }
}
