import Foundation
import MacIntentTesting
import Testing
@testable import FoundationEvals

/// Checks automatic setup, concurrent edits, cancellation, and truthful checklist readiness.
@MainActor struct SiriStudioSetupStoreTests {
    /// Supplies synthetic inspection facts while preserving the shape of a real matching signing configuration.
    private func report(registered: Bool = true, running: Bool = false, xcodeReady: Bool = true) -> SiriStudioSetupReport {
        let config = SiriStudioSetupConfiguration(developerDirectory: "/Detected/Xcode.app/Contents/Developer", teamIdentifier: "TEAM-A", signingIdentity: "CERT-A")
        return .init(osSupported: true, osVersion: "27.3", xcodes: [.init(developerDirectory: config.developerDirectory, version: "27.3")], xcodeReady: xcodeReady,
            identities: [.init(fingerprint: "CERT-A", name: "Development", team: "TEAM-A")], applicationTeam: "TEAM-A",
            registered: registered, running: running, xcodegen: "/tools/xcodegen", configuration: config)
    }

    /// Loads an app without touching disk or starting Siri, then performs the same automatic setup entry point as the view.
    private func store(probe: @escaping (URL, SiriStudioSetupConfiguration) async throws -> SiriStudioSetupReport) async -> MacIntentTestingStore {
        let model = MacIntentTestingStore(setupProbe: probe, catalogLoader: { app in
            .init(bundleIdentifier: "example.Setup", appURL: app, actions: [.init(id: "Open", title: "Open", parameters: [], outputType: "Void")])
        })
        model.load(appURL: URL(filePath: "/Subject.app"))
        await model.waitForLoad()
        return model
    }

    /// Applies all detected fields automatically but never claims Siri AI is enabled without user confirmation.
    @Test func automaticSetupRequiresExplicitSiriConfirmation() async {
        let found = report()
        let model = await store { _, _ in found }
        model.detectSiriSetup()
        await model.siriSetup.waitForCheck()
        #expect(model.setupConfiguration == found.configuration)
        #expect(model.siriSetup.steps.filter(\.complete).count == 6)
        #expect(model.siriSetup.issue(configuration: model.setupConfiguration)?.hasPrefix("Siri AI:") == true)
        model.siriSetup.siriConfirmed = true
        #expect(model.siriSetup.issue(configuration: model.setupConfiguration) == nil)
        model.developerDirectory = "/Manual/Xcode.app/Contents/Developer"
        #expect(model.siriSetup.issue(configuration: model.setupConfiguration)?.contains("Settings changed") == true)
        await model.closeAndWait()
    }

    /// Preserves user edits that arrive while automatic discovery is still inspecting the selected app.
    @Test func discoveryDoesNotOverwriteConcurrentManualEdits() async {
        let gate = SetupGate()
        let found = report()
        let model = await store { _, _ in await gate.wait(); return found }
        model.detectSiriSetup()
        await Task.yield()
        model.signingIdentity = "manual-identity"
        gate.resume()
        await model.siriSetup.waitForCheck()
        #expect(model.signingIdentity == "manual-identity")
        #expect(model.teamIdentifier.isEmpty)
        #expect(model.siriSetup.issue(configuration: model.setupConfiguration)?.contains("Settings changed") == true)
        await model.closeAndWait()
    }

    /// Cancels and joins an in-flight check before closing without publishing a late configuration or error.
    @Test func closingJoinsDiscoveryCancellation() async {
        let (started, stream) = AsyncStream<Void>.makeStream()
        defer { stream.finish() }
        var iterator = started.makeAsyncIterator()
        let found = report()
        let model = await store { _, _ in
            stream.yield(())
            try await Task.sleep(for: .seconds(30))
            return found
        }
        model.detectSiriSetup()
        _ = await iterator.next()
        await model.closeAndWait()
        #expect(!model.siriSetup.isChecking)
        #expect(model.siriSetup.report == nil)
        #expect(model.siriSetup.diagnostic == nil)
        #expect(model.signingIdentity.isEmpty)
    }

    /// Blocks execution until Xcode has completed its first-launch components and license setup.
    @Test func incompleteXcodeFirstLaunchIsActionable() async {
        let found = report(xcodeReady: false)
        let model = await store { _, _ in found }
        model.detectSiriSetup()
        await model.siriSetup.waitForCheck()
        model.siriSetup.siriConfirmed = true
        #expect(model.siriSetup.issue(configuration: model.setupConfiguration)?.hasPrefix("Xcode:") == true)
        #expect(model.siriSetup.steps.first { $0.id == "xcode" }?.detail.contains("license") == true)
        await model.closeAndWait()
    }

    /// Rejects a delayed result for the previous app even when that probe ignores cooperative cancellation.
    @Test func replacingAppInvalidatesDelayedDiscovery() async {
        let gate = SetupGate()
        let found = report()
        let model = await store { _, _ in await gate.wait(); return found }
        model.detectSiriSetup()
        await Task.yield()
        model.load(appURL: URL(filePath: "/Replacement.app"))
        await model.waitForLoad()
        gate.resume()
        await model.siriSetup.waitForCheck()
        #expect(model.catalog?.appURL.path == "/Replacement.app")
        #expect(model.siriSetup.report == nil)
        #expect(model.signingIdentity.isEmpty)
        await model.closeAndWait()
    }

    /// Keeps an unregistered or running app visible as an explicit action even when every tool is available.
    @Test func registrationAndStoppedAppRemainRequired() async {
        let found = report(registered: false, running: true)
        let model = await store { _, _ in found }
        model.detectSiriSetup()
        await model.siriSetup.waitForCheck()
        model.siriSetup.siriConfirmed = true
        #expect(model.siriSetup.steps.first { $0.id == "registered" }?.complete == false)
        #expect(model.siriSetup.steps.first { $0.id == "stopped" }?.complete == false)
        #expect(model.siriSetup.issue(configuration: model.setupConfiguration)?.hasPrefix("App registered:") == true)
        await model.closeAndWait()
    }
}

/// Suspends one synthetic check until the test has made a concurrent settings edit.
@MainActor private final class SetupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    /// Allows the test to release discovery before or after its continuation has been installed.
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    /// Releases the suspended check exactly once without introducing timing-dependent sleeps.
    func resume() { released = true; continuation?.resume(); continuation = nil }
}
