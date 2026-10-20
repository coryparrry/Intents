import XCTest
@testable import IntentsAutomationCore
#if canImport(Darwin)
import Darwin
#endif

final class AutomationXCUITestTests: XCTestCase, @unchecked Sendable {
    private actor ReleaseDuringWrite {
        var driver: AutomationXCUITestRouteDriver?
        var reference: AutomationDeviceLeaseManager.PrivatePayload?
        func set(_ driver: AutomationXCUITestRouteDriver) { self.driver = driver }
        func release(_ reference: AutomationDeviceLeaseManager.PrivatePayload) async {
            self.reference = reference
            _ = await driver?.release()
        }
        func capturedReference() -> AutomationDeviceLeaseManager.PrivatePayload? { reference }
    }
    private func fixture() throws -> (AutomationCase, RunApproval, UIHostPlan) {
        let app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "simulator", kind: .simulator)
        var create = AutomationSegment(id: "create", kind: .ui, phase: .setup, operation: "Create task", effects: [.fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        create.attemptTextBindings = ["title": "Fixture"]
        create.uiProgram = .init(operations: [.init(id: "add", kind: .tap, locator: .init(.testId, "add")),
            .init(id: "title", kind: .fillBinding, locator: .init(.testId, "title"), binding: "title"),
            .init(id: "save", kind: .tap, locator: .init(.testId, "save"))])
        var lookup = AutomationSegment(id: "lookup", kind: .systemQuery, phase: .setup, operation: "Fresh task query")
        lookup.hostProgram = .init(operations: [.init(id: "records", kind: .query, typeID: "TaskEntity", attemptQueryPrefix: "Fixture", properties: ["title": "text", "completed": "bool"])])
        let selection = AutomationEntitySelection(typeID: "TaskEntity", matchingProperties: [:], attemptProperties: ["title": "Fixture"])
        var invoke = AutomationSegment(id: "complete", kind: .systemIntent, phase: .subject, operation: "Complete task", effects: [.fixtureWrite])
        invoke.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "CompleteTask")])
        invoke.inputBindings = [.init(producerSegmentID: "lookup", outputID: "records", destination: .hostParameter,
                                      operationID: "invoke", name: "task", uniqueEntity: selection)]
        var readback = AutomationSegment(id: "readback", kind: .systemQuery, phase: .observe, operation: "Read completed task")
        readback.hostProgram = .init(operations: [.init(id: "records", kind: .query, typeID: "TaskEntity", properties: ["title": "text", "completed": "bool"])])
        readback.inputBindings = [.init(producerSegmentID: "lookup", outputID: "records", destination: .hostQueryIDs,
                                       operationID: "records", name: "queryIDs", uniqueEntity: selection)]
        let check = AutomationRequirement(observationID: "lookup", expected: .bool(false), proof: .appState,
            justification: "New fixture must be incomplete", checkID: "fresh.incomplete",
            entityProperty: .init(operationID: "records", selection: selection, property: "completed"))
        let plan = AutomationCase(id: "mixed", app: app, target: target, environmentID: "fixture", execution: invoke,
                                  setup: [create, lookup], observations: [readback], setupChecks: [check])
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "fixture",
                                   effects: [.observe, .navigate, .fixtureWrite], maximumActions: 100, disposable: true,
                                   approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
        return (plan, approval, try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 7))
    }
    private func queryValue(_ title: String, completed: Bool = false, id: String = "new-task") -> UIHostValue {
        .init(kind: "array", items: [.init(kind: "entity", value: id, typeId: "TaskEntity",
            properties: ["title": .init(kind: "text", value: title), "completed": .init(kind: "bool", boolValue: completed)])])
    }
    private func receiptData(_ wire: UIHostPlan) throws -> [Data] {
        let title = wire.bindings["create/title"]!
        return try wire.steps.enumerated().map { index, step in
            let value: UIHostValue? = step.kind == .query ? queryValue(title, completed: step.segmentID == "readback") :
                step.kind == .invokeIntent ? .init(kind: "noValue") : nil
            return try JSONEncoder().encode(UIHostStepReceipt(plan: wire, index: index, dispatched: true, completed: true, value: value))
        }
    }

    func testMixedCaseIsOneOrderedPlanWithFreshNameAndRuntimeEntityBindings() throws {
        let (_, _, wire) = try fixture()
        XCTAssertEqual(wire.steps.map(\.kind), [.launch, .tap, .clearAndType, .tap, .query, .checkFreshness, .invokeIntent, .query, .screenshot])
        XCTAssertEqual(wire.bindings["create/title"], try AutomationAttemptText.value(prefix: "Fixture", attemptID: "attempt"))
        let lookup = try XCTUnwrap(wire.steps.first { $0.segmentID == "lookup" })
        XCTAssertEqual(lookup.setupChecks?.count, 1)
        let title = wire.bindings["create/title"]!
        let selected = try XCTUnwrap(wire.steps[6].inputBindings?.first?.selection).resolve(queryValue(title))
        XCTAssertEqual(selected, .init(kind: "entity", value: "new-task", typeId: "TaskEntity"))
        XCTAssertNil(selected.properties)
        XCTAssertEqual(wire.steps[7].inputBindings?.first?.destination, "hostQueryIDs")
    }
    func testUniqueEntityBindingRejectsAmbiguityForeignTypeAndStaleIdentity() throws {
        let (_, _, wire) = try fixture()
        let selection = try XCTUnwrap(wire.steps[6].inputBindings?.first?.selection)
        let title = wire.bindings["create/title"]!
        var multiple = queryValue(title)
        multiple.items?.append(queryValue(title, id: "another").items!.first!)
        XCTAssertThrowsError(try selection.resolve(multiple))
        var foreign = queryValue(title); foreign.items?[0].typeId = "OtherEntity"
        XCTAssertThrowsError(try selection.resolve(foreign))
        let stale = UIHostSelection(typeID: "TaskEntity", properties: [:], identifier: "new-task", expiresAt: .distantPast)
        XCTAssertThrowsError(try stale.resolve(queryValue(title)))
    }
    func testSetupProjectionStopsOnChangedPrecondition() throws {
        let (_, _, wire) = try fixture()
        let check = try XCTUnwrap(wire.steps[4].setupChecks?.first)
        let title = wire.bindings["create/title"]!
        XCTAssertNoThrow(try check.validate(output: queryValue(title)))
        XCTAssertThrowsError(try check.validate(output: queryValue(title, completed: true)))
    }
    func testImportedQueryEvidencePreservesIndependentReadback() throws {
        let (plan, _, wire) = try fixture()
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(receiptData(wire), uiPlan: wire, plan: plan)
        XCTAssertEqual(receipts.map(\.segmentID), ["create", "lookup", "complete", "readback"])
        XCTAssertTrue(receipts.allSatisfy(\.completed))
        XCTAssertEqual(receipts.last?.observations.first?.proof, .appState)
        XCTAssertEqual(receipts.last?.scope.leaseGeneration, 7)
        XCTAssertNotEqual(receipts[1].verifiedOutputs?["records"], receipts[3].verifiedOutputs?["records"])
    }
    func testSingleUIObservationPreservesItsOperationKey() throws {
        var (plan, approval, _) = try fixture()
        var observe = AutomationSegment(id: "visible", kind: .observeOnly, phase: .observe, operation: "Read visible text", lifecycle: .noActivation)
        observe.uiProgram = .init(operations: [.init(id: "visible-text", kind: .observeProperty, locator: .init(.testId, "title"), property: "text")])
        plan.observations = [observe]
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let wire = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 7)
        var data = try receiptData(wire)
        let index = try XCTUnwrap(wire.steps.firstIndex { $0.id == "visible-text" })
        data[index] = try JSONEncoder().encode(UIHostStepReceipt(plan: wire, index: index, dispatched: true, completed: true,
                                                               value: .init(kind: "text", value: "New task")))
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(data, uiPlan: wire, plan: plan)
        XCTAssertEqual(receipts.last?.observations.first?.value, .object(["visible-text": .text("New task")]))
    }
    func testInitialHierarchyReadbackRequiresExactBoundedResultWithoutAnAppNameLocator() throws {
        let (fixturePlan, _, _) = try fixture()
        let catalog = ApplicationSurfaceCatalog(app: fixturePlan.app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        var approval = RunApproval(runID: "initial-run", app: fixturePlan.app, target: fixturePlan.target,
            environmentID: fixturePlan.environmentID, effects: [.observe, .navigate], maximumActions: 30, disposable: true)
        let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog, appName: "Product name absent from screen",
            approval: approval, capabilities: .init(), includeActions: false, includeUI: true, localeIdentifier: "en_GB")
        let plan = try XCTUnwrap(proposal.plans.first)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let wire = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "initial", leaseGeneration: 1)
        XCTAssertEqual(wire.steps.map(\.kind), [.launch, .readHierarchy, .screenshot])
        XCTAssertTrue(wire.steps.allSatisfy { $0.query == nil })
        let hierarchy = try UIHostHierarchyReadback.capture("Window\n  Text: Welcome\n  Button: Sign in")
        func encoded(_ value: UIHostValue?) throws -> [Data] {
            try wire.steps.enumerated().map { index, step in
                try JSONEncoder().encode(UIHostStepReceipt(plan: wire, index: index, dispatched: true,
                    completed: true, value: step.kind == .readHierarchy ? value : nil))
            }
        }
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(encoded(hierarchy), uiPlan: wire, plan: plan)
        XCTAssertEqual(receipts.first?.verifiedOutputs?["initial-hierarchy"], .object([
            "hierarchy": .text("Window\n  Text: Welcome\n  Button: Sign in"), "truncated": .bool(false)]))
        XCTAssertTrue(receipts.first?.observations.isEmpty == true, "Initial readback does not invent a business assertion")
        XCTAssertTrue(plan.requirements.isEmpty)
        XCTAssertEqual(AutomationAssessment.assess(plan: plan, attemptID: "initial", subjectDispatched: true,
            subjectCompleted: true, observations: []).summary, .executedUnassessed)
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(encoded(nil), uiPlan: wire, plan: plan))
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(encoded(.init(kind: "text", value: "Passed")), uiPlan: wire, plan: plan))
        var malformed = hierarchy; malformed.properties?["truncated"] = .init(kind: "text", value: "false")
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(encoded(malformed), uiPlan: wire, plan: plan))
        var foreign = try encoded(hierarchy)
        var receipt = try JSONDecoder().decode(UIHostStepReceipt.self, from: foreign[1])
        receipt.attemptID = "other-attempt"; foreign[1] = try JSONEncoder().encode(receipt)
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(foreign, uiPlan: wire, plan: plan))
        var underBudget = plan; underBudget.budget.subjectOperations = 2
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(underBudget)
        XCTAssertThrowsError(try AutomationXCUITestPlan.assemble(plan: underBudget, approval: approval, attemptID: "initial", leaseGeneration: 1))
    }
    func testFinalVerificationFailureKeepsKnownSubjectReceipts() throws {
        let (plan, _, wire) = try fixture()
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(receiptData(wire), uiPlan: wire, plan: plan)
        let failure = AutomationXCUITestRouteDriver.failedVerification(receipts: receipts, stepReceipts: [], plan: plan,
            testStarted: true, release: .init(commandsDrained: true, runnerTerminated: true))
        XCTAssertEqual(failure.receipts, receipts)
        XCTAssertEqual(failure.reason, .infrastructureFailed)
        XCTAssertFalse(failure.subjectDispatchUncertain)
        XCTAssertTrue(failure.resourcesReleased)
    }
    func testMissingDuplicateAndTamperedReceiptsNeverBecomeSuccess() throws {
        let (plan, _, wire) = try fixture()
        let data = try receiptData(wire)
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts([], uiPlan: wire, plan: plan))
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(Array(data.dropLast()), uiPlan: wire, plan: plan))
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(data + [data[0]], uiPlan: wire, plan: plan))
        var receipt = try JSONDecoder().decode(UIHostStepReceipt.self, from: data[4])
        for key in ["attempt", "digest", "step"] {
            var changed = receipt
            if key == "attempt" { changed.attemptID = "foreign" }
            if key == "digest" { changed.planDigest = String(repeating: "b", count: 64) }
            if key == "step" { changed.stepID = "other" }
            var altered = data; altered[4] = try JSONEncoder().encode(changed)
            XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(altered, uiPlan: wire, plan: plan))
        }
        receipt.value = nil
        var altered = data; altered[4] = try JSONEncoder().encode(receipt)
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(altered, uiPlan: wire, plan: plan))
    }
    func testFailureReceiptKeepsSetupOutputAndCannotClaimSubjectDispatch() throws {
        let (plan, _, wire) = try fixture()
        var data = try Array(receiptData(wire).prefix(5))
        var failed = try JSONDecoder().decode(UIHostStepReceipt.self, from: data[4])
        failed.completed = false; failed.error = "assertionFailed"
        data[4] = try JSONEncoder().encode(failed)
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(data, uiPlan: wire, plan: plan, allowPartial: true)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertFalse(receipts[1].completed)
        XCTAssertNotNil(receipts[1].verifiedOutputs?["records"])
        XCTAssertFalse(receipts.contains { $0.segmentID == plan.execution.id })
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(data + [receiptData(wire)[6]], uiPlan: wire, plan: plan, allowPartial: true))
    }
    func testTimeoutDispatchReceiptDoesNotBecomeCompleted() throws {
        let (plan, _, wire) = try fixture()
        var data = try Array(receiptData(wire).prefix(6))
        data.append(try JSONEncoder().encode(UIHostStepReceipt(plan: wire, index: 6, dispatched: true, completed: false)))
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(data, uiPlan: wire, plan: plan, allowPartial: true)
        XCTAssertEqual(receipts.last?.segmentID, plan.execution.id)
        XCTAssertTrue(receipts.last?.dispatched == true)
        XCTAssertFalse(receipts.last?.completed == true)
    }
    func testReadbackCannotSubstituteAnEntityWithMatchingProperties() throws {
        let (plan, _, wire) = try fixture()
        var data = try receiptData(wire)
        var receipt = try JSONDecoder().decode(UIHostStepReceipt.self, from: data[7])
        receipt.value = queryValue(wire.bindings["create/title"]!, completed: true, id: "substitute")
        data[7] = try JSONEncoder().encode(receipt)
        XCTAssertThrowsError(try AutomationXCUITestReceiptImporter.importReceipts(data, uiPlan: wire, plan: plan))
    }
    func testIntentErrorTextCannotPretendToBeUIAssertionFailure() throws {
        let (plan, _, wire) = try fixture()
        var data = try Array(receiptData(wire).prefix(6))
        let failed = UIHostStepReceipt(plan: wire, index: 6, dispatched: true, completed: false, error: "assertionFailed")
        data.append(try JSONEncoder().encode(failed))
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(data, uiPlan: wire, plan: plan, allowPartial: true)
        XCTAssertEqual(AutomationXCUITestRouteDriver.failureReason(error: nil, receipts: receipts, stepReceipts: [failed], plan: plan), .infrastructureFailed)
        XCTAssertNil(receipts.last!.terminalUIAssertionFailure)
        XCTAssertFalse(receipts.last!.completed)
    }
    func testApprovedCleanupRunsAfterReadbackAndBeforeFinalScreenshot() throws {
        var (plan, approval, _) = try fixture()
        var cleanup = AutomationSegment(id: "cleanup", kind: .ui, phase: .cleanup, operation: "Dismiss fixture", effects: [.navigate])
        cleanup.uiProgram = .init(operations: [.init(id: "dismiss", kind: .tap, locator: .init(.testId, "dismiss"))])
        plan.cleanup = [cleanup]
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let wire = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 7)
        XCTAssertEqual(wire.steps.suffix(3).map(\.segmentID), ["readback", "cleanup", "cleanup"])
        XCTAssertEqual(wire.steps.suffix(3).map(\.kind), [.query, .tap, .screenshot])
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(receiptData(wire), uiPlan: wire, plan: plan)
        XCTAssertEqual(receipts.last?.segmentID, "cleanup")
        XCTAssertTrue(receipts.last?.completed == true)
    }
    func testReusedFreshEntityStopsBeforeSubjectReceipt() throws {
        let (plan, approval, _) = try fixture()
        let wire = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 7,
                                                       excludedEntityIDs: ["TaskEntity:new-task"])
        let output = queryValue(wire.bindings["create/title"]!)
        XCTAssertThrowsError(try wire.validateFreshSubject(outputs: ["lookup": ["records": output]]))
        var data = try Array(receiptData(wire).prefix(5))
        let failed = UIHostStepReceipt(plan: wire, index: 5, dispatched: true, completed: false, error: "reusedEntity")
        data.append(try JSONEncoder().encode(failed))
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(data, uiPlan: wire, plan: plan, allowPartial: true)
        XCTAssertFalse(receipts.contains { $0.segmentID == plan.execution.id })
        XCTAssertFalse(AutomationXCUITestRouteDriver.dispatchUncertain(testStarted: true, receipts: receipts, stepReceipts: [failed], plan: plan))
    }
    func testMissingPostLaunchReceiptsRemainUncertainAndPreserveTimeoutReason() throws {
        let (plan, _, wire) = try fixture()
        XCTAssertTrue(AutomationXCUITestRouteDriver.dispatchUncertain(testStarted: true, receipts: [], stepReceipts: [], plan: plan))
        XCTAssertFalse(AutomationXCUITestRouteDriver.dispatchUncertain(testStarted: false, receipts: [], stepReceipts: [], plan: plan))
        XCTAssertEqual(AutomationXCUITestRouteDriver.failureReason(error: AutomationRPCError.timedOut, receipts: [], stepReceipts: [], plan: plan), .timedOut)
        XCTAssertEqual(AutomationXCUITestRouteDriver.failureReason(error: CancellationError(), receipts: [], stepReceipts: [], plan: plan), .cancelled)
        let timedOut = UIHostStepReceipt(plan: wire, index: 6, dispatched: true, completed: false, error: "timedOut")
        XCTAssertEqual(AutomationXCUITestRouteDriver.failureReason(error: nil, receipts: [], stepReceipts: [timedOut], plan: plan), .timedOut)
    }
    func testProtectedSetupEntityReuseAlsoStopsSubject() throws {
        var (plan, approval, _) = try fixture()
        let protected = AutomationEntitySelection(typeID: "TaskEntity", matchingProperties: ["title": .text("Protected")])
        plan.setupChecks?.append(.init(observationID: "lookup", expected: .bool(false), proof: .appState,
            justification: "Preserve protected task", checkID: "protected.incomplete",
            entityProperty: .init(operationID: "records", selection: protected, property: "completed")))
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let wire = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 7,
                                                       excludedEntityIDs: ["TaskEntity:protected"])
        var output = queryValue(wire.bindings["create/title"]!)
        output.items?.append(queryValue("Protected", id: "protected").items!.first!)
        XCTAssertThrowsError(try wire.validateFreshSubject(outputs: ["lookup": ["records": output]]))
        XCTAssertEqual(wire.freshnessBindings.count, 2)
    }
    func testDestinationMappingUsesPreparedTargetKind() throws {
        XCTAssertEqual(try AutomationXCUITestRouteDriver.destination(.init(id: "sim", kind: .simulator)), "platform=iOS Simulator,id=sim")
        XCTAssertEqual(try AutomationXCUITestRouteDriver.destination(.init(id: "device", kind: .physical)), "platform=iOS,id=device")
        XCTAssertEqual(try AutomationXCUITestRouteDriver.destination(.init(id: "local", kind: .nativeMac)), "platform=macOS")
        XCTAssertThrowsError(try AutomationXCUITestRouteDriver.destination(.init(id: "invalid,other", kind: .physical)))
    }
    func testDirectProgramCarriesFullQueriesLaunchInputsAndFailedPropertyAssertion() throws {
        var (plan, approval, _) = try fixture()
        plan.setup = []; plan.setupChecks = nil; plan.observations = []
        plan.execution.kind = .ui; plan.execution.hostProgram = nil; plan.execution.inputBindings = nil
        plan.execution.lifecycle = .persistedStateAcrossSegments; plan.execution.effects = [.observe, .navigate]
        plan.execution.uiProgram = .init(steps: [
            .init(id: "launch", segmentID: "ignored", kind: .launch, arguments: ["-fixture"], environment: ["SEED": "1"]),
            .init(id: "wait", segmentID: "ignored", kind: .waitFor, query: .init(labelContains: "New", elementType: "staticText", index: 0), property: "hittable", timeout: 1),
            .init(id: "assert", segmentID: "ignored", kind: .assert, query: .init(identifier: "title"), property: "label", equals: .init(kind: "text", value: "Wrong title")),
            .init(id: "capture", segmentID: "ignored", kind: .screenshot)
        ])
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let wire = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 1)
        XCTAssertEqual(wire.steps.map(\.kind), [.launch, .waitFor, .assert, .screenshot, .screenshot])
        XCTAssertTrue(wire.steps.allSatisfy { $0.segmentID == plan.execution.id })
        XCTAssertEqual(wire.steps[0].arguments, ["-fixture"])
        XCTAssertEqual(wire.steps[0].environment, ["SEED": "1"])
        XCTAssertEqual(wire.steps[1].query?.labelContains, "New")
        XCTAssertEqual(wire.steps[1].query?.index, 0)
        XCTAssertEqual(wire.steps[2].equals?.value, "Wrong title")
        let originalDigest = try AutomationFrozenCase.planDigest(plan)
        plan.execution.uiProgram?.steps?[2].equals?.value = "Correct title"
        XCTAssertNotEqual(try AutomationFrozenCase.planDigest(plan), originalDigest)
        plan.budget.subjectOperations = 2
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 1))
    }
    func testReadOnlyDirectStepsRejectMutationsAndAvoidAutomaticActivation() throws {
        var (plan, approval, _) = try fixture()
        plan.setup = []; plan.setupChecks = nil; plan.observations = []
        plan.execution.kind = .observeOnly; plan.execution.phase = .subject; plan.execution.hostProgram = nil
        plan.execution.inputBindings = nil; plan.execution.lifecycle = .noActivation; plan.execution.effects = [.observe]
        plan.execution.uiProgram = .init(steps: [.init(id: "assert", segmentID: "ignored", kind: .assert,
            query: .init(identifier: "title"), property: "exists", equals: .init(kind: "bool", boolValue: true))])
        XCTAssertNoThrow(try plan.execution.validateObservationOnly())
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let wire = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 1)
        XCTAssertFalse(wire.steps.contains { $0.kind == .launch })
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        for kind in [UIHostStep.Kind.launch, .tap, .typeText, .clearAndType, .swipe, .invokeIntent] {
            plan.execution.uiProgram?.steps = [.init(id: "mutate", segmentID: "ignored", kind: kind)]
            XCTAssertThrowsError(try plan.execution.validateObservationOnly())
            XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        }
    }
    func testReleaseDuringPayloadCallbackCannotWriteRetiredPrivateInputs() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcuitest-payload-" + UUID().uuidString)
        let host = root.appendingPathComponent("Host-Runner.app"), subject = root.appendingPathComponent("Subject.app")
        try FileManager.default.createDirectory(at: host.appendingPathComponent("PlugIns/Host.xctest"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry: [String: Any] = ["BlueprintName": "Host", "TestHostPath": "__TESTROOT__/Host-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/Host.xctest", "UITargetAppPath": "__TESTROOT__/Subject.app", "IsUITestBundle": true]
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["Host": entry], format: .xml, options: 0)
        let testFile = root.appendingPathComponent("host.xctestrun"); try bytes.write(to: testFile)
        let app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "sim", kind: .simulator)
        var segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "Tap", effects: [.navigate])
        segment.uiProgram = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.testId, "button"))])
        let plan = AutomationCase(id: "callback", app: app, target: target, environmentID: "fixture", execution: segment)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "fixture", effects: [.navigate], maximumActions: 10,
            disposable: true, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
        let prepared = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: testFile.path,
            xctestrunDigest: AutomationArtifactRegistry.digest(bytes), subjectProductPath: subject.path, hostBundlePath: host.path,
            hostProductDigest: String(repeating: "b", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Host")
        let box = ReleaseDuringWrite()
        let artifacts = try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts"))
        let driver = AutomationXCUITestRouteDriver(prepared: prepared, root: root, artifacts: artifacts,
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
            willWritePayload: { reference in await box.release(reference) })
        await box.set(driver)
        do { _ = try await driver.execute(plan: plan, approval: approval, attemptID: "attempt"); XCTFail("Revoked write was accepted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        let reference = await box.capturedReference()
        let captured = try XCTUnwrap(reference)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.path))
        XCTAssertNoThrow(try captured.verifyClean())
    }
    #if os(macOS)
    func testTimeoutStopsOwnedProcessGroup() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcuitest-group-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let command = AutomationOwnedCommand()
        do {
            _ = try await command.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", AutomationXCUITestRouteDriver.processGroupScript,
                "test-group", "/bin/sh", "-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "child", pidFile.path],
                directory: root, environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(1))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
        let pid = try XCTUnwrap(Int32(String(decoding: Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let stopped = await command.stopOwned()
        XCTAssertTrue(stopped)
    }
    #endif
}
