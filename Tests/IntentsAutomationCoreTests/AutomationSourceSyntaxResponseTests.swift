#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

/// Scanner-output validation without Xcode, SwiftSyntax or a compiled scanner.
final class AutomationSourceSyntaxResponseTests: XCTestCase {
    private let digest = String(repeating: "d", count: 64)
    private let inputs = [
        AutomationSourceSyntaxDiscovery.Input(relativePath: "A.swift", owner: "App", sha256: String(repeating: "a", count: 64), source: "struct A {}\n"),
        AutomationSourceSyntaxDiscovery.Input(relativePath: "B.swift", owner: "App", sha256: String(repeating: "b", count: 64), source: "struct B {}\n")
    ]
    private func declaration(_ path: String, line: Int = 1, protocols: [String] = ["AppIntent"]) -> [String: Any] {
        ["name": path.prefix(1).description, "protocols": protocols, "relativePath": path, "owner": "App", "line": line,
         "qualifiedName": "App." + path.prefix(1), "column": 1]
    }
    private func response(graphDigest: String? = nil, inputs: [AutomationSourceSyntaxDiscovery.Input]? = nil,
                          declarations: [[String: Any]]? = nil, recovery: [String] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "graphDigest": graphDigest ?? digest,
            "inputs": (inputs ?? self.inputs).map { ["relativePath": $0.relativePath, "owner": $0.owner, "sha256": $0.sha256] },
            "declarations": declarations ?? [declaration("A.swift"), declaration("B.swift")],
            "parseRecoveryFiles": recovery])
    }
    private func validate(_ data: Data) throws -> (all: [AutomationSourceDeclaration], retained: [AutomationSourceDeclaration], gaps: [String]) {
        try AutomationSourceSyntaxDiscovery.validateResponse(data, graphDigest: digest, inputs: inputs)
    }

    func testExactResponseRetainsEveryDeclarationWithoutGaps() throws {
        let result = try validate(try response())
        XCTAssertEqual(result.all.map(\.relativePath), ["A.swift", "B.swift"])
        XCTAssertEqual(result.retained, result.all)
        XCTAssertEqual(result.gaps, [])
    }
    func testDifferentGraphDigestOrInputListIsRejected() throws {
        XCTAssertThrowsError(try validate(try response(graphDigest: String(repeating: "e", count: 64))))
        XCTAssertThrowsError(try validate(try response(inputs: inputs.reversed())))
        XCTAssertThrowsError(try validate(try response(inputs: [inputs[0]])))
    }
    func testDeclarationOutsideItsInputBoundsOrWithoutProtocolsIsRejected() throws {
        XCTAssertNoThrow(try validate(try response(declarations: [declaration("A.swift", line: 2)])))
        for invalid in [declaration("A.swift", line: 0), declaration("A.swift", line: 3),
                        declaration("Unknown.swift"), declaration("A.swift", protocols: [])] {
            XCTAssertThrowsError(try validate(try response(declarations: [invalid])))
        }
        var foreignOwner = declaration("A.swift"); foreignOwner["owner"] = "Other"
        XCTAssertThrowsError(try validate(try response(declarations: [foreignOwner])))
    }
    func testParseRecoveryRequiresAKnownInputAndDropsItsDeclarations() throws {
        XCTAssertThrowsError(try validate(try response(recovery: ["Unknown.swift"])))
        let result = try validate(try response(recovery: ["B.swift"]))
        XCTAssertEqual(result.all.map(\.relativePath), ["A.swift", "B.swift"])
        XCTAssertEqual(result.retained.map(\.relativePath), ["A.swift"])
        XCTAssertEqual(result.gaps, ["SwiftSyntax parse recovery occurred in B.swift"])
    }
    func testBudgetExclusionsListFiftyPathsAndSummarizeTheRest() {
        XCTAssertEqual(AutomationSourceSyntaxDiscovery.exclusionGaps([]), [])
        XCTAssertEqual(AutomationSourceSyntaxDiscovery.exclusionGaps(["A.swift"]), ["Source syntax input budget excludes A.swift"])
        let fifty = (1...50).map { "File\($0).swift" }
        XCTAssertEqual(AutomationSourceSyntaxDiscovery.exclusionGaps(fifty).count, 50)
        let gaps = AutomationSourceSyntaxDiscovery.exclusionGaps(fifty + ["File51.swift"])
        XCTAssertEqual(gaps.count, 51)
        XCTAssertFalse(gaps.contains("Source syntax input budget excludes File51.swift"))
        XCTAssertEqual(gaps.last, "Source syntax input budget excludes 51 files; only the first 50 paths are listed.")
    }
}
#endif
