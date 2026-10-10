#if os(macOS)
import Foundation

/// A live read from this runner. Historical JSON and arbitrary identifiers cannot mint a choice.
public struct AutomationQueryEntityChoice: Equatable, Sendable, Identifiable {
    public let id: String
    public let typeID: String
    public let properties: [String: AutomationValue]
    public let sourceAttemptID: String
    let app: AppIdentity
    let target: TargetIdentity
    let environmentID: String
    let catalogDigest: String
}
public struct AutomationEntityQueryResult: Sendable {
    public let report: AutomationAttemptReport
    public let choices: [AutomationQueryEntityChoice]
    public let selectionGap: String?
    public let propertyProjection: AutomationEntityProjectionEvidence?
    init(report: AutomationAttemptReport, choices: [AutomationQueryEntityChoice], selectionGap: String?,
         propertyProjection: AutomationEntityProjectionEvidence? = nil) {
        self.report = report; self.choices = choices; self.selectionGap = selectionGap; self.propertyProjection = propertyProjection
    }
}
public enum AutomationEntityQuery {
    public static func acceptsQueryText(_ text: String) -> Bool {
        text.utf16.count <= 32768 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public static func capabilities(_ prepared: AutomationPreparedApplication) -> CapabilityProfile {
        .init(records: ["apple.entity.query": .init(state: .available,
            reason: "Associated host supports typed queries; subject registration is checked during the actual query",
            probeVersion: "host-v2", evidence: [prepared.host.xctestrunDigest])])
    }
    public static func plan(prepared: AutomationPreparedApplication, entity: ApplicationSurfaceCatalog.Entity,
                            text: String, approval: RunApproval) throws -> AutomationCase {
        guard prepared.catalog.app == prepared.host.app, prepared.catalog.entities?.contains(entity) == true,
              approval.app == prepared.host.app, approval.target == prepared.host.target, approval.effects == [.observe],
              acceptsQueryText(text) else {
            throw AutomationContractError.missingEvidence("Select a declared query and approve reading records on this app and target")
        }
        var segment = AutomationSegment(id: "query", kind: .systemQuery, phase: .subject, operation: entity.title,
            requiredCapabilities: ["apple.entity.query"], effects: [.observe], lifecycle: .persistedStateAcrossSegments)
        segment.hostProgram = .init(operations: [.init(id: "records", kind: .query, typeID: entity.typeID, queryText: text, properties: entity.properties)])
        var plan = AutomationCase(id: "query." + entity.typeID, app: prepared.host.app, target: prepared.host.target,
            environmentID: approval.environmentID, execution: segment)
        plan.provenance = ["catalog": try AutomationRecipeContext.catalogDigest(prepared.catalog), "expectation": "live query selection only; no business assessment"]
        plan.id = "query." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
        let digest = try AutomationFrozenCase.planDigest(plan)
        guard approval.approvedCaseDigest == nil || approval.approvedCaseDigest == digest else { throw AutomationContractError.conflictingOperation }
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities(prepared))
        return plan
    }
    public static func execute(runner: AutomationApplicationRunner, prepared: AutomationPreparedApplication,
                               entity: ApplicationSurfaceCatalog.Entity, text: String, approval: RunApproval,
                               attemptID: String, allowBootAndInstall: Bool) async throws -> AutomationEntityQueryResult {
        let plan = try plan(prepared: prepared, entity: entity, text: text, approval: approval)
        var scoped = approval
        let digest = try AutomationFrozenCase.planDigest(plan)
        guard scoped.approvedCaseDigest == nil || scoped.approvedCaseDigest == digest else { throw AutomationContractError.conflictingOperation }
        scoped.approvedCaseDigest = digest
        let report: AutomationAttemptReport
        do {
            report = try await runner.run(subject: .prepared(prepared), plan: plan, approval: scoped,
                capabilities: capabilities(prepared), attemptID: attemptID, allowBootAndInstall: allowBootAndInstall)
        } catch {
            // Preparation can fail after acquiring device ownership. The runner retains only
            // this invocation's durably saved failure, with exact plan and run scope.
            guard let failure = try await runner.retainedAttempt(attemptID: attemptID, plan: plan, runID: scoped.runID) else { throw error }
            return .init(report: failure, choices: [], selectionGap: "The query failed during preparation; its attempt and release state were retained.")
        }
        guard report.resourcesReleased, report.result.subjectCompleted, !report.result.subjectDispatchUncertain,
              let receipt = report.receipts.first(where: { $0.segmentID == plan.execution.id }),
              receipt.completed, let output = receipt.verifiedOutputs?["records"], let query = plan.execution.hostProgram?.operations.first else {
            return .init(report: report, choices: [], selectionGap: "The query did not return released, complete typed records.")
        }
        do {
            try AutomationRecordedEvidence.validate(report: report, plan: plan, expectedRunID: approval.runID)
            try AutomationEntitySelection.validateQueryOutput(output, query: query)
            guard case .array(let values) = output else { throw AutomationInputBindingError.inputUnavailable }
            let choices = try values.map { value -> AutomationQueryEntityChoice in
                guard case .object(let fields) = value, case .entity(let typeID, let id) = fields["entity"],
                      case .object(let properties) = fields["properties"] else { throw AutomationInputBindingError.inputUnavailable }
                return .init(id: id, typeID: typeID, properties: properties, sourceAttemptID: report.attemptID,
                    app: plan.app, target: plan.target, environmentID: plan.environmentID,
                    catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog))
            }
            let context = await runner.appleRuntimeContext(report: report, plan: plan, host: prepared.host)
            let projection = try AutomationEntityProjectionEvidence.issue(report: report, plan: plan, approval: scoped, prepared: prepared, runtimeContext: context)
            return .init(report: report, choices: choices, selectionGap: nil, propertyProjection: projection)
        } catch { return .init(report: report, choices: [], selectionGap: "The returned entity records were incomplete or inconsistent.") }
    }
}
#endif
