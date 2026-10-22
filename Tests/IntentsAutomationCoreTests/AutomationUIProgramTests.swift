import XCTest
@testable import IntentsAutomationCore

final class AutomationUIProgramTests: XCTestCase, @unchecked Sendable {
    func testHierarchyReadbackIsBoundedWithoutSplittingUnicodeScalars() throws {
        let short = try UIHostHierarchyReadback.capture("Window: Sign in\nButton: Continue")
        XCTAssertEqual(short.properties?["hierarchy"]?.value, "Window: Sign in\nButton: Continue")
        XCTAssertEqual(short.properties?["truncated"]?.boolValue, false)
        try UIHostHierarchyReadback.validate(short)
        let description = String(repeating: "a", count: 32_767) + "💫"
        let bounded = try UIHostHierarchyReadback.capture(description)
        XCTAssertEqual(bounded.properties?["hierarchy"]?.value?.utf16.count, 32_767)
        XCTAssertEqual(bounded.properties?["truncated"]?.boolValue, true)
        XCTAssertFalse(bounded.properties?["hierarchy"]?.value?.contains("�") == true)
        try UIHostHierarchyReadback.validate(bounded)
        let exact = try UIHostHierarchyReadback.capture(String(repeating: "💫", count: 16_384))
        XCTAssertEqual(exact.properties?["hierarchy"]?.value?.utf16.count, 32_768)
        XCTAssertEqual(exact.properties?["truncated"]?.boolValue, false)
        XCTAssertThrowsError(try UIHostHierarchyReadback.capture(" \n"))
        var oversized = short
        oversized.properties?["hierarchy"]?.value = String(repeating: "x", count: 32_769)
        XCTAssertThrowsError(try UIHostHierarchyReadback.validate(oversized))
    }

    func testDirectHierarchyReadbackCannotCarryQueriesOrMutationInputs() throws {
        let step = UIHostStep(id: "initial-hierarchy", kind: .readHierarchy)
        try AutomationUIProgram(steps: [step]).validate(phase: .subject)
        try AutomationUIProgram(steps: [step]).validate(phase: .observe)
        var invalid = step; invalid.query = .init(label: "Invented app name")
        XCTAssertThrowsError(try AutomationUIProgram(steps: [invalid]).validate(phase: .subject))
        invalid = step; invalid.text = "Enter data"
        XCTAssertThrowsError(try AutomationUIProgram(steps: [invalid]).validate(phase: .subject))
        invalid = step; invalid.environment = ["FIXTURE": "write"]
        XCTAssertThrowsError(try AutomationUIProgram(steps: [invalid]).validate(phase: .subject))
        invalid = step; invalid.equals = .init(kind: "bool", boolValue: true)
        XCTAssertThrowsError(try AutomationUIProgram(steps: [invalid]).validate(phase: .subject))
    }

    func testRoleLocatorOnlyAllowsOrdinaryTextFillWithoutReadingSensitiveLabels() throws {
        for role in ["textbox", "searchbox"] {
            let program = AutomationUIProgram(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.role, role), binding: "query")], bindings: ["query": "public"])
            try program.validate(phase: .subject)
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
    func testCanonicalJSONRejectsNumbersThatAreNotExactSafeIntegers() throws {
        let rejected: [AutomationJSON] = [
            .number(1.5), .number(-0.5), .number(.infinity), .number(-.infinity), .number(.nan),
            .number(9_007_199_254_740_992), .number(-9_007_199_254_740_992), .number(1e300),
            .array([.number(1), .number(2.25)]), .object(["timeoutMs": .number(120_000.5)])]
        for value in rejected {
            XCTAssertThrowsError(try AutomationCanonicalJSON.encode(value), "\(value)") { error in
                XCTAssertEqual(error as? AutomationContractError, .invalidIdentity)
            }
        }
    }
    func testCanonicalJSONRendersSafeIntegersWithoutFractionOrExponent() throws {
        let cases: [(AutomationJSON, String)] = [
            (.object(["2": .string("b"), "10": .string("a"), "é": .string("accent")]), #"{"10":"a","2":"b","é":"accent"}"#),
            (.number(0), "0"), (.number(-0.0), "0"), (.number(2), "2"), (.number(-42), "-42"), (.number(120_000), "120000"),
            (.number(9_007_199_254_740_991), "9007199254740991"), (.number(-9_007_199_254_740_991), "-9007199254740991"),
            (.array([.number(1), .number(-0.0)]), "[1,0]"), (.object(["b": .number(2), "a": .number(1)]), #"{"a":1,"b":2}"#)]
        for (value, expected) in cases {
            XCTAssertEqual(String(decoding: try AutomationCanonicalJSON.encode(value), as: UTF8.self), expected)
        }
        XCTAssertNotEqual(try AutomationCanonicalJSON.encode(.number(1)), try AutomationCanonicalJSON.encode(.number(2)))
    }
}
