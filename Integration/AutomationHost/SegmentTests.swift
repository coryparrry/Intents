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
        var kernel = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kernel, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              let executablePath = Bundle.main.executableURL?.path else { throw HostError.invalidPlan }
        let runner = HostReceipt.Runner(pid: getpid(), startIdentity: "\(kernel.kp_proc.p_un.__p_starttime.tv_sec):\(kernel.kp_proc.p_un.__p_starttime.tv_usec)", executablePath: executablePath)
        var receipt = HostReceipt(runner: runner, runID: plan.runID, attemptID: plan.attemptID, segmentID: plan.segmentID,
                                  leaseGeneration: plan.leaseGeneration, bundleID: plan.bundleID, productDigest: plan.productDigest)
        receipt.productDigestVersion = plan.productDigestVersion
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
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
