import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationSharedTimingTests {
    /// Verifies shared timing preserves the sign and fractional precision of monotonic durations.
    @Test func signedMillisecondsPreservePositiveNegativeAndZeroDurations() {
        let origin = ContinuousClock.now
        let cases: [(Duration, Double)] = [
            (.zero, 0),
            (.milliseconds(1_250), 1_250),
            (.milliseconds(-1_250), -1_250),
            (.nanoseconds(125_000), 0.125),
            (.nanoseconds(-125_000), -0.125),
            (.seconds(1_000_000), 1_000_000_000),
            (.seconds(-1_000_000), -1_000_000_000)
        ]
        for (duration, expected) in cases {
            #expect(abs(origin.evaluationMilliseconds(to: origin.advanced(by: duration)) - expected) < 0.000_000_001)
        }
    }

    /// Verifies workflow evidence alone clamps reversed starts and durations while retaining positive timing.
    @Test func workflowClampsReversedInstantsWithoutChangingPositiveDurations() throws {
        let origin = ContinuousClock.now
        let recorder = EvaluationWorkflowRecorder(origin: origin)
        let reversed = recorder.begin(kind: .preparation, title: "Reversed", at: origin.advanced(by: .milliseconds(-5)))
        recorder.finish(reversed, at: origin.advanced(by: .milliseconds(-10)))
        let positive = recorder.begin(kind: .generation, title: "Positive", at: origin.advanced(by: .milliseconds(5)))
        recorder.finish(positive, at: origin.advanced(by: .milliseconds(7)))
        let spans = recorder.snapshot().spans
        let reversedSpan = try #require(spans.first { $0.id == reversed })
        let positiveSpan = try #require(spans.first { $0.id == positive })
        #expect(reversedSpan.startOffsetMilliseconds == 0)
        #expect(reversedSpan.durationMilliseconds == 0)
        #expect(positiveSpan.startOffsetMilliseconds == 5)
        #expect(positiveSpan.durationMilliseconds == 2)
    }
}
