import Foundation

/// Data proposes a checked binding; decoding it grants no fixture authority.
public struct AutomationFreshFixtureBinding: Codable, Equatable, Sendable {
    public let producerSegmentID: String
    public let outputID: String
    public let selection: AutomationEntitySelection
    public init(producerSegmentID: String, outputID: String, selection: AutomationEntitySelection) {
        self.producerSegmentID = producerSegmentID; self.outputID = outputID; self.selection = selection
    }
}

/// Minted only from live runner evidence. This non-Codable token proves fresh
/// checked records in two attempts, not global reset, absence or query completeness.
public struct AutomationQualifiedFreshFixture: Sendable {
    public let context: AutomationRecipeContext
    public let fixtureDigest: String
    public let qualificationAttemptIDs: [String]
    public let qualificationReportDigests: [String]
    public let bindings: [AutomationFreshFixtureBinding]
    let qualifiedEntityIDs: Set<String>

    /// Validate proposed qualification before even its first mutation. This
    /// grants no freshness authority; two live completed attempts are still required.
    public static func validateProposal(bindings: [AutomationFreshFixtureBinding], plan: AutomationCase,
                                        approval: RunApproval, capabilities: CapabilityProfile,
                                        purpose: AutomationPlanValidationPurpose = .execution) throws {
        guard approval.disposable, (1...10).contains(bindings.count),
              bindings.indices.allSatisfy({ index in !bindings.prefix(index).contains(bindings[index]) }),
              approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)),
              let locale = plan.provenance["ui.locale"], !locale.isEmpty, locale.utf16.count <= 128 else {
            throw AutomationContractError.missingEvidence("Fixture qualification needs exact disposable approval and declared locale")
        }
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: purpose)
        try validateBindings(bindings, plan: plan)
    }

    init(bindings: [AutomationFreshFixtureBinding], evidence: [AutomationLiveRecipeEvidence]) throws {
        guard evidence.count == 2, (1...10).contains(bindings.count),
              Set(evidence.map { $0.report.attemptID }).count == 2, evidence[0].context == evidence[1].context else {
            throw AutomationContractError.missingEvidence("Fresh fixtures need two distinct live attempts in one exact environment")
        }
        let context = evidence[0].context; try context.validate()
        guard context.uiRuntimeManifestDigest != nil else { throw AutomationContractError.missingEvidence("Fresh UI fixtures need the exact verified runtime manifest") }
        let digest = try Self.digest(plan: evidence[0].plan)
        var previousIDs: Set<String> = []
        for live in evidence {
            try Self.validateLiveAttempt(bindings: bindings, evidence: live)
            guard live.plan.app == context.app, live.plan.target == context.target, live.plan.environmentID == context.environmentID,
                  live.plan.provenance["ui.locale"] == context.localeIdentifier,
                  live.approval.disposable, live.approval.app == context.app, live.approval.target == context.target,
                  live.approval.environmentID == context.environmentID,
                  live.approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(live.plan)),
                  live.report.resourcesReleased, live.report.result.subjectCompleted, !live.report.result.subjectDispatchUncertain,
                  [.passed, .assertionFailed, .executedUnassessed].contains(live.report.result.summary),
                  try Self.digest(plan: live.plan) == digest else {
                throw AutomationContractError.missingEvidence("Fresh fixture evidence changed its approved setup or environment")
            }
            try AutomationRecordedEvidence.validate(report: live.report, plan: live.plan, expectedRunID: live.approval.runID)
            try Self.validateBindings(bindings, plan: live.plan)
            var currentIDs: Set<String> = []
            for binding in bindings {
                guard let setup = live.plan.setup.first(where: { $0.id == binding.producerSegmentID }),
                      let query = setup.hostProgram?.operations.first(where: { $0.id == binding.outputID }),
                      let receipt = live.report.receipts.first(where: { $0.segmentID == setup.id }), receipt.environmentID == context.environmentID,
                      let output = receipt.verifiedOutputs?[binding.outputID],
                      case .entity(let type, let id) = try binding.selection.resolve(output, query: query, attemptID: live.report.attemptID),
                      currentIDs.insert(type + ":" + id).inserted else {
                    throw AutomationContractError.missingEvidence("Fresh fixture needs actual unique checked query entities")
                }
            }
            guard previousIDs.isDisjoint(with: currentIDs) else { throw AutomationContractError.missingEvidence("Fixture reused a prior entity identity") }
            previousIDs.formUnion(currentIDs)
        }
        self.context = context; fixtureDigest = digest; self.bindings = bindings
        qualifiedEntityIDs = previousIDs
        qualificationAttemptIDs = evidence.map { $0.report.attemptID }
        qualificationReportDigests = try evidence.map { AutomationArtifactRegistry.digest(try AutomationFrozenCase.canonicalData($0.report)) }
    }

    /// Check the first live attempt before authorising a qualification repetition.
    /// This still cannot produce a token from one attempt or from imported data.
    static func validateLiveAttempt(bindings: [AutomationFreshFixtureBinding], evidence live: AutomationLiveRecipeEvidence) throws {
        try live.context.validate()
        guard live.context.uiRuntimeManifestDigest != nil, (1...10).contains(bindings.count),
              live.approval.disposable, live.plan.app == live.context.app, live.plan.target == live.context.target,
              live.plan.environmentID == live.context.environmentID, live.plan.provenance["ui.locale"] == live.context.localeIdentifier,
              live.approval.app == live.context.app, live.approval.target == live.context.target,
              live.approval.environmentID == live.context.environmentID,
              live.approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(live.plan)),
              live.report.resourcesReleased, live.report.result.subjectCompleted, !live.report.result.subjectDispatchUncertain,
              [.passed, .assertionFailed, .executedUnassessed].contains(live.report.result.summary) else {
            throw AutomationContractError.missingEvidence("Qualification repetition requires an eligible complete live fixture attempt")
        }
        try validateBindings(bindings, plan: live.plan)
        try AutomationRecordedEvidence.validate(report: live.report, plan: live.plan, expectedRunID: live.approval.runID)
        var selected: Set<String> = []
        for binding in bindings {
            guard let segment = live.plan.setup.first(where: { $0.id == binding.producerSegmentID }),
                  let query = segment.hostProgram?.operations.first(where: { $0.id == binding.outputID }),
                  let receipt = live.report.receipts.first(where: { $0.segmentID == segment.id }),
                  receipt.environmentID == live.context.environmentID, let output = receipt.verifiedOutputs?[binding.outputID],
                  case .entity(let type, let id) = try binding.selection.resolve(output, query: query, attemptID: live.report.attemptID),
                  selected.insert(type + ":" + id).inserted else { throw AutomationContractError.missingEvidence("Qualification selected duplicate or unavailable live fixture identities") }
        }
    }

    func validate(plan: AutomationCase, approval: RunApproval) throws {
        guard approval.disposable, approval.app == context.app, approval.target == context.target,
              approval.environmentID == context.environmentID, plan.app == context.app, plan.target == context.target,
              plan.environmentID == context.environmentID, plan.provenance["ui.locale"] == context.localeIdentifier,
              try Self.digest(plan: plan) == fixtureDigest else {
            throw AutomationContractError.missingEvidence("Fresh fixture qualification does not match this build, setup or environment")
        }
        try Self.validateBindings(bindings, plan: plan)
    }

    func identities(receipts: [AutomationSegmentReceipt], plan: AutomationCase, approval: RunApproval, attemptID: String) throws -> Set<String> {
        try validate(plan: plan, approval: approval)
        guard approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)) else { throw AutomationFixtureFreshnessError.invalidFixture }
        return try Self.identities(bindings: bindings, receipts: receipts, plan: plan, runID: approval.runID, attemptID: attemptID)
    }

    /// Historical identities only prohibit reuse; this cannot create live fixture authority.
    static func recordedIdentities(report: AutomationAttemptReport, plan: AutomationCase) throws -> Set<String> {
        var bindings: [AutomationFreshFixtureBinding] = []
        for check in plan.setupChecks ?? [] {
            guard let property = check.entityProperty else { throw AutomationFixtureFreshnessError.invalidFixture }
            let binding = AutomationFreshFixtureBinding(producerSegmentID: check.observationID, outputID: property.operationID, selection: property.selection)
            if !bindings.contains(binding) { bindings.append(binding) }
        }
        guard (1...10).contains(bindings.count), let runID = report.receipts.first?.scope.runId else { throw AutomationFixtureFreshnessError.invalidFixture }
        try validateBindings(bindings, plan: plan)
        let receipts = report.receipts.filter { receipt in plan.setup.contains(where: { $0.id == receipt.segmentID }) }
        return try identities(bindings: bindings, receipts: receipts, plan: plan, runID: runID, attemptID: report.attemptID)
    }

    fileprivate static func identities(bindings: [AutomationFreshFixtureBinding], receipts: [AutomationSegmentReceipt],
                                   plan: AutomationCase, runID: String, attemptID: String) throws -> Set<String> {
        guard receipts.map(\.segmentID) == plan.setup.map(\.id),
              receipts.allSatisfy({ $0.dispatched && $0.completed && $0.app == plan.app && $0.target == plan.target &&
                  $0.environmentID == plan.environmentID && $0.scope.runId == runID && $0.scope.attemptId == attemptID &&
                  $0.scope.segmentId == $0.segmentID }) else { throw AutomationFixtureFreshnessError.invalidFixture }
        var identities: Set<String> = []
        for binding in bindings {
            guard let setup = plan.setup.first(where: { $0.id == binding.producerSegmentID }),
                  let query = setup.hostProgram?.operations.first(where: { $0.id == binding.outputID }),
                  let receipt = receipts.first(where: { $0.segmentID == setup.id }), receipt.route == setup.kind,
                  AutomationFixtureValidator.validates(receipt: receipt, segment: setup, plan: plan, runID: runID, attemptID: attemptID),
                  let output = receipt.verifiedOutputs?[binding.outputID],
                  case .entity(let type, let id) = try binding.selection.resolve(output, query: query, attemptID: attemptID),
                  identities.insert(type + ":" + id).inserted else { throw AutomationFixtureFreshnessError.invalidFixture }
        }
        return identities
    }

    private static func validateBindings(_ bindings: [AutomationFreshFixtureBinding], plan: AutomationCase) throws {
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        let checks = plan.setupChecks ?? []
        guard !segments.contains(where: { $0.effects.contains(.externalWrite) }), plan.cleanup.isEmpty, !checks.isEmpty,
              plan.setup.contains(where: { $0.kind == .ui && $0.effects.contains(.fixtureWrite) }),
              plan.setup.allSatisfy({ $0.kind == .ui || ($0.kind == .systemQuery && $0.effects.isSubset(of: [.observe, .navigate])) }),
              plan.observations.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate]) }),
              checks.allSatisfy({ check in bindings.contains(where: {
                  $0.producerSegmentID == check.observationID && $0.outputID == check.entityProperty?.operationID &&
                  $0.selection == check.entityProperty?.selection
              }) }) else { throw AutomationContractError.missingEvidence("Every checked owned fixture must be freshly qualified") }
        for binding in bindings {
            guard let setup = plan.setup.first(where: { $0.id == binding.producerSegmentID }), setup.kind == .systemQuery,
                  setup.effects.isSubset(of: [.observe, .navigate]), let query = setup.hostProgram?.operations.first(where: { $0.id == binding.outputID }),
                  checks.contains(where: { $0.observationID == setup.id && $0.entityProperty?.operationID == query.id && $0.entityProperty?.selection == binding.selection }),
                  plan.setup.prefix(while: { $0.id != setup.id }).contains(where: { $0.kind == .ui && $0.effects.contains(.fixtureWrite) }) else {
                throw AutomationContractError.missingEvidence("Fresh binding needs a prior UI write and an independent fixture check")
            }
            try binding.selection.validate(query: query)
        }
        if !plan.execution.effects.isSubset(of: [.observe, .navigate]) {
            let inputs = plan.execution.inputBindings ?? []
            guard plan.execution.kind == .systemIntent, !inputs.isEmpty, plan.execution.inputs.isEmpty,
                  let operations = plan.execution.hostProgram?.operations, operations.count == 1,
                  let operation = operations.first, operation.kind == .invoke, operation.parameters.isEmpty,
                  inputs.allSatisfy({ input in
                      input.destination == .hostParameter && input.operationID == operation.id && input.uniqueEntity != nil && bindings.contains(where: { binding in
                          binding.producerSegmentID == input.producerSegmentID && binding.outputID == input.outputID &&
                          binding.selection.typeID == input.uniqueEntity?.typeID &&
                          binding.selection.attemptProperties == input.uniqueEntity?.attemptProperties &&
                          binding.selection.matchingProperties.allSatisfy({ input.uniqueEntity?.matchingProperties[$0.key] == $0.value })
                      })
                  }) else { throw AutomationContractError.missingEvidence("Repeated mutation needs exclusively fresh checked entity bindings") }
        }
    }

    static func digest(plan: AutomationCase) throws -> String {
        struct Contract: Encodable {
            let setup: [AutomationSegment]
            let checks: [AutomationRequirement]
            let subjectBindings: [AutomationInputBinding]
        }
        return try AutomationFrozenCase.canonicalDigest(Contract(setup: plan.setup, checks: plan.setupChecks ?? [], subjectBindings: plan.execution.inputBindings ?? []))
    }
}

