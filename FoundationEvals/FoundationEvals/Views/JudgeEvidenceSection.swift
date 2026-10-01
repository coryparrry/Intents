import SwiftUI

struct JudgeEvidenceSection: View {
    let trace: EvaluationJudgeTrace

    var body: some View {
        DisclosureGroup("Scoring evidence") {
            VStack(alignment: .leading, spacing: 12) {
                if let error = trace.validationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let checks = trace.checks {
                    ForEach(checks, id: \.criterionIndex) { check in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Requirement \(check.criterionIndex) · \(check.score)/4")
                                .font(.caption.weight(.semibold))
                            Text(check.criterion)
                            Text(check.rationale).foregroundStyle(.secondary)
                            ForEach(Array(check.exactComparisons.enumerated()), id: \.offset) { _, comparison in
                                Text("Exact comparison verified by Swift: \(comparison.matches ? "matches" : "differs") · \(String(reflecting: comparison.expectedText))")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
                if let indexes = trace.judgedCriterionIndexes {
                    Text(indexes.isEmpty ? "All requirements were checked deterministically. No AI judge was called."
                         : "AI judge check order maps to rubric requirements: " + indexes.map(String.init).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !trace.instructions.isEmpty { evidence("Judge instructions", text: trace.instructions) }
                if !trace.prompt.isEmpty { evidence("Exact judge input", text: trace.prompt) }
                if let response = trace.rawResponse {
                    evidence("Raw judge verdict", text: response)
                }
                if let attempts = trace.attempts, attempts.count > 1 {
                    DisclosureGroup("All judge attempts (\(attempts.count))") {
                        ForEach(Array(attempts.enumerated()), id: \.offset) { index, attempt in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Attempt \(index + 1)").font(.caption.weight(.semibold))
                                if let error = attempt.validationError {
                                    Text(error).foregroundStyle(.orange)
                                }
                                evidence("Input", text: attempt.prompt)
                                if let raw = attempt.rawResponse { evidence("Raw verdict", text: raw) }
                            }
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.top, 10)
        }
        .font(.callout)
    }

    private func evidence(_ title: String, text: String) -> some View {
        DisclosureGroup(title) {
            Text(text)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        }
    }
}
