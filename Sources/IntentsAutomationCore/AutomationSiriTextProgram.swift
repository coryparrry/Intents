import Foundation

/// One frozen recognised-text submission. Device observations establish its business outcome.
public struct AutomationSiriTextProgram: Codable, Equatable, Sendable {
    static func validateAdmission(plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile,
                                  authority: AutomationSiriRouteAuthority? = nil, purpose: AutomationPlanValidationPurpose = .execution) throws {
        guard !(plan.requirements.isEmpty && plan.setup.isEmpty && plan.observations.isEmpty && plan.cleanup.isEmpty) else { return }
        guard capabilities.records["siri.actualRoute"]?.state != .unavailable, capabilities.records["siri.actualRoute"]?.state != .consentRequired else {
            throw AutomationContractError.missingEvidence("Siri route is vetoed or requires consent")
        }
        if purpose == .review { try AutomationSiriQualificationProposal.validate(plan: plan, approval: approval); return }
        guard let authority else { throw AutomationContractError.missingEvidence("Unqualified Siri API submission cannot assess routing or business outcomes") }
        try authority.validate(plan: plan, approval: approval)
    }
    public let request: String
    public init(request: String) { self.request = request }
    public var requestDigest: String { AutomationArtifactRegistry.digest(Data(request.utf8)) }

    func validate(segment: AutomationSegment, target: TargetIdentity) throws {
        try AutomationPhysicalExecutable.validateTarget(target)
        guard segment.kind == .siriText, segment.phase == .subject,
              segment.operation == "submitRecognizedText", segment.lifecycle == .persistedStateAcrossSegments,
              segment.requiredCapabilities.contains("siri.recognizedText.api"), segment.effects.contains(.navigate),
              segment.inputs.isEmpty, segment.inputBindings?.isEmpty != false, segment.attemptTextBindings?.isEmpty != false,
              segment.uiProgram == nil, segment.hostProgram == nil,
              !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.utf16.count <= 2048, !request.contains("\0") else {
            throw AutomationContractError.invalidPlan("Siri requires one approved physical recognised-text subject request")
        }
    }
}
