import Foundation

public struct AutomationBudget: Codable, Equatable, Sendable {
    public var subjectOperations = 20
    public var attempts = 100
    public var uiActions = 1000
    public var controllerCalls = 300
    public var wallClockSeconds = 120
    public init() {}
}
public struct AutomationSegment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case ui, systemIntent, systemQuery, siriText, pairedFeature, observeOnly }
    public enum Phase: String, Codable, Sendable { case setup, subject, observe, cleanup }
    public enum Lifecycle: String, Codable, Sendable { case persistedStateAcrossSegments, processContinuityRequired, noActivation }
    public var id: String
    public var kind: Kind
    public var phase: Phase
    public var requiredCapabilities: [String]
    public var lifecycle: Lifecycle
    public var operation: String
    public var inputs: [String: AutomationValue]
    public var inputBindings: [AutomationInputBinding]?
    public var attemptTextBindings: [String: String]?
    public var effects: Set<AutomationEffect>
    public var uiProgram: AutomationUIProgram?
    public var hostProgram: AutomationHostProgram?
    public var siriProgram: AutomationSiriTextProgram?
    private enum CodingKeys: String, CodingKey {
        case id, kind, phase, requiredCapabilities, lifecycle, operation, inputs, inputBindings, attemptTextBindings, effects, uiProgram, hostProgram, siriProgram
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        phase = try container.decode(Phase.self, forKey: .phase)
        requiredCapabilities = try container.decode([String].self, forKey: .requiredCapabilities)
        lifecycle = try container.decode(Lifecycle.self, forKey: .lifecycle)
        operation = try container.decode(String.self, forKey: .operation)
        inputs = try container.decode([String: AutomationValue].self, forKey: .inputs)
        inputBindings = try container.decodeIfPresent([AutomationInputBinding].self, forKey: .inputBindings)
        attemptTextBindings = try container.decodeIfPresent([String: String].self, forKey: .attemptTextBindings)
        let declared = try container.decode([AutomationEffect].self, forKey: .effects)
        guard Set(declared).count == declared.count else { throw AutomationContractError.invalidIdentity }
        effects = Set(declared)
        uiProgram = try container.decodeIfPresent(AutomationUIProgram.self, forKey: .uiProgram)
        hostProgram = try container.decodeIfPresent(AutomationHostProgram.self, forKey: .hostProgram)
        siriProgram = try container.decodeIfPresent(AutomationSiriTextProgram.self, forKey: .siriProgram)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(kind, forKey: .kind)
        try container.encode(phase, forKey: .phase); try container.encode(requiredCapabilities, forKey: .requiredCapabilities)
        try container.encode(lifecycle, forKey: .lifecycle); try container.encode(operation, forKey: .operation)
        try container.encode(inputs, forKey: .inputs); try container.encodeIfPresent(inputBindings, forKey: .inputBindings)
        try container.encodeIfPresent(attemptTextBindings, forKey: .attemptTextBindings)
        try container.encode(effects.sorted { $0.rawValue < $1.rawValue }, forKey: .effects)
        try container.encodeIfPresent(uiProgram, forKey: .uiProgram); try container.encodeIfPresent(hostProgram, forKey: .hostProgram)
        try container.encodeIfPresent(siriProgram, forKey: .siriProgram)
    }
    public init(id: String, kind: Kind, phase: Phase, operation: String, inputs: [String: AutomationValue] = [:],
                requiredCapabilities: [String] = [], effects: Set<AutomationEffect> = [.observe], lifecycle: Lifecycle = .noActivation) {
        self.id = id; self.kind = kind; self.phase = phase; self.operation = operation
        self.inputs = inputs; self.requiredCapabilities = requiredCapabilities; self.effects = effects; self.lifecycle = lifecycle
        self.uiProgram = nil; self.hostProgram = nil; self.siriProgram = nil
    }
}
public struct AutomationRequirement: Codable, Equatable, Sendable {
    public var checkID: String?
    public var observationID: String
    public var expected: AutomationValue
    public var proof: AutomationObservation.Proof
    public var justification: String
    public var entityProperty: AutomationEntityPropertyPredicate?
    public init(observationID: String, expected: AutomationValue, proof: AutomationObservation.Proof, justification: String,
                checkID: String? = nil, entityProperty: AutomationEntityPropertyPredicate? = nil) {
        self.observationID = observationID; self.expected = expected; self.proof = proof; self.justification = justification
        self.checkID = checkID; self.entityProperty = entityProperty
    }
}
public struct AutomationCase: Codable, Equatable, Sendable {
    public var schemaVersion = 3
    public var id: String
    public var revision: Int
    public var app: AppIdentity
    public var target: TargetIdentity
    public var environmentID: String
    public var setup: [AutomationSegment]
    public var setupChecks: [AutomationRequirement]?
    public var execution: AutomationSegment
    public var observations: [AutomationSegment]
    public var requirements: [AutomationRequirement]
    public var cleanup: [AutomationSegment]
    public var budget: AutomationBudget
    public var provenance: [String: String]
    public var preparedMacBuildArtifacts: AutomationPreparedMacBuildArtifacts?
    public init(id: String, app: AppIdentity, target: TargetIdentity, environmentID: String, execution: AutomationSegment,
                setup: [AutomationSegment] = [], observations: [AutomationSegment] = [], requirements: [AutomationRequirement] = [],
                cleanup: [AutomationSegment] = [], budget: AutomationBudget = .init(), setupChecks: [AutomationRequirement]? = nil) {
        self.id = id; revision = 1; self.app = app; self.target = target; self.environmentID = environmentID
        self.execution = execution; self.setup = setup; self.observations = observations; self.requirements = requirements
        self.setupChecks = setupChecks
        self.cleanup = cleanup; self.budget = budget; provenance = [:]
    }
}
public enum PlanValidator {
    public static func validate(_ plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile,
                                purpose: AutomationPlanValidationPurpose = .execution, siriAuthority: AutomationSiriRouteAuthority? = nil) throws {
        guard plan.schemaVersion == 3, plan.revision > 0, !plan.id.isEmpty, plan.execution.phase == .subject,
              plan.app == approval.app, plan.target == approval.target, plan.environmentID == approval.environmentID else {
            throw AutomationContractError.invalidPlan("Identity or required subject route is invalid")
        }
        try AutomationAttemptText.validate(plan: plan, approval: approval)
        if plan.execution.kind == .siriText {
            try AutomationSiriTextProgram.validateAdmission(plan: plan, approval: approval, capabilities: capabilities, authority: siriAuthority, purpose: purpose)
        }
        try plan.preparedMacBuildArtifacts?.validate(plan: plan)
        try AutomationInputResolver.validate(plan: plan)
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard Set(segments.map(\.id)).count == segments.count else { throw AutomationContractError.invalidPlan("Duplicate segment") }
        let producerCount = plan.setup.reduce(0) { $0 + ($1.hostProgram?.operations.count ?? 1) }
        guard producerCount <= 3 else { throw AutomationContractError.invalidPlan("Setup graphs support at most three producer operations") }
        guard plan.setup.allSatisfy({ $0.phase == .setup }), plan.observations.allSatisfy({ $0.phase == .observe }),
              plan.cleanup.allSatisfy({ $0.phase == .cleanup }) else { throw AutomationContractError.invalidPlan("Phase mismatch") }
        guard plan.budget.attempts > 0, plan.budget.subjectOperations > 0, plan.budget.wallClockSeconds > 0,
              plan.budget.uiActions > 0, plan.budget.controllerCalls >= 0 else { throw AutomationContractError.invalidPlan("Invalid budget") }
        for segment in segments {
            guard (segment.kind == .siriText) == (segment.siriProgram != nil) else {
                throw AutomationContractError.invalidPlan("Siri route requires its frozen recognised-text program")
            }
            if let program = segment.siriProgram { try program.validate(segment: segment, target: plan.target) }
            guard segment.uiProgram == nil || (segment.kind == .ui && segment.hostProgram == nil),
                  segment.hostProgram == nil || ([.systemIntent, .systemQuery].contains(segment.kind) && segment.uiProgram == nil) else {
                throw AutomationContractError.invalidPlan("Program does not match its route")
            }
            if var program = segment.uiProgram {
                // Deferred values are checked again after binding real producer outputs.
                for (name, _) in segment.attemptTextBindings ?? [:] { program.bindings[name] = "preflight-placeholder" }
                for binding in segment.inputBindings ?? [] where binding.destination == .uiBinding {
                    program.bindings[binding.name] = "preflight-placeholder"
                }
                try program.validate(phase: segment.phase)
            }
            if var program = segment.hostProgram {
                for binding in segment.inputBindings ?? [] where binding.destination == .hostQueryIDs {
                    if let index = program.operations.firstIndex(where: { $0.id == binding.operationID }) { program.operations[index].queryIDs = ["preflight-placeholder"] }
                }
                try program.validate(route: segment.kind, phase: segment.phase)
            }
            if segment.hostProgram != nil, segment.lifecycle != .persistedStateAcrossSegments {
                throw AutomationContractError.invalidPlan("Apple host requires persisted-state lifecycle")
            }
            if segment.kind == .ui, segment.uiProgram != nil {
                guard segment.effects.contains(.navigate), segment.lifecycle == .persistedStateAcrossSegments else {
                    throw AutomationContractError.invalidPlan("UI activation needs approved navigation and persisted-state lifecycle")
                }
                if segment.uiProgram?.operations.contains(where: { $0.goal?.saveControl != nil }) == true,
                   segment.phase == .observe || segment.effects.isDisjoint(with: [.fixtureWrite, .externalWrite]) {
                    throw AutomationContractError.invalidPlan("Save control requires approved write effects")
                }
            }
            try AutomationCodecRequirements.validate(segment, plan: plan, capabilities: capabilities, purpose: purpose)
            let required = purpose == .review ? segment.requiredCapabilities.filter { !$0.hasPrefix("apple.codec.") } : segment.requiredCapabilities
            guard capabilities.supports(required) else { throw AutomationContractError.missingEvidence(segment.id) }
            guard segment.effects.isSubset(of: approval.effects) && (!segment.effects.contains(.reset) || approval.disposable) else { throw AutomationContractError.invalidPlan("Effect is not approved") }
            if segment.phase == .observe, !segment.effects.isSubset(of: [.observe, .navigate]) {
                throw AutomationContractError.invalidPlan("Observer cannot repair the subject")
            }
        }
        if !plan.requirements.isEmpty || plan.setupChecks?.isEmpty == false {
            guard approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)) else { throw AutomationContractError.invalidPlan("Business assertions require approval of this exact frozen case") }
        }
        guard plan.requirements.allSatisfy({ !$0.justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            || plan.requirements.isEmpty else { throw AutomationContractError.invalidPlan("Unjustified assertion") }
        for requirement in plan.requirements {
            guard plan.observations.contains(where: { $0.id == requirement.observationID }) else {
                throw AutomationContractError.invalidPlan("Assertion has no independent observation")
            }
        }
        try AutomationRequirementValidator.validate(plan: plan)
    }
}
