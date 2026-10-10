import Foundation

/// A controlled existing-record calibration. It never creates or resets data,
/// guesses an entity ID, or changes the approved recognised-text request.
public enum AutomationSiriEntityPlanner {
    public static func compile(catalog: ApplicationSurfaceCatalog, entityType: String, nameProperty: String,
                               recordName: String, stateProperty: String, initialState: Bool, expectedState: Bool,
                               request: String, approval: RunApproval, capabilities: CapabilityProfile) throws -> AutomationCase {
        guard catalog.app == approval.app, approval.target.kind == .physical, approval.disposable,
              let entity = catalog.entities?.first(where: { $0.typeID == entityType }),
              entity.properties[nameProperty] == "text", entity.properties[stateProperty] == "bool",
              !recordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              recordName.utf16.count <= 1024, !recordName.contains("\0"), initialState != expectedState else {
            throw AutomationContractError.invalidPlan("Choose a readable named record and different approved before and after states")
        }
        let selection = AutomationEntitySelection(typeID: entityType, matchingProperties: [nameProperty: .text(recordName)])
        let predicate = AutomationEntityPropertyPredicate(operationID: "record", selection: selection, property: stateProperty)
        var baseline = AutomationSegment(id: "siri.fixture", kind: .systemQuery, phase: .setup,
            operation: entity.queryIdentifier, requiredCapabilities: ["apple.entity.query"], lifecycle: .persistedStateAcrossSegments)
        baseline.hostProgram = .init(operations: [.init(id: "record", kind: .query, typeID: entityType,
            queryText: recordName, properties: entity.properties)])
        var observer = baseline; observer.id = "siri.state"; observer.phase = .observe
        observer.hostProgram = .init(operations: [.init(id: "record", kind: .query, typeID: entityType, properties: entity.properties)])
        observer.inputBindings = [.init(producerSegmentID: baseline.id, outputID: "record", destination: .hostQueryIDs,
            operationID: "record", name: "queryIDs", uniqueEntity: selection)]
        var subject = AutomationSegment(id: "siri", kind: .siriText, phase: .subject, operation: "submitRecognizedText",
            requiredCapabilities: ["siri.recognizedText.api"], effects: [.observe, .navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        subject.siriProgram = .init(request: request)
        var plan = AutomationCase(id: "siri-record-state", app: catalog.app, target: approval.target,
            environmentID: approval.environmentID, execution: subject, setup: [baseline], observations: [observer],
            requirements: [.init(observationID: observer.id, expected: .bool(expectedState), proof: .appState,
                justification: "Developer-approved state of the independently identified record after actual Siri submission",
                checkID: "siri.outcome", entityProperty: predicate)],
            setupChecks: [.init(observationID: baseline.id, expected: .bool(initialState), proof: .appState,
                justification: "Developer-approved controlled record state before Siri submission",
                checkID: "siri.baseline", entityProperty: predicate)])
        plan.provenance = ["catalog": try AutomationRecipeContext.catalogDigest(catalog),
            "siri.evidenceScope": "controlledExistingRecordState", "physical.installedBytesVerified": "false"]
        plan.id = "siri-state-" + (try AutomationFrozenCase.planDigest(plan))
        var reviewApproval = approval; reviewApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: reviewApproval, capabilities: capabilities, purpose: .review)
        return plan
    }
}
