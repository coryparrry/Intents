import Foundation

/// A selected iOS bundle, not proof that it is installed, launchable, signed or registered.
/// Physical selection additionally checks the executable platform; execution requires owned install evidence.
public struct AutomationInstalledUIApplication: Sendable {
    public let app: AppIdentity
    public let target: TargetIdentity
    public let bundleURL: URL
    public init(bundleURL: URL, target: TargetIdentity) throws {
        try self.init(bundleURL: bundleURL, target: target, afterIntake: nil)
    }
    init(bundleURL: URL, target: TargetIdentity, afterIntake: (() throws -> Void)?) throws {
        if target.kind == .physical { try AutomationPhysicalExecutable.validateTarget(target) }
        else { guard target.kind == .simulator, UUID(uuidString: target.id) != nil else { throw AutomationContractError.invalidIdentity } }
        let selected = try AutomationPath.canonical(bundleURL)
        let intake = try AutomationApplicationIntake.assess(selected)
        guard intake.candidates.count == 1, let candidate = intake.candidates.first,
              candidate.kind == .installedProduct, let app = candidate.app, app.platform == "ios",
              app.productDigest != nil else { throw AutomationContractError.missingEvidence("Select an exact iOS app bundle") }
        try afterIntake?()
        let info = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: selected,
            relativePath: "Info.plist", maximumBytes: 1_048_576, version: app.productDigestVersion,
            expectedDigest: app.productDigest), format: nil) as? [String: Any]
        let expectedPlatform = target.kind == .physical ? "iPhoneOS" : "iPhoneSimulator"
        guard info?["CFBundleSupportedPlatforms"] as? [String] == [expectedPlatform] else {
            throw AutomationContractError.missingEvidence("Selected app platform does not match the selected target")
        }
        if target.kind == .physical {
            guard app.architecture == "arm64", let executable = info?["CFBundleExecutable"] as? String else {
                throw AutomationContractError.invalidIdentity
            }
            try AutomationPhysicalExecutable.validate(AutomationProductDigest.readFile(bundle: selected,
                relativePath: executable, maximumBytes: 512 * 1024 * 1024,
                version: app.productDigestVersion, expectedDigest: app.productDigest))
        }
        self.app = app; self.target = target; self.bundleURL = selected
    }
    func verifySelectedProduct() throws {
        guard try AutomationProductDigest.compute(bundle: bundleURL, version: app.productDigestVersion) == app.productDigest else { throw AutomationContractError.conflictingOperation }
    }
    static func preparedPhysicalProduct(_ prepared: AutomationPreparedApplication) throws -> Self {
        let selected = try Self(bundleURL: URL(fileURLWithPath: prepared.host.subjectProductPath), target: prepared.host.target)
        guard selected.app.bundleID == prepared.host.app.bundleID, selected.app.productDigest == prepared.host.app.productDigest,
              (selected.app.productDigestVersion ?? 1) == (prepared.host.app.productDigestVersion ?? 1),
              prepared.host.target.kind == .physical else { throw AutomationContractError.invalidIdentity }
        return .init(app: prepared.host.app, target: prepared.host.target, bundleURL: selected.bundleURL)
    }
    /// The developer explicitly selects this separately retained build as a fix
    /// for the frozen logical app. Actual bundle path and bytes remain distinct.
    public static func comparisonCandidate(bundleURL: URL, target: TargetIdentity, baseline: AppIdentity) throws -> Self {
        let selected = try Self(bundleURL: bundleURL, target: target)
        guard baseline.productDigest != nil, selected.app.productDigest != baseline.productDigest,
              (selected.app.productDigestVersion ?? 1) == (baseline.productDigestVersion ?? 1),
              selected.app.bundleID == baseline.bundleID, selected.app.platform == baseline.platform,
              selected.app.architecture == baseline.architecture, selected.app.configuration == baseline.configuration,
              selected.app.owningModule == baseline.owningModule else { throw AutomationContractError.invalidIdentity }
        var identity = selected.app; identity.logicalID = baseline.logicalID
        return .init(app: identity, target: selected.target, bundleURL: selected.bundleURL)
    }
    private init(app: AppIdentity, target: TargetIdentity, bundleURL: URL) {
        self.app = app; self.target = target; self.bundleURL = bundleURL
    }
}

public enum AutomationApplicationSubject: Sendable {
    case prepared(AutomationPreparedApplication)
    case installedUI(AutomationInstalledUIApplication)
    case installedPhysicalUI(AutomationPhysicalInstalledUIApplication)
    case installedMacUI(AutomationInstalledMacUIApplication)
    public var app: AppIdentity {
        switch self { case .prepared(let prepared): prepared.host.app; case .installedUI(let installed): installed.app; case .installedPhysicalUI(let installed): installed.app; case .installedMacUI(let installed): installed.app }
    }
    public var target: TargetIdentity {
        switch self { case .prepared(let prepared): prepared.host.target; case .installedUI(let installed): installed.target; case .installedPhysicalUI(let installed): installed.target; case .installedMacUI(let installed): installed.target }
    }
    var productPath: String? {
        switch self { case .prepared(let prepared): prepared.host.subjectProductPath; case .installedUI(let installed): installed.bundleURL.path; case .installedPhysicalUI: nil; case .installedMacUI(let installed): installed.bundleURL.path }
    }
    var prepared: AutomationPreparedApplication? { if case .prepared(let value) = self { value } else { nil } }
    func validate(plan: AutomationCase) throws {
        guard plan.app == app, plan.target == target else { throw AutomationContractError.invalidIdentity }
        if case .installedUI(let installed) = self {
            let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
            guard segments.allSatisfy({ $0.kind == .ui && $0.uiProgram != nil && $0.hostProgram == nil }) else {
                throw AutomationContractError.invalidPlan("Installed UI-only checks cannot dispatch an Apple host or system route")
            }
            try installed.verifySelectedProduct()
        }
        if case .installedPhysicalUI = self {
            let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
            guard segments.allSatisfy({ $0.kind == .ui && $0.uiProgram != nil && $0.hostProgram == nil && $0.effects.isSubset(of: [.observe, .navigate]) }) else {
                throw AutomationContractError.invalidPlan("Unreadable physical apps support visible-state UI checks only")
            }
        }
        if case .installedMacUI(let installed) = self {
            let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
            guard segments.allSatisfy({ $0.kind == .ui && $0.uiProgram != nil && $0.hostProgram == nil }) else {
                throw AutomationContractError.invalidPlan("Installed Mac checks require typed UI programs")
            }
            let inputs = AutomationPrivateMacDaemonUnit.programInputCapabilities(receiptSHA256: plan.provenance["ui.privateMacReceiptSHA256"] ?? "") ?? .tapOnly
            for segment in segments { try AutomationMacUIProgramPreflight.validate(segment, capabilities: inputs) }
            try installed.verifySelectedProduct()
        }
    }
}
