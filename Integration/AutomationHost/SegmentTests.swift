import XCTest
import Foundation
import Darwin

@MainActor
final class SegmentTests: XCTestCase {
    func testSegment() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_HOST_PLAN_B64"],
              let data = Data(base64Encoded: encoded), data.count <= 32 * 1024 else { throw HostError.invalidPlan }
        let plan = try JSONDecoder().decode(HostPlan.self, from: data)
        guard plan.schemaVersion == 1, (1...10).contains(plan.operations.count),
              Set(plan.operations.map(\.id)).count == plan.operations.count,
              plan.productDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              plan.productDigestVersion == nil || plan.productDigestVersion == 1 || plan.productDigestVersion == 2 else { throw HostError.invalidPlan }
        if let expected = plan.expectedOSBuild {
            var buffer = [CChar](repeating: 0, count: 256), count = 256
            guard sysctlbyname("kern.osversion", &buffer, &count, nil, 0) == 0, count > 1, count <= buffer.count,
                  String(cString: buffer) == expected else { throw HostError.invalidPlan }
        }
        var kernel = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kernel, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              let executablePath = Bundle.main.executableURL?.path else { throw HostError.invalidPlan }
        let runner = HostReceipt.Runner(pid: getpid(), startIdentity: "\(kernel.kp_proc.p_un.__p_starttime.tv_sec):\(kernel.kp_proc.p_un.__p_starttime.tv_usec)", executablePath: executablePath)
        var receipt = HostReceipt(runner: runner, runID: plan.runID, attemptID: plan.attemptID, segmentID: plan.segmentID,
                                  leaseGeneration: plan.leaseGeneration, bundleID: plan.bundleID, productDigest: plan.productDigest)
        receipt.productDigestVersion = plan.productDigestVersion
        if plan.activateSubject == true {
            let app = XCUIApplication(bundleIdentifier: plan.bundleID)
            let previousFailures = (testRun?.failureCount ?? 0) + (testRun?.unexpectedExceptionCount ?? 0)
            // Activation preserves an existing process and registers a freshly installed subject
            // before AppIntentsTesting resolves its definitions.
            app.activate()
            guard app.wait(for: .runningForeground, timeout: 10),
                  (testRun?.failureCount ?? 0) + (testRun?.unexpectedExceptionCount ?? 0) == previousFailures else {
                throw HostError.invalidPlan
            }
        }
        try Task.checkCancellation()
        // The caller's absolute case deadline bounds activation; this allowance covers readiness and operations.
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        #if INTENTS_AUTOMATION_CI_FIXTURE && os(iOS) && targetEnvironment(simulator)
        try await HostFixtureRegistration.waitForAuthoredFixture(bundleID: plan.bundleID, deadline: deadline, record: { diagnostic in
            attach(name: "intents-fixture-registration-\(diagnostic.index)", data: try JSONEncoder().encode(diagnostic))
        })
        #endif
        for operation in plan.operations {
            guard ContinuousClock.now < deadline else { throw HostError.invalidPlan }
            attach(name: "intents-dispatch-\(operation.id)", data: try JSONEncoder().encode(
                HostReceipt.OperationReceipt(operationID: operation.id, dispatched: true, value: nil, error: nil)))
            do {
                let value = try await IntentDefinitionsHost.execute(operation, bundleID: plan.bundleID)
                try HostValueBudget.validate(receipt.operations.compactMap(\.value) + [value])
                if let bytes = value.fileData, let metadata = value.file, let name = value.value {
                    try metadata.verify(bytes)
                    let binary = XCTAttachment(data: bytes, uniformTypeIdentifier: metadata.typeIdentifier ?? "public.data")
                    binary.name = name; binary.lifetime = .keepAlways; add(binary)
                }
                receipt.operations.append(.init(operationID: operation.id, dispatched: true, value: value, error: nil))
            } catch {
                receipt.operations.append(.init(operationID: operation.id, dispatched: true, value: nil, error: HostValueBudget.boundedErrorDescription(String(describing: error))))
                attach(name: "intents-system-receipt", data: try JSONEncoder().encode(receipt)); throw error
            }
            attach(name: "intents-system-receipt-\(operation.id)", data: try JSONEncoder().encode(receipt))
        }
        receipt.runtimeContext = HostReceipt.RuntimeContext.observe()
        receipt.complete = true
        attach(name: "intents-system-receipt", data: try JSONEncoder().encode(receipt))
    }
    private func attach(name: String, data: Data) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
