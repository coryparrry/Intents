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
        XCTAssertThrowsError(try program.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1), phase: .setup, operationID: "setup"))
    }
}
