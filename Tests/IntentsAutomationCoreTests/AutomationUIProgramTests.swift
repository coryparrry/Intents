import XCTest
@testable import IntentsAutomationCore

final class AutomationUIProgramTests: XCTestCase, @unchecked Sendable {
    func testRoleLocatorOnlyAllowsOrdinaryTextFillWithoutReadingSensitiveLabels() throws {
        for role in ["textbox", "searchbox"] {
            let program = AutomationUIProgram(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.role, role), binding: "query")], bindings: ["query": "public"])
            try program.validate(phase: .subject)
            let goal = AutomationNavigationGoal(id: "goal", instruction: "Find field", endpoint: .init(.role, role))
            XCTAssertThrowsError(try goal.validate())
            XCTAssertEqual(try JSONDecoder().decode(AutomationUIProgram.self, from: JSONEncoder().encode(program)), program)
            for kind in [AutomationUIProgram.Operation.Kind.tap, .readProperty, .observeProperty, .locate, .assertEndpoint] {
                var invalid = program; invalid.operations[0].kind = kind
                XCTAssertThrowsError(try invalid.validate(phase: .subject))
            }
        }
        let invalid = AutomationUIProgram(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.role, "AXSecureTextField"), binding: "query")], bindings: ["query": "public"])
        XCTAssertThrowsError(try invalid.validate(phase: .subject))
    }
    func testExactButtonRoleOnlyQualifiesLabelTaps() throws {
        let role = AutomationUIProgram.Locator(.label, "Wrong record", role: .button)
        let program = AutomationUIProgram(operations: [.init(id: "choose", kind: .tap, locator: role)])
        try program.validate(phase: .setup)
        let decoded = try JSONDecoder().decode(AutomationUIProgram.self, from: JSONEncoder().encode(program))
        XCTAssertEqual(decoded, program)
        for kind in [AutomationUIProgram.Operation.Kind.fillBinding, .readProperty, .observeProperty, .assertEndpoint, .locate] {
            var other = program; other.operations[0].kind = kind
            XCTAssertThrowsError(try other.validate(phase: .setup))
        }
        var other = program; other.operations[0].locator?.kind = .testId
        XCTAssertThrowsError(try other.validate(phase: .setup))
        let goal = AutomationNavigationGoal(id: "goal", instruction: "Open control", endpoint: role)
        XCTAssertThrowsError(try goal.validate())
    }
    func testPublicSidecarGoldenHasIdenticalNativePayloadAndDigest() throws {
        let url = Bundle.module.url(forResource: "ui-program", withExtension: "json", subdirectory: "Fixtures")!
        let expected = try JSONDecoder().decode(AutomationJSON.self, from: Data(contentsOf: url))
        let program = AutomationUIProgram(operations: [
            .init(id: "first", kind: .fillBinding, locator: .init(.testId, "first"), binding: "A"),
            .init(id: "second", kind: .fillBinding, locator: .init(.label, "é / 💫"), binding: "a"),
            .init(id: "read", kind: .readProperty, locator: .init(.label, "Read"), property: "text")], bindings: ["A": "quote\"\n /", "a": "é 💫\u{2028}"])
        let actual = try program.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1), phase: .setup, operationID: "attempt:setup", digestVersion: .legacyV1)
        XCTAssertEqual(actual, expected)
    }
    func testVersionedNumericBindingsHaveIdenticalSwiftAndTypeScriptGoldenDigests() throws {
        let program = AutomationUIProgram(operations: [
            .init(id: "first", kind: .fillBinding, locator: .init(.testId, "first"), binding: "10"),
            .init(id: "second", kind: .fillBinding, locator: .init(.label, "é / 💫"), binding: "2"),
            .init(id: "__proto__", kind: .readProperty, locator: .init(.label, "Read"), property: "text")],
            bindings: ["10": "quote\"\n /", "2": "é 💫\u{2028}"])
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1)
        for (name, version) in [("ui-program-v2", AutomationUIPayloadDigestVersion.lexicalV2), ("ui-program-v1-numeric", .legacyV1)] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            let expected = try JSONDecoder().decode(AutomationJSON.self, from: Data(contentsOf: url))
            let actual = try program.payload(scope: scope, phase: .setup, operationID: "attempt:setup", digestVersion: version)
            XCTAssertEqual(actual, expected)
        }
        let current = try program.payload(scope: scope, phase: .setup, operationID: "attempt:setup", digestVersion: .lexicalV2)
        XCTAssertEqual(current.object?["digestVersion"], .number(2))
        let legacy = try program.payload(scope: scope, phase: .setup, operationID: "attempt:setup", digestVersion: .legacyV1)
        XCTAssertNil(legacy.object?["digestVersion"])
        XCTAssertEqual(try program.payload(scope: scope, phase: .setup, operationID: "attempt:setup"), legacy)
        XCTAssertNotEqual(current.object?["payloadDigest"], legacy.object?["payloadDigest"])
        XCTAssertEqual(try JSONDecoder().decode(AutomationUIProgram.self, from: JSONEncoder().encode(program)), program)
    }
    func testProgramsRejectUnboundMutationObserverMutationAndAmbiguousFieldsBeforeLaunch() throws {
        var program = AutomationUIProgram(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.testId, "field"), binding: "value")])
        XCTAssertThrowsError(try program.validate(phase: .setup))
        program.bindings["value"] = "approved"
        XCTAssertThrowsError(try program.validate(phase: .observe))
        try program.validate(phase: .setup)
        program.operations[0].property = "text"
        XCTAssertThrowsError(try program.validate(phase: .setup))
        program = .init(operations: [.init(id: "scroll", kind: .scroll, direction: "down"), .init(id: "scroll", kind: .scroll, direction: "up")])
        XCTAssertThrowsError(try program.validate(phase: .setup))
        program = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.label, String(repeating: "💫", count: 513)))])
        XCTAssertThrowsError(try program.validate(phase: .setup))
    }
    func testEscapedPayloadBudgetIsCheckedBeforeAcquisition() throws {
        let operations = (0..<30).map { AutomationUIProgram.Operation(id: "fill\($0)", kind: .fillBinding, locator: .init(.testId, "field\($0)"), binding: "value\($0)") }
        let bindings = Dictionary(uniqueKeysWithValues: (0..<30).map { ("value\($0)", String(repeating: "\n", count: 32768)) })
        let program = AutomationUIProgram(operations: operations, bindings: bindings)
        XCTAssertThrowsError(try program.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1), phase: .setup, operationID: "setup")) { error in
            XCTAssertEqual(error as? AutomationContractError, .invalidPlan("UI payload exceeds frame budget"))
        }
    }
    func testFrameBudgetAdmitsPayloadsUnderTheLimitAndRejectsTheFirstOversizedOne() throws {
        func program(fills: Int) -> AutomationUIProgram {
            let operations = (0..<fills).map { AutomationUIProgram.Operation(id: "fill\($0)", kind: .fillBinding, locator: .init(.testId, "field\($0)"), binding: "value\($0)") }
            let bindings = Dictionary(uniqueKeysWithValues: (0..<fills).map { ("value\($0)", String(repeating: "\n", count: 32768)) })
            return AutomationUIProgram(operations: operations, bindings: bindings)
        }
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1)
        let admitted = try program(fills: 15).payload(scope: scope, phase: .setup, operationID: "setup")
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(admitted).count, 1_047_552)
        XCTAssertThrowsError(try program(fills: 16).payload(scope: scope, phase: .setup, operationID: "setup")) { error in
            XCTAssertEqual(error as? AutomationContractError, .invalidPlan("UI payload exceeds frame budget"))
        }
    }
    func testCanonicalJSONRejectsNumbersThatAreNotExactSafeIntegers() throws {
        let rejected: [AutomationJSON] = [
            .number(1.5), .number(-0.5), .number(.infinity), .number(-.infinity), .number(.nan),
            .number(9_007_199_254_740_992), .number(-9_007_199_254_740_992), .number(1e300),
            .array([.number(1), .number(2.25)]), .object(["timeoutMs": .number(120_000.5)])]
        for value in rejected {
            for legacy in [true, false] {
                XCTAssertThrowsError(try AutomationCanonicalJSON.encode(value, legacyObjectKeyOrder: legacy), "\(value)") { error in
                    XCTAssertEqual(error as? AutomationContractError, .invalidIdentity)
                }
            }
        }
    }
    func testCanonicalJSONRendersSafeIntegersWithoutFractionOrExponent() throws {
        let cases: [(AutomationJSON, String)] = [
            (.number(0), "0"), (.number(-0.0), "0"), (.number(2), "2"), (.number(-42), "-42"), (.number(120_000), "120000"),
            (.number(9_007_199_254_740_991), "9007199254740991"), (.number(-9_007_199_254_740_991), "-9007199254740991"),
            (.array([.number(1), .number(-0.0)]), "[1,0]"), (.object(["b": .number(2), "a": .number(1)]), #"{"a":1,"b":2}"#)]
        for (value, expected) in cases {
            XCTAssertEqual(String(decoding: try AutomationCanonicalJSON.encode(value), as: UTF8.self), expected)
            XCTAssertEqual(String(decoding: try AutomationCanonicalJSON.encode(value, legacyObjectKeyOrder: true), as: UTF8.self), expected)
        }
        XCTAssertNotEqual(try AutomationCanonicalJSON.encode(.number(1)), try AutomationCanonicalJSON.encode(.number(2)))
    }
}
