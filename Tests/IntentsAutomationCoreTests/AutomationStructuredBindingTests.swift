import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationStructuredBindingTests: XCTestCase, @unchecked Sendable {
    private let samples: [(String, AutomationValue)] = [
        ("textArray", .array([.text("a")])), ("boolArray", .array([.bool(true), .bool(false)])),
        ("integerArray", .array([.integer("9007199254740993")])), ("decimalArray", .array([.decimal("0.000000001")])),
        ("dateArray", .array([.date("2026-10-08T00:00:00Z", timeZone: "UTC")])),
        ("duration", .object(["seconds": .integer("7"), "attoseconds": .integer("123")])),
        ("calendarComponents", .object(["components": .object(["month": .integer("-2"), "nanosecond": .integer("123456789")])]))
    ]
    private func fixture(_ family: String) -> (AutomationCase, ApplicationSurfaceCatalog) {
        let app = AppIdentity(logicalID: "app", bundleID: "example.app", platform: "ios", productDigest: String(repeating: "a", count: 64))
        var producerAction = ApplicationSurfaceCatalog.SystemAction(id: "Producer", typeName: "Producer", title: "Producer", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false)
        producerAction.resultFamily = family
        let consumerAction = ApplicationSurfaceCatalog.SystemAction(id: "Consumer", typeName: "Consumer", title: "Consumer",
            parameters: [.init(name: "values", family: family, optional: false)], parametersComplete: true, compiled: true, registered: false, executed: false)
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [producerAction, consumerAction], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        var producer = AutomationSegment(id: "producer", kind: .systemIntent, phase: .setup, operation: "Produce", effects: [.fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        producer.hostProgram = .init(operations: [.init(id: "output", kind: .invoke, typeID: "Producer", resultCodec: family)])
        var consumer = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Consume", effects: [.fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        consumer.hostProgram = .init(operations: [.init(id: "consume", kind: .invoke, typeID: "Consumer", resultCodec: "noValue")])
        consumer.inputBindings = [.init(producerSegmentID: "producer", outputID: "output", destination: .hostParameter, operationID: "consume", name: "values")]
        let plan = AutomationCase(id: "case", app: app, target: .init(id: "owned", kind: .simulator), environmentID: "fixture", execution: consumer, setup: [producer])
        return (AutomationCodecRequirements.applying(to: plan, catalog: catalog), catalog)
    }
    private func receipt(_ plan: AutomationCase, value: AutomationValue) -> AutomationSegmentReceipt {
        .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "producer", leaseGeneration: 1), app: plan.app, target: plan.target,
            segmentID: "producer", route: .systemIntent, dispatched: true, completed: true, verifiedOutputs: ["output": value], environmentID: plan.environmentID)
    }
    private func capabilities(_ family: String) -> CapabilityProfile {
        .init(records: Dictionary(uniqueKeysWithValues: ["apple.intent.invoke", "apple.codec." + family].map {
            ($0, .init(state: .available, reason: "Synthetic binding driver only", probeVersion: "test", evidence: []))
        }))
    }
    private func run(_ plan: AutomationCase, family: String, driver: StructuredBindingDriver) async throws -> AutomationAttemptReport {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("structured-binding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = AutomationCoordinator(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json")))
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.fixtureWrite], maximumActions: 10, disposable: true)
        return try await owner.run(plan: plan, approval: approval, capabilities: capabilities(family), attemptID: "attempt", driver: driver)
    }
    func testFrozenFamiliesSerializeVerifiedCollectionsAndStructuredOutputsWithoutChangingPlan() throws {
        for (family, value) in samples {
            let (plan, catalog) = fixture(family)
            try AutomationPreparedProgramContract.validate(plan, catalog: catalog)
            XCTAssertEqual(plan.execution.inputBindings?.first?.parameterCodec, family)
            XCTAssertNil(plan.execution.hostProgram?.operations.first?.parameterCodecs)
            let resolved = try AutomationInputResolver.resolve(segment: plan.execution, receipts: [receipt(plan, value: value)], plan: plan, runID: "run", attemptID: "attempt")
            XCTAssertEqual(resolved.hostProgram?.operations.first?.parameters["values"], value)
            XCTAssertEqual(resolved.hostProgram?.operations.first?.parameterCodecs?["values"], family)
            XCTAssertTrue(plan.execution.hostProgram!.operations[0].parameters.isEmpty)
            try resolved.hostProgram!.validate(route: .systemIntent, phase: .subject)
            XCTAssertNoThrow(try resolved.hostProgram!.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 2), app: plan.app, route: .systemIntent, phase: .subject))
            XCTAssertTrue(AutomationCodecRequirements.segment(plan.execution, plan: plan).contains("apple.codec." + family))
            XCTAssertEqual(try JSONDecoder().decode(AutomationCase.self, from: JSONEncoder().encode(plan)), plan)
        }
        for family in AutomationCodecRegistry.arrayFamilies {
            let (plan, catalog) = fixture(family)
            try AutomationPreparedProgramContract.validate(plan, catalog: catalog)
            XCTAssertEqual(try AutomationInputResolver.resolve(segment: plan.execution, receipts: [receipt(plan, value: .array([]))], plan: plan, runID: "run", attemptID: "attempt").hostProgram?.operations.first?.parameters["values"], .array([]))
        }
    }
    func testMissingForgedOrMismatchedFamiliesCannotBecomePreparedBindings() throws {
        for (family, _) in samples {
            let (plan, catalog) = fixture(family)
            var missing = plan; missing.execution.inputBindings?[0].parameterCodec = nil
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(missing, catalog: catalog))
            var forged = plan; forged.execution.inputBindings?[0].parameterCodec = family == "boolArray" ? "integerArray" : "boolArray"
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(forged, catalog: catalog))
            var wrongCatalog = catalog; wrongCatalog.systemActions[1].parameters[0].family = "text"
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: wrongCatalog))
            wrongCatalog = catalog; wrongCatalog.systemActions[0].resultFamily = "text"
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: wrongCatalog))
            var wrongProducer = plan; wrongProducer.setup[0].hostProgram?.operations[0].resultCodec = "text"
            XCTAssertThrowsError(try AutomationInputResolver.validate(plan: wrongProducer))
        }
        for codec in ["url", "entity", "enum", "artifact", "file", "boolNestedArray", "text", "unknown"] {
            let (base, catalog) = fixture(codec); var plan = base
            plan.execution.inputBindings?[0].parameterCodec = codec
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        }
        let (base, catalog) = fixture("boolArray"); var plan = base
        plan.execution.hostProgram?.operations[0].parameterCodecs = ["values": "boolArray"]
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
    }
    func testWrongReceiptShapesAndStaleScopesFailBeforeResolvingInput() throws {
        let (plan, _) = fixture("boolArray")
        for value in [AutomationValue.null, .omission, .bool(true), .array(Array(repeating: .bool(true), count: 1001)), .array([.text("true")]), .array([.bool(true), .integer("1")]), .array([.array([.bool(true)])])] {
            XCTAssertThrowsError(try AutomationInputResolver.resolve(segment: plan.execution, receipts: [receipt(plan, value: value)], plan: plan, runID: "run", attemptID: "attempt")) {
                XCTAssertEqual($0 as? AutomationInputBindingError, .inputUnavailable)
            }
        }
        for field in ["run", "attempt", "app", "environment", "missingEnvironment", "route", "completed"] {
            var changed = receipt(plan, value: .array([.bool(true)]))
            switch field {
            case "run": changed.scope.runId = "other"
            case "attempt": changed.scope.attemptId = "old"
            case "app": changed.app.bundleID = "other.app"
            case "environment": changed.environmentID = "other"
            case "missingEnvironment": changed.environmentID = nil
            case "route": changed.route = .ui
            default: changed.completed = false
            }
            XCTAssertThrowsError(try AutomationInputResolver.resolve(segment: plan.execution, receipts: [changed], plan: plan, runID: "run", attemptID: "attempt"))
        }
        for family in ["duration", "calendarComponents"] {
            let (plan, _) = fixture(family)
            for value in [AutomationValue.null, .omission, .object(["unexpected": .integer("1")])] {
                XCTAssertThrowsError(try AutomationInputResolver.resolve(segment: plan.execution, receipts: [receipt(plan, value: value)], plan: plan, runID: "run", attemptID: "attempt")) {
                    XCTAssertEqual($0 as? AutomationInputBindingError, .inputUnavailable)
                }
            }
        }
    }
    func testCoordinatorAcquisitionAndExecutionReceiveTheSameFrozenTypedInput() async throws {
        for (family, value) in samples {
            let (plan, catalog) = fixture(family); try AutomationPreparedProgramContract.validate(plan, catalog: catalog)
            let driver = StructuredBindingDriver(value: value)
            let report = try await run(plan, family: family, driver: driver)
            XCTAssertTrue(report.result.subjectDispatched); XCTAssertTrue(report.result.subjectCompleted); XCTAssertTrue(report.resourcesReleased)
            let acquired = await driver.acquired, executed = await driver.executed
            XCTAssertEqual(acquired, value); XCTAssertEqual(executed, acquired)
            let codec = await driver.codec; XCTAssertEqual(codec, family)
        }
    }
    func testCoordinatorDoesNotAcquireOrDispatchWrongTypedInputs() async throws {
        let (plan, _) = fixture("boolArray")
        for value in [AutomationValue.null, .omission, .array([.text("wrong")]), .array(Array(repeating: .bool(true), count: 1001))] {
            let driver = StructuredBindingDriver(value: value)
            let report = try await run(plan, family: "boolArray", driver: driver)
            XCTAssertEqual(report.result.summary, .inputUnavailable); XCTAssertFalse(report.result.subjectDispatched)
            let acquired = await driver.acquired, executed = await driver.executed
            XCTAssertNil(acquired); XCTAssertNil(executed)
            let segments = await driver.segments; XCTAssertEqual(segments, ["producer"])
        }
    }
    func testFrozenCodecLabelsDoNotSupplyRuntimeConversionAvailability() throws {
        let (plan, catalog) = fixture("boolArray"); try AutomationPreparedProgramContract.validate(plan, catalog: catalog)
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.fixtureWrite], maximumActions: 10, disposable: true)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        var unknown = capabilities("boolArray"); unknown.records["apple.codec.boolArray"]?.state = .unknown
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: unknown))
    }
}
private actor StructuredBindingDriver: AutomationRouteDriver {
    let value: AutomationValue
    var acquired: AutomationValue?, executed: AutomationValue?, codec: String?
    var segments: [String] = []
    init(value: AutomationValue) { self.value = value }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) {
        if segment.phase == .subject { acquired = segment.hostProgram?.operations.first?.parameters["values"]; codec = segment.hostProgram?.operations.first?.parameterCodecs?["values"] }
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationSegmentReceipt {
        segments.append(segment.id)
        if segment.phase == .subject { executed = segment.hostProgram?.operations.first?.parameters["values"] }
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
            verifiedOutputs: segment.phase == .setup ? ["output": value] : nil, environmentID: plan.environmentID)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationReleaseProof { .init(commandsDrained: true, runnerTerminated: true) }
}
