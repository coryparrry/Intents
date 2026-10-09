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
