#if os(macOS)
import Foundation
import IntentsAutomationCore

enum AutomationNativePreparedEvidence {
    static func attachPreparedEvidence(to plan: inout AutomationCase, prepared: AutomationPreparedApplication) throws {
        if prepared.host.target.kind == .nativeMac {
            plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        } else {
            plan.preparedSimulatorBuildArtifacts = try .init(prepared: prepared)
            for key in ["ui.preparedHostDigest", "ui.preparedXctestrunDigest", "ui.preparedCatalogDigest", "ui.hostTemplateDigest"] {
                plan.provenance.removeValue(forKey: key)
            }
        }
    }
    static func preparedEvidenceMatches(plan: AutomationCase, prepared: AutomationPreparedApplication) -> Bool {
        guard plan.app == prepared.host.app, plan.target == prepared.host.target,
              prepared.catalog.app == plan.app, prepared.host.subjectProductPath == plan.app.canonicalBundlePath,
              prepared.generatedHost.configuration == plan.app.configuration else { return false }
        if prepared.host.target.kind == .simulator, plan.app.sourceManifestDigest != (try? prepared.source.digest) { return false }
        if let artifacts = plan.preparedMacBuildArtifacts { return artifacts == (try? .init(prepared: prepared)) }
        if let artifacts = plan.preparedSimulatorBuildArtifacts { return artifacts == (try? .init(prepared: prepared)) }
        return (try? preparedProvenance(prepared))?.allSatisfy { plan.provenance[$0.key] == $0.value } == true
    }
    static func preparedProvenance(_ prepared: AutomationPreparedApplication) throws -> [String: String] {
        ["ui.preparedHostDigest": prepared.host.hostProductDigest,
         "ui.preparedXctestrunDigest": prepared.host.xctestrunDigest,
         "ui.preparedCatalogDigest": try AutomationRecipeContext.catalogDigest(prepared.catalog),
         "ui.hostTemplateDigest": prepared.generatedHost.templateDigest]
    }
}
#endif

#if os(macOS)
/// Concrete controls supplied by the developer; no UI discovery is needed.
enum AutomationNativeWorkflowSteps {
    static func locator(_ value: String) throws -> AutomationUIProgram.Locator {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: AutomationUIProgram.Locator.Kind
        let name: String
        if text.hasPrefix("id:") { kind = .testId; name = String(text.dropFirst(3)) }
        else if text.hasPrefix("label:") { kind = .label; name = String(text.dropFirst(6)) }
        else { kind = .label; name = text }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 1024 else {
            throw AutomationContractError.invalidPlan("Supply a control label or id:accessibilityIdentifier")
        }
        return .init(kind, name)
    }
    static func optionalLocator(_ value: String) throws -> AutomationUIProgram.Locator? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try locator(value)
    }
    /// Count the actual lowered host steps, including launch, freshness and screenshot steps.
    static func applyBudget(to plan: inout AutomationCase, approval: RunApproval) throws {
        plan.budget.controllerCalls = 1
        plan.budget.uiActions = approval.maximumActions
        plan.budget.subjectOperations = approval.maximumActions
        var reviewed = approval
        reviewed.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let host = try AutomationXCUITestPlan.assemble(plan: plan, approval: reviewed,
            attemptID: "native-budget-preview", leaseGeneration: 1)
        plan.budget.uiActions = host.steps.filter { [.launch, .tap, .typeText, .clearAndType, .swipe].contains($0.kind) }.count
        plan.budget.subjectOperations = host.steps.filter { $0.segmentID == plan.execution.id }.count
    }
    static func program(tapControls: String, textEntry: String, approvedText: String, submitControl: String, endpoint: String) throws -> AutomationUIProgram {
        var operations: [AutomationUIProgram.Operation] = []
        for (index, control) in tapControls.split(whereSeparator: \.isNewline).enumerated() {
            operations.append(.init(id: "tap.\(index)", kind: .tap, locator: try locator(String(control))))
        }
        if !approvedText.isEmpty {
            operations.append(.init(id: "fill", kind: .fillBinding, locator: try locator(textEntry), binding: "approvedText"))
        }
        if let control = try optionalLocator(submitControl) { operations.append(.init(id: "submit", kind: .tap, locator: control)) }
        operations.append(.init(id: "destination", kind: .assertEndpoint, locator: try locator(endpoint)))
        let program = AutomationUIProgram(operations: operations, bindings: approvedText.isEmpty ? [:] : ["approvedText": approvedText])
        try program.validate(phase: .subject)
        return program
    }
}
#endif
