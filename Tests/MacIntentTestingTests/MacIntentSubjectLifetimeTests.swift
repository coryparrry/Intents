import AppKit
import Foundation
import Testing
@testable import MacIntentTesting

@MainActor
struct MacIntentSubjectLifetimeTests {
    private let launchDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func observedSubjectTerminationAcceptsOnlyCompletePassingEvidence() throws {
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        lifetime.observeTermination(processIdentifier: 101, launchedAt: launchDate)
        var productValidated = false
        var liveValidationCalled = false

        try lifetime.validateCompletion(subjectTerminated: true, hasOtherRunningCopy: false,
            summary: summary(), expectedCount: 1,
            validateLiveSubject: { liveValidationCalled = true },
            validateProduct: { productValidated = true })

        #expect(productValidated)
        #expect(!liveValidationCalled)
    }

    @Test(arguments: ["unobserved", "replacement-exited", "reused-pid", "unknown-launch", "unknown-termination", "other-running", "incomplete-summary"])
    func terminationDoesNotHideReplacementOrUnverifiedEvidence(condition: String) throws {
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        if condition != "unobserved" {
            lifetime.observeTermination(processIdentifier: 101, launchedAt: launchDate)
        }
        switch condition {
        case "replacement-exited":
            lifetime.observeLaunch(processIdentifier: 202, launchedAt: launchDate.addingTimeInterval(1))
            lifetime.observeTermination(processIdentifier: 202, launchedAt: launchDate.addingTimeInterval(1))
        case "reused-pid":
            lifetime.observeLaunch(processIdentifier: 101, launchedAt: launchDate.addingTimeInterval(1))
        case "unknown-launch":
            lifetime.observeLaunch(processIdentifier: 101, launchedAt: nil)
        case "unknown-termination":
            lifetime.observeTermination(processIdentifier: 101, launchedAt: nil)
        default: break
        }

        #expect(throws: MacIntentTestingError.self) {
            try lifetime.validateCompletion(subjectTerminated: true,
                hasOtherRunningCopy: condition == "other-running",
                summary: summary(passed: condition == "incomplete-summary" ? 0 : 1), expectedCount: 1,
                validateLiveSubject: {}, validateProduct: {})
        }
    }

    @Test func aLiveSubjectStillRequiresItsSignedProcessValidation() throws {
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        // A stale termination notification must not skip validation of a live app.
        lifetime.observeTermination(processIdentifier: 101, launchedAt: launchDate)
        var validatedLiveCode = false
        #expect(throws: MacIntentTestingError.self) {
            try lifetime.validateCompletion(subjectTerminated: false, hasOtherRunningCopy: false,
                summary: summary(), expectedCount: 1,
                validateLiveSubject: {
                    validatedLiveCode = true
                    throw MacIntentTestingError("The running signed code differs from the selected build.")
                }, validateProduct: {})
        }
        #expect(validatedLiveCode)
    }

    @Test func terminatedSubjectCannotQualifyAModifiedBundle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerminatedSubject-\(UUID()).app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = directory.appendingPathComponent("resource.txt")
        try Data("Selected build".utf8).write(to: resource)
        let identity = try MacIntentProductIdentity.capture(directory)
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        lifetime.observeTermination(processIdentifier: 101, launchedAt: launchDate)
        try Data("A different build".utf8).write(to: resource)

        #expect(throws: MacIntentTestingError.self) {
            try lifetime.validateCompletion(subjectTerminated: true, hasOtherRunningCopy: false,
                summary: summary(), expectedCount: 1,
                validateLiveSubject: {}, validateProduct: { try identity.validate() })
        }
    }

    @Test func replacementObservedDuringCleanupStillInvalidatesTheVerdict() throws {
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        lifetime.observeTermination(processIdentifier: 101, launchedAt: launchDate)
        try lifetime.validateCompletion(subjectTerminated: true, hasOtherRunningCopy: false,
            summary: summary(), expectedCount: 1, validateLiveSubject: {}, validateProduct: {})
        lifetime.observeLaunch(processIdentifier: 202, launchedAt: launchDate.addingTimeInterval(1))

        #expect(throws: MacIntentTestingError.self) {
            try lifetime.validateNoReplacement(hasOtherRunningCopy: false)
        }
    }

    @Test(arguments: ["original", "unobserved", "replacement", "incomplete-summary"])
    func queuedTerminationIsDeliveredBeforeTheCompletionVerdict(condition: String) async throws {
        let center = NotificationCenter()
        let bundleIdentifier = "dev.intents.lifecycle.\(UUID())"
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        lifetime.startObserving(bundleIdentifier: bundleIdentifier, center: center,
            applicationSnapshot: Self.applicationSnapshot)
        defer { lifetime.stopObserving() }
        let launchDate = launchDate
        DispatchQueue.main.async {
            if condition != "unobserved" {
                center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: ["bundleIdentifier": bundleIdentifier,
                        "processIdentifier": Int32(101), "launchedAt": launchDate])
            }
            if condition == "replacement" {
                Self.postReplacement(to: center, bundleIdentifier: bundleIdentifier, launchedAt: launchDate)
            }
        }
        // The process is already known to have ended, but the adapter has not
        // received its queued termination event while this actor is occupied.
        #expect(throws: MacIntentTestingError.self) {
            try lifetime.validateCompletion(subjectTerminated: true, hasOtherRunningCopy: false,
                summary: summary(), expectedCount: 1, validateLiveSubject: {}, validateProduct: {})
        }
        await lifetime.deliverPendingObservations()
        let validate = {
            try lifetime.validateCompletion(subjectTerminated: true, hasOtherRunningCopy: false,
                summary: summary(passed: condition == "incomplete-summary" ? 0 : 1), expectedCount: 1,
                validateLiveSubject: {}, validateProduct: {})
        }
        if condition == "original" {
            try validate()
            // Completion delivery does not end observation: cleanup still
            // rejects a later replacement before the final cutoff.
            Self.postReplacement(to: center, bundleIdentifier: bundleIdentifier, launchedAt: launchDate)
            #expect(throws: MacIntentTestingError.self) {
                try lifetime.validateNoReplacement(hasOtherRunningCopy: false)
            }
        } else {
            #expect(throws: MacIntentTestingError.self) { try validate() }
        }
    }

    @Test func queuedReplacementNotificationsAreDeliveredBeforeTheFinalCutoff() async throws {
        let center = NotificationCenter()
        let bundleIdentifier = "dev.intents.lifecycle.\(UUID())"
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        lifetime.startObserving(bundleIdentifier: bundleIdentifier, center: center,
            applicationSnapshot: Self.applicationSnapshot)
        defer { lifetime.stopObserving() }
        let launchDate = launchDate
        DispatchQueue.main.async {
            Self.postReplacement(to: center, bundleIdentifier: bundleIdentifier, launchedAt: launchDate)
        }
        // This test still occupies the main actor: the notifications are queued,
        // and a synchronous final check here would incorrectly accept the run.
        try lifetime.validateNoReplacement(hasOtherRunningCopy: false)

        await #expect(throws: MacIntentTestingError.self) {
            try await lifetime.finishObserving(afterProductValidation: {}, hasOtherRunningCopy: { false })
        }
    }

    @Test func backgroundNotificationDeliveryDoesNotWaitForTheMainActor() throws {
        let center = NotificationCenter()
        let bundleIdentifier = "dev.intents.lifecycle.\(UUID())"
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        lifetime.startObserving(bundleIdentifier: bundleIdentifier, center: center,
            applicationSnapshot: Self.applicationSnapshot)
        defer { lifetime.stopObserving() }
        let launchDate = launchDate
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Self.postReplacement(to: center, bundleIdentifier: bundleIdentifier, launchedAt: launchDate)
            delivered.signal()
        }
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        #expect(throws: MacIntentTestingError.self) {
            try lifetime.validateNoReplacement(hasOtherRunningCopy: false)
        }
    }

    @Test func eventsAfterTheExplicitCutoffDoNotChangeTheRetainedSnapshot() async throws {
        let center = NotificationCenter()
        let bundleIdentifier = "dev.intents.lifecycle.\(UUID())"
        let lifetime = MacIntentSubjectLifetime(processIdentifier: 101, launchedAt: launchDate)
        lifetime.startObserving(bundleIdentifier: bundleIdentifier, center: center,
            applicationSnapshot: Self.applicationSnapshot)
        try await lifetime.finishObserving(afterProductValidation: {}, hasOtherRunningCopy: { false })
        Self.postReplacement(to: center, bundleIdentifier: bundleIdentifier, launchedAt: launchDate)
        try lifetime.validateNoReplacement(hasOtherRunningCopy: false)
    }

    nonisolated private static func applicationSnapshot(_ notification: Notification) -> MacIntentSubjectLifetime.ApplicationSnapshot? {
        guard let bundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String,
              let processIdentifier = notification.userInfo?["processIdentifier"] as? Int32,
              let launchedAt = notification.userInfo?["launchedAt"] as? Date else { return nil }
        return .init(bundleIdentifier: bundleIdentifier, processIdentifier: processIdentifier, launchedAt: launchedAt)
    }

    nonisolated private static func postReplacement(to center: NotificationCenter, bundleIdentifier: String, launchedAt: Date) {
        let information: [AnyHashable: Any] = ["bundleIdentifier": bundleIdentifier,
            "processIdentifier": Int32(202), "launchedAt": launchedAt.addingTimeInterval(1)]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: information)
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: information)
    }

    private func summary(passed: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "result": "Passed", "passedTests": passed, "totalTestCount": 1,
            "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
        ])
    }
}
