import SwiftUI
import AppIntents
import FoundationEvalsDeveloper

@main
struct IntentLabFixtureApp: App {
    @State private var runner = IntentLabFixtureRunner()

    init() {
        FixtureShortcuts.updateAppShortcutParameters()
        #if INTENT_LAB_TEST_SUPPORT
        let contextArgument = argument(after: "-intent-lab-context")
        let operationID = argument(after: "-intent-lab-operation") ?? "resetFixture"
        if CommandLine.arguments.contains("-intent-lab-cleanup") {
            if let contextArgument {
                _ = try? FixtureTestSupport.cleanup(operationID: operationID, context: contextArgument)
            }
        } else if CommandLine.arguments.contains("-intent-lab-reset") {
            // Siri activation can outlast the phone’s normal auto-lock interval.
            // Keep only this test fixture awake for its lifetime.
            UIApplication.shared.isIdleTimerDisabled = true
            if let contextArgument {
                _ = try? FixtureTestSupport.prepare(operationID: operationID, context: contextArgument)
            }
        } else if let contextArgument {
            FixtureState.begin(context: contextArgument)
        } else {
            FixtureState.begin(context: "app-\(UUID().uuidString)")
        }
        #else
        FixtureState.begin(context: "app-\(UUID().uuidString)")
        #endif
    }

    private func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Fixture", systemImage: "note.text") }
                NavigationStack {
                    if runner.isReady {
                        DeveloperRunnerView(service: runner.service)
                    } else {
                        ProgressView("Registering feature…")
                    }
                }
                .tabItem { Label("Runner", systemImage: "antenna.radiowaves.left.and.right") }
            }
            .task { await runner.prepareIfNeeded() }
        }
    }
}

struct ContentView: View {
    @AppStorage(FixtureState.selectedNoteKey) private var selectedNoteID = "none"
    @AppStorage(FixtureState.mutationCountKey) private var mutationCount = 0
    @AppStorage(FixtureState.observedContextKey) private var observedContext = "none"
    @AppStorage(FixtureState.eventKey) private var lastEvent = "none"
    @AppStorage(FixtureState.summaryReceiptKey) private var summaryReceiptData = Data()
    @AppStorage(FixtureState.actionReceiptsKey) private var actionReceiptData = Data()
    @State private var summarizingNoteID: String?
    @State private var summaryError: String?

    private var summaryReceipt: FixtureSummaryReceipt? {
        try? JSONDecoder().decode(FixtureSummaryReceipt.self, from: summaryReceiptData)
    }

    private var actionReceiptsJSON: String {
        FixtureState.actionReceiptsJSON(from: actionReceiptData)
    }

    private var preparedFixtureDigestsJSON: String {
        let digests = FixtureTestSupport.snapshot().fixtureDigests
        guard let data = try? JSONEncoder().encode(digests) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        NavigationStack {
            List(FixtureNotes.all) { note in
                VStack(alignment: .leading) {
                    Text(note.title).font(.headline)
                    Text(note.body).foregroundStyle(.secondary)
                    Button("Summarize \(note.title)") {
                        Task { await summarize(note) }
                    }
                    .disabled(summarizingNoteID != nil)
                }
            }
            .navigationTitle("Synthetic notes")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let summarizingNoteID {
                        ProgressView("Summarizing \(summarizingNoteID)…")
                    }
                    if let summaryError {
                        Text(summaryError).foregroundStyle(.red)
                            .accessibilityIdentifier("intent-lab-summary-error")
                    }
                    if let summaryReceipt {
                        Text(summaryReceipt.summary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("intent-lab-visible-summary")
                        Text(summaryReceipt.noteID).accessibilityIdentifier("intent-lab-summary-source-note-id")
                        Text(summaryReceipt.sourceContentDigest).accessibilityIdentifier("intent-lab-summary-source-digest")
                        Text(summaryReceipt.context).accessibilityIdentifier("intent-lab-summary-context")
                        Text(summaryReceipt.completionID).accessibilityIdentifier("intent-lab-summary-completion-id")
                        if let caseID = summaryReceipt.subjectCaseID {
                            Text(caseID.uuidString).accessibilityIdentifier("intent-lab-summary-case-id")
                        }
                        if let attemptID = summaryReceipt.subjectAttemptID {
                            Text(attemptID.uuidString).accessibilityIdentifier("intent-lab-summary-attempt-id")
                        }
                    }
                    Text(selectedNoteID).accessibilityIdentifier("intent-lab-selected-note-id")
                    Text(preparedFixtureDigestsJSON)
                        .accessibilityIdentifier("intent-lab-fixture-digests")
                    if let selectedNote = FixtureNotes.note(id: selectedNoteID) {
                        Text(FixtureNotes.contentDigest(selectedNote))
                            .accessibilityIdentifier("intent-lab-fixture-digest")
                    }
                    Text(String(mutationCount)).accessibilityIdentifier("intent-lab-mutation-count")
                    Text(observedContext).accessibilityIdentifier("intent-lab-observed-context")
                    Text(lastEvent).accessibilityIdentifier("intent-lab-last-event")
                    Text("Action receipts")
                        .accessibilityLabel(actionReceiptsJSON)
                        .accessibilityIdentifier("intentlab.actionReceipts")
                        .font(.system(size: 1))
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                    Text(FixtureTestSupport.snapshotJSON())
                        .accessibilityIdentifier("intentlab.fixtureSnapshot")
                        .font(.system(size: 1))
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                }
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.ultraThinMaterial)
            }
        }
    }

    @MainActor
    private func summarize(_ note: FixtureNote) async {
        summarizingNoteID = note.id
        summaryError = nil
        FixtureState.beginSummaryAttempt(noteID: note.id)
        defer { summarizingNoteID = nil }
        do {
            let summary = try await SummaryService.summarize(note)
            try FixtureState.publishSummary(summary, for: note, route: "AppUI")
        } catch {
            summaryError = error.localizedDescription
        }
    }
}