enum AutomationFixtureFreshnessError: Error { case invalidFixture }

/// Campaign-wide identity reservations are consumed before subject acquisition,
/// including failed/cancelled attempts. A reservation is never refunded.
actor AutomationFixtureIdentityLedger {
    private var seen: Set<String>
    init(fixtures: [AutomationQualifiedFreshFixture], excludedHistoricalIDs: Set<String> = []) {
        // Historical facts can only prohibit reuse; they cannot qualify a fixture.
        seen = fixtures.reduce(into: excludedHistoricalIDs) { $0.formUnion($1.qualifiedEntityIDs) }
    }
    func reserve(_ identities: Set<String>) throws {
        guard !identities.isEmpty, seen.count + identities.count <= 4096, seen.isDisjoint(with: identities) else {
            throw AutomationFixtureFreshnessError.invalidFixture
        }
        seen.formUnion(identities)
    }
}

public actor AutomationFreshFixtureTracker {
    private let fixture: AutomationQualifiedFreshFixture
    private let ledger: AutomationFixtureIdentityLedger
    private var reservations: [String: Set<String>] = [:]
    public init(fixture: AutomationQualifiedFreshFixture) {
        self.fixture = fixture; ledger = AutomationFixtureIdentityLedger(fixtures: [fixture])
    }
    init(fixture: AutomationQualifiedFreshFixture, ledger: AutomationFixtureIdentityLedger) {
        self.fixture = fixture; self.ledger = ledger
    }
    func preflight(context: AutomationRecipeContext, plan: AutomationCase, approval: RunApproval) throws {
        guard fixture.context == context else { throw AutomationContractError.missingEvidence("Fresh fixture host, catalog or runtime changed") }
        try fixture.validate(plan: plan, approval: approval)
    }
    public func reserveBeforeSubject(receipts: [AutomationSegmentReceipt], plan: AutomationCase, approval: RunApproval, attemptID: String) async throws {
        guard reservations[attemptID] == nil, reservations.count < 100 else { throw AutomationFixtureFreshnessError.invalidFixture }
        let identities = try fixture.identities(receipts: receipts, plan: plan, approval: approval, attemptID: attemptID)
        // Insert before the actor hop: duplicate attempts cannot race ledger reservations.
        reservations[attemptID] = []
        try await ledger.reserve(identities)
        reservations[attemptID] = identities
    }
    func validate(report: AutomationAttemptReport, plan: AutomationCase, approval: RunApproval) throws {
        if !report.result.subjectDispatched { return }
        let setup = report.receipts.filter { receipt in plan.setup.contains(where: { $0.id == receipt.segmentID }) }
        let identities = try fixture.identities(receipts: setup, plan: plan, approval: approval, attemptID: report.attemptID)
        guard reservations[report.attemptID] == identities else { throw AutomationFixtureFreshnessError.invalidFixture }
    }
}

