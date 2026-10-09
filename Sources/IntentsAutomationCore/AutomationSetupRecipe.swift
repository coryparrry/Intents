import Foundation

/// A recipe identity is exact-build and environment scoped. Locale is the explicitly
/// approved profile declaration; a recipe does not discover or change device locale.
public struct AutomationRecipeContext: Codable, Equatable, Sendable {
    public let app: AppIdentity
    public let target: TargetIdentity
    public let environmentID: String
    public let catalogDigest: String
    public let hostDigest: String
    public let localeIdentifier: String
    public let uiRuntimeManifestDigest: String?
    public init(app: AppIdentity, target: TargetIdentity, environmentID: String, catalogDigest: String,
                hostDigest: String, localeIdentifier: String, uiRuntimeManifestDigest: String? = nil) {
        self.app = app; self.target = target; self.environmentID = environmentID
        self.catalogDigest = catalogDigest; self.hostDigest = hostDigest; self.localeIdentifier = localeIdentifier
        self.uiRuntimeManifestDigest = uiRuntimeManifestDigest
    }
    func validate() throws {
        guard [app.productDigest ?? "", catalogDigest, hostDigest].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
              uiRuntimeManifestDigest == nil || uiRuntimeManifestDigest?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !environmentID.isEmpty, !localeIdentifier.isEmpty, localeIdentifier.utf16.count <= 128 else {
            throw AutomationContractError.missingEvidence("Recipe needs exact product, schema, host, environment and declared locale identities")
        }
    }
    public static func catalogDigest(_ catalog: ApplicationSurfaceCatalog) throws -> String {
        let json = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(catalog))
        return AutomationArtifactRegistry.digest(try AutomationCanonicalJSON.encode(json))
    }
}

/// Data proposes a recipe; deserializing it grants no qualification or execution.
/// This first recipe family produces a uniquely observed text path, not an entity ID.
public struct AutomationSetupRecipeCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let version: Int
    public let producerSegmentID: String
    public let verifierSegmentID: String
    public let fillBinding: String
    public let outputID: String
    public let labelPrefix: String
    public let labelSuffix: String
    public init(id: String, version: Int = 1, producerSegmentID: String, verifierSegmentID: String,
                fillBinding: String, outputID: String, labelPrefix: String = "", labelSuffix: String = "") {
        self.id = id; self.version = version; self.producerSegmentID = producerSegmentID
        self.verifierSegmentID = verifierSegmentID; self.fillBinding = fillBinding; self.outputID = outputID
        self.labelPrefix = labelPrefix; self.labelSuffix = labelSuffix
    }
}

/// Neither Codable nor publicly constructible: reports imported from disk cannot
/// mint this authority. Only the native runner creates it after a completed live run.
struct AutomationLiveRecipeEvidence: Sendable {
    let context: AutomationRecipeContext
    let plan: AutomationCase
    let approval: RunApproval
    let report: AutomationAttemptReport
}

public struct AutomationQualifiedSetupRecipe: Sendable {
    public let candidate: AutomationSetupRecipeCandidate
    public let context: AutomationRecipeContext
    public let qualificationAttemptID: String
    public let qualificationReportDigest: String
    private let producer: AutomationSegment
    private let verifier: AutomationSegment

