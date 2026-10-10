import Foundation
import Testing
@testable import FoundationEvals
@testable import IntentsAutomationCore

struct ScenarioAutomationEvidenceTests {
    @Test func additiveNativeImportKeepsLegacyRunsAndOpaqueRunJSONArtifactsSeparate() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/scenario-automation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root.appendingPathComponent("IntentLab"))
        let storedLegacy = try await persistence.saveRun(legacyRun(), artifactRoot: nil)
        let source = root.appendingPathComponent("Automation")
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "sim", kind: .simulator)
        let segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "Navigate", requiredCapabilities: [], effects: [.navigate], lifecycle: .persistedStateAcrossSegments)
        let plan = AutomationCase(id: "navigation", app: app, target: target, environmentID: "env", execution: segment)
        let cases = try AutomationCaseStore(root: source.appendingPathComponent("Cases"))
        let frozen = try await cases.freeze(plan)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
        let artifactRoot = source.appendingPathComponent("attempt/artifacts")
        let registry = try AutomationArtifactRegistry(root: artifactRoot, secretEvidenceRoot: source.appendingPathComponent("secret-evidence"))
        var artifact = try await registry.store(data: Data("Opaque bytes, not a legacy ScenarioRun".utf8), name: "opaque.json", scope: scope)
        artifact.handle = "run.json"
        try JSONEncoder().encode([artifact.handle: artifact]).write(to: artifactRoot.appendingPathComponent("artifact-index.json"))
        let receipt = AutomationSegmentReceipt(scope: scope, app: app, target: target, segmentID: "subject", route: .ui, dispatched: true, completed: true, observations: [], artifact: artifact.handle, environmentID: "env")
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [])
        let report = AutomationAttemptReport(attemptID: "attempt", result: result, receipts: [receipt], resourcesReleased: true)
        try await cases.saveAttempt(report, for: frozen)
        let authority = try AutomationEvidenceExposureAuthority(supportRoot: source)
        let exposure = try authority.reserve(frozen: frozen, attempts: [report])
        let imported = try await persistence.importAutomationEvidence(plan: plan, report: report, sourceRoot: source, exposure: exposure)
        let snapshot = try await persistence.loadAutomationEvidence(authority: authority)
        #expect(snapshot?.documents == [imported])
        #expect(imported.report == report)
        #expect(imported.acquisitionTrust == "historicalUnverified")
        #expect(!imported.liveAccepted)
        #expect(imported.artifacts.first?.relativePath == "Artifacts/run.json")
        let legacyRuns = try await persistence.loadRuns()
        #expect(legacyRuns == [storedLegacy])
        let page = try await persistence.loadRunPage(scenarioID: nil, offset: 0, limit: 10)
        #expect(page.runs == [storedLegacy])
        #expect(page.totalCount == 1)
        #expect(!page.hasMore)
        #expect(page.runs.first?.acceptanceStatus == .pending)
        #expect(page.runs.first?.laneResults.first?.claims == nil)
        #expect(page.runs.first?.laneResults.first?.observationSources == ["title": .applicationInstrumentation])
        #expect(imported.report.result.summary == .executedUnassessed)
    }

    private func legacyRun() -> ScenarioRun {
        let date = Date(timeIntervalSince1970: 1000), scenarioID = UUID()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: "legacy-nonce", issuedAt: date,
            testIdentity: .init(bundleIdentifier: "example.LegacyTests", className: "LegacyTests", methodName: "testFeature"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "legacy-device", scenarioDigest: "original-legacy-digest", resultBundleIdentity: "legacy-xcresult"
        )
        let environment = ScenarioEnvironment(
            xcodeVersion: "27", sdkVersion: "27", deviceModel: "Legacy device", operatingSystem: "iOS 27",
            languageCode: "en-GB", regionCode: "GB", timeZoneIdentifier: "Europe/London", executedAt: date
        )
        let lane = ScenarioLaneResult(caseID: scenarioID, attempt: 1, lane: .appFeature, executionStatus: .completed,
                                      outcome: .needsReview, startedAt: date, completedAt: date,
                                      observationSources: ["title": .applicationInstrumentation])
        return ScenarioRun(id: UUID(), scenarioID: scenarioID, scenarioVersion: 1, scenarioDigest: invocation.scenarioDigest,
                           invocation: invocation, startedAt: date, completedAt: date, environment: environment,
                           executionStatus: .completed, outcome: .needsReview, laneResults: [lane], importedAt: date)
    }
}
