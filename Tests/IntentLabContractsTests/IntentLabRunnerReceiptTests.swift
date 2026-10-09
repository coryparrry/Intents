import Foundation
import XCTest
import IntentLabContracts

final class IntentLabRunnerReceiptTests: XCTestCase {
    func testReceiptBindsInvocationProductAndProcessWithoutClaimingRelease() throws {
        let receipt = sample()
        try validate(receipt)
        XCTAssertEqual(try JSONDecoder().decode(IntentLabRunnerReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
        var changed = receipt; changed.nonce = "other"
        XCTAssertThrowsError(try validate(changed))
        changed = receipt; changed.destinationIdentifier = "other"
        XCTAssertThrowsError(try validate(changed))
        changed = receipt; changed.testProductSHA256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try validate(changed))
        changed = receipt; changed.invocationID = UUID()
        XCTAssertThrowsError(try validate(changed))
    }
    func testInvalidProcessAndForeignExecutableCannotSupplyOwnership() throws {
        var changed = sample(); changed.processIdentifier = 0
        XCTAssertThrowsError(try validate(changed))
        changed = sample(); changed.kernelStartIdentity = "wall-clock"
        XCTAssertThrowsError(try validate(changed))
        changed = sample(); changed.executableName = "Foreign-Runner"
        XCTAssertThrowsError(try validate(changed))
        changed = sample(); changed.schemaVersion = 2
        XCTAssertThrowsError(try validate(changed))
    }
    func testReceiptFromAnotherScenarioOrTestBundleCannotSupplyOwnership() throws {
        var changed = sample(); changed.scenarioDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try validate(changed))
        changed = sample(); changed.testBundleIdentifier = "other"
        XCTAssertThrowsError(try validate(changed))
    }
    func testMatchingButMalformedBindingsAreRejected() throws {
        var changed = sample(); changed.nonce = String(repeating: "n", count: 256)
        try validate(changed, expected: changed)
        changed = sample(); changed.nonce = String(repeating: "n", count: 257)
        XCTAssertThrowsError(try validate(changed, expected: changed))
        changed = sample(); changed.nonce = ""
        XCTAssertThrowsError(try validate(changed, expected: changed))
        changed = sample(); changed.destinationIdentifier = ""
        XCTAssertThrowsError(try validate(changed, expected: changed))
        changed = sample(); changed.testBundleIdentifier = ""
        XCTAssertThrowsError(try validate(changed, expected: changed))
        changed = sample(); changed.scenarioDigest = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try validate(changed, expected: changed))
        changed = sample(); changed.testProductSHA256 = String(repeating: "C", count: 64)
        XCTAssertThrowsError(try validate(changed, expected: changed))
        changed = sample(); changed.scenarioDigest = String(repeating: "a", count: 63)
        XCTAssertThrowsError(try validate(changed, expected: changed))
    }
    func testPathShapedOrOversizedExecutableNamesAreRejectedEvenWhenExpected() throws {
        var changed = sample(); changed.executableName = String(repeating: "x", count: 256)
        try validate(changed, expected: changed)
        for name in ["a/b", "a\0b", "", String(repeating: "x", count: 257)] {
            changed = sample(); changed.executableName = name
            XCTAssertThrowsError(try validate(changed, expected: changed), "accepted executable name \(name.debugDescription)")
        }
    }
    private func sample() -> IntentLabRunnerReceipt {
        .init(invocationID: UUID(uuidString: "D0B748AA-010B-498B-A1D9-A867697392BD")!, nonce: "random-invocation-nonce",
              destinationIdentifier: "physical-target", scenarioDigest: String(repeating: "a", count: 64),
              testBundleIdentifier: "com.example.Tests", testProductSHA256: String(repeating: "c", count: 64),
              processIdentifier: 42, kernelStartIdentity: "1791302400:123456", executableName: "Tests-Runner")
    }
    private func validate(_ receipt: IntentLabRunnerReceipt, expected: IntentLabRunnerReceipt? = nil) throws {
        let expected = expected ?? sample()
        try receipt.validate(invocationID: expected.invocationID, nonce: expected.nonce,
            destinationIdentifier: expected.destinationIdentifier, scenarioDigest: expected.scenarioDigest,
            testBundleIdentifier: expected.testBundleIdentifier, testProductSHA256: expected.testProductSHA256,
            executableName: expected.executableName)
    }
}
