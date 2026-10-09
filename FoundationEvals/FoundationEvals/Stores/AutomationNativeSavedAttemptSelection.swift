#if os(macOS)
import Foundation
import IntentsAutomationCore

extension AppAutomationStore {
    var savedAttemptSelection: String { savedViewedReport?.attemptID ?? "" }
    func selectSavedAttempt(id: String) async {
        guard canLoadSavedAttemptSelection, let frozen = savedViewedCase else { return }
        await showSavedCase(frozen, attemptID: id.isEmpty ? nil : id)
    }
    func showSavedCase(_ frozen: AutomationFrozenCase, attemptID: String? = nil) async {
        guard canLoadSavedAttemptSelection else { return }
        invalidatePendingCommand(); clearSavedView()
        let epoch = selectionEpoch, requestID = UUID(); savedViewRequestID = requestID
        do {
            try frozen.validate(); savedViewedCase = frozen; savedAttemptLoading = true
            let attempts: [AutomationAttemptReport]
            if let savedAttemptsReader { attempts = try await savedAttemptsReader(frozen) }
            else { attempts = try await AutomationCaseStore(root: support.appendingPathComponent("Cases")).attempts(for: frozen) }
            try Task.checkCancellation()
            guard canLoadSavedAttemptSelection, selectionEpoch == epoch, savedViewRequestID == requestID else { return }
            try frozen.validate()
            guard attempts.count <= 1000, Set(attempts.map(\.attemptID)).count == attempts.count else { throw AutomationContractError.invalidIdentity }
            for report in attempts { try AutomationRecordedEvidence.validate(report: report, plan: frozen.plan) }
            let selected: AutomationAttemptReport?
            if let attemptID {
                guard let match = attempts.first(where: { $0.attemptID == attemptID }) else { throw AutomationContractError.invalidIdentity }
                selected = match
            } else { selected = attempts.count == 1 ? attempts.first : nil }
            let fields = frozen.plan.provenance
            let matches = preparedHistory.filter { value in
                AutomationNativeUIRuntime.preparedEvidenceMatches(plan: frozen.plan, prepared: value)
            }
            let baseline: AutomationPreparedApplication?
            if matches.count == 1 { baseline = matches[0] }
            else if matches.isEmpty, (fields["ui.preparedHostDigest"] != nil || frozen.plan.preparedMacBuildArtifacts != nil),
                    let retained = try? await loadRetainedPreparation(app: frozen.plan.app),
                    AutomationNativeUIRuntime.preparedEvidenceMatches(plan: frozen.plan, prepared: retained) { baseline = retained }
            else { baseline = nil }
            try Task.checkCancellation()
            guard canLoadSavedAttemptSelection, selectionEpoch == epoch, savedViewRequestID == requestID else { return }
            savedPreparedBaseline = baseline
            savedAttemptLoading = false
            savedViewedCase = frozen; savedViewedAttempts = attempts; savedViewedReport = selected
            if let selected {
                let directory = support.appendingPathComponent(selected.attemptID)
                savedViewedDirectory = FileManager.default.fileExists(atPath: directory.path) ? directory : nil
                await importEvidence(plan: frozen.plan, report: selected)
                try Task.checkCancellation()
            } else {
                message = attempts.isEmpty ? "This saved draft has no execution result." : "Choose the saved attempt to inspect or reproduce. Attempt IDs do not indicate time order."
            }
        } catch {
            guard canLoadSavedAttemptSelection, selectionEpoch == epoch, savedViewRequestID == requestID else { return }
            clearSavedView()
            message = error is CancellationError ? "Saved attempt loading was cancelled." : "Saved attempt integrity could not be verified."
        }
    }
    private func loadRetainedPreparation(app: AppIdentity) async throws -> AutomationPreparedApplication {
        let root = support
        return try await Task.detached { try AutomationPreparedApplicationRecord.load(app: app, supportRoot: root) }.value
    }
}
#endif
