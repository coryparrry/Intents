import XCTest
import IntentLabContracts
@testable import IntentLabTesting

@available(macOS 27.0, iOS 27.0, *)
@MainActor
final class IntentLabBoundedAdapterTests: XCTestCase {
    private let descriptions = [
        "Local feature test intent completed",
        "IntentLab readiness intent completed",
        "Direct intent completed",
    ]

    func testAdaptersReturnExactObservationsAndInvokeOnceOnMainActor() throws {
        let expected: [String: IntentLabValue] = [
            "text": .string("response"),
            "ready": .boolean(false),
            "count": .integer(7),
            "values": .array([.null, .number(1.5)]),
        ]
        for description in descriptions {
            var calls = 0
            let observations = try IntentLabScenarioRunner.boundedObservations(
                description: description,
                deadlineSeconds: 2
            ) {
                MainActor.assertIsolated()
                calls += 1
                return expected
            }
            XCTAssertEqual(observations, expected)
            XCTAssertEqual(calls, 1)
        }
    }

    func testAdaptersPreserveTheThrownOperationError() {
        for description in descriptions {
            let expected = OperationFailure()
            XCTAssertThrowsError(try IntentLabScenarioRunner.boundedObservations(
                description: description,
                deadlineSeconds: 2
            ) {
                throw expected
            }) { error in
                XCTAssertTrue((error as? OperationFailure) === expected)
            }
        }
    }

    func testWaitReceivesExactDescriptionAndSuppliedDeadline() {
        // These adapters intentionally leave deadline policy to their caller;
        // unlike the query observer they do not reject nonpositive deadlines.
        for description in descriptions {
            for deadline in [0.0, -1.0, 0.125] {
                XCTAssertThrowsError(try IntentLabScenarioRunner.boundedObservations(
                    description: description,
                    deadlineSeconds: deadline,
                    wait: { expectations, receivedDeadline in
                        XCTAssertEqual(expectations.map(\.expectationDescription), [description])
                        XCTAssertEqual(receivedDeadline, deadline)
                        return .timedOut
                    }
                ) { [:] }) { error in
                    XCTAssertTrue(error is IntentLabDirectIntentTimeout)
                }
            }
        }
    }

    func testCompletedWaitWithoutAResultStillThrowsDirectTimeoutAndCancelsTask() async {
        let cancelled = XCTestExpectation(description: "Missing-result task was cancelled")
        XCTAssertThrowsError(try IntentLabScenarioRunner.boundedObservations(
            description: "Direct intent completed",
            deadlineSeconds: 2,
            wait: { _, _ in .completed }
        ) {
            XCTAssertTrue(Task.isCancelled)
            cancelled.fulfill()
            return [:]
        }) { error in
            XCTAssertTrue(error is IntentLabDirectIntentTimeout)
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testTimeoutCancelsPendingOperationForEveryAdapter() async {
        for description in descriptions {
            let started = XCTestExpectation(description: "Operation started")
            let cancelled = XCTestExpectation(description: "Timed-out operation was cancelled")
            var completedOperation = false
            XCTAssertThrowsError(try IntentLabScenarioRunner.boundedObservations(
                description: description,
                deadlineSeconds: 0.02
            ) {
                started.fulfill()
                return try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(10))
                    completedOperation = true
                    return [:]
                } onCancel: {
                    cancelled.fulfill()
                }
            }) { error in
                XCTAssertTrue(error is IntentLabDirectIntentTimeout)
            }
            await fulfillment(of: [started, cancelled], timeout: 2)
            XCTAssertFalse(completedOperation)
        }
    }

    func testOperationCancellationIsPropagatedWithoutBecomingTimeout() {
        XCTAssertThrowsError(try IntentLabScenarioRunner.boundedObservations(
            description: "Direct intent completed",
            deadlineSeconds: 2
        ) {
            throw CancellationError()
        }) { error in
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(error is IntentLabDirectIntentTimeout)
        }
    }
}

private final class OperationFailure: Error {}
