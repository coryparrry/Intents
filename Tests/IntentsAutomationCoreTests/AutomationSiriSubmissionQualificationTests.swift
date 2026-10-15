#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

struct SiriSubmissionQualificationTestFixture {
    let plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile, prepared: AutomationPreparedApplication
    static func make() throws -> Self {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        let action = ApplicationSurfaceCatalog.SystemAction(id: "SetStateIntent", typeName: "SetStateIntent", title: "Set task state",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity"), .init(name: "completed", family: "bool", optional: false)],
            parametersComplete: true, compiled: true, registered: true, executed: false, resultFamily: "noValue")
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false,
            gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        let capabilities = CapabilityProfile(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "apple.intent.invoke", "apple.codec.bool", "apple.codec.entity", "siri.recognizedText.api"].map {
            ($0, CapabilityProfile.Record(state: .available, reason: "synthetic contract fixture", probeVersion: "test", evidence: []))
        }))
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "disposable-account", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        let original = try AutomationSiriEntityPlanner.compile(catalog: catalog, entityType: "TaskEntity", nameProperty: "title", recordName: "Approved task",
            stateProperty: "completed", initialState: false, expectedState: true, request: "Complete Approved task in Example", approval: approval, capabilities: capabilities)
        let plan = try AutomationSiriRepeatableQualification.restoring(original, catalog: catalog, actionID: action.id, approval: approval, capabilities: capabilities)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let host = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: "/synthetic/run.xctestrun", xctestrunDigest: String(repeating: "b", count: 64),
            subjectProductPath: "/synthetic/Subject.app", hostBundlePath: "/synthetic/Owned-Runner.app", hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Owned")
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: "/synthetic", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "/synthetic", scheme: "Owned", targetID: "HOST", bundleID: host.hostBundleID, configuration: "Debug", templateDigest: String(repeating: "d", count: 64), includesSiri: true),
            host: host, catalog: catalog, buildLogPath: "/synthetic/build.log", buildLogTruncated: false)
        return .init(plan: plan, approval: approval, capabilities: capabilities, prepared: prepared)
    }
    static func report(plan: AutomationCase, approval: RunApproval, attemptID: String, after: Bool = false,
                       initial: Bool = false, afterID: String = "real-id") -> AutomationAttemptReport {
        func records(_ state: Bool, _ id: String) -> AutomationValue { .array([.object(["entity": .entity(typeID: "TaskEntity", value: id),
            "properties": .object(["title": .text("Approved task"), "completed": .bool(state)])])]) }
        let observed = records(after, afterID)
        let observation = AutomationObservation(id: plan.observations[0].id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: attemptID, stepID: plan.observations[0].id, route: .systemQuery, proof: .appState, value: observed)
        let receipts = (plan.setup + [plan.execution] + plan.observations).enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: index + 1),
                app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [observation] : [], artifact: segment.kind == .siriText ? "synthetic-owned-submission" : nil,
                verifiedOutputs: segment.kind == .systemQuery ? ["record": segment.phase == .observe ? observed : records(initial, "real-id")] : nil,
                environmentID: plan.environmentID)
        }
        let result = AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: true, subjectCompleted: true,
            observations: [observation], receipts: receipts, runID: approval.runID)
        return .init(attemptID: attemptID, result: result, receipts: receipts, resourcesReleased: true)
    }
    static func submission(plan: AutomationCase, report: AutomationAttemptReport) throws -> AutomationImportedSiriSubmission {
        let scope = report.receipts.first { $0.route == .siriText }!.scope
        let program = plan.execution.siriProgram!
        let fields: AutomationJSON = .object(["schemaVersion": .number(3), "runID": .string(scope.runId), "attemptID": .string(scope.attemptId),
            "segmentID": .string(scope.segmentId), "leaseGeneration": .number(Double(scope.leaseGeneration)), "bundleID": .string(plan.app.bundleID),
            "productDigest": .string(plan.app.productDigest!), "requestDigest": .string(program.requestDigest), "submissionStarted": .bool(true),
            "submissionReturned": .bool(true), "submittedRecognizedText": .string(program.request), "osBuild": .string("24B5028f"),
            "runner": .object(["pid": .number(42), "startIdentity": .string("1:2"), "executablePath": .string("/private/var/containers/Bundle/Application/00000000-0000-0000-0000-000000000001/Owned-Runner.app/Owned-Runner")])])
        return try AutomationSiriSubmissionReceipt.importReceipt(JSONEncoder().encode(fields), scope: scope, app: plan.app, program: program)
    }
}

