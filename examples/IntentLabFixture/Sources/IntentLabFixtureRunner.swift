import Foundation
import FoundationEvalsDeveloper
import Observation

struct IntentLabSummaryOutput: Codable, Sendable {
    var noteID: String
    var summary: String
}

@MainActor
@Observable
final class IntentLabFixtureRunner {
    let registry: DeveloperFeatureRegistry
    let service: DeveloperRunnerService
    private(set) var isReady = false

    init() {
        let registry = DeveloperFeatureRegistry()
        self.registry = registry
        service = DeveloperRunnerService(
            identity: .current(
                id: Self.runnerID,
                displayName: "Intent Lab Fixture"
            ),
            registry: registry
        )
    }

    func prepareIfNeeded() async {
        guard !isReady else { return }
        let descriptor = DeveloperFeatureDescriptor(
            id: "intent-lab.summarize-note",
            displayName: "Summarize synthetic note",
            version: "1",
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            outputTypeName: String(reflecting: IntentLabSummaryOutput.self),
            capabilityNames: ["foundation-models", "typed-output", "synthetic-fixture"]
        )
        await registry.register(descriptor) { (input: DeveloperTextFeatureInput, context) in
            try context.checkCancellation()
            guard let note = FixtureNotes.all.first(where: {
                input.prompt.localizedCaseInsensitiveContains($0.id)
                    || input.prompt.localizedCaseInsensitiveContains($0.title)
            }) else {
                throw DeveloperExecutionFailure(
                    code: .invalidInput,
                    message: "Name a synthetic note by stable ID or title."
                )
            }
            let summary = try await SummaryService.summarize(note)
            try context.checkCancellation()
            return IntentLabSummaryOutput(noteID: note.id, summary: summary)
        } response: { $0.summary } metadata: {
            ["selectedNoteID": $0.noteID, "source": "production-summary-service"]
        }

        await registry.registerTextFeature(
            id: "intent-lab.summarize-note-broken",
            displayName: "Broken summary negative fixture",
            version: "1",
            capabilityNames: ["negative-control", "synthetic-fixture"]
        ) { _, context in
            try context.checkCancellation()
            return DeveloperFeatureOutput(
                response: "This deliberately incorrect fixture summary is not derived from the selected note.",
                metadata: ["defect": "wrong-source-note", "fixture": "negative-control"]
            )
        }
        isReady = true
    }

    private static var runnerID: UUID {
        let key = "IntentLabFixtureRunnerID"
        if let stored = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
