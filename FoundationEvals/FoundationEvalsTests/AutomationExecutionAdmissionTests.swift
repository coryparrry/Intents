import Foundation
import IntentsAutomationCore
import Testing
@testable import FoundationEvals

@MainActor
struct AutomationExecutionAdmissionTests {
    @Test func contendedOwnershipResetPreservesRecoveryStateWithoutCreatingABlocker() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let control = EvaluationAppControl(store: store)
        let automation = AppAutomationStore(supportDirectory: directory.appending(path: "Automation"))
        let admission = ScenarioExecutionAdmission()
        defer { control.runners.client.shutdown() }
        control.bindAutomationExecution(automation, admission: admission)
        await automation.ownershipRecoveryTask?.value

        for existingError in [nil, "Existing ownership could not be verified"] as [String?] {
            automation.recoveryError = nil
            let scenarioID = UUID()
            try admission.acquire(scenarioID)
            automation.recoveryError = existingError
            await automation.clearUnresolvedAttempt()
            #expect(automation.recoveryError == existingError)
            #expect(automation.message != nil)
            #expect(!automation.busy)
            admission.release(scenarioID)
            #expect(admission.allows(nil) == (existingError == nil))
            #expect(automation.permitsExecutionAdmission == (existingError == nil))
        }
    }

    @Test func compositionExcludesOtherRoutesAndPreservesOwnedRecoveryAcrossRebinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let control = EvaluationAppControl(store: store)
        let automation = AppAutomationStore(supportDirectory: directory.appending(path: "Automation"))
        let admission = ScenarioExecutionAdmission()
        defer { control.runners.client.shutdown() }

        control.bindAutomationExecution(automation, admission: admission)
        // Startup must check retained ownership before either route can start.
        #expect(!admission.allows(nil))
        #expect(!automation.permitsExecutionAdmission)
        await automation.ownershipRecoveryTask?.value
        #expect(admission.allows(nil))
        #expect(automation.permitsExecutionAdmission)

        let scenarioID = UUID()
        try admission.acquire(scenarioID)
        #expect(!automation.permitsExecutionAdmission)
        #expect(throws: (any Error).self) { try automation.beginExecutionAdmission() }
        admission.release(scenarioID)

        try automation.beginExecutionAdmission()
        #expect(!admission.allows(nil))
        #expect(throws: (any Error).self) { try admission.acquire(scenarioID) }
        control.bindAutomationExecution(automation, admission: admission)
        #expect(!admission.allows(nil))
        automation.finishExecutionAdmission()
        #expect(admission.allows(nil))

        automation.retainUnresolvedRequest(runID: "owned-request", target: .init(id: UUID().uuidString, kind: .simulator))
        #expect(!admission.allows(nil))
        #expect(!automation.permitsExecutionAdmission)
        #expect(throws: (any Error).self) { try automation.beginExecutionAdmission() }
        // An explicit reconciliation can own its existing blocker without
        // admitting a competing scenario or discarding unresolved evidence.
        try automation.beginExecutionAdmission(allowingRecovery: true)
        automation.finishExecutionAdmission()
        #expect(!admission.allows(nil))
        automation.finishOwnershipReset()
        #expect(admission.allows(nil))

        automation.pairedExecutionUnresolved = true
        #expect(!admission.allows(nil))
        #expect(!control.runners.automationExecutionBlocked)
        try automation.beginExecutionAdmission(allowingRecovery: true)
        automation.finishExecutionAdmission()
        automation.close()
        control.bindAutomationExecution(automation, admission: admission)
        #expect(!admission.allows(nil))
        #expect(throws: (any Error).self) { try automation.beginExecutionAdmission(allowingRecovery: true) }
    }
}
