import SwiftUI

struct FieldAssertionsEditor: View {
    @Binding var assertions: [EvaluationFieldAssertion]?
    let scoringMode: ScoringMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("JSON field assertions").font(.headline)
                Spacer()
                Button("Add Assertion", systemImage: "plus") {
                    assertions.fieldAssertionItems.append(EvaluationFieldAssertion())
                }
                .disabled(assertions.fieldAssertionItems.count >= EvaluationFieldAssertions.maximumAssertions)
                .accessibilityIdentifier("Add field assertion")
            }
            Text("Check the complete response as JSON. Every assertion must pass in addition to the selected scoring mode. An empty pointer checks the whole response.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if scoringMode == .review, !assertions.fieldAssertionItems.isEmpty {
                Label("Choose a scoring mode or remove these assertions. Collect only does not assign pass or fail.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach($assertions.fieldAssertionItems) { $assertion in
                FieldAssertionRow(assertion: $assertion) {
                    assertions.fieldAssertionItems.removeAll { $0.id == assertion.id }
                }
            }
        }
    }
}

private struct FieldAssertionRow: View {
    @Binding var assertion: EvaluationFieldAssertion
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("JSON Pointer, e.g. /answer", text: $assertion.pointer)
                    .accessibilityLabel("Field JSON Pointer")
                    .textFieldStyle(.roundedBorder)
                Picker("Check", selection: $assertion.operation) {
                    ForEach(EvaluationFieldAssertionOperation.allCases) { operation in
                        Text(operation.title).tag(operation)
                    }
                }
                .accessibilitySelectionActions(
                    EvaluationFieldAssertionOperation.allCases,
                    selection: $assertion.operation,
                    title: \.title
                )
                .frame(maxWidth: 240)
                Button("Remove Assertion", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
            }
            if assertion.operation != .exists {
                TextField(valuePrompt, text: $assertion.expectedValue)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Assertion expected value")
            }
            if let issue = EvaluationFieldAssertions.configurationIssue(assertion) {
                Text(issue).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private var valuePrompt: String {
        switch assertion.operation {
        case .exists: ""
        case .equals: "JSON value, e.g. \"Paris\", 42, true, or null"
        case .containsText: "Required text (case-sensitive)"
        case .minimum, .maximum: "Inclusive numeric bound, e.g. 0.5"
        }
    }
}

private extension Optional where Wrapped == [EvaluationFieldAssertion] {
    var fieldAssertionItems: [EvaluationFieldAssertion] {
        get { self ?? [] }
        set { self = newValue.isEmpty ? nil : newValue }
    }
}

struct FieldAssertionEvidenceSection: View {
    let results: [EvaluationFieldAssertionResult]

    var body: some View {
        DisclosureGroup("JSON field assertions · \(results.filter(\.passed).count) of \(results.count) passed") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "\(result.assertion.pointer.isEmpty ? "Whole response" : result.assertion.pointer) · \(result.assertion.operation.title)",
                            systemImage: result.passed ? "checkmark.circle" : "xmark.circle"
                        )
                        .foregroundStyle(result.passed ? Color.green : Color.red)
                        if result.assertion.operation != .exists {
                            Text("Expected: \(result.assertion.expectedValue)")
                        }
                        if let actual = result.actualJSON { Text("Actual: \(actual)").font(.system(.caption, design: .monospaced)) }
                        Text(result.explanation).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .padding(.top, 8)
        }
    }
}
