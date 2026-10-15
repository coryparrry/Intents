import Foundation

/// Frozen proposal only. A new session must expose both an empty-state value and
/// a distinct current session identity through independently verified UI readbacks.
public struct AutomationUIRequestFixture: Codable, Equatable, Sendable {
    public var resetControl: AutomationUIProgram.Locator
    public var sessionIdentity: AutomationUIProgram.Locator
    public var emptyState: AutomationUIProgram.Locator
    public var expectedEmptyState: String
    public var submitControl: AutomationUIProgram.Locator
    public var requestInputControl: AutomationUIProgram.Locator?
    public init(resetControl: AutomationUIProgram.Locator, sessionIdentity: AutomationUIProgram.Locator,
                emptyState: AutomationUIProgram.Locator, expectedEmptyState: String, submitControl: AutomationUIProgram.Locator, requestInputControl: AutomationUIProgram.Locator? = nil) {
        self.resetControl = resetControl; self.sessionIdentity = sessionIdentity; self.emptyState = emptyState
        self.expectedEmptyState = expectedEmptyState; self.submitControl = submitControl; self.requestInputControl = requestInputControl
    }
    static let segmentID = "request-session-reset"
    static let identityID = "session-identity", emptyID = "empty-session", inputID = "empty-request-input"
    var program: AutomationUIProgram {
        .init(operations: [.init(id: "new-session", kind: .tap, locator: resetControl),
            .init(id: Self.identityID, kind: .observeProperty, locator: sessionIdentity, property: "value"),
            .init(id: Self.emptyID, kind: .observeProperty, locator: emptyState, property: "text"),
            .init(id: Self.inputID, kind: .observeProperty, locator: requestInputControl, property: "value")])
    }
    public func applying(to original: AutomationCase, approval: RunApproval) throws -> AutomationCase {
        guard original.setup.isEmpty, original.setupChecks?.isEmpty != false, original.cleanup.isEmpty,
              original.execution.kind == .ui, original.execution.effects == [.observe, .navigate, .fixtureWrite],
              approval.disposable, approval.effects.contains(.fixtureWrite), !approval.effects.contains(.externalWrite),
              !original.requirements.isEmpty, var ui = original.execution.uiProgram, ui.operations.count == 1,
              var goal = ui.operations[0].goal, ui.bindings["approvedText"]?.isEmpty == false else {
            throw AutomationContractError.missingEvidence("AI request search requires approved disposable local fixture writes and a fresh UI session recipe")
        }
        var plan = original
        var reset = AutomationSegment(id: Self.segmentID, kind: .ui, phase: .setup, operation: "Create and independently verify a fresh empty local AI session",
            effects: [.observe, .navigate, .fixtureWrite, .reset], lifecycle: .persistedStateAcrossSegments)
        reset.uiProgram = program; plan.setup = [reset]; plan.uiRequestFixture = self
        goal.minimumBindingUses = ["approvedText": 1]; goal.allowedFillBindings = ["approvedText"]
        goal.requestInputControl = requestInputControl; goal.saveControl = submitControl; ui.operations[0].goal = goal; plan.execution.uiProgram = ui
        try validate(plan: plan)
        return plan
    }
    func validate(plan: AutomationCase) throws {
        guard let requestInputControl, [.simulator, .nativeMac].contains(plan.target.kind), !expectedEmptyState.isEmpty, expectedEmptyState.utf16.count <= 1024,
              plan.setup.count == 1, plan.setupChecks?.isEmpty != false, plan.cleanup.isEmpty,
              plan.setup[0].id == Self.segmentID, plan.setup[0].kind == .ui, plan.setup[0].phase == .setup,
              plan.setup[0].uiProgram == program, plan.setup[0].effects == [.observe, .navigate, .fixtureWrite, .reset],
              plan.execution.effects == [.observe, .navigate, .fixtureWrite], plan.execution.kind == .ui,
              let ui = plan.execution.uiProgram, ui.operations.count == 1, ui.bindings.count == 1,
              ui.bindings["approvedText"]?.isEmpty == false, (ui.bindings["approvedText"]?.utf16.count ?? 1025) <= 1024, let goal = ui.operations[0].goal,
              goal.minimumBindingUses == ["approvedText": 1], goal.allowedFillBindings == ["approvedText"], goal.saveControl == submitControl, goal.requestInputControl == requestInputControl,
              plan.execution.inputBindings?.isEmpty != false, plan.execution.attemptTextBindings?.isEmpty != false,
              !plan.requirements.isEmpty else { throw AutomationContractError.invalidPlan("UI session fixture or required request submission changed") }
        let runtimeKey = "ui.runtimeManifestDigest"
        guard plan.provenance[runtimeKey]?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.missingEvidence("UI session isolation requires the exact verified runtime fingerprint")
        }
        try program.validate(phase: .setup); try ui.validate(phase: .subject)
        guard resetControl != submitControl, resetControl != sessionIdentity, resetControl != emptyState,
              sessionIdentity != emptyState, submitControl != sessionIdentity, submitControl != emptyState,
              ![resetControl, sessionIdentity, emptyState, submitControl].contains(requestInputControl) else {
            throw AutomationContractError.invalidPlan("Reset, session identity, empty state and submit controls must be distinct")
        }
    }
    static func contract(_ plan: AutomationCase) throws -> String {
        guard let fixture = plan.uiRequestFixture else { throw AutomationContractError.invalidPlan("Missing UI session fixture") }
        try fixture.validate(plan: plan)
        var normalized = plan; normalized.id = "qualified-ui-session"; normalized.revision = 1
        normalized.execution.uiProgram!.bindings["approvedText"] = "approved-request-slot"
        return try AutomationFrozenCase.planDigest(normalized)
    }
    func identity(receipts: [AutomationSegmentReceipt], plan: AutomationCase, runID: String, attemptID: String) throws -> String {
        let candidates = receipts.filter { $0.segmentID == Self.segmentID }
        guard candidates.count == 1, let receipt = candidates.first, receipt.app == plan.app, receipt.target == plan.target,
              receipt.environmentID == plan.environmentID, receipt.scope.runId == runID, receipt.scope.attemptId == attemptID,
              receipt.scope.segmentId == Self.segmentID, receipt.route == .ui, receipt.dispatched, receipt.completed,
              receipt.artifact != nil, case .text(let identity) = receipt.verifiedOutputs?[Self.identityID],
              !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identity.utf16.count <= 1024,
              receipt.verifiedOutputs?[Self.emptyID] == .text(expectedEmptyState), receipt.verifiedOutputs?[Self.inputID] == .text("") else {
            throw AutomationContractError.missingEvidence("Fresh empty session identity was not independently observed before the subject")
        }
        return identity
    }
}

