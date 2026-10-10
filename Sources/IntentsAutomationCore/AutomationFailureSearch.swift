import Foundation

public enum AutomationMutationKind: String, Codable, Sendable {
    case duplicateLabel, unrelatedData, alternatePhrasing, missingEntity, lookupOrdering, beforeCommitFailure
}
public struct AutomationMutationCase: Codable, Equatable, Sendable {
    public var frozen: AutomationFrozenCase
    public var recipeIDs: [String]
    public var kinds: [AutomationMutationKind]
    public var requiredCapabilities: [String]
    public var semanticJustification: String
    public var goalPhraseVariation: Bool?
    public init(frozen: AutomationFrozenCase, recipeIDs: [String], kinds: [AutomationMutationKind], requiredCapabilities: [String], semanticJustification: String, goalPhraseVariation: Bool? = nil) {
        self.frozen = frozen; self.recipeIDs = recipeIDs; self.kinds = kinds
        self.requiredCapabilities = requiredCapabilities; self.semanticJustification = semanticJustification
        self.goalPhraseVariation = goalPhraseVariation
    }
}
public struct AutomationReductionEdge: Codable, Equatable, Sendable {
    public var parentDigest: String
    public var childDigest: String
    public var semanticJustification: String
    public init(parentDigest: String, childDigest: String, semanticJustification: String) {
        self.parentDigest = parentDigest; self.childDigest = childDigest; self.semanticJustification = semanticJustification
    }
}
public struct AutomationSearchApproval: Sendable {
    public var run: RunApproval
    public var approvedDigests: Set<String>
    public var limits: AutomationCampaignLimits
    /// Qualified setup/reset and fresh bindings are required for repeated writes.
    public var freshFixtureCapability: String?
    public var qualifiedFixtures: [String: AutomationQualifiedFreshFixture]
    public init(run: RunApproval, approvedDigests: Set<String>, limits: AutomationCampaignLimits = .init(), freshFixtureCapability: String? = nil,
                qualifiedFixtures: [String: AutomationQualifiedFreshFixture] = [:]) {
        self.run = run; self.approvedDigests = approvedDigests; self.limits = limits; self.freshFixtureCapability = freshFixtureCapability
        self.qualifiedFixtures = qualifiedFixtures
    }
}
public struct AutomationSearchAttempt: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case baseline, discovery, confirmation, reduction, finalConfirmation }
    public var stage: Stage
    public var caseDigest: String
    public var report: AutomationAttemptReport
}
public struct AutomationFailureConfirmation: Codable, Equatable, Sendable {
    public var caseDigest: String
    public var signature: [String]
    public var attempts: [String]
    public var matchingFailures: Int
    public var assessedPasses: Int
    public var otherFailures: Int
    public var unassessed: Int
    public var complete: Bool { attempts.count == 5 }
    public var confirmed: Bool { complete && matchingFailures > 0 }
}
public struct AutomationSearchInterruption: Codable, Equatable, Sendable {
    public var attemptID: String
    public var caseDigest: String
    public var stage: AutomationSearchAttempt.Stage
    public var dispatchMayHaveOccurred: Bool
    public var reason: String
}
public struct AutomationFailureSearchReport: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var baselineDigest: String
    public var attempts: [AutomationSearchAttempt] = []
    public var confirmations: [AutomationFailureConfirmation] = []
    public var interruptions: [AutomationSearchInterruption] = []
    public var counters = ScopeCounters()
    public var usage = AutomationCampaignUsage()
    public var bestConfirmedCaseDigest: String?
    public var finalReproduction: AutomationFailureConfirmation?
    public var stopReason: String?
    public var capabilityGaps: [String] = []
    public var reductionScope = "Best confirmed smaller approved case; no claim of global minimality"
}
public protocol AutomationCampaignAttemptExecutor: Sendable {
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                 budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport
}

