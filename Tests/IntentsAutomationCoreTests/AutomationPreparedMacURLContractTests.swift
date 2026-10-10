#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

extension AutomationPrivateMacAppleRouteDriverTests {
    func testPreparedMacURLDeclarationRejectsTextBeforeAnyRouteDispatch() async throws {
        let h = try await macFreshHarness()
        var prepared = h.prepared, plan = h.plan, approval = h.approval
        prepared.catalog.systemActions[0].parameters.append(.init(name: "url", family: "url", optional: false))
        plan.execution.hostProgram?.operations[0].parameters["url"] = .text("file:///private/tmp/customer.txt")
        plan.execution.inputs["url"] = .text("file:///private/tmp/customer.txt")
        plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        do {
            _ = try await h.runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: h.capabilities,
                attemptID: "invalid-url", allowBootAndInstall: false)
            XCTFail("Text must not reach a URL declaration's SDK setter")
        } catch {
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("URL program does not match its selected declaration and qualified codec"))
        }
        let names = await h.driver.names, invocations = await h.driver.invocations
        XCTAssertTrue(names.isEmpty); XCTAssertEqual(invocations, 0)
    }
    func testPreparedMacDeferredTextCannotFillOptionalOrDefaultURLDeclarations() async throws {
        let h = try await macFreshHarness()
        let declarations: [(Bool, AutomationValue?)] = [(true, nil), (false, .object(["url": .text("https://example.invalid")]))]
        for (index, declaration) in declarations.enumerated() {
            var prepared = h.prepared, plan = h.plan, approval = h.approval
            var parameter = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "url", family: "url", optional: declaration.0)
            parameter.defaultValue = declaration.1; prepared.catalog.systemActions[0].parameters.append(parameter)
            var producer = AutomationSegment(id: "url-producer", kind: .ui, phase: .setup, operation: "Read verified text", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
            producer.uiProgram = .init(operations: [.init(id: "url-label", kind: .observeProperty, locator: .init(.testId, "url-field"), property: "value")])
            plan.setup.append(producer)
            plan.execution.inputBindings = (plan.execution.inputBindings ?? []) + [.init(producerSegmentID: producer.id, outputID: "url-label", destination: .hostParameter, operationID: "invoke", name: "url")]
            try AutomationInputResolver.validate(plan: plan)
            plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
            approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            do {
                _ = try await h.runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: h.capabilities,
                    attemptID: "invalid-url-binding-" + String(index), allowBootAndInstall: false)
                XCTFail("Untyped producer text cannot target a URL declaration")
            } catch {
                XCTAssertEqual(error as? AutomationContractError, .missingEvidence("URL program does not match its selected declaration and qualified codec"))
            }
        }
        let names = await h.driver.names, invocations = await h.driver.invocations
        XCTAssertTrue(names.isEmpty); XCTAssertEqual(invocations, 0)
    }
}
#endif
