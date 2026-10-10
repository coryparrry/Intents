import Foundation
import XCTest
@testable import IntentsAutomationCore

/// Actual extractor rejection, not codec or runtime qualification.
final class AutomationAppleNestedArrayBuildTests: XCTestCase {
    #if os(macOS)
    func testSelectedToolchainRejectsAuthoredNestedArrayMetadataWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_NESTED_ARRAY_BUILD"] == "1",
              let parentPath = ProcessInfo.processInfo.environment["INTENTS_NESTED_ARRAY_BUILD_ROOT"] else {
            throw XCTSkip("Authored nested-array extractor check is opt-in")
        }
        let parent = try AutomationPath.canonical(URL(fileURLWithPath: parentPath))
        let root = parent.appendingPathComponent("nested-array-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let original = root.appendingPathComponent("original")
        let fixture = try AutomationMacInputProbeFixture.write(at: original, sourceKind: .nestedArrays)
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(fixture.project).candidates.first)
        let target = try AutomationMacGUIIdentity.currentTarget()
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let session = root.appendingPathComponent("prepare")
        do {
            _ = try await AutomationPreparation().prepare(candidate: candidate,
                approval: .init(sourceRoot: original.path, candidateID: candidate.id, configuration: "Debug", target: target),
                sessionRoot: session, templates: templates,
                developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
            XCTFail("Toolchain behavior changed; nested arrays need separate qualification before admission")
        } catch AutomationContractError.missingEvidence(let reason) {
            XCTAssertTrue(reason.contains("Associated host build failed"), reason)
            let log = try String(contentsOf: session.appendingPathComponent("build.log"), encoding: .utf8)
            XCTAssertTrue(log.contains("Command ExtractAppIntentsMetadata failed"))
            XCTAssertTrue(log.contains("Invalid parameter not satisfying: ![memberValueType isKindOfClass:[LN_TYPE(ArrayValueType) class]]"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("prepared-application.json").path))
            print("Owned nested-array extractor rejection retained: \(root.path); no prepared record or runtime launch")
        }
    }
    #endif
}
