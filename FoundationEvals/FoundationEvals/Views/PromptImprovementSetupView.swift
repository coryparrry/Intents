import SwiftUI

struct PromptImprovementSetupView: View {
    let suite: EvaluationSuite
    @Binding var heldOutCaseIDs: Set<UUID>
    let issue: String?
    let configure: (() -> Void)?
    @State private var choosesExamples = false
    @State private var showsInstructions = false

    private var finalCount: Int { heldOutCaseIDs.count }
    private var practiceCount: Int { suite.cases.count - finalCount }
    private var budget: Int? { PromptImprovementPresentation.maximumSamples(suite: suite, heldOutCaseIDs: heldOutCaseIDs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            EditorSection("How it works", description: "Improve the shared instructions that guide every response in this suite.") {
                step("1", title: "Try two suggestions", detail: "Intents uses practice examples to write and compare new instructions.")
                step("2", title: "Run a final check", detail: "Separate examples check that the best suggestion still works on something new.")
                step("3", title: "Review before saving", detail: "You choose whether to use the suggestion. Nothing changes automatically.")
            }
            EditorSection("Your examples", description: "We’ve set aside a few cases for the final check. You can change this selection.") {
                HStack(spacing: 24) {
                    count(practiceCount, title: "Practice", symbol: "pencil.and.list.clipboard")
                    Divider().frame(height: 40)
                    count(finalCount, title: "Final check", symbol: "checkmark.shield")
                    Spacer()
                }
                DisclosureGroup("Choose examples", isExpanded: $choosesExamples) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Check the cases to save for the final check. Leave the others for practice. Use fresh final-check cases for each comparison.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                        ForEach(suite.cases) { test in
                            Toggle(isOn: Binding(
                                get: { heldOutCaseIDs.contains(test.id) },
                                set: { if $0 { heldOutCaseIDs.insert(test.id) } else { heldOutCaseIDs.remove(test.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(test.name.isEmpty ? "Untitled case" : test.name).font(.callout.weight(.medium))
                                    Text(heldOutCaseIDs.contains(test.id) ? "Final check" : "Practice")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Save \(test.name.isEmpty ? "untitled case" : test.name) for final check")
                            if test.id != suite.cases.last?.id { Divider() }
                        }
                    }
                }
                if let issue {
                    WorkspaceNotice(.warning, message: issue) {
                        if let configure {
                            Button(suite.cases.count < 2 ? "Add cases" : "Edit scoring", action: configure)
                                .accessibilityIdentifier("Configure instruction comparison")
                        }
                    }
                }
            }
            DisclosureGroup("Current instructions", isExpanded: $showsInstructions) {
                Text(suite.instructions.isEmpty ? "No shared instructions yet. Intents will suggest a starting point." : suite.instructions)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            .font(.callout).padding(16).workspaceSurface()
            Label {
                Text("Suggestions are written on this Mac. Comparisons use your suite’s model, tools, references and scoring, including an approved external judge.\(budget.map { " Up to \($0) responses may be generated, plus two suggestions." } ?? "")")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "info.circle") }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Instruction comparison setup")
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func count(_ value: Int, title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value) \(value == 1 ? "example" : "examples")").font(.headline)
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
