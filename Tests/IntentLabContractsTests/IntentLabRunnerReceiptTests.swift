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
    private func sample() -> IntentLabRunnerReceipt {
        .init(invocationID: UUID(uuidString: "D0B748AA-010B-498B-A1D9-A867697392BD")!, nonce: "random-invocation-nonce",
              destinationIdentifier: "physical-target", scenarioDigest: String(repeating: "a", count: 64),
              testBundleIdentifier: "com.example.Tests", testProductSHA256: String(repeating: "c", count: 64),
              processIdentifier: 42, kernelStartIdentity: "1791302400:123456", executableName: "Tests-Runner")
    }
    private func validate(_ receipt: IntentLabRunnerReceipt) throws {
        let expected = sample()
        try receipt.validate(invocationID: expected.invocationID, nonce: expected.nonce,
            destinationIdentifier: expected.destinationIdentifier, scenarioDigest: expected.scenarioDigest,
            testBundleIdentifier: expected.testBundleIdentifier, testProductSHA256: expected.testProductSHA256,
            executableName: expected.executableName)
    }
}