/// Swift freezes each attempt and computes failure signatures. Executors return facts, never predicates.
public actor AutomationFailureSearch {
    private let cases: AutomationCaseStore
    private var running = false
    private var result = AutomationFailureSearchReport(baselineDigest: "")
    private var stopped = false
    private struct Context: Sendable {
        var approval: AutomationSearchApproval
        var executor: any AutomationCampaignAttemptExecutor
        var budget: AutomationCampaignBudget
        var fixtureTrackers: [String: AutomationFreshFixtureTracker]
    }
    private var context: Context?
    public init(cases: AutomationCaseStore) { self.cases = cases }
    public func run(baseline: AutomationFrozenCase, mutations: [AutomationMutationCase], reductions: [AutomationReductionEdge] = [],
                    approval: AutomationSearchApproval, capabilities: CapabilityProfile,
                    executor: any AutomationCampaignAttemptExecutor) async throws -> AutomationFailureSearchReport {
        guard !running else { throw AutomationContractError.targetBusy }
        try validate(baseline: baseline, mutations: mutations, reductions: reductions, approval: approval, capabilities: capabilities)
        guard approval.qualifiedFixtures.isEmpty || executor is any AutomationFreshFixtureAttemptExecutor else {
            throw AutomationContractError.missingEvidence("Mutating search requires a pre-dispatch fresh-fixture executor")
        }
        running = true; defer { running = false; context = nil }
        // Freeze the entire approved population before any subject can execute.
        for frozen in [baseline] + mutations.map(\.frozen) { _ = try await cases.freeze(frozen.plan) }
        let budget = try AutomationCampaignBudget(limits: approval.limits)
        let ledger = AutomationFixtureIdentityLedger(fixtures: Array(approval.qualifiedFixtures.values))
        let trackers = approval.qualifiedFixtures.mapValues { AutomationFreshFixtureTracker(fixture: $0, ledger: ledger) }
        context = Context(approval: approval, executor: executor, budget: budget, fixtureTrackers: trackers)
        result = AutomationFailureSearchReport(baselineDigest: baseline.digest); stopped = false
        for kind in [AutomationMutationKind.duplicateLabel, .unrelatedData, .alternatePhrasing, .missingEntity, .lookupOrdering, .beforeCommitFailure] {
            if !mutations.contains(where: { $0.kinds.contains(kind) }) { result.capabilityGaps.append("No qualified approved " + kind.rawValue + " recipe") }
        }
        var candidates: [(AutomationFrozenCase, [String])] = []
        for _ in 0..<min(3, approval.limits.attempts) {
            guard let report = await attempt(baseline, .baseline) else { break }
            if Self.isFailure(report), !candidates.contains(where: { $0.0.digest == baseline.digest }) { candidates.append((baseline, Self.signature(report))) }
        }
        let queue = mutations.sorted {
            if $0.recipeIDs.count != $1.recipeIDs.count { return $0.recipeIDs.count < $1.recipeIDs.count }
            return $0.frozen.digest < $1.frozen.digest
        }
        // Singles precede explicitly qualified compatible pairs. No Cartesian product is invented.
        for candidate in queue.prefix(50) {
            guard let report = await attempt(candidate.frozen, .discovery) else { break }
            if Self.isFailure(report) { candidates.append((candidate.frozen, Self.signature(report))) }
        }
        var best: (AutomationFrozenCase, [String])?
        // Initial allocation: ten confirmation attempts, five fresh attempts per candidate.
        for candidate in candidates.prefix(2) {
            let confirmation = await confirm(candidate.0, candidate.1, .confirmation)
            result.confirmations.append(confirmation)
            if confirmation.confirmed && best == nil { best = candidate }
        }
        if var selected = best {
            var reductionAttempts = 0
            let definitions = Dictionary(uniqueKeysWithValues: ([baseline] + mutations.map(\.frozen)).map { ($0.digest, $0) })
            while !stopped {
                let children = reductions.filter { $0.parentDigest == selected.0.digest }.sorted { $0.childDigest < $1.childDigest }
                var improved = false
                for edge in children {
                    // Reserve five additional attempts for a fresh final reproduction.
                    guard reductionAttempts + 5 <= 32, let child = definitions[edge.childDigest] else { continue }
                    let confirmation = await confirm(child, selected.1, .reduction)
                    reductionAttempts += confirmation.attempts.count; result.confirmations.append(confirmation)
                    if confirmation.confirmed { selected = (child, selected.1); improved = true; break }
                }
                if !improved { break }
            }
            result.bestConfirmedCaseDigest = selected.0.digest
            result.finalReproduction = await confirm(selected.0, selected.1, .finalConfirmation)
        }
        result.usage = await budget.snapshot()
        if result.stopReason == nil { result.stopReason = "Approved search population completed" }
        return result
    }
    private func attempt(_ frozen: AutomationFrozenCase, _ stage: AutomationSearchAttempt.Stage) async -> AutomationAttemptReport? {
            guard !stopped, let context else { return nil }
            let budget = context.budget, approval = context.approval, executor = context.executor
            var attemptID: String?
            var enteredExecutor = false
            do {
                try await budget.available()
                let id = UUID().uuidString
                try await budget.reserveAttempt(id: id); attemptID = id
                _ = try await cases.freeze(frozen.plan)
                var runApproval = approval.run; runApproval.approvedCaseDigest = frozen.digest
                enteredExecutor = true
                let report: AutomationAttemptReport
                if let tracker = context.fixtureTrackers[frozen.digest], let fresh = executor as? any AutomationFreshFixtureAttemptExecutor {
                    report = try await fresh.execute(frozen: frozen, approval: runApproval, attemptID: id, budget: budget, fixtureTracker: tracker)
                    try await tracker.validate(report: report, plan: frozen.plan, approval: runApproval)
                } else { report = try await executor.execute(frozen: frozen, approval: runApproval, attemptID: id, budget: budget) }
                guard report.attemptID == id else { throw AutomationContractError.conflictingOperation }
                try AutomationRecordedEvidence.validate(report: report, plan: frozen.plan, expectedRunID: runApproval.runID)
                // The executor may already have persisted this exact immutable attempt.
                if let existing = try? await cases.loadAttempt(id: id, frozen: frozen) {
                    guard existing == report else { throw AutomationContractError.conflictingOperation }
                } else { try await cases.saveAttempt(report, for: frozen) }
                result.attempts.append(.init(stage: stage, caseDigest: frozen.digest, report: report)); result.counters.record(report.result)
                if !report.resourcesReleased || report.result.subjectDispatchUncertain {
                    result.stopReason = "Unresolved dispatch or resource release; fresh attempts stopped"; stopped = true
                }
                return report
            } catch {
                let reason: String
                if error is CancellationError { reason = "Cancelled" }
                else if let budgetError = error as? AutomationCampaignBudgetError { reason = String(describing: budgetError) }
                else { reason = "Attempt failed before canonical evidence could be verified" }
                if let attemptID {
                    result.interruptions.append(.init(attemptID: attemptID, caseDigest: frozen.digest, stage: stage, dispatchMayHaveOccurred: enteredExecutor, reason: reason))
                    result.counters.planned += 1
                    if enteredExecutor { result.counters.unresolved += 1 } else { result.counters.notRun += 1 }
                }
                result.stopReason = reason
                stopped = true; return nil
            }
        }
    private func confirm(_ frozen: AutomationFrozenCase, _ signature: [String], _ stage: AutomationSearchAttempt.Stage) async -> AutomationFailureConfirmation {
            var confirmation = AutomationFailureConfirmation(caseDigest: frozen.digest, signature: signature, attempts: [], matchingFailures: 0, assessedPasses: 0, otherFailures: 0, unassessed: 0)
            for _ in 0..<5 {
                guard let report = await attempt(frozen, stage) else { break }
                confirmation.attempts.append(report.attemptID)
                if report.result.assessed && report.result.evidenceComplete && report.result.summary == .assertionFailed {
                    if Self.signature(report) == signature { confirmation.matchingFailures += 1 } else { confirmation.otherFailures += 1 }
                } else if report.result.assessed && report.result.summary == .passed { confirmation.assessedPasses += 1 }
                else { confirmation.unassessed += 1 }
            }
            return confirmation
        }
    private static func isFailure(_ report: AutomationAttemptReport) -> Bool {
        report.result.summary == .assertionFailed && report.result.assessed && report.result.evidenceComplete
    }
    private static func signature(_ report: AutomationAttemptReport) -> [String] { report.result.failedObservations.sorted() }
    private func reductionSize(_ frozen: AutomationFrozenCase, mutations: [AutomationMutationCase]) -> [Int] {
        let recipes = mutations.first { $0.frozen.digest == frozen.digest }?.recipeIDs.count ?? 0
        let setup = frozen.plan.setup.reduce(0) { $0 + ($1.uiProgram?.operations.count ?? $1.hostProgram?.operations.count ?? 1) }
        let inputs = frozen.plan.execution.inputs.values.reduce(0) { $0 + ((try? AutomationFrozenCase.canonicalData($1).count) ?? 0) }
        return [recipes, setup, inputs]
    }
    private func validate(baseline: AutomationFrozenCase, mutations: [AutomationMutationCase], reductions: [AutomationReductionEdge], approval: AutomationSearchApproval, capabilities: CapabilityProfile) throws {
        try baseline.validate(); try approval.limits.validate()
        guard !baseline.plan.requirements.isEmpty, mutations.count <= 50, reductions.count <= 100,
              Set(([baseline] + mutations.map(\.frozen)).map(\.digest)).count == mutations.count + 1 else { throw AutomationContractError.invalidPlan("Search requires distinct frozen cases and approved business assertions") }
        let all = [baseline] + mutations.map(\.frozen)
        for frozen in all {
            try frozen.validate()
            let phrase = mutations.first { $0.frozen.digest == frozen.digest && $0.goalPhraseVariation == true }
            if let phrase { try AutomationGoalPhraseVariation.validate(phrase, baseline: baseline) }
            let sameSubject: Bool
            if phrase != nil { sameSubject = true }
            else {
                sameSubject = try frozen.plan.execution.operation == baseline.plan.execution.operation &&
                    AutomationFrozenCase.subjectContractDigest(frozen.plan) == AutomationFrozenCase.subjectContractDigest(baseline.plan)
            }
            guard approval.approvedDigests.contains(frozen.digest), frozen.plan.app == baseline.plan.app, frozen.plan.target == baseline.plan.target,
                  frozen.plan.environmentID == baseline.plan.environmentID, frozen.oracleDigest == baseline.oracleDigest,
                  frozen.plan.execution.kind == baseline.plan.execution.kind, sameSubject,
                  frozen.plan.observations == baseline.plan.observations else { throw AutomationContractError.invalidPlan("Mutation changes an unapproved oracle, route or observer") }
            var runApproval = approval.run; runApproval.approvedCaseDigest = frozen.digest
            try PlanValidator.validate(frozen.plan, approval: runApproval, capabilities: capabilities)
            for segment in frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup {
                try segment.hostProgram?.validate(route: segment.kind, phase: segment.phase)
                try segment.uiProgram?.validate(phase: segment.phase)
            }
            let effects = (frozen.plan.setup + [frozen.plan.execution] + frozen.plan.cleanup).reduce(into: Set<AutomationEffect>()) { $0.formUnion($1.effects) }
            guard !effects.contains(.externalWrite) else { throw AutomationContractError.invalidPlan("External writes are not qualified for repeated failure search") }
            if effects.contains(.fixtureWrite) || effects.contains(.reset) {
                guard approval.run.disposable, let fixture = approval.qualifiedFixtures[frozen.digest] else { throw AutomationContractError.missingEvidence("Repeated writes require a live-qualified fresh fixture and bindings per attempt") }
                if let capability = approval.freshFixtureCapability {
                    guard capabilities.supports([capability]), frozen.plan.setup.contains(where: { $0.requiredCapabilities.contains(capability) }) else {
                        throw AutomationContractError.missingEvidence("The additionally declared fixture capability is unavailable")
                    }
                }
                try fixture.validate(plan: frozen.plan, approval: runApproval)
            }
        }
        for mutation in mutations {
            if mutation.goalPhraseVariation == true { try AutomationGoalPhraseVariation.validate(mutation, baseline: baseline); continue }
            guard !mutation.recipeIDs.isEmpty, mutation.recipeIDs.count <= 2, Set(mutation.recipeIDs).count == mutation.recipeIDs.count,
                  !mutation.kinds.isEmpty, !mutation.requiredCapabilities.isEmpty, capabilities.supports(mutation.requiredCapabilities),
                  !mutation.semanticJustification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AutomationContractError.missingEvidence("Mutation recipe or semantic qualification is unavailable") }
        }
        let definitions = Dictionary(uniqueKeysWithValues: all.map { ($0.digest, $0) })
        for edge in reductions {
            guard let parent = definitions[edge.parentDigest], let child = definitions[edge.childDigest], parent.digest != child.digest,
                  !edge.semanticJustification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reductionSize(child, mutations: mutations).lexicographicallyPrecedes(reductionSize(parent, mutations: mutations)) else { throw AutomationContractError.invalidPlan("Reduction must be an approved smaller semantically equivalent case") }
        }
    }
}
#if os(macOS)
/// Production adapter uses the same approved native application runner and dispatch budget.
public struct AutomationPreparedCampaignExecutor: AutomationCampaignAttemptExecutor {
    public let runner: AutomationApplicationRunner
    public let prepared: AutomationPreparedApplication
    public let capabilities: CapabilityProfile
    public let allowBootAndInstall: Bool
    public let uiRuntime: AutomationUIRuntime?
    public init(runner: AutomationApplicationRunner, prepared: AutomationPreparedApplication, capabilities: CapabilityProfile, allowBootAndInstall: Bool, uiRuntime: AutomationUIRuntime? = nil) {
        self.runner = runner; self.prepared = prepared; self.capabilities = capabilities; self.allowBootAndInstall = allowBootAndInstall
        self.uiRuntime = uiRuntime
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        try await runner.run(prepared: prepared, plan: frozen.plan, approval: approval, capabilities: capabilities,
            attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: budget, uiRuntime: uiRuntime)
    }
}
#endif