/// Mutation campaigns require an executor that checks freshness before dispatch.
public protocol AutomationFreshFixtureAttemptExecutor: AutomationCampaignAttemptExecutor {
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                 budget: AutomationCampaignBudget, fixtureTracker: AutomationFreshFixtureTracker) async throws -> AutomationAttemptReport
}

/// Duplicate-identity guard during two live qualification attempts. This grants
/// no recipe authority and cannot be constructed from imported evidence.
public actor AutomationFreshFixtureQualificationFence {
    private let bindings: [AutomationFreshFixtureBinding]
    private let planDigest: String
    private let runID: String
    private var seen: Set<String> = []
    init(bindings: [AutomationFreshFixtureBinding], plan: AutomationCase, approval: RunApproval,
         capabilities: CapabilityProfile, context: AutomationRecipeContext, previous: [AutomationLiveRecipeEvidence]) throws {
        try AutomationQualifiedFreshFixture.validateProposal(bindings: bindings, plan: plan, approval: approval, capabilities: capabilities)
        guard context.app == plan.app, context.target == plan.target, context.environmentID == plan.environmentID,
              context.localeIdentifier == plan.provenance["ui.locale"], context.uiRuntimeManifestDigest != nil else {
            throw AutomationFixtureFreshnessError.invalidFixture
        }
        self.bindings = bindings; planDigest = try AutomationFrozenCase.planDigest(plan); runID = approval.runID
        for live in previous where live.context.app.logicalID == context.app.logicalID && live.context.app.bundleID == context.app.bundleID &&
            live.context.target == context.target && live.context.environmentID == context.environmentID &&
            live.context.uiRuntimeManifestDigest == context.uiRuntimeManifestDigest && live.plan.setup == plan.setup &&
            live.plan.setupChecks == plan.setupChecks && live.plan.execution.inputBindings == plan.execution.inputBindings {
            seen.formUnion(try AutomationQualifiedFreshFixture.identities(bindings: bindings,
                receipts: live.report.receipts.filter { receipt in plan.setup.contains { $0.id == receipt.segmentID } },
                plan: live.plan, runID: live.approval.runID, attemptID: live.report.attemptID))
        }
    }
    func reserveBeforeSubject(receipts: [AutomationSegmentReceipt], plan: AutomationCase, approval: RunApproval, attemptID: String) throws {
        guard runID == approval.runID, planDigest == (try AutomationFrozenCase.planDigest(plan)), approval.approvedCaseDigest == planDigest else {
            throw AutomationFixtureFreshnessError.invalidFixture
        }
        let ids = try AutomationQualifiedFreshFixture.identities(bindings: bindings, receipts: receipts, plan: plan, runID: runID, attemptID: attemptID)
        guard seen.isDisjoint(with: ids), seen.count + ids.count <= 4096 else { throw AutomationFixtureFreshnessError.invalidFixture }
        seen.formUnion(ids)
    }
}
