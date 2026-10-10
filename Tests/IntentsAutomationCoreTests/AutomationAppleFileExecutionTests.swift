#if os(macOS)
import Foundation
import XCTest
import IntentsAutomationDateCodec
@testable import IntentsAutomationCore

extension AutomationAppleRouteDriverTests {
    func testSyntheticFileExecutionKeepsBinaryAndRunnerLogOutOfOrdinaryEvidence() async throws {
        try await checkFileExecution(tamper: false)
    }
    func testSyntheticFileExecutionRejectsChangedBinaryBeforeReturningReceipt() async throws {
        try await checkFileExecution(tamper: true)
    }
    func testResolvedFileInputFreezesBytesOnlyThroughProducerPermitAndCleansAfterDrain() async throws {
        let h = try await fixture()
        var plan = h.plan, setup = h.plan.execution
        setup.id = "setup"; setup.phase = .setup
        setup.hostProgram = .init(operations: [.init(id: "make", kind: .invoke, typeID: "MakeIntent", resultCodec: "intentFile")])
        setup.requiredCapabilities = ["apple.codec.intentFile"]; plan.setup = [setup]
        plan.execution.inputBindings = [.init(producerSegmentID: "setup", outputID: "make", destination: .hostParameter, operationID: "probe", name: "file", parameterCodec: "intentFile")]
        plan.execution.requiredCapabilities = ["apple.codec.intentFile"]
        let digest = try AutomationFrozenCase.planDigest(plan), artifacts = try AutomationArtifactRegistry(root: h.root.appendingPathComponent("artifacts"))
        let source = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: h.lease.generation)
        let metadata = try AutomationIntentFileMetadata(filename: "sample.txt", typeIdentifier: nil, data: AutomationFileExecutionFixture.bytes)
        let artifact = try await artifacts.storeNativeEvidence(data: AutomationFileExecutionFixture.bytes, scope: source, metadata: metadata,
            provenance: .init(planDigest: digest, operationID: "make", receiptDigest: String(repeating: "c", count: 64)))
        var producer = AutomationSegmentReceipt(scope: source, app: plan.app, target: plan.target, segmentID: "setup", route: .systemIntent,
            dispatched: true, completed: true, verifiedOutputs: ["make": .artifact(handle: artifact.handle, sha256: artifact.sha256)], environmentID: plan.environmentID)
        producer.hostReceiptDigest = String(repeating: "c", count: 64)
        let resolved = try AutomationInputResolver.resolveForExecution(segment: plan.execution, receipts: [producer], plan: plan, runID: "run", attemptID: "attempt")
        try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
        let lease = try await h.leases.acquire(runID: "run", target: plan.target, control: .system)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation)
        var approval = h.approval; approval.approvedCaseDigest = digest
        let capability = CapabilityProfile(records: ["apple.codec.intentFile": .init(state: .available, reason: "Synthetic input contract", probeVersion: "fixture", evidence: [])])
        let driver = try driver(h, approval: approval, capabilities: capability)
        try await driver.acquireResolved(plan: plan, segment: resolved.segment, scope: scope, lease: lease, authority: resolved.authority)
        let file = h.root.appendingPathComponent("driver/system-\(lease.generation)/host.xctestrun")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        let target = try XCTUnwrap(plist["OwnedHost"] as? [String: Any]), environment = try XCTUnwrap(target["EnvironmentVariables"] as? [String: String])
        let payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(environment["INTENTS_AUTOMATION_HOST_PLAN_B64"])))
        let host = try JSONDecoder().decode(AutomationJSON.self, from: payload)
        guard case .array(let operations) = host.object?["operations"] else { return XCTFail("Missing operations") }
        let input = try XCTUnwrap(operations.first?.object?["parameters"]?.object?["file"]?.object)
        XCTAssertEqual(input["kind"], .string("intentFile")); XCTAssertEqual(input["value"], .string(AutomationFileExecutionFixture.bytes.base64EncodedString()))
        let proof = await driver.release(scope: scope, lease: lease)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated); XCTAssertTrue(proof.privatePayloadCleaned)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("INTENTS_AUTOMATION_HOST_PLAN_B64"))
    }
    private func checkFileExecution(tamper: Bool) async throws {
        let h = try await fixture()
        var plan = h.plan; plan.execution.hostProgram!.operations[0].resultCodec = "intentFile"
        plan.execution.requiredCapabilities = ["apple.codec.intentFile"]
        var approval = h.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let capability = CapabilityProfile(records: ["apple.codec.intentFile": .init(state: .available, reason: "Synthetic binary contract", probeVersion: "fixture", evidence: [])])
        let commands = AutomationAppleRouteDriver.Commands(run: { arguments, _, _ in
            if let index = arguments.firstIndex(of: "--output-path") {
                try AutomationFileExecutionFixture.export(root: URL(fileURLWithPath: arguments[index + 1]), scope: h.scope,
                    app: h.host.app, hostPath: h.host.hostBundlePath, tamper: tamper)
            }
            return .init(exitStatus: 0, stdout: AutomationFileExecutionFixture.bytes, stderr: Data(), logsTruncated: false)
        }, stop: { true })
        let driver = try driver(h, approval: approval, capabilities: capability, commands: commands)
        try await driver.acquire(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease)
        if tamper {
            do { _ = try await driver.execute(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease); XCTFail("Changed binary accepted") } catch {}
        } else {
            let receipt = try await driver.execute(plan: plan, segment: plan.execution, scope: h.scope, lease: h.lease)
            guard case .artifact(let handle, let digest) = receipt.verifiedOutputs?["probe"] else { return XCTFail("Missing opaque file result") }
            XCTAssertEqual(digest, AutomationArtifactRegistry.digest(AutomationFileExecutionFixture.bytes))
            let registry = try AutomationArtifactRegistry(root: h.root.appendingPathComponent("artifacts"))
            do { _ = try await registry.resolve(handle: handle, scope: h.scope); XCTFail("Binary exposed") } catch {}
            let json = try await registry.resolve(handle: XCTUnwrap(receipt.artifact), scope: h.scope)
            XCTAssertFalse(try String(contentsOf: json, encoding: .utf8).contains("private-file-content"))
            XCTAssertEqual(receipt.hostReceiptDigest, AutomationArtifactRegistry.digest(try Data(contentsOf: json)))
        }
        let index = try JSONDecoder().decode([String: AutomationArtifactRegistry.Artifact].self,
            from: Data(contentsOf: h.root.appendingPathComponent("artifacts/artifact-index.json")))
        XCTAssertEqual(index.values.filter { $0.fileMetadata != nil }.count, tamper ? 0 : 1)
        let registry = try AutomationArtifactRegistry(root: h.root.appendingPathComponent("artifacts"))
        for artifact in index.values where artifact.nativeOnly == true {
            do { _ = try await registry.resolve(handle: artifact.handle, scope: h.scope); XCTFail("File-bearing native log or binary exposed") } catch {}
        }
        let proof = await driver.release(scope: h.scope, lease: h.lease)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated); XCTAssertTrue(proof.privatePayloadCleaned)
    }
}
#endif
