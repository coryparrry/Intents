import SwiftUI

struct JudgeConfigurationSection: View {
    @Bindable var store: EvaluationStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsPage") private var settingsPage = "mcp"

    private var connection: EvaluationJudgeConnection? {
        store.judgeConnections.first { $0.id == store.draftSuite.judgeConfiguration.connectionID }
    }

    var body: some View {
        GroupBox("Independent judge") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Judge", selection: $store.draftSuite.judgeConfiguration.mode) {
                    Text("Same model").tag(EvaluationJudgeMode.sameModel)
                    Text("Independent connection").tag(EvaluationJudgeMode.connection)
                }
                .pickerStyle(.segmented)

                if store.draftSuite.judgeConfiguration.usesExternalConnection {
                    Picker("Connection", selection: $store.draftSuite.judgeConfiguration.connectionID) {
                        Text("Choose a connection").tag(Optional<UUID>.none)
                        ForEach(store.judgeConnections) { connection in
                            Text(connection.name).tag(Optional<UUID>.some(connection.id))
                        }
                    }

                    Button("Manage judge connections…") {
                        settingsPage = "judges"
                        openSettings()
                    }
                    if store.judgeConnections.isEmpty {
                        Text("Add a local endpoint, OpenRouter, or another OpenAI-compatible connection in Settings → Judges.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        "Include reference images with the judge",
                        isOn: $store.draftSuite.judgeConfiguration.includeReferenceAttachments
                    )

                    if let connection, let disclosure = store.externalJudgeDisclosure {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Evidence disclosure", systemImage: "network.badge.shield.half.filled")
                                .font(.headline)
                            Text(disclosure)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if !store.draftSuite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection) {
                                if store.draftSuite.judgeConfiguration.externalEvidenceApprovedAt != nil {
                                    Label("Approval needs updating", systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.orange)
                                }
                                Button("Approve this evidence transfer") {
                                    store.approveExternalJudgeDisclosure()
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Label("Approved for this connection and evidence", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(12)
                        .workspaceInset(radius: 8)
                    }
                } else {
                    Text("The subject model also scores the response. Use an independent connection when model separation matters.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            }
            .padding(8)
        }
        .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)
    }
}

struct ReleasePolicySection: View {
    @Bindable var store: EvaluationStore

    var body: some View {
        GroupBox("Release check") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Require this suite for release", isOn: $store.draftSuite.releasePolicy.required)
                if store.draftSuite.releasePolicy.required {
                    Stepper(
                        "Maximum errors: \(store.draftSuite.releasePolicy.maximumErrorCount)",
                        value: $store.draftSuite.releasePolicy.maximumErrorCount,
                        in: 0...100
                    )
                    Toggle("Require an approved baseline", isOn: $store.draftSuite.releasePolicy.requireApprovedBaseline)
                    LabeledContent("Maximum pass-rate regression") {
                        TextField(
                            "0",
                            value: $store.draftSuite.releasePolicy.maximumPassRateRegression,
                            format: .percent.precision(.fractionLength(0...2))
                        )
                        .frame(width: 100)
                    }
                    LabeledContent("Maximum average latency (ms)") {
                        TextField(
                            "No limit",
                            value: $store.draftSuite.releasePolicy.maximumAverageLatencyMilliseconds,
                            format: .number
                        )
                        .frame(width: 120)
                    }
                    Text("Mark critical cases below. Missing, stale, incomplete, or incompatible evidence fails closed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(store.draftSuite.cases) { evaluationCase in
                        Toggle(
                            evaluationCase.name.isEmpty ? "Untitled case" : evaluationCase.name,
                            isOn: Binding(
                                get: { store.draftSuite.releasePolicy.criticalCaseIDs.contains(evaluationCase.id) },
                                set: { required in
                                    if required {
                                        if !store.draftSuite.releasePolicy.criticalCaseIDs.contains(evaluationCase.id) {
                                            store.draftSuite.releasePolicy.criticalCaseIDs.append(evaluationCase.id)
                                        }
                                    } else {
                                        store.draftSuite.releasePolicy.criticalCaseIDs.removeAll { $0 == evaluationCase.id }
                                    }
                                }
                            )
                        )
                    }
                }
            }
            .padding(8)
        }
        .disabled(store.isRunning || store.isProcessingFiles)
    }
}
