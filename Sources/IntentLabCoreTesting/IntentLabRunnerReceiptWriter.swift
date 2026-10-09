import Darwin
import Foundation
import IntentLabContracts
import XCTest

@MainActor
enum IntentLabRunnerReceiptWriter {
    /// Missing kernel/bundle evidence preserves old harness behavior, but cannot mint ownership proof.
    static func attachIfAvailable(invocation: IntentLabInvocation, testCase: XCTestCase) {
        guard let receipt = try? capture(invocation: invocation, testCase: testCase),
              let data = try? JSONEncoder().encode(receipt) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "IntentLabRunnerReceipt-\(invocation.id.uuidString).json"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    private static func capture(invocation: IntentLabInvocation, testCase: XCTestCase) throws -> IntentLabRunnerReceipt {
        let bundle = Bundle(for: type(of: testCase))
        guard let product = invocation.testProduct, let url = bundle.executableURL,
              let bundleID = bundle.bundleIdentifier, let executable = Bundle.main.executableURL else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let digest = try IntentLabExecutableDigest.hash(url)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc(), count = MemoryLayout<kinfo_proc>.size
        let status = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, u_int($0.count), &info, &count, nil, 0) }
        guard status == 0, count == MemoryLayout<kinfo_proc>.size else { throw CocoaError(.featureUnsupported) }
        let receipt = IntentLabRunnerReceipt(invocationID: invocation.id, nonce: invocation.nonce,
            destinationIdentifier: invocation.destinationIdentifier, scenarioDigest: invocation.scenarioDigest,
            testBundleIdentifier: bundleID, testProductSHA256: digest, processIdentifier: getpid(),
            kernelStartIdentity: "\(info.kp_proc.p_starttime.tv_sec):\(info.kp_proc.p_starttime.tv_usec)",
            executableName: executable.lastPathComponent)
        try receipt.validate(invocationID: invocation.id, nonce: invocation.nonce,
            destinationIdentifier: invocation.destinationIdentifier, scenarioDigest: invocation.scenarioDigest,
            testBundleIdentifier: product.bundleIdentifier, testProductSHA256: product.sha256,
            executableName: executable.lastPathComponent)
        return receipt
    }

}
