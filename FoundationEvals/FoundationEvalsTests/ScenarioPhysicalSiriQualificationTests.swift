import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

/// Opt-in qualification of the repository's synthetic fixture, through the actual native executor.
struct ScenarioPhysicalSiriQualificationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_PHYSICAL_SIRI_QUALIFICATION_PROFILE"] != nil, "Requires an explicit approved synthetic physical fixture profile"))
    func signedSyntheticFixtureUsesSharedOwnershipAndCorrelatedSiriEvidence() async throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_PHYSICAL_SIRI_QUALIFICATION_PROFILE"] else { throw QualificationError.invalidProfile }
        struct Profile: Decodable {
            var repository: String; var targetUDID: String; var supportRoot: String
            var xcodebuildWrapper: String; var leaseStorePath: String; var fixtureResetApproved: Bool; var siriLanguage: String
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let fields = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        guard Set(fields.keys) == ["repository", "targetUDID", "supportRoot", "xcodebuildWrapper", "leaseStorePath", "fixtureResetApproved", "siriLanguage"] else { throw QualificationError.invalidProfile }
        let profile = try JSONDecoder().decode(Profile.self, from: bytes)
        guard profile.fixtureResetApproved, profile.siriLanguage == "en-GB", !profile.targetUDID.isEmpty,
              profile.supportRoot.hasPrefix("/private/tmp/"), profile.xcodebuildWrapper.hasPrefix(profile.supportRoot + "/") else {
            throw QualificationError.invalidProfile
        }
        let repo = URL(fileURLWithPath: profile.repository).resolvingSymlinksInPath()
        guard repo == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath(),
              profile.leaseStorePath == "/private/tmp/intents-automation-canonical-campaign/target-leases.json" else { throw QualificationError.invalidProfile }
        let fixture = repo.appendingPathComponent("examples/IntentLabFixture")
        let project = fixture.appendingPathComponent("IntentLabFixture.xcodeproj")
        let root = URL(fileURLWithPath: profile.supportRoot)
        let persistence = ScenarioPersistence(rootDirectory: root.appendingPathComponent("IntentLab"))
        let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("IntentLab/Executor"), persistence: persistence,
            physicalLeaseStoreURL: URL(fileURLWithPath: profile.leaseStorePath))
        let discovered = try XcodeConnectionDiscoveryService(xcodebuildPath: profile.xcodebuildWrapper).discoverProject(container: project)
        let app = try #require(discovered.applications.first { $0.bundleIdentifier == "com.coryparry.IntentLabFixture" })
        let tests = try #require(discovered.uiTestBundles.first { $0.targetName == "IntentLabFixtureV2UITests" })
        let manifestData = try Data(contentsOf: fixture.appendingPathComponent("UITests/IntentLabIntegration.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.reusableSchemaVersion
        definition.target.projectPath = project.path; definition.target.scheme = "IntentLabFixtureV2"
        definition.target.testTarget = "IntentLabFixtureV2UITests"; definition.target.destinationIdentifier = profile.targetUDID
        definition.fixture.preparationOperation = "resetFixture"; definition.fixture.cleanupOperation = "resetFixture"
        definition.coverage.appFeature = .notApplicable; definition.coverage.siri = .required; definition.coverage.siriAttemptCount = 3
        definition.purpose = .releaseRequirement; definition.checkMode = .behaviour
        definition.requiredClaims = [.executionCompleted, .applicationStateChecked]
        definition.observationPlan = [
            .init(id: "selectedNoteID", source: .uiElement, selector: "intent-lab-selected-note-id"),
            .init(id: "noteStoreMutationCount", source: .uiElement, selector: "intent-lab-mutation-count"),
            .init(id: "invocationContext", source: .uiElement, selector: "intent-lab-observed-context"),
            .init(id: "applicationEvent", source: .uiElement, selector: "intent-lab-last-event"),
        ]
        definition.integration = .init(id: try #require(manifest["id"] as? String), version: try #require(manifest["version"] as? String),
            digest: SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined())
        definition.directControl.outputFields = [.init(name: "openedNoteID", type: .primitive(.string), path: [.init(kind: .property, name: "value")])]
        definition = try definition.frozen(); try ScenarioValidator.validate(definition)
        try await persistence.saveDefinition(definition)
        let configuration = XcodeTestConfiguration(containerPath: project.path, isWorkspace: false, scheme: "IntentLabFixtureV2",
            testTarget: "IntentLabFixtureV2UITests", testBundleIdentifier: tests.bundleIdentifier, destinationIdentifier: profile.targetUDID,
            generatedResourceDirectory: fixture.appendingPathComponent("UITests/Generated").path,
            harnessVersion: tests.harnessVersion, harnessCapabilities: tests.harnessCapabilities,
            applicationSigningConfigured: app.signingConfigured, testSigningConfigured: tests.signingConfigured,
            xcodebuildPath: profile.xcodebuildWrapper, selectedTestProductID: tests.id, selectedApplicationProductID: app.id)
        print("Physical qualification: checking the signed synthetic fixture connection on exact target \(profile.targetUDID)")
        _ = try await executor.verifyConnection(definition: definition, configuration: configuration, projectTrusted: true)
        print("Physical qualification: connection runner independently released; executing direct baseline and three Siri attempts")
        let execution = try await executor.execute(definition: definition, configuration: configuration, projectTrusted: true)
        var ledger = try await persistence.loadLedger(), runs: [ScenarioRun] = []
        for attachment in execution.evidenceAttachments {
            var run = try XCTestEvidenceImporter().importEvidence(data: Data(contentsOf: attachment.url), definition: definition,
                journal: execution.journal, artifactRoot: execution.attachmentDirectory, ledger: &ledger)
            run.xctestExitCode = execution.processExitCode
            if execution.processExitCode != 0 { run.executionStatus = .invalidEvidence; run.outcome = .needsReview }
            runs.append(try await persistence.saveRun(run, artifactRoot: execution.attachmentDirectory))
        }
        try await persistence.saveLedger(ledger)
        let accepted = execution.journal.physicalRunner?.released == true && execution.journal.physicalRunner?.receiptError == nil
            && ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(attachments: execution.evidenceAttachments, runs: runs, xctestExitCode: execution.processExitCode)
        try await executor.finishEvidenceValidation(journal: execution.journal, accepted: accepted)
        if accepted { for run in runs { _ = try await persistence.acceptRun(run, journal: execution.journal) } }
        #expect(execution.reportedTestCount == 1)
        #expect(execution.processExitCode == 0)
        #expect(execution.journal.physicalRunner?.receipt != nil)
        #expect(accepted)
        #expect(!runs.isEmpty)
        #expect(runs.allSatisfy { $0.laneResults.filter { $0.lane != .appFeature }.allSatisfy { $0.executionStatus == .completed && $0.outcome == .passed } })
        print("Physical qualification: original business evidence saved; accepted=\(accepted); ownership receipt=\(execution.journal.physicalRunner?.receipt != nil)")
    }
    private enum QualificationError: Error { case invalidProfile }
}
