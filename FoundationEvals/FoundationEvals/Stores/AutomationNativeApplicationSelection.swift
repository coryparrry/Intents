#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeApplicationListing: Codable, Equatable, Sendable {
    struct Application: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let kind: AutomationApplicationCandidate.Kind
        let bundleID: String?
        let platform: String?
        let configurations: [String]
    }
    let applications: [Application]
    let snapshotDigest: String
    let selectedID: String?
    let total: Int
    let truncated: Bool
}
struct AutomationNativeMacWorkflowReview: Identifiable, Sendable {
    enum Kind: Sendable { case ui, freshRecord }
    let plan: AutomationCase
    let approval: RunApproval
    let bundlePath: String
    let visibleCheck: String
    let id: String
    var kind: Kind = .ui
}

extension AppAutomationStore {
    var isInstalledMacUI: Bool { candidate?.kind == .installedProduct && candidate?.app?.platform == "macos" }
    var isPreparedMacUI: Bool { candidate?.kind == .sourceTarget && preparationDestination == .macOS && workflowRoute == "ui" }
    var isMacUIReview: Bool { isInstalledMacUI || isPreparedMacUI }
    var preparedMacUISelectionMatches: Bool {
        guard isPreparedMacUI, let prepared, let target = sourcePreparationTarget else { return false }
        return prepared.host.target == target && prepared.host.app.platform == "macos" && prepared.host.app.logicalID == candidateID &&
            prepared.host.app.configuration == configuration && prepared.generatedHost.configuration == configuration && prepared.catalog.app == prepared.host.app
    }
    var canReviewMacWorkflow: Bool {
        ((isInstalledMacUI && selectedMacTarget != nil) || preparedMacUISelectionMatches) && canSelectApplicationFromCommand &&
        !uiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && uiInstruction.utf16.count <= 4096 &&
        !uiEndpoint.isEmpty && uiEndpoint.utf16.count <= 1024 && uiApprovedText.isEmpty &&
        uiExpectedText.utf16.count <= 1024 && uiObservationLabel.utf16.count <= 1024 &&
        ["text", "value", "checked", "selected"].contains(uiObservationProperty) &&
        (uiExpectedText.isEmpty || uiObservationProperty == "text" || !uiObservationLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        (uiExpectedText.isEmpty || !["checked", "selected"].contains(uiObservationProperty) || ["true", "false"].contains(uiExpectedText)) &&
        ["navigation", "fixture", "external"].contains(effectChoice) && effectsConfirmed && (effectChoice != "fixture" || disposable)
    }
    /// Review freezes a data-only workflow. It is never execution approval.
    func reviewMacWorkflow() throws -> AutomationNativeMacWorkflowReview {
        guard canReviewMacWorkflow, let candidate else { throw AutomationContractError.missingEvidence("Complete the Mac workflow and permitted effects") }
        let current = try nativeMacTargetReader()
        let app: AppIdentity, bundlePath: String
        if isPreparedMacUI {
            guard let prepared, preparedMacUISelectionMatches, current == prepared.host.target else { throw AutomationContractError.conflictingOperation }
            app = prepared.host.app; bundlePath = prepared.host.subjectProductPath
        } else {
            guard current == selectedMacTarget else { throw AutomationContractError.conflictingOperation }
            let selected = try AutomationInstalledMacUIApplication(bundleURL: URL(fileURLWithPath: candidate.containerPath), target: current)
            guard selected.app == candidate.app else { throw AutomationContractError.conflictingOperation }
            app = selected.app; bundlePath = selected.bundleURL.path
        }
        var effects: Set<AutomationEffect> = [.observe, .navigate]
        if effectChoice == "fixture" { effects.insert(.fixtureWrite) }
        if effectChoice == "external" { effects.insert(.externalWrite) }
        var approval = RunApproval(runID: "mac-workflow-draft", app: app, target: current,
            environmentID: "selected-mac-session:" + current.loginSession!, effects: effects, maximumActions: 30, disposable: disposable)
        var plan = try AutomationUIOnlyPlanner.compile(app: app, target: current, instruction: uiInstruction,
            endpoint: uiEndpoint, expectedVisibleText: uiExpectedText,
            observationLabel: uiObservationProperty == "text" ? "" : uiObservationLabel,
            observationProperty: uiObservationProperty, approval: approval, localeIdentifier: Locale.current.identifier)
        if isPreparedMacUI, let prepared {
            try AutomationNativeUIRuntime.attachPreparedEvidence(to: &plan, prepared: prepared)
            plan.id = "ui." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        }
        let digest = try AutomationFrozenCase.planDigest(plan)
        approval.approvedCaseDigest = digest
        guard try nativeMacTargetReader() == current else { throw AutomationContractError.conflictingOperation }
        return .init(plan: plan, approval: approval, bundlePath: bundlePath,
            visibleCheck: uiExpectedText.isEmpty ? "No independent check; completion would be unassessed." :
                (uiObservationProperty == "text" ? "text" : uiObservationLabel + " · " + uiObservationProperty) + ": " + uiExpectedText,
            id: digest)
    }
    func saveMacWorkflowDraft(_ reviewed: AutomationNativeMacWorkflowReview) async throws {
        let current = try reviewed.kind == .freshRecord ? reviewPreparedMacFreshWorkflow() : reviewMacWorkflow()
        guard current.id == reviewed.id, try AutomationFrozenCase.planDigest(reviewed.plan) == current.id else {
            throw AutomationContractError.conflictingOperation
        }
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        _ = try await cases.freeze(reviewed.plan)
        await refreshSavedCases()
        message = "Mac workflow draft saved. It has no execution result or approval."
    }

    /// Only the population already admitted through the native file picker is visible.
    /// A remote path cannot create a candidate or a new security scope.
    func listApplications() throws -> AutomationNativeApplicationListing {
        let candidates = intake?.candidates ?? []
        let applications = candidates.prefix(200).map {
            AutomationNativeApplicationListing.Application(id: $0.id, name: $0.name, kind: $0.kind,
                bundleID: $0.bundleID, platform: $0.platform, configurations: $0.configurations)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = AutomationArtifactRegistry.digest(try encoder.encode(candidates))
        return .init(applications: applications, snapshotDigest: digest,
            selectedID: candidates.contains(where: { $0.id == candidateID }) ? candidateID : nil,
            total: candidates.count, truncated: candidates.count > applications.count)
    }
    func selectApplication(id: String, snapshotDigest: String) throws -> AutomationNativeApplicationListing {
        guard canSelectApplicationFromCommand else { throw AutomationContractError.targetBusy }
        let listing = try listApplications()
        guard snapshotDigest == listing.snapshotDigest, listing.applications.contains(where: { $0.id == id }) else {
            throw AutomationContractError.conflictingOperation
        }
        if candidateID != id { candidateID = id; selectCandidate() }
        return try listApplications()
    }
}
#endif
