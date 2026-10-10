import Foundation

/// Exact selected Mac product bytes. This selection does not qualify a GUI route.
public struct AutomationInstalledMacUIApplication: Sendable {
    public let app: AppIdentity
    public let target: TargetIdentity
    public let bundleURL: URL
    public init(bundleURL: URL, target: TargetIdentity) throws {
        guard target.kind == .nativeMac, target.id == "host-macos-local",
              let login = target.loginSession, !login.isEmpty, login.utf8.count <= 256,
              !login.contains("\n"), !login.contains("\0") else { throw AutomationContractError.invalidIdentity }
        let selected = try AutomationPath.canonical(bundleURL)
        let intake = try AutomationApplicationIntake.assess(selected)
        guard intake.candidates.count == 1, let candidate = intake.candidates.first,
              candidate.kind == .installedProduct, let app = candidate.app, app.platform == "macos",
              app.productDigestVersion == 2, app.productDigest != nil, app.canonicalBundlePath == selected.path else {
            throw AutomationContractError.missingEvidence("Select an exact Mac app bundle")
        }
        let info = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: selected,
            relativePath: "Contents/Info.plist", maximumBytes: 1_048_576, version: 2, expectedDigest: app.productDigest), format: nil) as? [String: Any]
        guard info?["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"] else {
            throw AutomationContractError.invalidPlan("Selected product does not declare the Mac platform")
        }
        self.app = app; self.target = target; self.bundleURL = selected
    }
    func verifySelectedProduct() throws {
        guard try AutomationProductDigest.compute(bundle: bundleURL, version: 2) == app.productDigest else {
            throw AutomationContractError.conflictingOperation
        }
    }
    /// Explicitly selects a separately retained fix build while preserving its actual path and bytes.
    public static func comparisonCandidate(bundleURL: URL, target: TargetIdentity, baseline: AppIdentity) throws -> Self {
        let selected = try Self(bundleURL: bundleURL, target: target)
        guard baseline.platform == "macos", baseline.productDigestVersion == 2, baseline.productDigest != nil,
              selected.app.productDigest != baseline.productDigest, selected.app.bundleID == baseline.bundleID,
              selected.app.architecture == baseline.architecture, selected.app.configuration == baseline.configuration,
              selected.app.owningModule == baseline.owningModule else { throw AutomationContractError.invalidIdentity }
        var identity = selected.app; identity.logicalID = baseline.logicalID
        return .init(app: identity, target: selected.target, bundleURL: selected.bundleURL)
    }
    private init(app: AppIdentity, target: TargetIdentity, bundleURL: URL) {
        self.app = app; self.target = target; self.bundleURL = bundleURL
    }
}

enum AutomationMacUIProgramPreflight {
    static func validateReadOnly(_ segment: AutomationSegment, capabilities: AutomationMacInputCapabilities, allowNavigationGoals: Bool = false) throws {
        guard segment.effects.isSubset(of: [.observe, .navigate]), segment.inputBindings?.isEmpty != false,
              segment.attemptTextBindings?.isEmpty != false, segment.uiProgram?.bindings.isEmpty == true else {
            throw AutomationContractError.invalidPlan("Saved Mac read-only review cannot approve input bindings")
        }
        try validate(segment, capabilities: capabilities)
        guard segment.uiProgram?.operations.allSatisfy({ operation in
            if operation.kind == .navigateGoal {
                return allowNavigationGoals && operation.goal?.allowedFillBindings?.isEmpty != false &&
                    operation.goal?.minimumBindingUses?.isEmpty != false && operation.goal?.selectionBindings?.isEmpty != false && operation.goal?.saveControl == nil
            }
            return [.tap, .scroll, .readProperty, .observeProperty, .assertEndpoint, .locate].contains(operation.kind)
        }) == true else { throw AutomationContractError.missingEvidence("Saved Mac read-only review requires navigation and visible checks without text entry") }
    }
    static func validateDeferred(_ segment: AutomationSegment, capabilities: AutomationMacInputCapabilities, attemptID: String) throws {
        var validation = segment
        for (name, prefix) in segment.attemptTextBindings ?? [:] {
            validation.uiProgram?.bindings[name] = try AutomationAttemptText.value(prefix: prefix, attemptID: attemptID)
        }
        // Producer outputs remain deferred until the coordinator verifies their receipts.
        for binding in segment.inputBindings ?? [] where binding.destination == .uiBinding {
            validation.uiProgram?.bindings[binding.name] = "preflight-placeholder"
        }
        try validate(validation, capabilities: capabilities)
    }
    static func validate(_ segment: AutomationSegment, capabilities: AutomationMacInputCapabilities = .tapOnly) throws {
        guard segment.kind == .ui, segment.hostProgram == nil, let program = segment.uiProgram,
              segment.lifecycle == .persistedStateAcrossSegments else {
            throw AutomationContractError.invalidPlan("Mac UI requires a frozen persisted-state program")
        }
        try program.validate(phase: segment.phase)
        try capabilities.validate(program)
    }
}
