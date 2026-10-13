#if os(macOS)
import Foundation
import IntentsAutomationCore

extension AppAutomationStore {
    var inputConversionSelection: AutomationInputConversionDiagnostic.Selection? {
        guard let prepared else { return nil }
        if !actionID.isEmpty { return AutomationInputConversionDiagnostic.selection(prepared: prepared, actionID: actionID) }
        return prepared.catalog.systemActions.compactMap {
            AutomationInputConversionDiagnostic.selection(prepared: prepared, actionID: $0.id)
        }.first
    }
    func checkInputConversion(expectedSelection: AutomationInputConversionDiagnostic.Selection) {
        guard !busy, !closing, let prepared, inputConversionSelection == expectedSelection else { return }
        let epoch = selectionEpoch, developer = developerDirectory(for: prepared.host.target)
        message = nil; progress = "Checking fixed input samples in the private Mac host…"
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let diagnosticRoot = support
                let diagnostic = try await AutomationNativeOffMainVerification.run {
                    try AutomationInputConversionDiagnostic(prepared: prepared, selection: expectedSelection,
                        supportRoot: diagnosticRoot, developerDirectory: developer)
                }
                guard !closing, selectionEpoch == epoch else { return }
                await executeInputConversion(runID: diagnostic.runID, target: prepared.host.target, epoch: epoch) {
                    try await diagnostic.run()
                }
            } catch {
                if !closing, selectionEpoch == epoch { message = errorText(error) }
                await reconcileAbandonedOwnership()
            }
        }
    }

    /// Finish the exact diagnostic before publishing recovery controls or clearing busy state.
    func executeInputConversion(runID: String, target: TargetIdentity, epoch: Int,
        operation: @Sendable () async throws -> AutomationInputConversionDiagnostic.Result) async {
        do {
            let result = try await operation()
            if !result.resourcesReleased { retainUnresolvedRequest(runID: runID, target: target) }
            if !closing, selectionEpoch == epoch { message = result.message }
        } catch {
            await retainUnresolvedReservation(runID: runID, target: target)
            if !closing, selectionEpoch == epoch { message = errorText(error) }
        }
        // refreshRecovery intentionally skips busy stores. This read refreshes durable
        // records while the diagnostic still owns its progress/closing cleanup scope.
        await reconcileAbandonedOwnership()
    }
}
#endif
