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
                let result = try await diagnostic.run()
                guard !closing, selectionEpoch == epoch else { return }
                message = result.message
            } catch { message = errorText(error) }
        }
    }
}
#endif
