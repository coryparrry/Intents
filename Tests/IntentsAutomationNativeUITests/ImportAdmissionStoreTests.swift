#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class ImportAdmissionStoreTests: XCTestCase {
    func testImportsPreserveBlockedApplicationSelectionAndPendingConfirmation() async throws {
        for blocker in ["unresolved", "confirmation", "closed"] {
            for route in ["repository", "recipe", "ipa"] {
                let root = URL(fileURLWithPath: "/private/tmp/import-admission-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let script = root.appendingPathComponent("package.sh")
                try Data("// Fixture only\n".utf8).write(to: root.appendingPathComponent("Package.swift"))
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
                let recipe = try AutomationSourceRecipe.swiftPMPackaging(source: root, script: script)
                // If a regression schedules recipe work, fail before any command launch.
                try Data("#!/bin/sh\nexit 1\n".utf8).write(to: script)
                let archive = root.appendingPathComponent("invalid.ipa")
                try Data("not an archive".utf8).write(to: archive)
                let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"))
                await model.ownershipRecoveryTask?.value
                model.selectedURL = root
                let commandID = UUID()
                switch blocker {
                case "unresolved":
                    model.retainUnresolvedRequest(runID: "retained", target: .init(id: UUID().uuidString, kind: .simulator))
                case "confirmation":
                    model.commandRequests[commandID] = .init(requestID: commandID,
                        digest: String(repeating: "a", count: 64), state: "awaitingApproval")
                    model.pendingCommand = commandID
                default: model.close()
                }
                model.message = "Retained state"
                let epoch = model.selectionEpoch
                XCTAssertFalse(model.canSelectApplicationFromCommand)
                switch route {
                case "repository": model.importRepository("https://example.invalid/fixture.git")
                case "recipe": model.runSourceRecipe(recipe)
                default: model.importIPA(archive)
                }
                let context = blocker + ":" + route
                XCTAssertFalse(model.busy, context)
                XCTAssertNil(model.task, context)
                XCTAssertEqual(model.selectionEpoch, epoch, context)
                XCTAssertEqual(model.selectedURL, root, context)
                XCTAssertEqual(model.message, "Retained state", context)
                if blocker == "confirmation" {
                    XCTAssertEqual(model.pendingCommand, commandID, context)
                    XCTAssertEqual(model.commandRequests[commandID]?.state, "awaitingApproval", context)
                }
                // Cancel before yielding so a failed admission check cannot start git/network work.
                let unexpected = model.task
                model.cancel()
                await unexpected?.value
                await model.closeAndWait()
            }
        }
    }
}
#endif
