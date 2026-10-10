#if os(macOS)
import Foundation

/// Issued by a live query owner, never decoded from saved JSON or used for intent setters/results.
public struct AutomationEntityProjectionEvidence: Sendable {
    public let entityTypeID: String
    public let properties: [String: String]
    public let recordCount: Int
    public let sourceAttemptID: String
    public let receiptDigest: String
    private let host: AutomationPreparedAppleHost
    private let environmentID: String
    private let sourceDigest: String
    private let catalogDigest: String
    private let templateDigest: String
    private let runtimeContext: AutomationLiveAppleRuntimeContext?

    private init(entityTypeID: String, properties: [String: String], recordCount: Int,
                 report: AutomationAttemptReport, receipt: AutomationSegmentReceipt,
                 prepared: AutomationPreparedApplication, environmentID: String, runtimeContext: AutomationLiveAppleRuntimeContext?) throws {
        self.entityTypeID = entityTypeID; self.properties = properties; self.recordCount = recordCount
        sourceAttemptID = report.attemptID; self.environmentID = environmentID; host = prepared.host
        sourceDigest = try prepared.source.digest; catalogDigest = try AutomationRecipeContext.catalogDigest(prepared.catalog)
        templateDigest = prepared.generatedHost.templateDigest
        self.runtimeContext = runtimeContext
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        receiptDigest = AutomationArtifactRegistry.digest(try encoder.encode(receipt))
    }

    /// Internal issuer accepts only the completed receipt returned by the owned runner.
    /// Structural synthetic tests exercise this boundary but do not establish live qualification.
    static func issue(report: AutomationAttemptReport, plan: AutomationCase, approval: RunApproval,
                      prepared: AutomationPreparedApplication, runtimeContext: AutomationLiveAppleRuntimeContext? = nil) throws -> Self? {
        guard plan.app == prepared.host.app, prepared.catalog.app == prepared.host.app,
              plan.target == prepared.host.target, plan.app == approval.app, plan.target == approval.target,
              plan.environmentID == approval.environmentID, approval.effects == [.observe],
              plan.provenance["catalog"] == (try AutomationRecipeContext.catalogDigest(prepared.catalog)),
              [prepared.host.app.productDigest, prepared.host.hostProductDigest, prepared.host.xctestrunDigest,
               prepared.generatedHost.templateDigest].allSatisfy({ value in
                  value?.count == 64 && value?.allSatisfy({ $0.isASCII && ("0123456789abcdef".contains($0)) }) == true
              }),
              approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)),
              plan.setup.isEmpty, plan.observations.isEmpty, plan.cleanup.isEmpty,
              plan.execution.kind == .systemQuery, plan.execution.phase == .subject, plan.execution.effects == [.observe],
              let program = plan.execution.hostProgram, program.operations.count == 1,
              let query = program.operations.first, query.kind == .query,
              report.resourcesReleased, report.result.subjectCompleted, !report.result.subjectDispatchUncertain,
              report.receipts.count == 1, let receipt = report.receipts.first,
              receipt.segmentID == plan.execution.id, receipt.environmentID == plan.environmentID,
              receipt.completed, receipt.dispatched, receipt.artifact?.isEmpty == false,
              let output = receipt.verifiedOutputs?[query.id] else { throw AutomationContractError.conflictingOperation }
        try PlanValidator.validate(plan, approval: approval, capabilities: AutomationEntityQuery.capabilities(prepared))
        try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog)
        try AutomationRecordedEvidence.validate(report: report, plan: plan, expectedRunID: approval.runID)
        try AutomationEntitySelection.validateQueryOutput(output, query: query)
        guard case .array(let records) = output else { throw AutomationContractError.conflictingOperation }
        // Empty results or identity-only reads never demonstrate a property getter conversion.
        guard !records.isEmpty, let properties = query.properties, !properties.isEmpty else { return nil }
        let qualifiedContext = try runtimeContext.flatMap { context in
            try context.matches(report: report, plan: plan, host: prepared.host) ? context : nil
        }
        return try .init(entityTypeID: query.typeID, properties: properties, recordCount: records.count,
            report: report, receipt: receipt, prepared: prepared, environmentID: plan.environmentID, runtimeContext: qualifiedContext)
    }

    /// Returns only named property-projection records for the exact preparation and requested subset.
    /// Caller-supplied OS/toolchain labels cannot qualify context; these records cannot satisfy apple.codec.*.
    public func capabilities(prepared: AutomationPreparedApplication, environmentID: String,
                             query: AutomationHostProgram.Operation) throws -> CapabilityProfile {
        guard prepared.host == host, prepared.catalog.app == host.app, self.environmentID == environmentID,
              try prepared.source.digest == sourceDigest,
              try AutomationRecipeContext.catalogDigest(prepared.catalog) == catalogDigest,
              prepared.generatedHost.templateDigest == templateDigest,
              query.kind == .query, query.typeID == entityTypeID,
              (query.properties ?? [:]).allSatisfy({ properties[$0.key] == $0.value }) else {
            throw AutomationContractError.conflictingOperation
        }
        try AutomationHostProgram(operations: [query]).validate(route: .systemQuery, phase: .subject)
        let qualified = runtimeContext.map { (try? $0.validate(host: host)) != nil } ?? false
        return .init(records: (query.properties ?? [:]).reduce(into: [:]) { records, item in
            records["apple.entity.propertyProjection." + entityTypeID + "." + item.key] = .init(
                state: qualified ? .available : .unknown,
                reason: qualified ? "Observed " + item.value + " projection in the verified Mac runtime" : "Observed " + item.value + " property projection; independent runtime context remains unverified",
                probeVersion: "entity-property-projection-v2",
                evidence: [sourceAttemptID, receiptDigest, host.hostProductDigest, host.xctestrunDigest, catalogDigest, sourceDigest, templateDigest] + (qualified ? runtimeContext?.evidence ?? [] : []))
        })
    }
}
#endif
