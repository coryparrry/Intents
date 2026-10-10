import Foundation
import IntentsAutomationDateCodec
import XCTest
@testable import IntentsAutomationCore

final class AutomationURLCodecTests: XCTestCase {
    func testURLReferencesPreserveExactValuesAndRejectFileRelativeCredentialOrNormalizedURLs() throws {
        let catalog = ApplicationSurfaceCatalog(app: .init(logicalID: "app", bundleID: "example.app", platform: "ios"), systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        let parameter = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "url", family: "url", optional: false)
        for text in ["https://example.invalid", "http://example.invalid:8080/path?q=a%20b#fragment", "https://[::1]/a%2Fb"] {
            let input = try AutomationCodecRegistry.input(text, parameter: parameter, catalog: catalog)
            XCTAssertEqual(input.value, .object(["url": .text(text)]))
            XCTAssertEqual(try AutomationURLReference(taggedValue: input.value).url().absoluteString, text)
            XCTAssertThrowsError(try AutomationCodecRegistry.validate(.text(text), parameter: parameter, catalog: catalog))
            XCTAssertThrowsError(try AutomationCodecRegistry.validate(input.value, parameter: .init(name: "text", family: "text", optional: false), catalog: catalog))
        }
        for text in ["", "relative/path", "//example.invalid/path", "file:///private/tmp/customer.txt", "FILE:///private/tmp/customer.txt", "https://user:password@example.invalid", "https://@example.invalid", "https://example.invalid/a b", "https://example.invalid/%xx", "https://example.invalid:99999", "javascript:alert(1)", "https:relative", "https://example.invalid\n", "https://example.invalid/" + String(repeating: "a", count: 4096)] {
            XCTAssertThrowsError(try AutomationCodecRegistry.input(text, parameter: parameter, catalog: catalog), text)
        }
        for value in [AutomationValue.object(["url": .text("https://example.invalid"), "bookmark": .text("private")]), .object(["url": .artifact(handle: "owned", sha256: String(repeating: "a", count: 64))]), .object(["url": .null])] {
            XCTAssertThrowsError(try AutomationURLReference(taggedValue: value))
        }
        let base = try XCTUnwrap(URL(string: "https://example.invalid/"))
        XCTAssertThrowsError(try AutomationURLReference.encode(try XCTUnwrap(URL(string: "relative", relativeTo: base))))
    }

    func testURLExecutionRequiresIndependentCodecCapabilityEvenWhenCaseOmitsIt() throws {
        let app = AppIdentity(logicalID: "app", bundleID: "example.app", platform: "ios"), target = TargetIdentity(id: "sim", kind: .simulator)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test", effects: [.observe], maximumActions: 2, disposable: false)
        var segment = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Intent", requiredCapabilities: ["apple.intent.invoke"], effects: [.observe], lifecycle: .persistedStateAcrossSegments)
        segment.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", resultCodec: "url")])
        var plan = AutomationCase(id: "url", app: app, target: target, environmentID: "test", execution: segment)
        let available = CapabilityProfile.Record(state: .available, reason: "Synthetic test authority", probeVersion: "test", evidence: ["test"])
        var capabilities = CapabilityProfile(records: ["apple.intent.invoke": available, "apple.codec.url": available])
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
        plan.execution.requiredCapabilities.append("apple.codec.url")
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        capabilities.records.removeValue(forKey: "apple.codec.url")
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
        let object = try AutomationURLReference("https://example.invalid").taggedValue
        let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["url": object], resultCodec: "noValue", parameterCodecs: ["url": "url"])])
        XCTAssertEqual(program.requiredCodecCapabilities, ["apple.codec.url"])
        XCTAssertThrowsError(try AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["url": object])]).validate(route: .systemIntent, phase: .subject))
    }
    func testInvocationPlannerCarriesURLQualificationWithoutEnablingItFromMetadata() throws {
        let app = AppIdentity(logicalID: "app", bundleID: "example.app", platform: "ios", productDigest: String(repeating: "a", count: 64))
        var action = ApplicationSurfaceCatalog.SystemAction(id: "URLIntent", typeName: "Subject.URLIntent", title: "URL", parameters: [.init(name: "url", family: "url", optional: false)], parametersComplete: true, compiled: true, registered: false, executed: false)
        action.resultFamily = "url"
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        let approval = RunApproval(runID: "run", app: app, target: .init(id: "sim", kind: .simulator), environmentID: "owned", effects: [.observe], maximumActions: 2, disposable: false)
        let input = try AutomationCodecRegistry.input("https://example.invalid", parameter: action.parameters[0], catalog: catalog)
        let effects = AutomationActionEffectDeclaration(app: app, actionID: action.id, effects: [.observe], developerConfirmation: "Synthetic fixture reads reference only")
        let available = CapabilityProfile.Record(state: .available, reason: "Synthetic contract", probeVersion: "test", evidence: ["test"])
        var capabilities = CapabilityProfile(records: ["apple.intent.invoke": available])
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog, actionID: action.id, inputs: ["url": input], declaredEffects: effects, approval: approval, capabilities: capabilities))
        capabilities.records["apple.codec.url"] = available
        let plan = try AutomationTemplatePlanner.compile(catalog: catalog, actionID: action.id, inputs: ["url": input], declaredEffects: effects, approval: approval, capabilities: capabilities)
        XCTAssertEqual(plan.execution.requiredCapabilities, ["apple.intent.invoke", "apple.codec.url"])
        XCTAssertEqual(plan.execution.hostProgram?.operations.first?.parameterCodecs, ["url": "url"])
        XCTAssertEqual(plan.execution.hostProgram?.operations.first?.resultCodec, "url")
        try AutomationURLProgramContract.validate(plan, catalog: catalog)
        var handBuilt = plan
        handBuilt.execution.hostProgram?.operations[0].parameters["url"] = .text("file:///private/tmp/customer.txt")
        handBuilt.execution.hostProgram?.operations[0].parameterCodecs = nil
        handBuilt.execution.hostProgram?.operations[0].resultCodec = "noValue"
        handBuilt.execution.requiredCapabilities.removeAll { $0 == "apple.codec.url" }
        XCTAssertThrowsError(try AutomationURLProgramContract.validate(handBuilt, catalog: catalog))
        handBuilt = plan; handBuilt.execution.hostProgram?.operations[0].resultCodec = "text"
        XCTAssertThrowsError(try AutomationURLProgramContract.validate(handBuilt, catalog: catalog))
        var wrongDeclaration = catalog; wrongDeclaration.systemActions[0].parameters[0].family = "text"
        XCTAssertThrowsError(try AutomationURLProgramContract.validate(plan, catalog: wrongDeclaration))
    }
}