    init(candidate: AutomationSetupRecipeCandidate, live: AutomationLiveRecipeEvidence) throws {
        try live.context.validate()
        guard [candidate.id, candidate.producerSegmentID, candidate.verifierSegmentID, candidate.fillBinding, candidate.outputID].allSatisfy(AutomationHostProgram.identifier),
              candidate.version > 0, candidate.labelPrefix.utf16.count + candidate.labelSuffix.utf16.count <= 1024,
              live.plan.app == live.context.app, live.plan.target == live.context.target,
              live.plan.environmentID == live.context.environmentID,
              live.plan.provenance["ui.locale"] == live.context.localeIdentifier,
              live.approval.disposable, live.approval.app == live.plan.app, live.approval.target == live.plan.target,
              live.approval.environmentID == live.plan.environmentID,
              live.approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(live.plan)),
              live.report.executionSucceeded else { throw AutomationContractError.missingEvidence("Recipe has no approved, complete live qualification") }
        try AutomationRecordedEvidence.validate(report: live.report, plan: live.plan, expectedRunID: live.approval.runID)
        let subject = live.plan.execution
        let readOnlySubject = (subject.kind == .systemQuery && subject.hostProgram?.operations.allSatisfy({ $0.kind == .query }) == true)
            || (subject.kind == .ui && subject.uiProgram?.operations.allSatisfy({ $0.kind == .observeProperty }) == true)
        guard readOnlySubject, subject.effects.isSubset(of: [.observe, .navigate]), live.plan.cleanup.isEmpty else {
            throw AutomationContractError.missingEvidence("Recipe qualification cannot depend on an intervening mutation")
        }
        guard let producer = live.plan.setup.first(where: { $0.id == candidate.producerSegmentID }),
              let verifier = live.plan.observations.first(where: { $0.id == candidate.verifierSegmentID }),
              producer.kind == .ui, verifier.kind == .ui,
              live.plan.setup == [producer], live.plan.observations == [verifier],
              producer.inputBindings?.isEmpty ?? true, verifier.inputBindings?.isEmpty ?? true,
              producer.effects.isSubset(of: [.observe, .navigate, .fixtureWrite]), producer.effects.contains(.fixtureWrite),
              verifier.effects.isSubset(of: [.observe, .navigate]),
              let program = producer.uiProgram, let verification = verifier.uiProgram,
              let input = program.bindings[candidate.fillBinding], !input.isEmpty,
              program.operations.filter({ $0.kind == .fillBinding && $0.binding == candidate.fillBinding }).count == 1,
              !program.operations.contains(where: { $0.kind == .navigateGoal || $0.kind == .observeProperty || $0.kind == .readProperty }),
              verification.operations.count == 1, let endpoint = verification.operations.first,
              endpoint.kind == .observeProperty, endpoint.id == candidate.outputID, endpoint.property == "text",
              endpoint.locator == .init(.label, candidate.labelPrefix + input + candidate.labelSuffix),
              verification.bindings.isEmpty else { throw AutomationContractError.missingEvidence("Recipe needs one approved fill and a distinct exact-label observer") }
        try program.validate(phase: .setup); try verification.validate(phase: .observe)
        let receipts = live.report.receipts.filter { $0.segmentID == verifier.id }
        guard receipts.count == 1, let receipt = receipts.first,
              receipt.environmentID == live.context.environmentID,
              receipt.verifiedOutputs?[candidate.outputID] == .text(candidate.labelPrefix + input + candidate.labelSuffix) else {
            throw AutomationContractError.missingEvidence("Fresh independent setup endpoint was not verified")
        }
        self.candidate = candidate; context = live.context; qualificationAttemptID = live.report.attemptID
        // Native reports contain fractional Date values, unlike integer-only RPC
        // frames. Preserve them in deterministic native storage encoding.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        qualificationReportDigest = AutomationArtifactRegistry.digest(try encoder.encode(live.report))
        self.producer = producer; self.verifier = verifier
    }

    /// Compile fresh setup and observation operations. No prior output or verdict
    /// is copied. Consumers use ordinary input bindings from the new verifier.
    public func instantiate(text: String, context: AutomationRecipeContext, segmentPrefix: String) throws -> [AutomationSegment] {
        try context.validate()
        guard context == self.context, AutomationHostProgram.identifier(segmentPrefix), segmentPrefix.utf16.count <= 200,
              !text.isEmpty, text.utf16.count <= 32768,
              candidate.labelPrefix.utf16.count + text.utf16.count + candidate.labelSuffix.utf16.count <= 1024 else {
            throw AutomationContractError.missingEvidence("Recipe identity changed or its input has no qualified text path")
        }
        var create = producer, verify = verifier
        create.id = segmentPrefix + ".create"; create.phase = .setup
        create.uiProgram?.bindings[candidate.fillBinding] = text
        verify.id = segmentPrefix + ".verify"; verify.phase = .setup
        verify.uiProgram?.operations[0].locator = .init(.label, candidate.labelPrefix + text + candidate.labelSuffix)
        try create.uiProgram?.validate(phase: .setup); try verify.uiProgram?.validate(phase: .setup)
        return [create, verify]
    }
}
