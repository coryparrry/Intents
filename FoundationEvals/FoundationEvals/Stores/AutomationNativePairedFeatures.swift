#if os(macOS)
import Foundation
import IntentsAutomationCore
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif

struct AutomationNativePairedFeature: Identifiable {
    let runner: DeveloperRunnerSnapshot
    let feature: DeveloperFeatureDescriptor
    var id: String { runner.id.uuidString + ":" + feature.id }
    var title: String { feature.displayName + " · " + runner.identity.displayName }
}
struct AutomationNativePairedReview: Identifiable, Sendable {
    let id: String
    let plan: AutomationCase
    let approval: RunApproval
    let title: String
}

@MainActor struct AutomationNativePairedClient: AutomationPairedFeatureClient {
    let client: DeveloperRunnerClient
    static func supportsTextInput(_ name: String) -> Bool {
        // The desktop includes these SDK sources directly; customer apps import
        // the SDK module. Both names encode the same versioned public payload.
        name == "FoundationEvalsDeveloper.DeveloperTextFeatureInput" || name == String(reflecting: DeveloperTextFeatureInput.self)
    }
    static func registration(_ runner: DeveloperRunnerSnapshot, _ feature: DeveloperFeatureDescriptor) throws -> String {
        struct Registration: Encodable { let runner: DeveloperRunnerIdentity; let feature: DeveloperFeatureDescriptor }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return AutomationArtifactRegistry.digest(try encoder.encode(Registration(runner: runner.identity, feature: feature)))
    }
    func validate(program: AutomationPairedFeatureProgram, app: AppIdentity) async throws {
        guard let runner = client.runners.first(where: { $0.id == program.runnerID && $0.state == .connected }),
              runner.identity.appBundleIdentifier == app.bundleID, runner.identity.appVersion == program.appVersion,
              let feature = runner.features.first(where: { $0.id == program.featureID && $0.version == program.featureVersion }),
              Self.supportsTextInput(feature.inputTypeName),
              try Self.registration(runner, feature) == program.registrationDigest else {
            throw AutomationContractError.missingEvidence("The selected registered feature or trusted runner changed")
        }
    }
    static func input(program: AutomationPairedFeatureProgram, requestID: UUID) -> DeveloperTextFeatureInput {
        .init(caseID: requestID, instructions: program.instructions, prompt: program.prompt, expected: "", repetition: 0)
    }
    func execute(program: AutomationPairedFeatureProgram, app: AppIdentity, requestID: UUID, runID: UUID, timeout: Duration) async throws -> AutomationPairedFeatureReply {
        try await validate(program: program, app: app)
        guard let inputTypeName = client.runners.first(where: { $0.id == program.runnerID })?.features.first(where: { $0.id == program.featureID })?.inputTypeName else { throw AutomationContractError.conflictingOperation }
        let request = DeveloperFeatureExecutionRequest(id: requestID, runID: runID, featureID: program.featureID, featureVersion: program.featureVersion,
            encodedInput: try JSONEncoder().encode(Self.input(program: program, requestID: requestID)), inputTypeName: inputTypeName, deadline: Date().addingTimeInterval(120))
        let result = try await client.execute(request, on: program.runnerID, timeout: timeout)
        guard result.requestID == requestID, result.runID == runID, result.featureID == program.featureID else { throw AutomationContractError.ambiguousDispatch }
        return .init(requestID: requestID, response: result.output?.response, failure: result.failure.map { $0.code.rawValue })
    }
}

