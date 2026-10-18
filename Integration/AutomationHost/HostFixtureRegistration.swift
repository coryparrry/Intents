import Foundation
#if INTENTS_AUTOMATION_CI_FIXTURE && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
import AppIntentsTesting
#endif

/// A diagnostic for the authored CI fixture, never a retry policy for tested operations.
@MainActor
enum HostFixtureRegistration {
    static let bundleID = "com.coryparry.IntentsAutomation.AutomationFixture"
    static let macBundleID = bundleID + "Mac"
    static let intentID = "EchoTextIntent"
    static let value = "registration-ready"
    enum Failure: Error, Equatable { case wrongBundle, wrongOutput, deadlineExceeded }
    struct Attempt: Encodable {
        let index: Int
        let succeeded: Bool
        let error: String?
    }

    #if INTENTS_AUTOMATION_CI_FIXTURE && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
    static func waitForAuthoredFixture(bundleID: String, deadline: ContinuousClock.Instant,
                                       record: (Attempt) throws -> Void) async throws {
        try await wait(bundleID: bundleID, deadline: deadline, probe: { typeID, value in
            let definitions = IntentDefinitions(bundleIdentifier: bundleID)
            let definition = definitions.intents[typeID]
            var intent = definition.makeIntent()
            try HostIntentIdentity.validate(bundle: bundleID, action: typeID, definitionsBundle: definitions.bundleIdentifier,
                definitionBundle: definition.bundleIdentifier, definitionID: definition.identifier, intentBundle: intent.bundleIdentifier, intentID: intent.identifier)
            intent[dynamicMember: "value"] = value
            let result = try await intent.run()
            let output: String = try result.value
            return output
        }, record: record)
    }
    #endif

    static func wait(bundleID selectedBundle: String, deadline: ContinuousClock.Instant,
                     now: () -> ContinuousClock.Instant = { .now },
                     probe: (String, String) async throws -> String,
                     pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                     record: (Attempt) throws -> Void = { _ in }) async throws {
        guard selectedBundle == bundleID || selectedBundle == macBundleID else { throw Failure.wrongBundle }
        func checkDeadline() throws {
            try Task.checkCancellation()
            guard now() < deadline else { throw Failure.deadlineExceeded }
        }
        for index in 1...3 {
            try checkDeadline()
            let outcome: Result<String, any Error>
            do {
                let output = try await probe(intentID, value)
                try checkDeadline()
                guard output == value else { throw Failure.wrongOutput }
                outcome = .success(output)
            } catch { outcome = .failure(error) }
            switch outcome {
            case .success:
                try record(.init(index: index, succeeded: true, error: nil))
                return
            case .failure(let error):
                try record(.init(index: index, succeeded: false, error: String(String(describing: error).prefix(4096))))
                try checkDeadline()
                let native = error as NSError
                guard index < 3, native.domain == "AppIntentsServicesMetadataErrorDomain", native.code == 400,
                      native.localizedDescription == "\(selectedBundle) is not present" else { throw error }
                // Do not begin a pause that cannot fit inside the existing host deadline.
                guard now().duration(to: deadline) > .seconds(5) else { throw Failure.deadlineExceeded }
                try await pause(.seconds(5))
                try checkDeadline()
            }
        }
    }
}
