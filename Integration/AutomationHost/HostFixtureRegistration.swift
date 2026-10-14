import Foundation

/// A diagnostic for the authored CI fixture, never a retry policy for tested operations.
@MainActor
enum HostFixtureRegistration {
    static let bundleID = "com.coryparry.IntentsAutomation.AutomationFixture"
    static let intentID = "EchoTextIntent"
    static let value = "registration-ready"
    enum Failure: Error, Equatable { case wrongBundle, wrongOutput, deadlineExceeded }
    struct Attempt: Encodable {
        let index: Int
        let succeeded: Bool
        let error: String?
    }

    static func wait(bundleID selectedBundle: String, deadline: ContinuousClock.Instant,
                     now: () -> ContinuousClock.Instant = { .now },
                     probe: (String, String) async throws -> String,
                     pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                     record: (Attempt) throws -> Void = { _ in }) async throws {
        guard selectedBundle == bundleID else { throw Failure.wrongBundle }
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
                      native.localizedDescription == "\(bundleID) is not present" else { throw error }
                // Do not begin a pause that cannot fit inside the existing host deadline.
                guard now().duration(to: deadline) > .seconds(5) else { throw Failure.deadlineExceeded }
                try await pause(.seconds(5))
                try checkDeadline()
            }
        }
    }
}