final class AutomationSiriSubmissionQualificationTests: XCTestCase, @unchecked Sendable {
    func testTwoDeterministicBusinessFailuresQualifyExactSubmissionChannel() async throws {
        let f = try SiriSubmissionQualificationTestFixture.make(), registry = AutomationSiriQualificationAuthority()
        for id in ["one", "two"] {
            let report = SiriSubmissionQualificationTestFixture.report(plan: f.plan, approval: f.approval, attemptID: id)
            XCTAssertEqual(report.result.summary, .assertionFailed)
            XCTAssertTrue(report.result.assessed); XCTAssertTrue(report.result.evidenceComplete)
            try await registry.record(prepared: f.prepared, plan: f.plan, approval: f.approval, report: report,
                submission: SiriSubmissionQualificationTestFixture.submission(plan: f.plan, report: report))
        }
        let authority = await registry.admission(prepared: f.prepared, plan: f.plan, approval: f.approval)
        XCTAssertTrue(try XCTUnwrap(authority).isRepeatableQualification)
        try AutomationSiriRepeatableQualification.validate(plan: f.plan, approval: f.approval, authority: authority)
    }
    func testBusinessFailureCannotQualifyMissingAmbiguousForeignPartialOrUnreleasedSubmission() async throws {
        let f = try SiriSubmissionQualificationTestFixture.make()
        let original = SiriSubmissionQualificationTestFixture.report(plan: f.plan, approval: f.approval, attemptID: "one")
        let submitted = try SiriSubmissionQualificationTestFixture.submission(plan: f.plan, report: original)
        for index in 0..<13 {
            let registry = AutomationSiriQualificationAuthority()
            var report = original, submission = submitted
            switch index {
            case 0: report.resourcesReleased = false
            case 1: report.result.subjectDispatchUncertain = true
            case 2: report.result.subjectCompleted = false
            case 3: report.result.subjectDispatched = false
            case 4: report.result.summary = .infrastructureFailed
            case 5: report.receipts[3].artifact = nil
            case 6: report.receipts[3].completed = false
            case 7: report.receipts.removeLast()
            case 8: report = SiriSubmissionQualificationTestFixture.report(plan: f.plan, approval: f.approval, attemptID: "one", initial: true)
            case 9: report = SiriSubmissionQualificationTestFixture.report(plan: f.plan, approval: f.approval, attemptID: "one", afterID: "foreign-id")
            case 10: submission = .init(runner: submitted.runner, executablePath: submitted.executablePath, requestDigest: "foreign", osBuild: submitted.osBuild, submittedRecognizedText: submitted.submittedRecognizedText)
            case 11: submission.submittedRecognizedText = nil
            default: submission = .init(runner: submitted.runner, executablePath: submitted.executablePath, requestDigest: submitted.requestDigest, osBuild: nil, submittedRecognizedText: submitted.submittedRecognizedText)
            }
            do { try await registry.record(prepared: f.prepared, plan: f.plan, approval: f.approval, report: report, submission: submission); XCTFail("Rejected qualification \(index)") } catch {}
            let authority = await registry.admission(prepared: f.prepared, plan: f.plan, approval: f.approval); XCTAssertNil(authority)
        }
        var foreignApproval = f.approval; foreignApproval.target = .init(id: "00008140-001049013EF3401D", kind: .physical)
        let registry = AutomationSiriQualificationAuthority()
        do { try await registry.record(prepared: f.prepared, plan: f.plan, approval: foreignApproval, report: original, submission: submitted); XCTFail("Foreign physical approval") } catch {}
    }
}
#endif
