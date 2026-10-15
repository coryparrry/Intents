import Foundation

public enum AutomationPairedFeaturePlanner {
    public static func compile(app: AppIdentity, program: AutomationPairedFeatureProgram, approval: RunApproval, expectedResponse: String?) throws -> AutomationCase {
        guard app == approval.app, app.provenanceStrength == "pairedRegistration", app.productDigest == nil,
              approval.target.kind == .pairedRunner, !approval.effects.isEmpty, approval.effects.contains(.observe), program.mode == .execute,
              expectedResponse.map({ !$0.isEmpty && $0.utf16.count <= 32768 }) ?? true else { throw AutomationContractError.invalidIdentity }
        var subject = AutomationSegment(id: "feature", kind: .pairedFeature, phase: .subject, operation: program.featureID,
            requiredCapabilities: ["paired.feature.execute"], effects: approval.effects, lifecycle: .persistedStateAcrossSegments)
        subject.pairedProgram = program
        var observer = AutomationSegment(id: "feature-response", kind: .pairedFeature, phase: .observe, operation: "Read the returned app response",
            requiredCapabilities: ["paired.feature.execute"], effects: [.observe], lifecycle: .persistedStateAcrossSegments)
        var observationProgram = program; observationProgram.mode = .readResponse; observer.pairedProgram = observationProgram
        let requirements: [AutomationRequirement] = expectedResponse.map { [.init(observationID: observer.id, expected: .text($0), proof: .appState,
            justification: "User-approved response expectation, withheld from the registered feature", checkID: "business.feature-response")] } ?? []
        var budget = AutomationBudget(); budget.subjectOperations = 1; budget.attempts = 1; budget.controllerCalls = 0; budget.uiActions = 1; budget.wallClockSeconds = 150
        var plan = AutomationCase(id: "paired-feature", app: app, target: approval.target, environmentID: approval.environmentID,
            execution: subject, observations: [observer], requirements: requirements, budget: budget)
        plan.provenance = ["paired.registration": program.registrationDigest, "paired.appVersion": program.appVersion,
            "execution": "Existing authenticated production feature registration", "remoteBuild": "Registration and version only; remote product bytes are unverified",
            "model": "Provider and model requests remain unobserved without correlated app-owned evidence"]
        plan.id = "paired." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        var scoped = approval; scoped.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let capabilities = CapabilityProfile(records: ["paired.feature.execute": .init(state: .available, reason: "Registered feature", probeVersion: "paired-v1", evidence: [program.registrationDigest])])
        try PlanValidator.validate(plan, approval: scoped, capabilities: capabilities)
        return plan
    }
}
