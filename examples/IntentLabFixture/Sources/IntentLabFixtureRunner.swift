import Foundation
import FoundationEvalsDeveloper
import Observation

struct IntentLabSummaryOutput: Codable, Sendable {
    var noteID: String
    var summary: String
    var sourceContentDigest: String
    var completionID: String
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
            let note: FixtureNote
            do {
                note = try FixtureNotes.resolve(prompt: input.prompt)
            } catch {
                throw DeveloperExecutionFailure(
                    code: .invalidInput,
                    message: "Name exactly one synthetic note by stable ID or full title."
                )
            }
            FixtureState.beginSummaryAttempt(noteID: note.id)
            let summary = try await SummaryService.summarize(note)
            try context.checkCancellation()
            let receipt = try FixtureState.publishSummary(summary, for: note, route: "AppFeature")
            return IntentLabSummaryOutput(
                noteID: note.id,
                summary: summary,
                sourceContentDigest: receipt.sourceContentDigest,
                completionID: receipt.completionID
            )
        } response: { $0.summary } metadata: {
            ["selectedNoteID": $0.noteID, "sourceContentDigest": $0.sourceContentDigest,
             "completionID": $0.completionID, "source": "production-summary-service"]
        }

        await registry.registerSubjectFeature(
            id: "intent-lab.summarize-note-subject",
            displayName: "Summarize synthetic note (combined run)",
            version: "1",
            outputTypeName: String(reflecting: IntentLabSummaryOutput.self),
            inputSchema: DeveloperSubjectInputSchema(version: "1", fields: [
                .init(name: "noteID", valueType: .string)
            ]),
            capabilityNames: ["foundation-models", "typed-output", "synthetic-fixture"]
        ) { input, context in
            try context.checkCancellation()
            guard let value = input.businessInputs["noteID"],
                  case .string(let noteID) = value,
                  let note = FixtureNotes.note(id: noteID),
                  input.fixtureReferences.count == 1,
                  input.fixtureReferences[0].identifier == note.id,
                  input.fixtureReferences[0].contractDigest == FixtureNotes.contentDigest(note) else {
                throw DeveloperExecutionFailure(
                    code: .invalidInput,
                    message: "Select one synthetic note and its matching ID/title/body fixture digest."
                )
            }
            FixtureState.beginSummaryAttempt(noteID: note.id)
            let summary = try await SummaryService.summarize(note)
            try context.checkCancellation()
            let receipt = try FixtureState.publishSummary(
                summary, for: note, route: "AppFeature",
                subjectCaseID: input.caseID, subjectAttemptID: input.attemptID
            )
            let output = IntentLabSummaryOutput(
                noteID: note.id,
                summary: summary,
                sourceContentDigest: receipt.sourceContentDigest,
                completionID: receipt.completionID
            )
            return DeveloperFeatureOutput(
                response: summary,
                encodedValue: try JSONEncoder().encode(output),
                encodedValueTypeName: String(reflecting: IntentLabSummaryOutput.self),
                metadata: [
                    "selectedNoteID": note.id,
                    "sourceContentDigest": receipt.sourceContentDigest,
                    "completionID": receipt.completionID,
                    "subjectCaseID": input.caseID.uuidString,
                    "subjectAttemptID": input.attemptID.uuidString,
                    "source": "production-summary-service"
                ]
            )
        }

        #if INTENT_LAB_TEST_SUPPORT
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
        #endif
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
