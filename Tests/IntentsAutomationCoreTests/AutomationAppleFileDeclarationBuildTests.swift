#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

/// Fixed declarations only. Their perform methods always throw; this test never launches them.
final class AutomationAppleFileDeclarationBuildTests: XCTestCase {
    func testRetainedSDKFileDescriptorMatchesAuthoredInputAndOutput() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verification/Automation/Fixtures/IntentFileDeclarations")
        let data = try Data(contentsOf: root.appendingPathComponent("extract.actionsdata"))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("provenance.json"))) as? [String: Any])
        XCTAssertEqual(AutomationArtifactRegistry.digest(data), provenance["metadataSHA256"] as? String)
        XCTAssertEqual(AutomationArtifactRegistry.digest(try Data(contentsOf: root.appendingPathComponent("QualifiedDeclarations.swift.txt"))), provenance["sourceSHA256"] as? String)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let actions = try XCTUnwrap(metadata["actions"] as? [String: [String: Any]])
        XCTAssertEqual(Set(actions.keys), ["FileInputIntent", "FileOutputIntent"])
        let parameter = try XCTUnwrap((actions["FileInputIntent"]?["parameters"] as? [[String: Any]])?.first)
        for descriptor in [parameter["valueType"], actions["FileOutputIntent"]?["outputType"]] {
            let value = try XCTUnwrap(descriptor as? [String: Any])
            XCTAssertTrue(AutomationCodecMetadata.intentFile(value))
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                           Data("{\"intents\":{\"wrapper\":{\"typeIdentifier\":12}}}".utf8))
        }
        XCTAssertNil(AutomationCodecMetadata.primitiveFamily(12))
        XCTAssertNil(AutomationCodecMetadata.inputPrimitiveFamily(12))
        XCTAssertFalse(AutomationCodecMetadata.intentFile(["primitive": ["wrapper": ["typeIdentifier": 12]]]))
        XCTAssertFalse(AutomationCodecMetadata.intentFile(["intents": ["wrapper": ["typeIdentifier": 12, "unexpected": 1]]]))
        XCTAssertEqual(try AutomationInputAdapterProbePlan.samples(family: "intentFile").count, 1)
        XCTAssertFalse(CapabilityProfile().supports(["apple.codec.intentFile"]))
        XCTAssertEqual(provenance["runtimeLaunched"] as? Bool, false)
        XCTAssertEqual(provenance["codecTransportQualified"] as? Bool, false)
    }
    private static let source = """
    import SwiftUI
    import Foundation
    import AppIntents
    import UniformTypeIdentifiers
    @main struct SubjectApp: App {
        var body: some Scene { WindowGroup { Text("Intents file declaration fixture") } }
    }
    struct FileInputIntent: AppIntent {
        static let title: LocalizedStringResource = "File input declaration"
        static let openAppWhenRun = false
        @Parameter(title: "File") var file: IntentFile
        func perform() async throws -> some IntentResult {
            try rejectBusinessDispatch()
            return .result()
        }
    }
    struct FileOutputIntent: AppIntent {
        static let title: LocalizedStringResource = "File output declaration"
        static let openAppWhenRun = false
        func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
            try rejectBusinessDispatch()
            return .result(value: IntentFile(data: Data("authored fixture".utf8), filename: "fixture.txt", type: .plainText))
        }
    }
    private func rejectBusinessDispatch() throws { throw FilePerformForbidden() }
    private struct FilePerformForbidden: Error {}
    """
    func testActualFileDeclarationsBuildWithoutRuntimeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_APPLE_FILE_DECLARATION_BUILD"] == "1",
              let parentPath = ProcessInfo.processInfo.environment["INTENTS_APPLE_FILE_DECLARATION_ROOT"] else {
            throw XCTSkip("Authored IntentFile declaration build-only check is opt-in")
        }
        let parent = try AutomationPath.canonical(URL(fileURLWithPath: parentPath))
        let root = parent.appendingPathComponent("file-declaration-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let original = root.appendingPathComponent("original"), fixture = try AutomationMacInputProbeFixture.write(at: original)
        try Data(Self.source.utf8).write(to: original.appendingPathComponent("Subject.swift"))
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(fixture.project).candidates.first)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let prepared = try await AutomationPreparation().prepare(candidate: candidate,
            approval: .init(sourceRoot: original.path, candidateID: candidate.id, configuration: "Debug", target: AutomationMacGUIIdentity.currentTarget()),
            sessionRoot: root.appendingPathComponent("prepare"), templates: templates, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
        XCTAssertEqual(Set(prepared.catalog.systemActions.map(\.id)), ["FileInputIntent", "FileOutputIntent"])
        XCTAssertTrue(prepared.catalog.systemActions.allSatisfy { $0.compiled && !$0.executed && !$0.registered })
        let input = try XCTUnwrap(prepared.catalog.systemActions.first { $0.id == "FileInputIntent" })
        XCTAssertEqual(input.parameters.count, 1)
        XCTAssertEqual(input.parameters.first?.family, "intentFile")
        XCTAssertEqual(prepared.catalog.systemActions.first { $0.id == "FileOutputIntent" }?.resultFamily, "intentFile")
        print("Owned IntentFile declaration build: \(root.path); subjectSHA256 \(prepared.host.app.productDigest ?? "unknown"); hostSHA256 \(prepared.host.hostProductDigest)")
        print("Actual Apple file input/result declarations extracted; no app, adapter, perform or intent runtime launched; binary transport remains unqualified")
    }
}
#endif
