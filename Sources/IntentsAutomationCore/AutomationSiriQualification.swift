import Foundation

/// Deliberately non-Codable. A saved capability profile cannot authorize calibration
/// or restore a live, exact-case routing qualification in another process.
public struct AutomationSiriRouteAuthority: Sendable {
    private let digest: String
    private let calibrationRunID: String?
    private let deadline: ContinuousClock.Instant
    let expectedOSBuild: String?
    let evidenceDigest: String?
    var isQualification: Bool { calibrationRunID != nil }
    let isRepeatableQualification: Bool
    private let now: @Sendable () -> ContinuousClock.Instant

    init(plan: AutomationCase, approval: RunApproval, osBuild: String? = nil, evidenceDigest: String? = nil, repeatable: Bool = false,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }, calibrationOSBuild: String? = nil) throws {
        try AutomationSiriQualificationProposal.validate(plan: plan, approval: approval)
        guard (osBuild == nil && evidenceDigest == nil) ||
              (osBuild?.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil &&
               evidenceDigest?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil) else { throw AutomationContractError.invalidIdentity }
        self.now = now; isRepeatableQualification = repeatable
        guard calibrationOSBuild == nil || calibrationOSBuild?.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        digest = try AutomationFrozenCase.planDigest(plan)
        calibrationRunID = osBuild == nil ? approval.runID : nil
        expectedOSBuild = osBuild ?? calibrationOSBuild; self.evidenceDigest = evidenceDigest
        deadline = now().advanced(by: .seconds(1800))
    }
    func validate(plan: AutomationCase, approval: RunApproval) throws {
        guard now() < deadline, digest == (try AutomationFrozenCase.planDigest(plan)),
              approval.approvedCaseDigest == digest,
              calibrationRunID == nil || calibrationRunID == approval.runID else { throw AutomationContractError.conflictingOperation }
        try AutomationSiriQualificationProposal.validate(plan: plan, approval: approval)
    }
}

/// Narrow first-run admission: one controlled existing record, positive baseline,
/// actual Siri subject, and a read-only query of that same returned record identity.
/// It deliberately cannot authorize arbitrary setup writes or external effects.
public enum AutomationSiriQualificationProposal {
    public static func validate(plan: AutomationCase, approval: RunApproval) throws {
        if plan.provenance["siri.repeatableReset"] != nil {
            try AutomationSiriRepeatableQualification.validateStructure(plan: plan, approval: approval); return
        }
        try validateSingle(plan: plan, approval: approval)
    }
    static func validateSingle(plan: AutomationCase, approval: RunApproval) throws {
        guard plan.target.kind == .physical, plan.app == approval.app, plan.target == approval.target,
              plan.environmentID == approval.environmentID, approval.disposable,
              plan.execution.kind == .siriText, plan.execution.siriProgram != nil,
              plan.execution.effects == [.observe, .navigate, .fixtureWrite],
              plan.setup.count == 1, plan.observations.count == 1, plan.cleanup.isEmpty,
              plan.setupChecks?.count == 1, plan.requirements.count == 1,
              let before = plan.setupChecks?.first, let after = plan.requirements.first,
              before.entityProperty == after.entityProperty, let predicate = before.entityProperty,
              before.proof == .appState, after.proof == .appState,
              case .bool(let initial) = before.expected, case .bool(let expected) = after.expected,
              initial != expected, before.observationID == plan.setup[0].id,
              after.observationID == plan.observations[0].id else {
            throw AutomationContractError.invalidPlan("Siri calibration needs an approved disposable record with different before and after states")
        }
        let baseline = plan.setup[0], observer = plan.observations[0]
        guard baseline.kind == .systemQuery, baseline.effects == [.observe], baseline.requiredCapabilities == ["apple.entity.query"],
              observer.kind == .systemQuery, observer.effects == [.observe], observer.requiredCapabilities == ["apple.entity.query"],
              baseline.hostProgram?.operations.count == 1, observer.hostProgram?.operations.count == 1,
              let query = baseline.hostProgram?.operations.first, let readback = observer.hostProgram?.operations.first,
              query.kind == .query, readback.kind == .query, query.id == predicate.operationID,
              query.id == readback.id, query.typeID == readback.typeID, query.properties == readback.properties,
              let text = query.queryText, !text.isEmpty, query.queryIDs == nil, query.attemptQueryPrefix == nil,
              readback.queryText == nil, readback.queryIDs == nil, readback.attemptQueryPrefix == nil,
              predicate.selection.attemptProperties == nil,
              predicate.selection.matchingProperties.values.contains(.text(text)),
              baseline.inputBindings?.isEmpty != false, baseline.attemptTextBindings?.isEmpty != false,
              observer.attemptTextBindings?.isEmpty != false,
              observer.inputBindings == [.init(producerSegmentID: baseline.id, outputID: query.id,
                destination: .hostQueryIDs, operationID: query.id, name: "queryIDs", uniqueEntity: predicate.selection)],
              query.properties?[predicate.property] == "bool" else {
            throw AutomationContractError.invalidPlan("Siri calibration must independently query the same uniquely selected real record before and after submission")
        }
        try AutomationRequirementValidator.validate(plan: plan)
    }
}

