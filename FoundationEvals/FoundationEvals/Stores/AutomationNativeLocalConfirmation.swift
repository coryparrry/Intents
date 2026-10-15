#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativePreparationReview: Sendable {
    let candidate: AutomationApplicationCandidate
    let configuration: String
    let target: TargetIdentity
    let selectionEpoch: Int
    let developerDirectoryPath: String
    let toolchainMetadataDigest: String?
    let sourceRoot: String
    let additionalSourceRoots: [String]
    let includesDependencies: Bool
    var servedJavaScriptProfileDigest: String? = nil
    var automaticMetroRecipe: AutomationMetroAutomaticRecipe? = nil
    let message: String
}
struct AutomationNativeSearchReview: Sendable {
    let digest: String
    let selectionEpoch: Int
    let message: String
}
extension AppAutomationStore {
    func reviewNativePreparation() throws -> AutomationNativePreparationReview {
        guard canPrepare, let candidate, let target = sourcePreparationTarget, let root = selectedSourceRoot else { throw AutomationContractError.conflictingOperation }
        if hasExplicitToolchainSelection {
            guard currentInstalledToolchainChoices().contains(where: { $0.directory == developerDirectory && $0.metadataDigest == selectedToolchainMetadataDigest }) else {
                throw AutomationContractError.missingEvidence("The selected Xcode installation changed. Refresh Xcodes and choose it again before reviewing the build.")
            }
        }
        let developmentProfile = servedJavaScriptProfile == nil && configuration.caseInsensitiveCompare("Debug") == .orderedSame
        let discovered = developmentProfile
            ? try AutomationMetroAutomaticRecipe.discover(source: root, candidate: candidate) : nil
        if discovered != nil, target.kind != .simulator { throw AutomationContractError.missingEvidence("This app's recognized development server requires iOS Simulator. Choose a bundled configuration for other destinations.") }
        automaticMetroRecipe = discovered
        if discovered != nil { includesSourceDependencies = true }
        _ = try AutomationSourceSnapshot.validateRoots(source: root, additionalRoots: sourceGrants.urls)
        let extras = sourceGrants.urls.map(\.path)
        return .init(candidate: candidate, configuration: configuration, target: target, selectionEpoch: selectionEpoch,
            developerDirectoryPath: developerDirectory.path,
            toolchainMetadataDigest: hasExplicitToolchainSelection ? selectedToolchainMetadataDigest : nil,
            sourceRoot: root.path, additionalSourceRoots: extras, includesDependencies: includesSourceDependencies,
            servedJavaScriptProfileDigest: try servedJavaScriptProfile?.digest,
            automaticMetroRecipe: discovered,
            message: "App: \(candidate.name)\nProject: \(candidate.containerPath)\nSource folder: \(root.path)\nAdditional source folders: \(extras.isEmpty ? "None" : "\n" + extras.joined(separator: "\n"))\nCopy installed native dependencies: \(includesSourceDependencies ? "Yes; linked inputs stay inside the selected folders" : "No")\nConfiguration: \(configuration)\nXcode: \(installedToolchains.first(where: { $0.directory == developerDirectory })?.label ?? developerDirectory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)\nDestination: \(target.kind == .nativeMac ? "This Mac" : target.id)\nXcode may resolve dependencies and run this project's build scripts. Intents freezes the current files and adds its host to a private copy." + (servedJavaScriptProfile.map { "\nJavaScript server: \($0.bundleURL)\nStart the selected installed Node recipe in the private copy during preparation and each approved run; verify the served bytes and stop the owned server after use. The recipe cannot spawn child processes or connect to external services." } ?? "") + (discovered == nil ? "" : "\nDetected Expo development tools: start owned Metro in the private copy, pin the served JavaScript, verify the selected Simulator app receives those exact bytes, and stop the server after use. Installed dependencies are copied; no tools or packages are installed."))
    }
    func confirmNativePreparation(_ review: AutomationNativePreparationReview) throws {
        guard canPrepare, candidate == review.candidate, configuration == review.configuration,
              developerDirectory.path == review.developerDirectoryPath,
              review.toolchainMetadataDigest == nil || currentInstalledToolchainChoices().contains(where: {
                  $0.directory == developerDirectory && $0.metadataDigest == review.toolchainMetadataDigest
              }),
              try servedJavaScriptProfile?.digest == review.servedJavaScriptProfileDigest,
              automaticMetroRecipe == review.automaticMetroRecipe,
              includesSourceDependencies == review.includesDependencies,
              sourcePreparationTarget == review.target, selectionEpoch == review.selectionEpoch,
              selectedSourceRoot?.path == review.sourceRoot, sourceGrants.urls.map(\.path) == review.additionalSourceRoots else { throw AutomationContractError.conflictingOperation }
        if savedAttemptLoading { clearSavedView() }
        selectionEpoch += 1; invalidatePendingCommand()
        prepare(expectedTarget: review.target)
    }
    func reviewNativeSearch() throws -> AutomationNativeSearchReview {
        guard canFindFailures else { throw AutomationContractError.conflictingOperation }
        let request = try isFreshSearchWorkflow ? makeFreshRecordRequest(runID: "preview") : makeUIRunRequest(runID: "preview")
        let proposal = try makeSearchProposal(request)
        if isFreshSearchWorkflow {
            return .init(digest: try Self.nativeSearchDigest(request, proposal), selectionEpoch: selectionEpoch,
                message: "App: \(request.plan.app.bundleID)\nDestination: \(request.plan.target.kind == .nativeMac ? "This Mac" : request.plan.target.id)\nIntents creates fresh disposable records, adds duplicate names where approved context distinguishes them, and adds unrelated records. Each setup must succeed twice with distinct real identities before repeat testing. The subject, expected state and observer stay fixed. Qualification and search share a cap of 100 attempts, 1,000 UI actions, 300 controller calls and one hour. Reductions remove added-record conditions only.")
        }
        return .init(digest: try Self.nativeSearchDigest(request, proposal), selectionEpoch: selectionEpoch,
            message: "App: \(request.plan.app.bundleID)\nDestination: \(request.plan.target.id)\n\(uiVarySubjectRequest ? "Request input control (must be empty): \(uiRequestInputControl)\nNew-session control: \(uiRequestResetControl)\nSession identity value control: \(uiRequestSessionIdentity)\nEmpty-state control: \(uiRequestEmptyStateControl)\nExpected empty-state text: \(uiRequestEmptyStateText)\nSubmit control: \(uiRequestSubmitControl)\n" : "")Alternative phrases:\n\(uiAlternatePhrases)\nThe selected workflow and these phrases share one frozen business check. \(uiVarySubjectRequest ? "You declare the approved text is the actual AI request and these alternatives preserve its meaning. Only that text binding changes; controller instructions stay fixed. Before every request, Intents taps the approved new-session control and independently reads the empty state and a new session identity and an empty value in the frozen request input control; it then requires the approved request fill and submit tap. These are disposable local fixture writes and resets. Two live qualification attempts share the campaign budget." : "Only controller navigation instructions change; approved text stays fixed.") \(uiVarySubjectRequest ? "External writes remain unsupported." : "Only observation and navigation are allowed.") Up to 100 attempts, 5,500 reserved subject operations (including readbacks), 1,000 setup operations, 1,000 observer operations, 1,000 UI actions, 300 controller calls and one hour." +
                (request.plan.target.kind == .nativeMac ? " Every attempt uses the selected Mac app and current login session." :
                    request.installApproved ? " Intents may start this simulator and install the exact selected app." : " The app must already be installed on the running simulator."))
    }
    func makeSearchProposal(_ request: AutomationNativeRunRequest) throws -> AutomationNativeUIFailureSearchProposal {
        if isFreshSearchWorkflow { return try .compileFresh(plan: request.plan, approval: request.approval, context: freshContext) }
        return try .compile(plan: request.plan, approval: request.approval, alternatePhrases: uiAlternatePhrases, varySubjectRequest: uiVarySubjectRequest, requestFixture: uiVarySubjectRequest ? uiRequestFixtureDraft : nil)
    }
    static func nativeSearchDigest(_ request: AutomationNativeRunRequest, _ proposal: AutomationNativeUIFailureSearchProposal) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields = ["request": request.digest, "baseline": proposal.baseline.digest,
            "mutations": proposal.mutations.map { $0.frozen.digest }.joined(separator: ","),
            "reductions": AutomationArtifactRegistry.digest(try encoder.encode(proposal.reductions)),
            "limits": AutomationArtifactRegistry.digest(try encoder.encode(proposal.approval.limits))]
        return AutomationArtifactRegistry.digest(try encoder.encode(fields))
    }
}
#endif
