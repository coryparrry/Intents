#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSiriRouteDriverTests: XCTestCase, @unchecked Sendable {
    actor Release: AutomationDeviceReleaseVerifier {
        var absent = true
        func prepare(target: TargetIdentity, controllerBundleIDs: [String]) {}
        func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) -> Bool { absent }
        func deny() { absent = false }
    }
    struct Subject: AutomationSubjectVerifier {
        let app: AppIdentity, target: TargetIdentity
        func verify(app: AppIdentity, target: TargetIdentity) throws {
            guard app == self.app, target == self.target else { throw AutomationContractError.invalidIdentity }
        }
    }
    actor Commands {
        var calls: [[String]] = []
        var fail = false, foreign = false
        let receipt: [String: AutomationJSON]
        init(receipt: [String: AutomationJSON]) { self.receipt = receipt }
        func run(_ executable: String, _ arguments: [String], _ directory: URL, _ duration: Duration) throws -> AutomationOwnedCommand.Result {
            calls.append([executable] + arguments)
            if arguments.first == "xcodebuild", fail { return .init(exitStatus: 65, stdout: Data(), stderr: Data(), logsTruncated: false) }
            if arguments.first == "xcresulttool" {
                let output = URL(fileURLWithPath: arguments[try XCTUnwrap(arguments.firstIndex(of: "--output-path")) + 1])
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                var value = receipt; if foreign { value["attemptID"] = .string("foreign") }
                try JSONEncoder().encode(AutomationJSON.object(value)).write(to: output.appendingPathComponent("submission.json"))
            }
            return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
        }
        func setFailure() { fail = true }
        func setForeign() { foreign = true }
    }
    struct Harness {
        let root: URL, prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval
        let leases: AutomationDeviceLeaseManager, lease: AutomationDeviceLeaseManager.Lease, scope: AutomationScope
        let release: Release, commands: Commands, capabilities: CapabilityProfile
        func driver() throws -> AutomationSiriRouteDriver {
            try .init(prepared: prepared, approval: approval, capabilities: capabilities,
                developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), stateDirectory: root.appendingPathComponent("driver"),
                leases: leases, artifacts: AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts")),
                subjectVerifier: Subject(app: plan.app, target: plan.target), releaseVerifier: release,
                commands: .init(run: { try await commands.run($0, $1, $2, $3) }, stop: { true }))
        }
    }
    func fixture() async throws -> Harness {
        let root = URL(fileURLWithPath: "/private/tmp/synthetic-siri-driver-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("OwnedHost-Runner.app"), subject = root.appendingPathComponent("Subject.app")
        for (bundle, id, executable) in [(host, "example.Host.xctrunner", "OwnedHost-Runner"), (subject, "example.Subject", "Subject")] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleExecutable": executable], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
            try Data("synthetic payload".utf8).write(to: bundle.appendingPathComponent(executable))
        }
        try FileManager.default.createDirectory(at: host.appendingPathComponent("PlugIns/OwnedHost.xctest"), withIntermediateDirectories: true)
        let entry: [String: Any] = ["BlueprintName": "OwnedHost", "IsUITestBundle": true, "TestHostPath": "__TESTROOT__/OwnedHost-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/OwnedHost.xctest", "UITargetAppPath": "__TESTROOT__/Subject.app"]
        let data = try PropertyListSerialization.data(fromPropertyList: ["OwnedHost": entry], format: .xml, options: 0)
        let testFile = root.appendingPathComponent("host.xctestrun"); try data.write(to: testFile)
        let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: subject))
        let hostRecord = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: testFile.path, xctestrunDigest: AutomationArtifactRegistry.digest(data),
            subjectProductPath: subject.path, hostBundlePath: host.path, hostProductDigest: try AutomationProductDigest.compute(bundle: host), hostBundleID: "example.Host.xctrunner", testTarget: "OwnedHost")
        let generated = AutomationGeneratedHost(projectPath: "synthetic", scheme: "OwnedHost", targetID: "HOST", bundleID: hostRecord.hostBundleID,
            configuration: "Debug", templateDigest: String(repeating: "a", count: 64), includesSiri: true)
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: root.path, files: [], directories: [], excludedPaths: []), generatedHost: generated,
            host: hostRecord, catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []), buildLogPath: root.appendingPathComponent("build.log").path, buildLogTruncated: false)
        var segment = AutomationSegment(id: "siri", kind: .siriText, phase: .subject, operation: "submitRecognizedText", requiredCapabilities: ["siri.recognizedText.api"], effects: [.navigate], lifecycle: .persistedStateAcrossSegments)
        segment.siriProgram = .init(request: "Open the approved fixture")
        let plan = AutomationCase(id: "siri-case", app: app, target: target, environmentID: "test", execution: segment)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test", effects: [.navigate], maximumActions: 10, disposable: true, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
        let leases = AutomationDeviceLeaseManager(); try await leases.reserveCampaign(runID: "run", target: target)
        let lease = try await leases.acquire(runID: "run", target: target, control: .system)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "siri", leaseGeneration: lease.generation)
        let receipt: [String: AutomationJSON] = ["schemaVersion": .number(1), "runID": .string("run"), "attemptID": .string("attempt"), "segmentID": .string("siri"),
            "leaseGeneration": .number(Double(lease.generation)), "bundleID": .string(app.bundleID), "productDigest": .string(app.productDigest!),
            "requestDigest": .string(segment.siriProgram!.requestDigest), "submissionStarted": .bool(true), "submissionReturned": .bool(true),
            "runner": .object(["pid": .number(42), "startIdentity": .string("1:2"), "executablePath": .string("/private/var/containers/Bundle/Application/" + UUID().uuidString + "/OwnedHost-Runner.app/OwnedHost-Runner")])]
        return .init(root: root, prepared: prepared, plan: plan, approval: approval, leases: leases, lease: lease, scope: scope, release: Release(),
            commands: Commands(receipt: receipt), capabilities: .init(records: ["siri.recognizedText.api": .init(state: .available, reason: "synthetic command test", probeVersion: "test", evidence: [])]))
    }
    func testReturnedSubmissionRemainsUnassessedAndRetiresPrivateRequest() async throws {
        let h = try await fixture(), driver = try h.driver()
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        let receipt = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        XCTAssertTrue(receipt.completed); XCTAssertTrue(receipt.observations.isEmpty); XCTAssertTrue(receipt.verifiedOutputs?.isEmpty ?? true)
        let record = try await h.leases.currentRecord(h.lease); XCTAssertTrue(record.runners.isEmpty); XCTAssertNotNil(record.privatePayload)
        let calls = await h.commands.calls
        let dispatch = try XCTUnwrap(calls.first { $0.dropFirst().first == "xcodebuild" })
        XCTAssertTrue(dispatch.contains("platform=iOS,id=" + h.plan.target.id)); XCTAssertTrue(dispatch.contains("-only-testing:OwnedHost/SiriSubmissionTests/testSubmitRecognizedText"))
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated); XCTAssertTrue(proof.privatePayloadCleaned)
        let clean = try await h.leases.currentRecord(h.lease); XCTAssertNil(clean.privatePayload)
        let file = h.root.appendingPathComponent("driver/siri-\(h.lease.generation)/host.xctestrun")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("INTENTS_AUTOMATION_SIRI_PLAN_B64"))
    }
    func testActualAppleBaselineAcquisitionRequiresAndAcceptsOwnedSiriCalibrationAuthority() async throws {
        let h = try await fixture()
        let catalog = ApplicationSurfaceCatalog(app: h.plan.app, systemActions: [], systemDiscoveryComplete: false,
            uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
                properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        var approval = h.approval; approval.effects = [.observe, .navigate, .fixtureWrite]; approval.maximumActions = 20
        var capabilities = h.capabilities
        capabilities.records["apple.entity.query"] = .init(state: .available, reason: "synthetic acquisition", probeVersion: "test", evidence: [])
        let plan = try AutomationSiriEntityPlanner.compile(catalog: catalog, entityType: "TaskEntity", nameProperty: "title",
            recordName: "Approved task", stateProperty: "completed", initialState: false, expectedState: true,
            request: "Complete Approved task in Example", approval: approval, capabilities: capabilities)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let segment = plan.setup[0]
        let scope = AutomationScope(runID: approval.runID, attemptID: h.scope.attemptId, segmentID: segment.id, leaseGeneration: h.lease.generation)
        func apple(_ authority: AutomationSiriRouteAuthority?, _ suffix: String) throws -> AutomationAppleRouteDriver {
            try .init(prepared: h.prepared.host, approval: approval, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
                stateDirectory: h.root.appendingPathComponent(suffix), leases: h.leases,
                artifacts: AutomationArtifactRegistry(root: h.root.appendingPathComponent("artifacts-" + suffix)),
                subjectVerifier: Subject(app: plan.app, target: plan.target), releaseVerifier: h.release,
                capabilities: capabilities, siriAuthority: authority,
                commands: .init(run: { _, _, _ in throw AutomationContractError.invalidIdentity }, stop: { true }))
        }
        let denied = try apple(nil, "denied")
        do { try await denied.acquire(plan: plan, segment: segment, scope: scope, lease: h.lease); XCTFail("No authority must stop before query preparation") } catch {}
        _ = await denied.release(scope: scope, lease: h.lease)
        let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval)
        let admitted = try apple(authority, "admitted")
        try await admitted.acquire(plan: plan, segment: segment, scope: scope, lease: h.lease)
        let held = try await h.leases.currentRecord(h.lease); XCTAssertNotNil(held.privatePayload)
        let proof = await admitted.release(scope: scope, lease: h.lease)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated); XCTAssertTrue(proof.privatePayloadCleaned)
        let released = try await h.leases.currentRecord(h.lease); XCTAssertNil(released.privatePayload)
    }
    func testUnreturnedOrForeignSubmissionCannotCompleteAndCannotRedispatch() async throws {
        for foreign in [false, true] {
            let h = try await fixture(), driver = try h.driver()
            if foreign { await h.commands.setForeign() } else { await h.commands.setFailure() }
            try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
            for _ in 0..<2 {
                do { _ = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("must reject") } catch {}
            }
            let calls = await h.commands.calls; XCTAssertEqual(calls.filter { $0.dropFirst().first == "xcodebuild" }.count, 1)
            let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.privatePayloadCleaned)
        }
    }
    func testUnprovedRemoteReleaseRetainsPrivatePayloadAndLease() async throws {
        let h = try await fixture(), driver = try h.driver()
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        await h.release.deny()
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertFalse(proof.runnerTerminated); XCTAssertFalse(proof.privatePayloadCleaned)
        let record = try await h.leases.currentRecord(h.lease); XCTAssertNotNil(record.privatePayload)
        do { try await h.leases.release(h.lease, commandsDrained: proof.commandsDrained, ownedRunnerTerminated: proof.runnerTerminated); XCTFail("retain lease") } catch {}
    }
    func testUnqualifiedAPIGrantDoesNotPermitBusinessAssessment() async throws {
        let h = try await fixture()
        var plan = h.plan
        plan.observations = [.init(id: "business", kind: .observeOnly, phase: .observe, operation: "Independent outcome", effects: [.observe])]
        plan.requirements = [.init(observationID: "business", expected: .bool(true), proof: .appState, justification: "Requires independent Siri outcome")]
        var approval = h.approval; approval.effects.insert(.observe); approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: h.capabilities)) {
            XCTAssertEqual($0 as? AutomationContractError, .missingEvidence("Unqualified Siri API submission cannot assess routing or business outcomes"))
        }
        let driver = try AutomationSiriRouteDriver(prepared: h.prepared, approval: approval, capabilities: h.capabilities,
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), stateDirectory: h.root.appendingPathComponent("driver"), leases: h.leases,
            artifacts: AutomationArtifactRegistry(root: h.root.appendingPathComponent("artifacts")), subjectVerifier: Subject(app: plan.app, target: plan.target), releaseVerifier: h.release)
        do { try await driver.acquire(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease); XCTFail("must remain unassessed") }
        catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Unqualified Siri API submission cannot assess routing or business outcomes")) }
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.privatePayloadCleaned)
    }
    func testSerializedCompilationGrantCannotQualifyAHostAndCannotOverrideVeto() async throws {
        let h = try await fixture()
        var claims = h.capabilities
        claims.records["siri.actualRoute"] = .init(state: .available, reason: "cached route", probeVersion: "test", evidence: ["saved.json"])
        let cached = try await AutomationSiriCapabilitySnapshot.resolve(prepared: h.prepared, capabilities: claims)
        XCTAssertEqual(cached.records["siri.recognizedText.api"]?.state, .unknown)
        XCTAssertEqual(cached.records["siri.actualRoute"]?.state, .unknown)
        for state in [CapabilityProfile.State.unavailable, .consentRequired] {
            let veto = CapabilityProfile(records: ["siri.recognizedText.api": .init(state: state, reason: "veto", probeVersion: "test", evidence: [])])
            let result = try await AutomationSiriCapabilitySnapshot.resolve(prepared: h.prepared, capabilities: veto)
            XCTAssertEqual(result.records["siri.recognizedText.api"]?.state, state)
        }
    }
    func testUnqualifiedSiriRefusesWriteSetupBeforeAnyDriverOrInstallation() async throws {
        let h = try await fixture()
        var plan = h.plan
        plan.setup = [.init(id: "write", kind: .systemIntent, phase: .setup, operation: "Write fixture", effects: [.fixtureWrite])]
        var approval = h.approval; approval.effects.insert(.fixtureWrite); approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: h.capabilities)) {
            XCTAssertEqual($0 as? AutomationContractError, .missingEvidence("Unqualified Siri API submission cannot assess routing or business outcomes"))
        }
        let calls = await h.commands.calls; XCTAssertTrue(calls.isEmpty)
    }
}
#endif