/// Verifies the safe repeated submission channel independently of the business oracle.
/// These historical facts alone cannot create runtime authority or prove app invocation.
enum AutomationSiriSubmissionQualification {
    static func validate(report: AutomationAttemptReport, plan: AutomationCase, approval: RunApproval) throws {
        try AutomationSiriQualificationProposal.validate(plan: plan, approval: approval)
        let businessChecks = Set(plan.requirements.map { $0.checkID ?? $0.observationID })
        guard report.resourcesReleased, report.result.assessed, report.result.evidenceComplete,
              [.passed, .assertionFailed].contains(report.result.summary),
              report.result.failedObservations.allSatisfy(businessChecks.contains),
              report.result.subjectDispatched, report.result.subjectCompleted, !report.result.subjectDispatchUncertain,
              report.receipts.count == plan.setup.count + 1 + plan.observations.count,
              (plan.setup + [plan.execution] + plan.observations).allSatisfy({ segment in
                  report.receipts.filter { $0.segmentID == segment.id && $0.route == segment.kind && $0.dispatched && $0.completed }.count == 1
              }),
              report.receipts.filter({ $0.route == .siriText && $0.segmentID == plan.execution.id && $0.artifact?.isEmpty == false }).count == 1 else {
            throw AutomationContractError.missingEvidence("Siri submission qualification needs complete canonical setup, submission, observer and release evidence")
        }
        try AutomationRecordedEvidence.validate(report: report, plan: plan, expectedRunID: approval.runID)
        guard let check = plan.setupChecks?.first, let predicate = check.entityProperty,
              let query = plan.setup.last?.hostProgram?.operations.first,
              let before = report.receipts.first(where: { $0.segmentID == plan.setup.last?.id })?.verifiedOutputs?[query.id],
              let observed = report.receipts.first(where: { $0.segmentID == plan.observations[0].id }),
              let after = observed.verifiedOutputs?[query.id], observed.observations.count == 1,
              observed.observations[0].value == after,
              try predicate.value(queryResult: before, query: query) == check.expected,
              try predicate.selection.resolve(before, query: query) == predicate.selection.resolve(after, query: query) else {
            throw AutomationContractError.missingEvidence("Siri submission qualification requires the restored initial state and the same real record observed after submission")
        }
    }
}

#if os(macOS)
/// Only the owned physical campaign records direct live evidence here. JSON reports
/// remain historical and cannot be imported to create this authority.
actor AutomationSiriQualificationAuthority {
    static let shared = AutomationSiriQualificationAuthority()
    private struct Entry: Sendable {
        let prepared: AutomationPreparedApplication
        let plan: AutomationCase
        let authority: AutomationSiriRouteAuthority
        let attemptIDs: [String]
        let entityIdentity: AutomationValue
    }
    private var entries: [Entry] = []

    func record(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
                report: AutomationAttemptReport, submission: AutomationImportedSiriSubmission) throws {
        try AutomationSiriSubmissionQualification.validate(report: report, plan: plan, approval: approval)
        guard prepared.host.app == plan.app, prepared.host.target == plan.target,
              plan.provenance["siri.repeatableReset"] != nil || report.result.summary == .passed,
              submission.requestDigest == plan.execution.siriProgram?.requestDigest,
              let osBuild = submission.osBuild, !osBuild.isEmpty else {
            throw AutomationContractError.missingEvidence("Siri qualification needs a fresh exact owned submission and selected prepared physical target")
        }

        guard let predicate = plan.setupChecks?.first?.entityProperty,
              let query = plan.setup.last?.hostProgram?.operations.first,
              let before = report.receipts.first(where: { $0.segmentID == plan.setup.last?.id })?.verifiedOutputs?[query.id] else {
            throw AutomationContractError.missingEvidence("Missing live Siri selected record")
        }
        let identity = try predicate.selection.resolve(before, query: query)
        let previous = entries.last { $0.prepared == prepared && $0.plan == plan &&
            (try? $0.authority.validate(plan: plan, approval: approval)) != nil }
        var attemptIDs = [report.attemptID]
        if plan.provenance["siri.repeatableReset"] != nil {
            guard submission.submittedRecognizedText == plan.execution.siriProgram?.request else {
                throw AutomationContractError.missingEvidence("Unknown submitted recognised text cannot qualify repeated Siri submission")
            }
            if let previous {
                guard previous.entityIdentity == identity, previous.authority.expectedOSBuild == osBuild,
                      !previous.attemptIDs.contains(report.attemptID) else { throw AutomationContractError.conflictingOperation }
                attemptIDs = previous.attemptIDs + attemptIDs
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = AutomationArtifactRegistry.digest(try encoder.encode(report))
        let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval, osBuild: osBuild, evidenceDigest: digest, repeatable: plan.provenance["siri.repeatableReset"] != nil && attemptIDs.count >= 2)
        entries.append(.init(prepared: prepared, plan: plan, authority: authority, attemptIDs: attemptIDs, entityIdentity: identity))
        if entries.count > 32 { entries.removeFirst() }
    }
    func revoke(prepared: AutomationPreparedApplication, plan: AutomationCase) {
        entries.removeAll { $0.prepared == prepared && $0.plan == plan }
    }
    func admission(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval) -> AutomationSiriRouteAuthority? {
        entries.reversed().first { $0.prepared == prepared && $0.plan == plan &&
            (try? $0.authority.validate(plan: plan, approval: approval)) != nil }?.authority
    }
}
#endif
