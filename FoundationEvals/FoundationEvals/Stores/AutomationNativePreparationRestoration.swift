#if os(macOS)
import Foundation
import IntentsAutomationCore

extension AppAutomationStore {
    /// Restores selection and retained build together; loading the catalog alone
    /// would leave saved cases unusable because their target no longer matches.
    func restoreLatestPreparation() {
        // Keep ordinary first-launch selection immediately available.
        let sessions = (try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        guard sessions.contains(where: { $0.lastPathComponent.hasPrefix("prepare-") &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("prepared-application.json").path) }) else { return }
        let root = support, assess = intakeAssessor, epoch = selectionEpoch
        progress = "Checking saved prepared files…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let restored = try await AutomationNativeOffMainVerification.run {
                    guard let prepared = try AutomationPreparedApplicationRecord.loadLatest(supportRoot: root) else { return nil as (AutomationPreparedApplication, AutomationIntakeAssessment)? }
                    return (prepared, try assess(AutomationPreparedApplicationRecord.intakeURL(for: prepared)))
                }
                try Task.checkCancellation()
                guard !closing, selectionEpoch == epoch, let (value, assessment) = restored else { return }
                guard value.host.target.kind != .pairedRunner,
                      let candidate = assessment.candidates.first(where: { $0.id == value.host.app.logicalID }),
                      candidate.kind == .sourceTarget, candidate.configurations.contains(value.generatedHost.configuration) else {
                    throw AutomationContractError.conflictingOperation
                }
                let source = URL(fileURLWithPath: value.source.sourceRoot)
                let additional = Array((value.source.capturedRoots?.map(\.inputPath) ?? []).dropFirst())
                let automaticMetro = value.servedJavaScriptProfile?.automaticMetro
                let javaScriptProfile = automaticMetro == nil ? value.servedJavaScriptProfile : nil
                let approval = AutomationBuildApproval(sourceRoot: source.path, candidateID: candidate.id,
                    configuration: value.generatedHost.configuration, target: value.host.target, additionalSourceRoots: additional,
                    includesDependencies: value.source.includesDependencies == true,
                    servedJavaScriptProfile: javaScriptProfile, automaticMetroRecipe: automaticMetro)
                try validatePreparedSelection(value, candidate: candidate, approval: approval)
                let siriProfile = AutomationPreparedCapabilities.base(value)
                try Task.checkCancellation()
                guard !closing, selectionEpoch == epoch else { return }
                // Source access is useful for a later Check fix; execution itself
                // uses the already verified private copy and does not rebuild.
                for path in additional { try sourceGrants.add(URL(fileURLWithPath: path), primary: source) }
                hasSecurityScope = source.startAccessingSecurityScopedResource()
                securityScopedURL = hasSecurityScope ? source : nil
                selectedURL = source; intake = assessment; restoredCandidateID = candidate.id; candidateID = candidate.id
                configuration = value.generatedHost.configuration
                includesSourceDependencies = approval.includesDependencies == true
                servedJavaScriptProfile = javaScriptProfile; automaticMetroRecipe = automaticMetro
                switch value.host.target.kind {
                case .simulator:
                    preparationDestination = .simulator; simulatorID = value.host.target.id
                case .physical:
                    preparationDestination = .physical; physicalDeviceID = value.host.target.id
                    if let identifier = value.host.target.physicalDeviceIdentifier {
                        resolvedPhysicalDeviceIdentifiers[value.host.target.id.lowercased()] = identifier
                    }
                case .nativeMac:
                    preparationDestination = .macOS; selectedMacTarget = value.host.target
                case .pairedRunner:
                    throw AutomationContractError.invalidIdentity
                }
                prepared = value; catalog = value.catalog; siriCapabilities = siriProfile
                message = "Restored the prepared app. Saved checks can run without rebuilding."
            } catch {
                guard !closing, selectionEpoch == epoch else { return }
                sourceGrants.clear()
                message = "The saved prepared app could not be restored. Prepare the app again."
            }
        }
    }
}
#endif
