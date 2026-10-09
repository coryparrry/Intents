import XCTest
@testable import IntentsAutomationCore

final class AutomationUIReadbackTests: XCTestCase, @unchecked Sendable {
    private let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios")
    private let target = TargetIdentity(id: "owned", kind: .simulator)
    private var operation: AutomationUIProgram.Operation { .init(id: "read", kind: .observeProperty, locator: .init(.testId, "result"), property: "value") }
    private func capture() -> AutomationUIReadback {
        .init(schemaVersion: 1, appBundleId: "example.App", targetId: "owned", complete: true,
            nodes: [.init(index: 1, identifier: "result", label: "Result", value: "actual", blocked: false, hidden: false, visible: true, disabled: false, secure: false, checked: false)])
    }
    func testOrdinaryFillRoleCannotBeMisreadAsALabelOracle() throws {
        var proof = capture(); proof.nodes[0].label = "textbox"
        var read = operation; read.locator = .init(.role, "textbox")
        XCTAssertThrowsError(try proof.extract(operation: read, app: app, target: target))
    }
    func testNativeExtractsActualPropertyInsteadOfControllerAssessment() throws {
        var proof = capture()
        XCTAssertEqual(try proof.extract(operation: operation, app: app, target: target), .text("actual"))
        var checked = operation; checked.property = "checked"
        XCTAssertEqual(try proof.extract(operation: checked, app: app, target: target), .bool(false))
        proof.nodes[0].value = ""
        XCTAssertEqual(try proof.extract(operation: operation, app: app, target: target), .text(""))
        proof.nodes[0].value = nil
        XCTAssertThrowsError(try proof.extract(operation: operation, app: app, target: target))
    }
    func testIncompleteIdentityAmbiguityAndHiddenOrSecretNodesFailClosed() throws {
        var cases: [AutomationUIReadback] = []
        var proof = capture(); proof.complete = false; cases.append(proof)
        proof = capture(); proof.appBundleId = "other"; cases.append(proof)
        proof = capture(); proof.targetId = "other"; cases.append(proof)
        proof = capture(); proof.nodes[0].visible = false; cases.append(proof)
        proof = capture(); proof.nodes[0].secure = true; cases.append(proof)
        proof = capture(); proof.nodes[0].parentIndex = 99; cases.append(proof)
        proof = capture(); proof.nodes[0].parentIndex = 1; cases.append(proof)
        proof = capture(); var duplicate = proof.nodes[0]; duplicate.index = 2; proof.nodes.append(duplicate); cases.append(proof)
        for invalid in cases { XCTAssertThrowsError(try invalid.extract(operation: operation, app: app, target: target)) }
    }
    func testExplicitForeignOwnerOrHiddenSecureAncestorCannotProvideBusinessEvidence() throws {
        var proof = capture(); proof.nodes[0].ownerBundle = "foreign.App"
        XCTAssertThrowsError(try proof.extract(operation: operation, app: app, target: target))
        for kind in ["hidden", "secure", "foreign"] {
            proof = capture(); proof.nodes[0].parentIndex = 2
            proof.nodes.append(.init(index: 2, ownerBundle: kind == "foreign" ? "foreign.App" : "example.App", blocked: false, hidden: kind == "hidden", visible: false, disabled: false, secure: kind == "secure"))
            XCTAssertThrowsError(try proof.extract(operation: operation, app: app, target: target))
        }
    }
    func testUnrecognizedCaptureFieldsCannotReachArtifactStorage() throws {
        let data = try JSONEncoder().encode(capture())
        var payload = try JSONDecoder().decode(AutomationJSON.self, from: data).object!
        payload["extraSecret"] = .string("secret")
        XCTAssertThrowsError(try AutomationUIReadback.outputs(["read": .object(payload)], program: .init(operations: [operation]), app: app, target: target))
        guard case .array(var nodes) = payload.removeValue(forKey: "extraSecret").flatMap({ _ in payload["nodes"] }) else { return XCTFail("Fixture nodes missing") }
        var node = nodes[0].object!; node["extraSecret"] = .string("secret"); nodes[0] = .object(node); payload["nodes"] = .array(nodes)
        XCTAssertThrowsError(try AutomationUIReadback.outputs(["read": .object(payload)], program: .init(operations: [operation]), app: app, target: target))
    }
    func testRejectedSecureCaptureNeverCreatesAnArtifact() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let registry = try AutomationArtifactRegistry(root: root)
        var invalid = capture(); invalid.nodes[0].secure = true
        let payload = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(invalid))
        let outputs = ["read": payload]
        do {
            _ = try await AutomationUIReadback.storeVerified(receipt: .object(["outputs": .object(outputs)]), outputs: outputs,
                program: .init(operations: [operation]), app: app, target: target,
                scope: .init(runID: "run", attemptID: "attempt", segmentID: "observe", leaseGeneration: 1), artifacts: registry, name: "readback.json")
            XCTFail("Unredacted secure capture accepted")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testUnselectedSecureDescendantNeverCreatesAnArtifact() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let registry = try AutomationArtifactRegistry(root: root)
        var invalid = capture()
        invalid.nodes.append(.init(index: 2, blocked: false, hidden: false, visible: false, disabled: false, secure: true))
        invalid.nodes.append(.init(index: 3, parentIndex: 2, value: "secret", blocked: false, hidden: false, visible: false, disabled: false, secure: false))
        let payload = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(invalid)); let outputs = ["read": payload]
        do {
            _ = try await AutomationUIReadback.storeVerified(receipt: .object(["outputs": .object(outputs)]), outputs: outputs,
                program: .init(operations: [operation]), app: app, target: target,
                scope: .init(runID: "run", attemptID: "attempt", segmentID: "observe", leaseGeneration: 1), artifacts: registry, name: "readback.json")
            XCTFail("Unselected secure descendant accepted")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testCoveredAncestorCannotProvideVisibleEvidence() throws {
        var proof = capture(); proof.nodes[0].parentIndex = 2
        proof.nodes.append(.init(index: 2, blocked: true, hidden: false, visible: false, disabled: false, secure: false))
        XCTAssertThrowsError(try proof.extract(operation: operation, app: app, target: target))
    }
    func testLegacyScalarCannotBePromotedToVerifiedReadback() throws {
        let program = AutomationUIProgram(operations: [operation])
        XCTAssertThrowsError(try AutomationUIReadback.outputs(["read": .string("expected")], program: program, app: app, target: target))
        let data = try JSONEncoder().encode(capture())
        let proof = try JSONDecoder().decode(AutomationJSON.self, from: data)
        XCTAssertEqual(try AutomationUIReadback.outputs(["read": proof], program: program, app: app, target: target), ["read": .text("actual")])
    }
}
