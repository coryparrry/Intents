#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSourcePlatformPredicateBuildTests: XCTestCase, @unchecked Sendable {
    func testActualSelectedMacPlatformBranchesReconcileWithoutRuntimeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_SOURCE_PLATFORM_BUILD"] == "1",
              let path = ProcessInfo.processInfo.environment["INTENTS_SOURCE_PLATFORM_ROOT"] else {
            throw XCTSkip("Authored platform-condition build-only qualification is opt-in")
        }
        let parent = try AutomationPath.canonical(URL(fileURLWithPath: path))
        let root = parent.appendingPathComponent("platform-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let original = root.appendingPathComponent("original"), fixture = try AutomationMacInputProbeFixture.write(at: original)
        let source = AutomationMacInputProbeFixture.source.replacingOccurrences(of: "struct HostProbeIntent: AppIntent {", with:
            "#if os(macOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)\nstruct HostProbeIntent: AppIntent {") + """

        #else
        struct HostProbeIntent: AppIntent {
            static let title: LocalizedStringResource = "Inactive platform"
            func perform() async throws -> some IntentResult { throw ProbePerformForbidden() }
        }
        struct ProbePerformForbidden: Error {}
        #endif
        """
        try Data(source.utf8).write(to: original.appendingPathComponent("Subject.swift"))
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(fixture.project).candidates.first)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let prepared = try await AutomationPreparation().prepare(candidate: candidate,
            approval: .init(sourceRoot: original.path, candidateID: candidate.id, configuration: "Debug", target: AutomationMacGUIIdentity.currentTarget()),
            sessionRoot: root.appendingPathComponent("prepare-" + UUID().uuidString), templates: templates, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
        let syntax = try XCTUnwrap(prepared.sourceSyntax), conditions = try XCTUnwrap(syntax.compilationConditions)
        XCTAssertEqual(conditions.platformPredicates, .init(version: 1, operatingSystem: "macOS", environment: "native"))
        let action = try XCTUnwrap(prepared.catalog.systemActions.first { $0.id == "HostProbeIntent" })
        XCTAssertEqual(action.sourceReconciliation, "syntaxCandidate"); XCTAssertEqual(action.sourceCandidates?.count, 1)
        XCTAssertEqual(syntax.declarations.filter { $0.name == "HostProbeIntent" }.count, 2)
        XCTAssertTrue(action.compiled); XCTAssertFalse(action.executed); XCTAssertFalse(action.registered)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
        print("Owned Swift platform-condition build: \(root.path); subjectSHA256 \(prepared.host.app.productDigest ?? "unknown"); hostSHA256 \(prepared.host.hostProductDigest)")
        print("Exact selected native Mac OS/environment settings reconciled active source only; no app/intent runtime launched; compiler source coverage remains partial")
    }
}
#endif
