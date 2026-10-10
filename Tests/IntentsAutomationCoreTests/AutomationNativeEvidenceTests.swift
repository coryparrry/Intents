import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationNativeEvidenceTests: XCTestCase {
    func testReadOnlySourceRejectsAliasesMissingStoresAndWritesWithoutCreatingDirectories() async throws {
        let (root, source, frozen, report, archive) = try await fixture(complete: false)
        let missing = root.appendingPathComponent("MissingSource")
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: missing, exposure: try exposure(source, frozen, report)); XCTFail("Created missing source") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let alias = root.appendingPathComponent("AliasedSource")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias.appendingPathComponent("Cases"), withDestinationURL: source.appendingPathComponent("Cases"))
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: alias, exposure: try exposure(source, frozen, report)); XCTFail("Followed Cases alias") } catch {}
        let store = try AutomationCaseStore(readOnlyRoot: source.appendingPathComponent("Cases"))
        var changed = frozen.plan; changed.id = "missing-definition"
        do { _ = try await store.freeze(changed); XCTFail("Wrote through read-only store") } catch {}
        do { try await store.saveAttempt(report, for: frozen); XCTFail("Saved through read-only store") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("Cases/Definitions/missing-definition").path))
    }
    func testUnpublishedAttemptDirectoriesCountTowardHistoryTraversalLimit() async throws {
        let (root, source, frozen, _, archive) = try await fixture(complete: false)
        let caseRoot = root.appendingPathComponent("IntentLab/Runs/AppAutomation/" + frozen.digest)
        try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
        for index in 0..<1001 {
            let key = AutomationArtifactRegistry.digest(Data("unpublished-\(index)".utf8))
            try FileManager.default.createDirectory(at: caseRoot.appendingPathComponent(key), withIntermediateDirectories: false)
        }
        do { _ = try await archive.snapshot(authority: try AutomationEvidenceExposureAuthority(supportRoot: source)).documents; XCTFail("Traversed unlimited unpublished attempts") } catch {}
    }
    func testDestinationAliasCannotCreateAttemptDirectoryOutsideArchive() async throws {
        let (root, source, frozen, report, archive) = try await fixture(complete: false)
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("IntentLab/Runs/AppAutomation/" + frozen.digest), withDestinationURL: outside)
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report)); XCTFail("Followed destination alias") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testArtifactDirectoryAliasCannotWriteOutsideOrPublishDocument() async throws {
        let (root, source, frozen, report, archive) = try await fixture()
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = AutomationArtifactRegistry.digest(Data(report.attemptID.utf8))
        let attempt = root.appendingPathComponent("IntentLab/Runs/AppAutomation/" + frozen.digest + "/" + key)
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: attempt.appendingPathComponent("Artifacts"), withDestinationURL: outside)
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report)); XCTFail("Followed artifact directory alias") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempt.appendingPathComponent("evidence.json").path))
    }
    private func exposure(_ source: URL, _ frozen: AutomationFrozenCase, _ report: AutomationAttemptReport) throws -> AutomationEvidenceExposure {
        try AutomationEvidenceExposureAuthority(supportRoot: source).reserve(frozen: frozen, attempts: [report])
    }
    private func fixture(complete: Bool = true, assessed: Bool = false) async throws -> (URL, URL, AutomationFrozenCase, AutomationAttemptReport, AutomationNativeEvidenceArchive) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("native-evidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Automation")
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "sim", kind: .simulator)
        let segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "Navigate", requiredCapabilities: [], effects: [.navigate], lifecycle: .persistedStateAcrossSegments)
        var plan = AutomationCase(id: "navigation", app: app, target: target, environmentID: "env", execution: segment)
        plan.observations = [.init(id: "observe", kind: complete ? .ui : .observeOnly, phase: .observe, operation: "Read state", requiredCapabilities: [], effects: [.observe], lifecycle: .persistedStateAcrossSegments)]
        if assessed {
            plan.requirements = [.init(observationID: "observe", expected: .text("Tasks"), proof: .visibleState,
                justification: "Synthetic recorded visible state")]
        }
        let cases = try AutomationCaseStore(root: source.appendingPathComponent("Cases")), frozen = try await cases.freeze(plan)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2)
        var observations: [AutomationObservation] = [], artifact: String?
        if complete {
            let registry = try AutomationArtifactRegistry(root: source.appendingPathComponent("attempt/artifacts"), secretEvidenceRoot: source.appendingPathComponent("secret-evidence"))
            let stored = try await registry.store(data: Data("Actual opaque artifact bytes".utf8), name: "ui.json", scope: scope)
            artifact = stored.handle
            var observation = AutomationObservation(id: "observe", app: app, target: target, environmentID: "env", attemptID: "attempt", stepID: "observe", route: .ui, proof: .visibleState, value: .text("Tasks"))
            observation.collectedAt = Date(timeIntervalSince1970: 1000)
            observations = [observation]
        }
        let receipt = AutomationSegmentReceipt(scope: scope, app: app, target: target, segmentID: "subject", route: .ui, dispatched: true, completed: complete, observations: [], artifact: artifact, environmentID: "env")
        var result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: complete, observations: observations, termination: complete ? nil : .unresolved)
        if !complete { result.subjectDispatchUncertain = true }
        var receipts = [receipt]
        if complete {
            receipts.append(.init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "observe", leaseGeneration: 3), app: app, target: target, segmentID: "observe", route: .ui, dispatched: true, completed: true, observations: observations, environmentID: "env"))
        }
        let report = AutomationAttemptReport(attemptID: "attempt", result: result, receipts: receipts, resourcesReleased: complete)
        try await cases.saveAttempt(report, for: frozen)
        let archive = try AutomationNativeEvidenceArchive(root: root.appendingPathComponent("IntentLab/Runs/AppAutomation"))
        return (root, source, frozen, report, archive)
    }
    func testImportIsIdempotentPreservesUnassessedNavigationAndOriginalArtifactBytes() async throws {
        let (root, source, frozen, report, archive) = try await fixture()
        let originalURL = source.appendingPathComponent("Cases/Attempts/" + frozen.digest + "/attempt.json")
        let original = try Data(contentsOf: originalURL)
        let first = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        let second = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        XCTAssertEqual(first, second); XCTAssertEqual(first.report, report)
        XCTAssertEqual(first.schemaVersion, 3); XCTAssertEqual(first.evidenceTrust, "recordedFacts")
        XCTAssertFalse(first.report.result.assessed); XCTAssertEqual(first.report.result.summary, .executedUnassessed)
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        let saved = try await archive.snapshot(authority: try AutomationEvidenceExposureAuthority(supportRoot: source)).documents; XCTAssertEqual(saved, [first])
        XCTAssertEqual(first.artifacts.count, 1)
        let artifact = first.artifacts[0], key = AutomationArtifactRegistry.digest(Data(report.attemptID.utf8))
        let copied = root.appendingPathComponent("IntentLab/Runs/AppAutomation/" + frozen.digest + "/" + key + "/" + artifact.relativePath)
        XCTAssertEqual(try Data(contentsOf: copied), Data("Actual opaque artifact bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("acceptance.json").path))
    }
    func testRecordedPassRemainsHistoricalAndImportedFieldsCannotGrantLiveAcceptance() async throws {
        let (_, source, frozen, report, archive) = try await fixture(assessed: true)
        XCTAssertEqual(report.result.summary, .passed)
        XCTAssertTrue(report.result.assessed)
        let document = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        XCTAssertEqual(document.report, report)
        XCTAssertEqual(document.acquisitionTrust, "historicalUnverified")
        XCTAssertFalse(document.liveAccepted)
        let saved = try await archive.snapshot(authority: try AutomationEvidenceExposureAuthority(supportRoot: source)).documents
        XCTAssertEqual(saved, [document])
        XCTAssertFalse(try XCTUnwrap(saved.first).liveAccepted)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        payload["acquisitionTrust"] = "liveAccepted"; payload["liveAccepted"] = true
        let decoded = try JSONDecoder().decode(AutomationNativeEvidenceDocument.self, from: JSONSerialization.data(withJSONObject: payload))
        try decoded.validate()
        XCTAssertEqual(decoded.acquisitionTrust, "historicalUnverified")
        XCTAssertFalse(decoded.liveAccepted)
        XCTAssertEqual(decoded.report, report)
    }
    func testTimelinePreservesRouteProofTimestampAndUnresolvedMissingReceipt() async throws {
        let (_, source, frozen, report, archive) = try await fixture(complete: false)
        let document = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        XCTAssertTrue(document.report.result.subjectDispatchUncertain); XCTAssertFalse(document.report.resourcesReleased)
        let steps = try AutomationNativeEvidenceTimeline.steps(document)
        XCTAssertEqual(steps.map(\.id), ["subject", "observe"])
        XCTAssertEqual(steps[0].route, .ui); XCTAssertFalse(try XCTUnwrap(steps[0].receipt).completed)
        XCTAssertNil(steps[1].receipt); XCTAssertFalse(document.report.result.assessed)
        let (_, fullSource, fullFrozen, fullReport, fullArchive) = try await fixture()
        let full = try await fullArchive.importAttempt(frozen: fullFrozen, report: fullReport, sourceRoot: fullSource, exposure: try exposure(fullSource, fullFrozen, fullReport))
        let observation = try XCTUnwrap(AutomationNativeEvidenceTimeline.steps(full)[1].receipt?.observations.first)
        XCTAssertEqual(observation.proof, .visibleState); XCTAssertEqual(observation.route, .ui)
        XCTAssertEqual(observation.collectedAt, Date(timeIntervalSince1970: 1000))
    }
    func testWrongRouteReportChangedFactsAndArtifactScopeCannotEnterNativeResults() async throws {
        let (_, source, frozen, report, archive) = try await fixture()
        var changed = report; changed.receipts[0].route = .siriText
        do { _ = try await archive.importAttempt(frozen: frozen, report: changed, sourceRoot: source, exposure: try exposure(source, frozen, report)); XCTFail("Accepted substituted route") } catch {}
        changed = report; changed.result.summary = .passed
        do { _ = try await archive.importAttempt(frozen: frozen, report: changed, sourceRoot: source, exposure: try exposure(source, frozen, report)); XCTFail("Accepted invented pass") } catch {}
        let indexURL = source.appendingPathComponent("attempt/artifacts/artifact-index.json")
        var index = try JSONDecoder().decode([String: AutomationArtifactRegistry.Artifact].self, from: Data(contentsOf: indexURL))
        let handle = try XCTUnwrap(report.receipts[0].artifact)
        index[handle]?.scope.attemptId = "foreign"
        try JSONEncoder().encode(index).write(to: indexURL)
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report)); XCTFail("Accepted foreign artifact scope") } catch {}
    }
    func testSourceArtifactAndCopiedArtifactSymlinksOrByteDriftFailClosed() async throws {
        let (root, source, frozen, report, archive) = try await fixture()
        let document = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        let key = AutomationArtifactRegistry.digest(Data(report.attemptID.utf8)), artifact = document.artifacts[0]
        let copied = root.appendingPathComponent("IntentLab/Runs/AppAutomation/" + frozen.digest + "/" + key + "/" + artifact.relativePath)
        try Data("changed".utf8).write(to: copied)
        do { _ = try await archive.snapshot(authority: try AutomationEvidenceExposureAuthority(supportRoot: source)).documents; XCTFail("Accepted changed copied bytes") } catch {}
        let outside = root.appendingPathComponent("outside.json"); try Data("Actual opaque artifact bytes".utf8).write(to: outside)
        try FileManager.default.removeItem(at: copied)
        try FileManager.default.createSymbolicLink(at: copied, withDestinationURL: outside)
        do { _ = try await archive.snapshot(authority: try AutomationEvidenceExposureAuthority(supportRoot: source)).documents; XCTFail("Followed copied alias") } catch {}
        let index = try JSONDecoder().decode([String: AutomationArtifactRegistry.Artifact].self, from: Data(contentsOf: source.appendingPathComponent("attempt/artifacts/artifact-index.json")))
        let original = source.appendingPathComponent("attempt/artifacts/" + index[artifact.handle]!.relativePath)
        try FileManager.default.removeItem(at: original); try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report)); XCTFail("Followed source alias") } catch {}
    }
    func testTaintedRunCannotImportPreviouslyRegisteredArtifactsOrExportDerivedReport() async throws {
        let (root, source, frozen, report, archive) = try await fixture()
        let fence = try AutomationSecretEvidenceFence(root: source.appendingPathComponent("secret-evidence"))
        try fence.restrict(report.receipts[0].scope)
        XCTAssertThrowsError(try exposure(source, frozen, report))
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source); XCTFail("Imported without exposure permission") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("IntentLab/Runs/AppAutomation/" + frozen.digest).path))
        for compressed in [false, true] {
            let output = root.appendingPathComponent(UUID().uuidString + ".intentscase")
            let approval = AutomationCapsuleExportApproval(caseDigest: frozen.digest, attemptIDs: [report.attemptID], syntheticDataAndMetadataReviewed: true)
            XCTAssertThrowsError(try compressed
                ? AutomationCaseCapsule.exportCompressed(frozen: frozen, attempts: [report], approval: approval, to: output)
                : AutomationCaseCapsule.export(frozen: frozen, attempts: [report], approval: approval, to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
    func testExposureRetainsCampaignLockForPreviewAndBothCapsulePublications() async throws {
        let (root, source, frozen, report, _) = try await fixture()
        var permit: AutomationEvidenceExposure? = try exposure(source, frozen, report)
        let fence = try AutomationSecretEvidenceFence(root: source.appendingPathComponent("secret-evidence"))
        XCTAssertThrowsError(try fence.restrict(report.receipts[0].scope))
        let approval = AutomationCapsuleExportApproval(caseDigest: frozen.digest, attemptIDs: [report.attemptID], syntheticDataAndMetadataReviewed: true)
        for compressed in [false, true] {
            let output = root.appendingPathComponent(UUID().uuidString + ".intentscase")
            if compressed { try AutomationCaseCapsule.exportCompressed(frozen: frozen, attempts: [report], approval: approval, exposure: permit, to: output) }
            else { try AutomationCaseCapsule.export(frozen: frozen, attempts: [report], approval: approval, exposure: permit, to: output) }
            XCTAssertEqual(try AutomationCaseCapsule.read(output).historicalAttempts, [report])
            XCTAssertThrowsError(try fence.restrict(report.receipts[0].scope))
        }
        withExtendedLifetime(permit) {}; permit = nil
        try fence.restrict(report.receipts[0].scope)
        XCTAssertThrowsError(try exposure(source, frozen, report))
    }
    func testArchivedSnapshotRequiresCurrentFenceAndRetainsItWhileDisplayed() async throws {
        let (_, source, frozen, report, archive) = try await fixture()
        _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        do { _ = try await archive.documents(); XCTFail("Read archived facts without authority") } catch {}
        let authority = try AutomationEvidenceExposureAuthority(supportRoot: source)
        var snapshot: AutomationNativeEvidenceSnapshot? = try await archive.snapshot(authority: authority)
        XCTAssertEqual(snapshot?.documents.first?.report, report)
        let fence = try AutomationSecretEvidenceFence(root: source.appendingPathComponent("secret-evidence"))
        XCTAssertThrowsError(try fence.restrict(report.receipts[0].scope))
        withExtendedLifetime(snapshot) {}; snapshot = nil
        try fence.restrict(report.receipts[0].scope)
        do { _ = try await archive.snapshot(authority: authority); XCTFail("Read archive after taint") } catch {}
    }
    func testExposureBindsExactPlanAndEveryReportByteBeforePublication() async throws {
        let (root, source, frozen, report, archive) = try await fixture()
        let permit = try exposure(source, frozen, report)
        var changed = report; changed.resourcesReleased.toggle()
        do { _ = try await archive.importAttempt(frozen: frozen, report: changed, sourceRoot: source, exposure: permit); XCTFail("Reused permit for changed report") } catch {}
        var changedPlan = frozen.plan; changedPlan.id = "different"
        let changedFrozen = try AutomationFrozenCase(plan: changedPlan)
        let output = root.appendingPathComponent("changed.intentscase")
        XCTAssertThrowsError(try AutomationCaseCapsule.exportCompressed(frozen: changedFrozen, attempts: [report], approval: .init(caseDigest: changedFrozen.digest, attemptIDs: [report.attemptID], syntheticDataAndMetadataReviewed: true), exposure: permit, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testForeignCampaignRootCannotAuthorizeImportOrArchivedRead() async throws {
        let (root, source, frozen, report, archive) = try await fixture()
        let foreign = root.appendingPathComponent("foreign-support")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let wrongAuthority = try AutomationEvidenceExposureAuthority(supportRoot: foreign)
        let wrongPermit = try wrongAuthority.reserve(frozen: frozen, attempts: [report])
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: wrongPermit); XCTFail("Imported using foreign root") } catch {}
        _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        do { _ = try await archive.snapshot(authority: wrongAuthority); XCTFail("Read archive using foreign root") } catch {}
        try AutomationSecretEvidenceFence(root: source.appendingPathComponent("secret-evidence")).restrict(report.receipts[0].scope)
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: wrongPermit); XCTFail("Copied tainted artifacts using unrelated clean root") } catch {}
    }
    func testDecodedHiddenSingularReceiptCannotBypassValidatedPluralScopes() async throws {
        let (_, source, frozen, report, _) = try await fixture()
        var hidden = report.receipts[1]; hidden.scope.runId = "tainted-hidden-run"
        hidden.observations[0].value = .text("synthetic-secret-sentinel")
        var json = try JSONSerialization.jsonObject(with: AutomationFrozenCase.canonicalData(report)) as! [String: Any]
        json["receipt"] = try JSONSerialization.jsonObject(with: AutomationFrozenCase.canonicalData(hidden))
        let decoded = try JSONDecoder().decode(AutomationAttemptReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNotNil(decoded.receipt)
        XCTAssertThrowsError(try exposure(source, frozen, decoded))
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: decoded, plan: frozen.plan))
    }
    func testRenderedPresentationRetainsExposureAfterSnapshotIsReleased() async throws {
        let (_, source, frozen, report, archive) = try await fixture()
        _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        var snapshot: AutomationNativeEvidenceSnapshot? = try await archive.snapshot(authority: AutomationEvidenceExposureAuthority(supportRoot: source))
        var presentation = snapshot?.presentations.first
        snapshot = nil
        let fence = try AutomationSecretEvidenceFence(root: source.appendingPathComponent("secret-evidence"))
        XCTAssertThrowsError(try fence.restrict(report.receipts[0].scope))
        withExtendedLifetime(presentation) {}; presentation = nil
        try fence.restrict(report.receipts[0].scope)
    }

    func testFailedForeignImportCannotPinAnUnprovenPopulatedLegacyArchive() async throws {
        let (root, source, frozen, report, archive) = try await fixture()
        _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: source, exposure: try exposure(source, frozen, report))
        let pin = root.appendingPathComponent("IntentLab/Runs/AppAutomation/campaign-root.json")
        try FileManager.default.removeItem(at: pin)
        try AutomationSecretEvidenceFence(root: source.appendingPathComponent("secret-evidence")).restrict(report.receipts[0].scope)
        let foreign = root.appendingPathComponent("foreign-support")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let wrongAuthority = try AutomationEvidenceExposureAuthority(supportRoot: foreign)
        let permit = try wrongAuthority.reserve(frozen: frozen, attempts: [report])
        do { _ = try await archive.importAttempt(frozen: frozen, report: report, sourceRoot: foreign, exposure: permit); XCTFail("Accepted missing foreign source") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: pin.path))
        do { _ = try await archive.snapshot(authority: wrongAuthority); XCTFail("Exposed unproven old archive") } catch {}
        // Even a valid unrelated source may not claim the populated old archive.
        let cases = try AutomationCaseStore(root: foreign.appendingPathComponent("Cases"))
        let foreignFrozen = try await cases.freeze(frozen.plan)
        var withoutArtifact = report; withoutArtifact.receipts[0].artifact = nil
        try await cases.saveAttempt(withoutArtifact, for: foreignFrozen)
        let validPermit = try wrongAuthority.reserve(frozen: foreignFrozen, attempts: [withoutArtifact])
        do { _ = try await archive.importAttempt(frozen: foreignFrozen, report: withoutArtifact, sourceRoot: foreign, exposure: validPermit); XCTFail("Rebound old archive") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: pin.path))
    }

}
