import Foundation
import MacIntentTesting
import Observation

/// One actionable prerequisite, kept separate from scenario validation and Siri's eventual verdict.
struct SiriStudioSetupStep: Identifiable {
    /// Identifies the user action that can satisfy a missing prerequisite.
    enum Action { case none, softwareUpdate, xcode, signing, xcodegen, registerApp, quitApp, siri }
    let id: String
    let title: String
    let detail: String
    let complete: Bool
    let action: Action
}

/// Owns automatic discovery and human-confirmed Siri readiness without overwriting concurrent edits.
@MainActor @Observable final class SiriStudioSetupStore {
    private(set) var report: SiriStudioSetupReport?
    private(set) var isChecking = false
    private(set) var diagnostic: String?
    var siriConfirmed = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let probe: (URL, SiriStudioSetupConfiguration) async throws -> SiriStudioSetupReport

    /// Keeps a discovery owner alive across rechecks, or accepts an isolated deterministic probe for tests.
    init(probe: ((URL, SiriStudioSetupConfiguration) async throws -> SiriStudioSetupReport)? = nil) {
        let discovery = SiriStudioSetupDiscovery()
        self.probe = probe ?? { app, preferred in try await discovery.detect(appURL: app, preferred: preferred) }
    }

    /// Replaces a previous check only after it finishes cancellation, publishing only the latest app's report.
    func refresh(appURL: URL, configuration: SiriStudioSetupConfiguration,
                 apply: @escaping @MainActor (SiriStudioSetupConfiguration) -> Void) {
        let previous = task
        previous?.cancel()
        let token = UUID()
        generation = token
        report = nil; diagnostic = nil; isChecking = true
        task = Task {
            await previous?.value
            defer { if generation == token { isChecking = false; task = nil } }
            do {
                try Task.checkCancellation()
                let found = try await probe(appURL, configuration)
                try Task.checkCancellation()
                guard generation == token else { return }
                report = found
                apply(found.configuration)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                diagnostic = error.localizedDescription
            }
        }
    }

    /// Invalidates the old app immediately while retaining cancellation ownership until the next check or close joins it.
    func clear() {
        generation = UUID()
        task?.cancel()
        report = nil; diagnostic = nil; isChecking = false
    }

    /// Joins discovery before allowing the owning workspace to finish closing.
    func closeAndWait() async {
        clear()
        await task?.value
        task = nil
    }

    /// Waits for the current discovery without cancelling it, for deterministic integration checks.
    func waitForCheck() async { await task?.value }

    /// Explains missing or stale prerequisites; authoring and exports remain usable while execution is blocked.
    func issue(configuration: SiriStudioSetupConfiguration) -> String? {
        if isChecking { return "Checking this Mac and the selected app…" }
        if let diagnostic { return diagnostic }
        guard let report else { return "Check setup to detect Xcode and signing automatically." }
        guard configuration == report.configuration else { return "Settings changed. Recheck setup to validate them." }
        return steps.first(where: { !$0.complete }).map { "\($0.title): \($0.detail)" }
    }

    /// Builds the checklist from observed facts; it never infers Siri AI enablement from an OS version or installed app.
    var steps: [SiriStudioSetupStep] {
        guard let report else { return [] }
        let xcode = report.xcodes.first { $0.developerDirectory == report.configuration.developerDirectory }
        let identity = report.identities.first { $0.fingerprint == report.configuration.signingIdentity && $0.team == report.applicationTeam }
        return [
            .init(id: "macos", title: "Compatible Mac", detail: report.osSupported ? "macOS \(report.osVersion)" : "Update to macOS 27.3 or later.", complete: report.osSupported, action: .softwareUpdate),
            .init(id: "xcode", title: "Xcode", detail: xcode.map { report.xcodeReady ? "Xcode \($0.version), detected automatically" : "Open Xcode \($0.version) once and finish its component and license setup." } ?? "Install Xcode 27.3 or later, then recheck.", complete: xcode != nil && report.xcodeReady, action: .xcode),
            .init(id: "signing", title: "Development signing", detail: identity.map { "Development certificate matched to team \($0.team)" } ?? (report.applicationTeam.map { "Add an Apple Development certificate for team \($0) in Xcode → Settings → Accounts." } ?? "Choose a development-signed build of your app."), complete: identity != nil, action: .signing),
            .init(id: "xcodegen", title: "Test project tools", detail: report.xcodegen == nil ? "Install XcodeGen: brew install xcodegen" : "XcodeGen is installed", complete: report.xcodegen != nil, action: .xcodegen),
            .init(id: "registered", title: "App registered", detail: report.registered ? "The selected build is registered with macOS" : "Install this build in Applications, open it once, then quit it and recheck.", complete: report.registered, action: .registerApp),
            .init(id: "stopped", title: "App closed", detail: report.running ? "Quit the selected app, then recheck." : "The selected app is closed", complete: !report.running, action: .quitApp),
            .init(id: "siri", title: "Siri AI", detail: siriConfirmed ? "Confirmed by you; leave this Mac unlocked during the run" : "Enable Siri AI and finish its model downloads in Settings, then confirm below.", complete: siriConfirmed, action: .siri),
        ]
    }
}
