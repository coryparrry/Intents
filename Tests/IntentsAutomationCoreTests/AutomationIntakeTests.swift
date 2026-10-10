import XCTest
@testable import IntentsAutomationCore

final class AutomationIntakeTests: XCTestCase {
    func testUnsupportedWorkspaceGroupDoesNotDiscoverAnUnrelatedInRootProject() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("Subject.xcworkspace"), project = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<Workspace><Group location=\"absolute:/outside\"><FileRef location=\"group:App.xcodeproj\"/></Group></Workspace>".utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
        let resolved = try AutomationWorkspaceProjects.resolve(workspace)
        XCTAssertTrue(resolved.projects.isEmpty); XCTAssertFalse(resolved.gaps.isEmpty)
    }
    func testWorkspaceProjectResolutionKeepsReferencesInsideTheAuthorisedSourceRoot() throws {
        let container = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent("Source"), workspace = root.appendingPathComponent("Subject.xcworkspace")
        defer { try? FileManager.default.removeItem(at: container) }
        for directory in ["Source/Subject.xcworkspace", "Source/App.xcodeproj", "Source/Top.xcodeproj", "Source/Sub/Nested.xcodeproj", "Outside/Outside.xcodeproj", "SourceEvil/App.xcodeproj"] {
            try FileManager.default.createDirectory(at: container.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.xcodeproj"), withDestinationURL: container.appendingPathComponent("Outside/Outside.xcodeproj"))
        let canonicalContainer = try AutomationPath.canonical(container)
        let outside = "Workspace project is outside the authorised source root.", unavailable = "A referenced workspace project is unavailable."
        let unsupportedReference = "An external or unsupported workspace reference requires explicit preparation."
        let unsupportedGroup = "An unsupported workspace group requires explicit preparation."
        let cases: [(name: String, xml: String, projects: [String], gaps: [String])] = [
            ("container reference", "<FileRef location=\"container:App.xcodeproj\"/>", ["Source/App.xcodeproj"], []),
            ("nested group reference", "<Group location=\"group:Sub\"><FileRef location=\"group:Nested.xcodeproj\"/></Group>", ["Source/Sub/Nested.xcodeproj"], []),
            ("container reference inside a group", "<Group location=\"group:Sub\"><FileRef location=\"container:App.xcodeproj\"/></Group>", ["Source/App.xcodeproj"], []),
            ("closed group restores parent", "<Group location=\"group:Sub\"></Group><FileRef location=\"group:Top.xcodeproj\"/>", ["Source/Top.xcodeproj"], []),
            ("closed unsupported group restores parent", "<Group location=\"absolute:/outside\"></Group><FileRef location=\"group:App.xcodeproj\"/>", ["Source/App.xcodeproj"], [unsupportedGroup]),
            ("duplicate references", "<FileRef location=\"container:App.xcodeproj\"/><FileRef location=\"group:App.xcodeproj\"/><FileRef location=\"group:Sub/../App.xcodeproj\"/>", ["Source/App.xcodeproj"], []),
            ("sorted distinct references", "<FileRef location=\"group:Top.xcodeproj\"/><FileRef location=\"container:App.xcodeproj\"/>", ["Source/App.xcodeproj", "Source/Top.xcodeproj"], []),
            ("parent traversal", "<FileRef location=\"group:../Outside/Outside.xcodeproj\"/>", [], [outside]),
            ("container parent traversal", "<FileRef location=\"container:../Outside/Outside.xcodeproj\"/>", [], [outside]),
            ("sibling root sharing a prefix", "<FileRef location=\"group:../SourceEvil/App.xcodeproj\"/>", [], [outside]),
            ("in-root symlink to outside project", "<FileRef location=\"group:Link.xcodeproj\"/>", [], [outside]),
            ("missing project", "<FileRef location=\"group:Missing.xcodeproj\"/>", [], [unavailable]),
            ("non-project reference", "<FileRef location=\"group:Package.swift\"/>", [], [unsupportedReference]),
            ("absolute reference", "<FileRef location=\"absolute:\(root.path)/App.xcodeproj\"/>", [], [unsupportedReference]),
            ("reference without a kind", "<FileRef location=\"App.xcodeproj\"/>", [], [unsupportedReference]),
            ("reference inside unsupported group", "<Group location=\"absolute:/outside\"><FileRef location=\"group:App.xcodeproj\"/></Group>", [], [unsupportedGroup, unsupportedReference]),
            ("mixed in-root and outside references", "<FileRef location=\"group:Link.xcodeproj\"/><FileRef location=\"container:App.xcodeproj\"/>", ["Source/App.xcodeproj"], [outside]),
        ]
        for testCase in cases {
            try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Workspace version=\"1.0\">\(testCase.xml)</Workspace>".utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
            let resolved = try AutomationWorkspaceProjects.resolve(workspace)
            XCTAssertEqual(resolved.projects.map(\.path), testCase.projects.map { canonicalContainer.appendingPathComponent($0).path }, testCase.name)
            XCTAssertEqual(resolved.gaps, testCase.gaps, testCase.name)
        }
    }
    func testWorkspaceProjectResolutionRejectsDoctypeAndOversizedDocuments() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("Subject.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func groups(_ depth: Int) -> String { String(repeating: "<Group>", count: depth) + String(repeating: "</Group>", count: depth) }
        func elements(_ count: Int) -> String { String(repeating: "<FileRef/>", count: count - 1) }
        let reference = "<FileRef location=\"container:App.xcodeproj\"/>"
        let cases: [(name: String, contents: String, accepted: Bool)] = [
            ("plain workspace", "<Workspace>\(reference)</Workspace>", true),
            ("internal entity declaration", "<!DOCTYPE Workspace [<!ENTITY project \"App.xcodeproj\">]><Workspace><FileRef location=\"container:&project;\"/></Workspace>", false),
            ("lowercase doctype", "<!doctype Workspace><Workspace>\(reference)</Workspace>", false),
            ("external entity declaration", "<!DOCTYPE Workspace SYSTEM \"file:///etc/passwd\"><Workspace>\(reference)</Workspace>", false),
            ("64 nested groups", "<Workspace>\(groups(64))</Workspace>", true),
            ("65 nested groups", "<Workspace>\(groups(65))</Workspace>", false),
            ("10000 elements", "<Workspace>\(elements(10_000))</Workspace>", true),
            ("10001 elements", "<Workspace>\(elements(10_001))</Workspace>", false),
        ]
        for testCase in cases {
            try Data(testCase.contents.utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
            if testCase.accepted {
                XCTAssertNoThrow(try AutomationWorkspaceProjects.resolve(workspace), testCase.name)
            } else {
                XCTAssertThrowsError(try AutomationWorkspaceProjects.resolve(workspace), testCase.name) { XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity, testCase.name) }
            }
        }
        try Data("<Workspace>\(reference)</Workspace>".utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
        XCTAssertEqual(try AutomationWorkspaceProjects.resolve(workspace).projects, [try AutomationPath.canonical(root.appendingPathComponent("App.xcodeproj"))])
    }
    func testSourceTargetDiscoveryExcludesLibrariesAndTestsWithoutRunningScripts() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".xcodeproj")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let objects: [String: Any] = ["APP": ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application"],
                                     "LIB": ["isa": "PBXNativeTarget", "name": "Library", "productType": "com.apple.product-type.library.static"],
                                     "TEST": ["isa": "PBXNativeTarget", "name": "Tests", "productType": "com.apple.product-type.bundle.ui-testing"]]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0).write(to: root.appendingPathComponent("project.pbxproj"))
        let result = try AutomationApplicationIntake.assess(root)
        XCTAssertEqual(result.candidates.map(\.name), ["Subject"]); XCTAssertEqual(result.candidates.first?.targetID, "APP")
        XCTAssertTrue(result.requiresBuildApproval); XCTAssertNil(result.candidates.first?.app); XCTAssertFalse(result.gaps.isEmpty)
    }
    func testRealFrozenProductIntakeReadsActualPlatformArchitectureAndProductBytes() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_SUBJECT_BUNDLE"] else { throw XCTSkip("No explicit frozen product profile") }
        let result = try AutomationApplicationIntake.assess(URL(fileURLWithPath: path))
        XCTAssertEqual(result.candidates.count, 1); XCTAssertEqual(result.candidates[0].bundleID, "com.coryparry.FlipBook")
        XCTAssertEqual(result.candidates[0].platform, "ios"); XCTAssertEqual(result.candidates[0].architectures, ["arm64", "x86_64"])
        XCTAssertEqual(result.candidates[0].app?.productDigest, "6311e6b95db95e606946f48eedb05a2740824a37c7d8004e9b82e8cd8ed3b2f4")
        XCTAssertFalse(result.requiresBuildApproval)
    }
    func testMalformedExecutableAndFatArchitectureTableAreNotApps() {
        XCTAssertThrowsError(try AutomationMachOIdentity.architectures(Data("not a MachO application".utf8)))
        XCTAssertThrowsError(try AutomationMachOIdentity.architectures(Data([0xca,0xfe,0xba,0xbe,0,0,0,2,0,0,0,0])))
    }
    func testThinAndUniversalMachOHeadersReportQualifiedArchitectures() throws {
        let arm64: UInt32 = 0x0100000c, x86_64: UInt32 = 0x01000007
        XCTAssertEqual(try AutomationMachOIdentity.architectures(machO(0xfeedfacf, [arm64], stride: 0)), ["arm64"])
        XCTAssertEqual(try AutomationMachOIdentity.architectures(machO(0xfeedfacf, [x86_64], stride: 0, big: false)), ["x86_64"])
        XCTAssertEqual(try AutomationMachOIdentity.architectures(machO(0xcafebabe, [x86_64, arm64], stride: 20)), ["arm64", "x86_64"])
        XCTAssertEqual(try AutomationMachOIdentity.architectures(machO(0xcafebabe, [x86_64, arm64], stride: 20, big: false)), ["arm64", "x86_64"])
        XCTAssertEqual(try AutomationMachOIdentity.architectures(machO(0xcafebabf, [x86_64, arm64], stride: 32)), ["arm64", "x86_64"])
        XCTAssertEqual(try AutomationMachOIdentity.architectures(machO(0xcafebabf, [arm64, x86_64], stride: 32, big: false)), ["arm64", "x86_64"])
    }
    func testUniversalMachOHeadersRejectDuplicateUnknownAndOutOfBoundsTables() {
        let arm64: UInt32 = 0x0100000c, x86_64: UInt32 = 0x01000007
        func rejects(_ data: Data, _ expected: AutomationContractError, line: UInt = #line) {
            XCTAssertThrowsError(try AutomationMachOIdentity.architectures(data), line: line) { XCTAssertEqual($0 as? AutomationContractError, expected, line: line) }
        }
        let unqualified = AutomationContractError.invalidPlan("Unqualified CPU architecture")
        rejects(machO(0xcafebabe, [arm64, arm64], stride: 20), .invalidIdentity)
        rejects(machO(0xcafebabf, [arm64, arm64], stride: 32), .invalidIdentity)
        rejects(machO(0xcafebabe, [arm64, 0x0000000c], stride: 20), unqualified)
        rejects(machO(0xfeedfacf, [0x00000007], stride: 0), unqualified)
        rejects(machO(0xcafebabe, [], stride: 20, count: 0, padding: 20), .invalidIdentity)
        rejects(machO(0xcafebabe, Array(repeating: 0, count: 17), stride: 20), .invalidIdentity)
        rejects(machO(0xcafebabe, [x86_64, arm64], stride: 20).prefix(8 + 20 + 19), .invalidIdentity)
        rejects(machO(0xcafebabf, [x86_64, arm64], stride: 20), .invalidIdentity)
    }
    private func machO(_ magic: UInt32, _ cpus: [UInt32], stride: Int, big: Bool = true, count: UInt32? = nil, padding: Int = 0) -> Data {
        func word(_ value: UInt32) -> [UInt8] {
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
            return big ? bytes : bytes.reversed()
        }
        guard stride > 0 else { return Data(word(magic) + word(cpus[0]) + [UInt8](repeating: 0, count: 24)) }
        let entries = cpus.flatMap { word($0) + [UInt8](repeating: 0, count: stride - 4) }
        return Data(word(magic) + word(count ?? UInt32(cpus.count)) + entries + [UInt8](repeating: 0, count: padding))
    }
}
