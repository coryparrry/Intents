#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

/// Approval guards that must reject before any snapshot, intake refresh or build.
final class AutomationPreparationGuardTests: XCTestCase {
    private let target = TargetIdentity(id: UUID().uuidString, kind: .simulator, loginSession: nil)
    private func layout() throws -> (root: URL, source: URL, project: URL, session: URL) {
        let root = try AutomationPath.canonical(URL(fileURLWithPath: "/private/tmp")).appendingPathComponent("preparation-guard-" + UUID().uuidString)
        let source = root.appendingPathComponent("source"), project = source.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, source, project, root.appendingPathComponent("session"))
    }
    private func candidate(_ project: URL, kind: AutomationApplicationCandidate.Kind = .sourceTarget, targetID: String? = "SUBJECT") -> AutomationApplicationCandidate {
        AutomationApplicationCandidate(id: "subject", name: "Subject", kind: kind, containerPath: project.path, targetID: targetID,
            bundleID: "example.Subject", platform: "ios", architectures: ["arm64"], configurations: ["Debug"])
    }
    private func prepare(_ preparation: AutomationPreparation, _ candidate: AutomationApplicationCandidate, _ approval: AutomationBuildApproval, session: URL) async throws {
        _ = try await preparation.prepare(candidate: candidate, approval: approval, sessionRoot: session,
            templates: session.appendingPathComponent("templates"), developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
    }
    private func assertInvalidPlan(_ body: () async throws -> Void, _ label: String) async {
        do { try await body(); XCTFail("Prepared: " + label) }
        catch AutomationContractError.invalidPlan {}
        catch { XCTFail("\(label): unexpected \(error)") }
    }

    func testMismatchedApprovalRejectsWithoutCreatingASnapshot() async throws {
        let l = try layout(), preparation = AutomationPreparation()
        let approval = AutomationBuildApproval(sourceRoot: l.source.path, candidateID: "subject", configuration: "Debug", target: target)
        var wrongID = approval; wrongID.candidateID = "other"
        var wrongConfiguration = approval; wrongConfiguration.configuration = "Release"
        await assertInvalidPlan({ try await self.prepare(preparation, self.candidate(l.project), wrongID, session: l.session) }, "candidate ID")
        await assertInvalidPlan({ try await self.prepare(preparation, self.candidate(l.project), wrongConfiguration, session: l.session) }, "configuration")
        await assertInvalidPlan({ try await self.prepare(preparation, self.candidate(l.project, kind: .installedProduct), approval, session: l.session) }, "kind")
        await assertInvalidPlan({ try await self.prepare(preparation, self.candidate(l.project, targetID: nil), approval, session: l.session) }, "target")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.session.path))
    }
    func testProjectOutsideTheApprovedSourceRootIsRejectedBeforeSnapshot() async throws {
        let l = try layout(), preparation = AutomationPreparation()
        let outside = l.root.appendingPathComponent("Outside.xcodeproj")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let approval = AutomationBuildApproval(sourceRoot: l.source.path, candidateID: "subject", configuration: "Debug", target: target)
        do { try await prepare(preparation, candidate(outside), approval, session: l.session); XCTFail("Escaped source root") }
        catch AutomationContractError.invalidIdentity {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.session.path))
    }
    func testIdleCancellationDoesNotLatchIntoLaterPreparation() async throws {
        let l = try layout(), preparation = AutomationPreparation()
        let stopped = await preparation.cancel(); XCTAssertTrue(stopped)
        var approval = AutomationBuildApproval(sourceRoot: l.source.path, candidateID: "subject", configuration: "Debug", target: target)
        approval.candidateID = "other"
        // A latched cancellation would surface as CancellationError instead of the approval guard.
        await assertInvalidPlan({ try await self.prepare(preparation, self.candidate(l.project), approval, session: l.session) }, "after cancel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.session.path))
    }
}
#endif