extension AppAutomationStore {
    func restorePairedOwnership() async {
        do {
            pairedExecutionUnresolved = try await AutomationPairedFeatureCampaign.hasAnyRetainedOwnership(supportRoot: support)
            if pairedExecutionUnresolved { message = "A previous app feature may still be running. Its saved ownership blocks another request until the runner is reconciled." }
        } catch {
            pairedExecutionUnresolved = true
            message = "Saved app-feature ownership could not be read. Further requests remain blocked."
        }
    }
    var availablePairedFeatures: [AutomationNativePairedFeature] {
        guard let app = catalog?.app ?? candidate?.app, let pairedClient else { return [] }
        return pairedClient.runners.filter { $0.state == .connected && $0.identity.appBundleIdentifier == app.bundleID &&
            (app.platform == "macos" ? $0.identity.platform == .mac : [.iPhone, .iPad].contains($0.identity.platform)) }
            .flatMap { runner in runner.features.filter { AutomationNativePairedClient.supportsTextInput($0.inputTypeName) }.map { .init(runner: runner, feature: $0) } }
            .sorted { $0.id < $1.id }
    }
    var selectedPairedFeature: AutomationNativePairedFeature? {
        let features = availablePairedFeatures
        return features.first { $0.id == pairedFeatureID } ?? (pairedFeatureID.isEmpty && features.count == 1 ? features[0] : nil)
    }
    var canRunPairedFeature: Bool {
        permitsExecutionAdmission && canSelectApplicationFromCommand && pairedCanStart?() != false && selectedPairedFeature != nil && pairedEffectsConfirmed &&
            ["navigation", "fixture", "external"].contains(effectChoice) && (effectChoice != "fixture" || disposable) &&
            !pairedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pairedPrompt.utf16.count <= 32768 &&
            pairedInstructions.utf16.count <= 32768 && pairedExpectedResponse.utf16.count <= 32768
    }
    func reviewPairedFeature() throws -> AutomationNativePairedReview {
        guard canRunPairedFeature, let selected = selectedPairedFeature, let local = catalog?.app ?? candidate?.app else { throw AutomationContractError.missingEvidence("Choose a connected app feature and approve its request and effects") }
        let registration = try AutomationNativePairedClient.registration(selected.runner, selected.feature)
        var app = AppIdentity(logicalID: local.logicalID + "::paired:" + selected.runner.id.uuidString, bundleID: local.bundleID, platform: local.platform)
        app.provenanceStrength = "pairedRegistration"
        let target = TargetIdentity(id: selected.runner.id.uuidString, kind: .pairedRunner)
        var effects: Set<AutomationEffect> = [.observe]
        if effectChoice == "fixture" { effects.insert(.fixtureWrite) }; if effectChoice == "external" { effects.insert(.externalWrite) }
        var approval = RunApproval(runID: "00000000-0000-0000-0000-000000000001", app: app, target: target, environmentID: "paired:" + registration,
            effects: effects, maximumActions: 1, disposable: disposable)
        let program = AutomationPairedFeatureProgram(runnerID: selected.runner.id, registrationDigest: registration, appVersion: selected.runner.identity.appVersion,
            featureID: selected.feature.id, featureVersion: selected.feature.version, instructions: pairedInstructions, prompt: pairedPrompt)
        let plan = try AutomationPairedFeaturePlanner.compile(app: app, program: program, approval: approval, expectedResponse: pairedExpectedResponse.isEmpty ? nil : pairedExpectedResponse)
        let digest = try AutomationFrozenCase.planDigest(plan); approval.approvedCaseDigest = digest
        return .init(id: digest, plan: plan, approval: approval, title: selected.title)
    }
    func runPairedFeature(_ review: AutomationNativePairedReview) {
        do { guard try reviewPairedFeature().id == review.id, let client = pairedClient else { throw AutomationContractError.conflictingOperation }
            try beginExecutionAdmission()
            progress = "Running the registered app feature…"; message = nil; report = nil
            var approval = review.approval; approval.runID = UUID().uuidString
            task = Task {
                defer { progress = nil; task = nil; releaseScopeIfClosing(); finishExecutionAdmission() }
                do {
                    let attemptID = UUID().uuidString
                    let result = try await AutomationPairedFeatureCampaign.run(plan: review.plan, approval: approval, attemptID: attemptID,
                        supportRoot: support, client: AutomationNativePairedClient(client: client))
                    report = result; reportDirectory = support.appendingPathComponent(attemptID)
                    pairedExecutionUnresolved = !result.resourcesReleased || result.result.subjectDispatchUncertain
                    await importEvidence(plan: review.plan, report: result); await refreshSavedCases()
                } catch {
                    pairedExecutionUnresolved = (try? await AutomationPairedFeatureCampaign.hasRetainedOwnership(target: review.plan.target, supportRoot: support)) != false
                    message = errorText(error); await refreshSavedCases()
                }
            }
        } catch { message = errorText(error) }
    }
}
#endif
