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
            message: "App: \(candidate.name)\nProject: \(candidate.containerPath)\nSource folder: \(root.path)\nAdditional source folders: \(extras.isEmpty ? "None" : "\n" + extras.joined(separator: "\n"))\nCopy installed native dependencies: \(includesSourceDependencies ? "Yes; linked inputs stay inside the selected folders" : "No")\nConfiguration: \(configuration)\nXcode: \(installedToolchains.first(where: { $0.directory == developerDirectory })?.label ?? developerDirectory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)\nDestination: \(target.kind == .nativeMac ? "This Mac" : target.id)\nXcode may resolve dependencies and run this project's build scripts. Intents freezes the current files and adds its host to a private copy." + (servedJavaScriptProfile.map { "\nJavaScript server: \($0.bundleURL)\nStart the selected installed Node recipe in the private copy during preparation and each approved run; verify the served bytes and stop the owned server after use. The recipe cannot spawn child processes or connect to external services." } ?? "") + (discovered.map { "\nNode executable: \($0.nodePath)\nDetected Expo development tools: start owned Metro in the private copy, pin the served JavaScript, verify the selected Simulator app receives those exact bytes, and stop the server after use. Installed dependencies are copied; no tools or packages are installed." } ?? ""))
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
}
#endif
