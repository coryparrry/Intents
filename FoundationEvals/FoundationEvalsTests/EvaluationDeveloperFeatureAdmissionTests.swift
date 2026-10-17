import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationDeveloperFeatureAdmissionTests {
    @Test func registeredTextFeatureNeedsNoNewCapabilityMetadata() async throws {
        let registry = DeveloperFeatureRegistry()
        await registry.registerTextFeature(id: "text", displayName: "Text", version: "1") { input, _ in
            .init(response: input.prompt)
        }
        let features = await registry.descriptors
        let feature = try #require(features.first)
        #expect(feature.capabilityNames.isEmpty)
        #expect(feature.subjectInputSchema == nil)
        try EvaluationDeveloperFeatureAdapter.validate(feature)
        var unqualifiedLegacy = feature
        unqualifiedLegacy.inputTypeName = String(describing: DeveloperTextFeatureInput.self)
        try EvaluationDeveloperFeatureAdapter.validate(unqualifiedLegacy)
        var packageRunner = feature
        packageRunner.inputTypeName = "FoundationEvalsDeveloper.DeveloperTextFeatureInput"
        try EvaluationDeveloperFeatureAdapter.validate(packageRunner)

        let input = DeveloperTextFeatureInput(caseID: UUID(), instructions: "Instructions",
                                              prompt: "The app receives this prompt", expected: "Expected", repetition: 1)
        let result = await registry.execute(.init(
            runID: UUID(), featureID: feature.id, featureVersion: feature.version,
            encodedInput: try JSONEncoder().encode(input), inputTypeName: feature.inputTypeName,
            deadline: Date().addingTimeInterval(10)
        ))
        #expect(result.failure == nil)
        #expect(result.output?.response == input.prompt)
    }

    @MainActor
    @Test(arguments: ["typed", "subject"])
    func incompatibleFeatureIsRejectedBeforeCreatingOrDispatchingARun(_ kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [.init(name: "Case", prompt: "Prompt", expected: "Expected")]
        try #require(store.saveSuite(forDeveloperFeature: true))
        var feature = descriptor(inputTypeName: "Application.CustomInput")
        if kind == "subject" {
            feature.inputTypeName = String(reflecting: DeveloperSubjectInput.self)
            feature.capabilityNames = [DeveloperSubjectInputSchema.capabilityName]
        }
        let runner = snapshot(feature: feature)
        let client = DeveloperRunnerClient(desktopID: UUID(), trustStoreURL: directory.appending(path: "trust.json"))
        defer { client.shutdown() }

        do {
            _ = try await store.runDeveloperFeature(
                expectedRevision: store.currentSuiteRevision(), runner: runner, feature: feature, client: client
            )
            Issue.record("An incompatible feature must fail admission before transport dispatch.")
        } catch let error as DeveloperExecutionFailure {
            #expect(error.code == .unsupportedInputContract)
        }
        #expect(store.runs.isEmpty)
        #expect(!store.hasActiveExecution)
        #expect(client.activeRuns.isEmpty)
    }

    @MainActor
    @Test func adapterAlsoRejectsUnsupportedInputWhenCalledDirectly() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = descriptor(inputTypeName: "Application.CustomInput")
        let client = DeveloperRunnerClient(desktopID: UUID(), trustStoreURL: directory.appending(path: "trust.json"))
        defer { client.shutdown() }
        let adapter = EvaluationDeveloperFeatureAdapter(
            runID: UUID(), runner: snapshot(feature: feature), feature: feature, client: client, timeout: .seconds(1)
        )
        do {
            _ = try await adapter.evaluate(.init(caseID: UUID(), instructions: "Instructions",
                                                 prompt: "Prompt", expected: "Expected", repetition: 1))
            Issue.record("The direct adapter must validate its wire input contract.")
        } catch let error as DeveloperExecutionFailure {
            #expect(error.code == .unsupportedInputContract)
        }
        #expect(client.activeRuns.isEmpty)
    }

    @Test func subjectCapabilityCannotBeDisguisedAsALegacyTextType() {
        var feature = descriptor(inputTypeName: String(reflecting: DeveloperTextFeatureInput.self))
        feature.capabilityNames = [DeveloperSubjectInputSchema.capabilityName]
        #expect(EvaluationDeveloperFeatureAdapter.validationIssue(for: feature)?.contains("business inputs") == true)
    }

    private func descriptor(inputTypeName: String) -> DeveloperFeatureDescriptor {
        .init(id: "feature", displayName: "Feature", version: "1", inputTypeName: inputTypeName,
              outputTypeName: String(reflecting: DeveloperFeatureOutput.self))
    }

    private func snapshot(feature: DeveloperFeatureDescriptor) -> DeveloperRunnerSnapshot {
        .init(identity: .init(id: UUID(), displayName: "Fixture", platform: .iPhone,
                              operatingSystem: "iOS 27", hardwareModel: "iPhone",
                              appBundleIdentifier: "example.fixture", appVersion: "1"),
              features: [feature], state: .connected)
    }
}
