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
        var fail = false, foreign = false, duplicate = false, flood = false
        var codesign: AutomationOwnedCommand.Result?
        var receipt: [String: AutomationJSON]
        init(receipt: [String: AutomationJSON]) { self.receipt = receipt }
        func run(_ executable: String, _ arguments: [String], _ directory: URL, _ duration: Duration) throws -> AutomationOwnedCommand.Result {
            calls.append([executable] + arguments)
            if executable == "/usr/bin/codesign", let codesign { return codesign }
            if arguments.first == "xcodebuild", fail { return .init(exitStatus: 65, stdout: Data(), stderr: Data(), logsTruncated: false) }
            if arguments.first == "xcresulttool" {
                let output = URL(fileURLWithPath: arguments[try XCTUnwrap(arguments.firstIndex(of: "--output-path")) + 1])
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                var value = receipt; if foreign { value["attemptID"] = .string("foreign") }
                let encoded = try JSONEncoder().encode(AutomationJSON.object(value))
                try encoded.write(to: output.appendingPathComponent("submission.json"))
                if duplicate { try encoded.write(to: output.appendingPathComponent("submission-copy.json")) }
                if flood { for index in 0..<1000 { try Data().write(to: output.appendingPathComponent("noise-\(index).txt")) } }
            }
            return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
        }
        func setFailure() { fail = true }
        func setForeign() { foreign = true }
        func setDuplicate() { duplicate = true }
        func setFlood() { flood = true }
        func setCodesign(exitStatus: Int32, logsTruncated: Bool) {
            codesign = .init(exitStatus: exitStatus, stdout: Data(), stderr: Data(), logsTruncated: logsTruncated)
        }
        func setReceipt(_ key: String, _ value: AutomationJSON) { receipt[key] = value }
    }
    struct Harness {
        let root: URL, prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval
        let leases: AutomationDeviceLeaseManager, lease: AutomationDeviceLeaseManager.Lease, scope: AutomationScope
        let release: Release, commands: Commands, capabilities: CapabilityProfile
        func driver(prepared: AutomationPreparedApplication? = nil, approval: RunApproval? = nil, capabilities: CapabilityProfile? = nil,
                    siriAuthority: AutomationSiriRouteAuthority? = nil) throws -> AutomationSiriRouteDriver {
            try .init(prepared: prepared ?? self.prepared, approval: approval ?? self.approval, capabilities: capabilities ?? self.capabilities,
                developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), stateDirectory: root.appendingPathComponent("driver"),
                leases: leases, artifacts: AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts")),
                subjectVerifier: Subject(app: plan.app, target: plan.target), releaseVerifier: release, siriAuthority: siriAuthority,
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
        do { try await denied.acquire(plan: plan, segment: segment, scope: scope, lease: h.lease); XCTFail("No authority must stop before query preparation") }
        catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Unqualified Siri API submission cannot assess routing or business outcomes")) }
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
            for expected in [AutomationContractError.ambiguousDispatch, .unknownLease] {
                await assertRejects(expected) { try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
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
        do { try await h.leases.release(h.lease, commandsDrained: proof.commandsDrained, ownedRunnerTerminated: proof.runnerTerminated); XCTFail("retain lease") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
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
    func assertRejects<T>(_ expected: AutomationContractError, file: StaticString = #filePath, line: UInt = #line,
                          _ body: () async throws -> T) async {
        do { _ = try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationContractError, expected, file: file, line: line) }
    }
    func xcodebuildCalls(_ h: Harness) async -> Int { await h.commands.calls.filter { $0.dropFirst().first == "xcodebuild" }.count }
    func testInitRefusesAnyHostThatIsNotTheApprovedSiriSubject() async throws {
        let h = try await fixture()
        let otherTarget = TargetIdentity(id: "00008140-0000000000000001", kind: .physical)
        var noSiri = h.prepared; noSiri.generatedHost.includesSiri = false
        var unknownSiri = h.prepared; unknownSiri.generatedHost.includesSiri = nil
        var macApp = h.prepared; macApp.host.app.platform = "macos"
        var macApproval = h.approval; macApproval.app = macApp.host.app
        var digestV2 = h.prepared; digestV2.host.app.productDigestVersion = 2
        var digestV2Approval = h.approval; digestV2Approval.app = digestV2.host.app
        var hostDigestV2 = h.prepared; hostDigestV2.host.hostProductDigestVersion = 2
        var badTestTarget = h.prepared; badTestTarget.host.testTarget = "Owned Host/../Other"
        var simulator = h.prepared; simulator.host.target = TargetIdentity(id: h.plan.target.id, kind: .simulator)
        var simulatorApproval = h.approval; simulatorApproval.target = simulator.host.target
        var otherApp = h.approval; otherApp.app.bundleID = "example.Other"
        var otherApproval = h.approval; otherApproval.target = otherTarget
        let cases: [(String, AutomationPreparedApplication, RunApproval)] = [
            ("no Siri host", noSiri, h.approval), ("unknown Siri host", unknownSiri, h.approval), ("non-iOS app", macApp, macApproval),
            ("v2 subject digest", digestV2, digestV2Approval), ("v2 host digest", hostDigestV2, h.approval),
            ("invalid test target", badTestTarget, h.approval), ("simulator target", simulator, simulatorApproval),
            ("foreign approved app", h.prepared, otherApp), ("foreign approved target", h.prepared, otherApproval)]
        for (name, prepared, approval) in cases {
            XCTAssertThrowsError(try h.driver(prepared: prepared, approval: approval), name) {
                XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity, name)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("driver").path))
        XCTAssertNoThrow(try h.driver())
        let calls = await h.commands.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testAcquireRefusesUnapprovedPlanScopeOrLeaseBeforeRecordingPayload() async throws {
        let denied = AutomationContractError.invalidPlan("Siri requires the exact approved physical subject and lease")
        let h = try await fixture(), driver = try h.driver()
        var drifted = h.plan; drifted.execution.siriProgram = .init(request: "Open a different fixture")
        await assertRejects(denied) { try await driver.acquire(plan: drifted, segment: drifted.execution, scope: h.scope, lease: h.lease) }
        let scopes = [AutomationScope(runID: "run", attemptID: "attempt", segmentID: "siri", leaseGeneration: h.lease.generation + 1),
            AutomationScope(runID: "other", attemptID: "attempt", segmentID: "siri", leaseGeneration: h.lease.generation),
            AutomationScope(runID: "run", attemptID: "attempt", segmentID: "other", leaseGeneration: h.lease.generation)]
        for scope in scopes {
            await assertRejects(denied) { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: scope, lease: h.lease) }
        }
        var foreignLease = h.lease; foreignLease.generation += 1
        await assertRejects(denied) { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: foreignLease) }
        var record = try await h.leases.currentRecord(h.lease); XCTAssertNil(record.privatePayload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("driver/siri-\(h.lease.generation)").path))
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        record = try await h.leases.currentRecord(h.lease); let held = try XCTUnwrap(record.privatePayload)
        await assertRejects(denied) { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
        record = try await h.leases.currentRecord(h.lease); XCTAssertEqual(record.privatePayload, held)
        let calls = await h.commands.calls; XCTAssertTrue(calls.isEmpty)
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.privatePayloadCleaned)
    }
    func testAcquireRefusesAnApprovalForADifferentCaseOrAStaleLease() async throws {
        let denied = AutomationContractError.invalidPlan("Siri requires the exact approved physical subject and lease")
        let h = try await fixture()
        for digest in [String(repeating: "b", count: 64), nil] {
            var approval = h.approval; approval.approvedCaseDigest = digest
            let driver = try h.driver(approval: approval)
            await assertRejects(denied) { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
        }
        let record = try await h.leases.currentRecord(h.lease); XCTAssertNil(record.privatePayload)
        try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
        let next = try await h.leases.acquire(runID: "run", target: h.plan.target, control: .system)
        let stale = try h.driver()
        await assertRejects(denied) { try await stale.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
        let current = try await h.leases.currentRecord(next); XCTAssertNil(current.privatePayload)
        let calls = await h.commands.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testUnverifiedSignatureStopsBeforeDispatch() async throws {
        for (status, truncated) in [(Int32(1), false), (0, true)] {
            let h = try await fixture(), driver = try h.driver()
            await h.commands.setCodesign(exitStatus: status, logsTruncated: truncated)
            try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
            await assertRejects(.conflictingOperation) { try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
            await assertRejects(.unknownLease) { try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
            let calls = await h.commands.calls
            XCTAssertEqual(calls, [["/usr/bin/codesign", "--verify", "--deep", "--strict", h.prepared.host.subjectProductPath]])
            let submission = await driver.qualificationSubmission(); XCTAssertNil(submission)
            let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.privatePayloadCleaned)
        }
    }
    func testDuplicateOrFloodedAttachmentsCannotComplete() async throws {
        for duplicate in [true, false] {
            let h = try await fixture(), driver = try h.driver()
            if duplicate { await h.commands.setDuplicate() } else { await h.commands.setFlood() }
            try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
            await assertRejects(.ambiguousDispatch) { try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
            let dispatched = await xcodebuildCalls(h); XCTAssertEqual(dispatched, 1)
            let submission = await driver.qualificationSubmission(); XCTAssertNil(submission)
            let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.privatePayloadCleaned)
        }
    }
    func testReceiptFromAnotherRunnerExecutableCannotComplete() async throws {
        let container = "/private/var/containers/Bundle/Application/" + UUID().uuidString
        for path in [container + "/Other-Runner.app/OwnedHost-Runner", container + "/OwnedHost-Runner.app/Other", "/Applications/OwnedHost-Runner.app/OwnedHost-Runner"] {
            let h = try await fixture(), driver = try h.driver()
            await h.commands.setReceipt("runner", .object(["pid": .number(42), "startIdentity": .string("1:2"), "executablePath": .string(path)]))
            try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
            await assertRejects(.ambiguousDispatch) { try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
            let dispatched = await xcodebuildCalls(h); XCTAssertEqual(dispatched, 1, path)
            let submission = await driver.qualificationSubmission(); XCTAssertNil(submission, path)
            _ = await driver.release(scope: h.scope, lease: h.lease)
        }
    }
    func testReceiptFromAnotherOSBuildCannotQualify() async throws {
        for build in ["23B200", "23A100"] {
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
            let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval, osBuild: "23A100", evidenceDigest: String(repeating: "c", count: 64))
            let driver = try h.driver(approval: approval, capabilities: capabilities, siriAuthority: authority)
            await h.commands.setReceipt("schemaVersion", .number(2)); await h.commands.setReceipt("osBuild", .string(build))
            let requestDigest = try XCTUnwrap(plan.execution.siriProgram).requestDigest
            await h.commands.setReceipt("requestDigest", .string(requestDigest))
            try await driver.acquire(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease)
            if build == "23A100" {
                let receipt = try await driver.execute(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease)
                XCTAssertTrue(receipt.completed)
                let submission = await driver.qualificationSubmission(); XCTAssertEqual(submission?.osBuild, "23A100")
            } else {
                await assertRejects(.conflictingOperation) { try await driver.execute(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease) }
                let submission = await driver.qualificationSubmission(); XCTAssertNil(submission)
            }
            let dispatched = await xcodebuildCalls(h); XCTAssertEqual(dispatched, 1)
            let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.privatePayloadCleaned)
        }
    }
    func testProductOrFrozenRunChangedAfterAcquireStopsBeforeAnyCommand() async throws {
        let tampering: [(String, AutomationContractError, (Harness) throws -> Void)] = [
            ("subject executable", .conflictingOperation, { try Data("re-signed".utf8).write(to: URL(fileURLWithPath: $0.prepared.host.subjectProductPath).appendingPathComponent("Subject")) }),
            ("host executable", .conflictingOperation, { try Data("re-signed".utf8).write(to: URL(fileURLWithPath: $0.prepared.host.hostBundlePath).appendingPathComponent("OwnedHost-Runner")) }),
            ("source xctestrun", .conflictingOperation, { try Data("swapped".utf8).write(to: URL(fileURLWithPath: $0.prepared.host.xctestrunPath)) }),
            ("frozen xctestrun", .unknownLease, { h in
                let file = h.root.appendingPathComponent("driver/siri-\(h.lease.generation)/host.xctestrun")
                try FileManager.default.removeItem(at: file); try Data("swapped".utf8).write(to: file)
            })]
        for (name, expected, tamper) in tampering {
            let h = try await fixture(), driver = try h.driver()
            try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
            try tamper(h)
            do { _ = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail(name) }
            catch { XCTAssertEqual(error as? AutomationContractError, expected, name) }
            let calls = await h.commands.calls; XCTAssertTrue(calls.isEmpty, name)
            let submission = await driver.qualificationSubmission(); XCTAssertNil(submission, name)
            _ = await driver.release(scope: h.scope, lease: h.lease)
        }
    }
    func testForeignReleaseIsRefusedAndKeepsPrivatePayloadAndAdmission() async throws {
        let h = try await fixture(), driver = try h.driver()
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        var foreignLease = h.lease; foreignLease.generation += 1
        let foreignScope = AutomationScope(runID: "run", attemptID: "other-attempt", segmentID: "siri", leaseGeneration: h.lease.generation)
        for (scope, lease) in [(foreignScope, h.lease), (h.scope, foreignLease)] {
            let proof = await driver.release(scope: scope, lease: lease)
            XCTAssertFalse(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
            let record = try await h.leases.currentRecord(h.lease); XCTAssertNotNil(record.privatePayload)
        }
        let receipt = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        XCTAssertTrue(receipt.completed)
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated); XCTAssertTrue(proof.privatePayloadCleaned)
        let clean = try await h.leases.currentRecord(h.lease); XCTAssertNil(clean.privatePayload)
    }
}
#endif
