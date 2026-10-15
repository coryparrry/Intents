import Foundation

extension AutomationUIFailureSearchRecord {
    /// Read-only compatibility for the original schema-3 request records. This
    /// checks the old frozen proposal and canonical facts, never the current live
    /// fixture contract. No plan, digest, report, evidence byte or token is upgraded.
    func validateLegacyUIRequestQualification() throws {
        guard schemaVersion == 3, let qualification = report.qualificationAttempts, qualification.count <= 2,
              !mutations.isEmpty, mutations.allSatisfy({ $0.subjectPhraseSlot == .uiRequestBinding("approvedText") }),
              reductions?.isEmpty != false else { throw AutomationContractError.conflictingOperation }
        try validateLegacyUIRequestPlan(baseline.plan)
        var identities = Set<String>()
        for (index, attempt) in qualification.enumerated() {
            guard attempt.caseDigest == baseline.digest else { throw AutomationContractError.conflictingOperation }
            try AutomationRecordedEvidence.validate(report: attempt.report, plan: baseline.plan, expectedRunID: runID)
            if attempt.report.result.subjectDispatched {
                guard identities.insert(try legacyUIRequestIdentity(report: attempt.report, plan: baseline.plan)).inserted else { throw AutomationContractError.conflictingOperation }
            }
            if !attempt.report.resourcesReleased || !attempt.report.result.subjectCompleted || attempt.report.result.subjectDispatchUncertain {
                guard index == qualification.count - 1, report.attempts.isEmpty else { throw AutomationContractError.conflictingOperation }
            }
        }
        if !report.attempts.isEmpty { guard qualification.count == 2 else { throw AutomationContractError.conflictingOperation } }
        for attempt in report.attempts where attempt.report.result.subjectDispatched {
            guard let frozen = ([baseline] + mutations.map(\.frozen)).first(where: { $0.digest == attempt.caseDigest }),
                  identities.insert(try legacyUIRequestIdentity(report: attempt.report, plan: frozen.plan)).inserted else { throw AutomationContractError.conflictingOperation }
        }
    }

    func validateLegacyUIRequestMutation(_ mutation: AutomationMutationCase) throws {
        try mutation.frozen.validate(); try validateLegacyUIRequestPlan(mutation.frozen.plan)
        guard mutation.subjectPhraseSlot == .uiRequestBinding("approvedText"), mutation.goalPhraseVariation != true,
              mutation.recipeIDs.isEmpty, mutation.kinds == [.alternatePhrasing], mutation.requiredCapabilities.isEmpty,
              !mutation.semanticJustification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              mutation.semanticJustification.utf16.count <= 4096,
              let request = mutation.frozen.plan.execution.uiProgram?.bindings["approvedText"], request.utf16.count <= 2048,
              !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !request.contains("\0"),
              let original = baseline.plan.execution.uiProgram?.bindings["approvedText"], request != original else { throw AutomationContractError.conflictingOperation }
        var normalized = mutation.frozen.plan
        normalized.id = baseline.plan.id; normalized.revision = baseline.plan.revision
        normalized.execution.uiProgram!.bindings["approvedText"] = original
        guard normalized == baseline.plan else { throw AutomationContractError.conflictingOperation }
    }

    private func validateLegacyUIRequestPlan(_ plan: AutomationCase) throws {
        guard let fixture = plan.uiRequestFixture, [.simulator, .nativeMac].contains(plan.target.kind),
              !fixture.expectedEmptyState.isEmpty, fixture.expectedEmptyState.utf16.count <= 1024,
              plan.setup.count == 1, plan.setupChecks?.isEmpty != false, plan.cleanup.isEmpty,
              plan.setup[0].id == AutomationUIRequestFixture.segmentID, plan.setup[0].kind == .ui, plan.setup[0].phase == .setup,
              plan.setup[0].effects == [.observe, .navigate, .fixtureWrite, .reset],
              plan.execution.kind == .ui, plan.execution.effects == [.observe, .navigate, .fixtureWrite],
              let ui = plan.execution.uiProgram, ui.operations.count == 1, ui.bindings.count == 1,
              ui.bindings["approvedText"]?.isEmpty == false, let goal = ui.operations[0].goal,
              goal.minimumBindingUses == ["approvedText": 1], goal.allowedFillBindings == ["approvedText"], goal.saveControl == fixture.submitControl,
              goal.requestInputControl == fixture.requestInputControl,
              plan.execution.inputBindings?.isEmpty != false, plan.execution.attemptTextBindings?.isEmpty != false,
              !plan.requirements.isEmpty else { throw AutomationContractError.conflictingOperation }
        var operations: [AutomationUIProgram.Operation] = [.init(id: "new-session", kind: .tap, locator: fixture.resetControl),
            .init(id: AutomationUIRequestFixture.identityID, kind: .observeProperty, locator: fixture.sessionIdentity, property: "value"),
            .init(id: AutomationUIRequestFixture.emptyID, kind: .observeProperty, locator: fixture.emptyState, property: "text")]
        if let input = fixture.requestInputControl { operations.append(.init(id: AutomationUIRequestFixture.inputID, kind: .observeProperty, locator: input, property: "value")) }
        let expected = AutomationUIProgram(operations: operations)
        guard plan.setup[0].uiProgram == expected else { throw AutomationContractError.conflictingOperation }
        guard fixture.resetControl != fixture.submitControl, fixture.resetControl != fixture.sessionIdentity,
              fixture.resetControl != fixture.emptyState, fixture.sessionIdentity != fixture.emptyState,
              fixture.submitControl != fixture.sessionIdentity, fixture.submitControl != fixture.emptyState else { throw AutomationContractError.conflictingOperation }
        if let input = fixture.requestInputControl {
            guard ![fixture.resetControl, fixture.sessionIdentity, fixture.emptyState, fixture.submitControl].contains(input) else { throw AutomationContractError.conflictingOperation }
        }
        let runtimeKey = plan.target.kind == .nativeMac ? "ui.privateMacReceiptSHA256" : "ui.runtimeManifestDigest"
        guard plan.provenance[runtimeKey]?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AutomationContractError.conflictingOperation }
        try expected.validate(phase: .setup); try ui.validate(phase: .subject)
    }

    private func legacyUIRequestIdentity(report: AutomationAttemptReport, plan: AutomationCase) throws -> String {
        guard let fixture = plan.uiRequestFixture else { throw AutomationContractError.conflictingOperation }
        let candidates = report.receipts.filter { $0.segmentID == AutomationUIRequestFixture.segmentID }
        guard candidates.count == 1, let receipt = candidates.first,
              receipt.app == plan.app, receipt.target == plan.target, receipt.environmentID == plan.environmentID,
              receipt.scope.runId == runID, receipt.scope.attemptId == report.attemptID, receipt.scope.segmentId == receipt.segmentID,
              receipt.route == .ui, receipt.dispatched, receipt.completed, receipt.artifact != nil,
              case .text(let identity) = receipt.verifiedOutputs?[AutomationUIRequestFixture.identityID],
              !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identity.utf16.count <= 1024,
              receipt.verifiedOutputs?[AutomationUIRequestFixture.emptyID] == .text(fixture.expectedEmptyState) else { throw AutomationContractError.conflictingOperation }
        if fixture.requestInputControl != nil {
            guard receipt.verifiedOutputs?[AutomationUIRequestFixture.inputID] == .text("") else { throw AutomationContractError.conflictingOperation }
        }
        return identity
    }
}