/// Minted only by the owned runner after two released live reset/submission attempts.
/// Decoding an archive never creates this authority.
public struct AutomationQualifiedUIRequestFixture: Sendable {
    let contractDigest: String
    let runID: String
    private let deadline: ContinuousClock.Instant
    let tracker: AutomationUIRequestFixtureTracker
    public let qualificationAttemptIDs: [String]
    init(plan: AutomationCase, approval: RunApproval, tracker: AutomationUIRequestFixtureTracker, attempts: [AutomationAttemptReport]) throws {
        guard attempts.count == 2, Set(attempts.map(\.attemptID)).count == 2,
              attempts.allSatisfy({ $0.resourcesReleased && $0.result.subjectCompleted && !$0.result.subjectDispatchUncertain }) else {
            throw AutomationContractError.missingEvidence("UI request fixture requires two released live qualification attempts")
        }
        contractDigest = try AutomationUIRequestFixture.contract(plan); runID = approval.runID; self.tracker = tracker
        deadline = ContinuousClock.now.advanced(by: .seconds(3600))
        qualificationAttemptIDs = attempts.map(\.attemptID)
    }
    func validate(plan: AutomationCase, approval: RunApproval) throws {
        guard ContinuousClock.now < deadline, approval.runID == runID, approval.disposable, !approval.effects.contains(.externalWrite), approval.effects.isSuperset(of: [.fixtureWrite, .reset]),
              approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)), contractDigest == (try AutomationUIRequestFixture.contract(plan)) else {
            throw AutomationContractError.missingEvidence("UI session qualification no longer matches the frozen app, route, request slot or reset contract")
        }
    }
}

public actor AutomationUIRequestFixtureTracker {
    private let contractDigest: String
    private let runID: String
    private var identities = Set<String>(), attempts = Set<String>()
    init(plan: AutomationCase, approval: RunApproval) throws {
        contractDigest = try AutomationUIRequestFixture.contract(plan); runID = approval.runID
        guard approval.disposable, approval.effects.isSuperset(of: [.fixtureWrite, .reset]), !approval.effects.contains(.externalWrite) else {
            throw AutomationContractError.invalidPlan("A session reset requires disposable local write approval")
        }
    }
    func reserveBeforeSubject(receipts: [AutomationSegmentReceipt], plan: AutomationCase, approval: RunApproval, attemptID: String) throws {
        guard approval.runID == runID, approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)),
              contractDigest == (try AutomationUIRequestFixture.contract(plan)), let fixture = plan.uiRequestFixture else { throw AutomationContractError.conflictingOperation }
        let identity = try fixture.identity(receipts: receipts, plan: plan, runID: runID, attemptID: attemptID)
        guard !identities.contains(identity), !attempts.contains(attemptID) else { throw AutomationContractError.missingEvidence("UI session reset reused a prior session identity") }
        identities.insert(identity); attempts.insert(attemptID)
    }
    func validate(report: AutomationAttemptReport, plan: AutomationCase, approval: RunApproval) throws {
        if report.result.subjectDispatched {
            guard attempts.contains(report.attemptID), let fixture = plan.uiRequestFixture,
                  identities.contains(try fixture.identity(receipts: report.receipts, plan: plan, runID: approval.runID, attemptID: report.attemptID)) else {
                throw AutomationContractError.missingEvidence("Subject lacks its independently verified fresh UI session")
            }
        }
    }
}

public protocol AutomationUIRequestFixtureAttemptExecutor: AutomationCampaignAttemptExecutor {
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                 budget: AutomationCampaignBudget, uiRequestFixtureTracker: AutomationUIRequestFixtureTracker) async throws -> AutomationAttemptReport
}
