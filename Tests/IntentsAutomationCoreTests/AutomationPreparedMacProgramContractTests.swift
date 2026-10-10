#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

extension AutomationPrivateMacAppleRouteDriverTests {
    func testPreparedMacReviewedPlanCannotDispatchWithoutItsCodecFamily() async throws {
        let h = try await macFreshHarness()
        var capabilities = h.capabilities; capabilities.records.removeValue(forKey: "apple.codec.entity")
        XCTAssertNoThrow(try PlanValidator.validate(h.plan, approval: h.approval, capabilities: capabilities, purpose: .review))
        do {
            _ = try await h.runner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: capabilities,
                attemptID: "unqualified-conversion", allowBootAndInstall: false)
            XCTFail("Review cannot stand in for conversion evidence")
        } catch {
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Input and result conversion has not been verified for this app and target"))
        }
        let names = await h.driver.names, invocations = await h.driver.invocations
        XCTAssertTrue(names.isEmpty); XCTAssertEqual(invocations, 0)
    }

    func testPreparedMacQueryMismatchStopsBeforeUIOrAppleDispatch() async throws {
        let h = try await macFreshHarness()
        for index in 0..<5 {
            var prepared = h.prepared, plan = h.plan, approval = h.approval
            let queryIndex = try XCTUnwrap(plan.setup.firstIndex(where: { $0.kind == .systemQuery }))
            switch index {
            case 0: prepared.catalog.entities = nil
            case 1: plan.setup[queryIndex].hostProgram?.operations[0].properties?["undeclared"] = "text"
            case 2: plan.setup[queryIndex].hostProgram?.operations[0].properties?["completed"] = "text"
            case 3:
                let duplicate = try XCTUnwrap(prepared.catalog.entities?.first)
                prepared.catalog.entities?.append(duplicate)
            default: prepared.catalog.entities?[0].queryIdentifier = ""
            }
            plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
            approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            do {
                _ = try await h.runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: h.capabilities,
                    attemptID: "invalid-query-" + String(index), allowBootAndInstall: false)
                XCTFail("Mismatched query declarations must stop before setup")
            } catch {
                XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Prepared query does not match the selected app's entity and property declarations"))
            }
        }
        let names = await h.driver.names, invocations = await h.driver.invocations
        XCTAssertTrue(names.isEmpty); XCTAssertEqual(invocations, 0)
    }

    func testPreparedMacProgramMismatchStopsBeforeUIOrAppleDispatch() async throws {
        let h = try await macFreshHarness()
        for index in 0..<5 {
            var prepared = h.prepared, plan = h.plan, approval = h.approval
            switch index {
            case 0:
                prepared.catalog.systemActions[0].parameters.append(.init(name: "text", family: "text", optional: false))
                plan.execution.hostProgram?.operations[0].parameters["text"] = .bool(true)
            case 1: plan.execution.hostProgram?.operations[0].parameters["foreign"] = .text("extra")
            case 2:
                prepared.catalog.systemActions[0].resultFamily = "bool"
                plan.execution.hostProgram?.operations[0].resultCodec = "text"
            case 3: prepared.catalog.systemActions[0].parameters.append(.init(name: "required", family: "text", optional: false))
            default:
                prepared.catalog.systemActions[0].parameters.append(.init(name: "flag", family: "bool", optional: true))
                var producer = AutomationSegment(id: "text-producer", kind: .ui, phase: .setup, operation: "Read text", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
                producer.uiProgram = .init(operations: [.init(id: "output", kind: .observeProperty, locator: .init(.testId, "text-field"), property: "value")])
                plan.setup.append(producer)
                plan.execution.inputBindings = (plan.execution.inputBindings ?? []) + [.init(producerSegmentID: producer.id, outputID: "output", destination: .hostParameter, operationID: "invoke", name: "flag")]
            }
            plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
            approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            do {
                _ = try await h.runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: h.capabilities,
                    attemptID: "invalid-program-" + String(index), allowBootAndInstall: false)
                XCTFail("Mismatched selected declarations must stop before setup")
            } catch {
                XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Prepared program does not match the selected app's input and result declarations"))
            }
        }
        let names = await h.driver.names, invocations = await h.driver.invocations
        XCTAssertTrue(names.isEmpty); XCTAssertEqual(invocations, 0)
    }
}
#endif
