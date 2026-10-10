import XCTest
import Foundation
import CryptoKit
import Darwin

@MainActor
final class SiriSubmissionTests: XCTestCase {
    private enum SubmissionError: Error { case invalidPlan }
    private struct Runner: Encodable { let pid: Int32; let startIdentity: String; let executablePath: String }
    private struct Plan: Decodable {
        let schemaVersion: Int
        let runID: String
        let attemptID: String
        let segmentID: String
        let leaseGeneration: Int
        let bundleID: String
        let productDigest: String
        let productDigestVersion: Int?
        let request: String
        let expectedOSBuild: String?
    }
    private struct Receipt: Encodable {
        var schemaVersion = 2
        let runner: Runner
        let runID: String
        let attemptID: String
        let segmentID: String
        let leaseGeneration: Int
        let bundleID: String
        let productDigest: String
        let productDigestVersion: Int?
        let requestDigest: String
        let osBuild: String
        var submissionStarted = true
        var submissionReturned = false
    }
    func testSubmitRecognizedText() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        guard let encoded = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_SIRI_PLAN_B64"],
              let data = Data(base64Encoded: encoded), data.count <= 16_384 else { throw SubmissionError.invalidPlan }
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        guard plan.schemaVersion == 1, plan.leaseGeneration > 0,
              [plan.runID, plan.attemptID, plan.segmentID].allSatisfy({ $0.range(of: #"^[A-Za-z0-9.-]{1,128}$"#, options: .regularExpression) != nil }),
              !plan.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              plan.request.utf16.count <= 2048, !plan.request.contains("\0"),
              plan.productDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              plan.productDigestVersion == nil || plan.productDigestVersion == 1,
              plan.bundleID.range(of: #"^[A-Za-z0-9.-]{1,256}$"#, options: .regularExpression) != nil else { throw SubmissionError.invalidPlan }
        var kernel = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kernel, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              let executablePath = Bundle.main.executableURL?.path else { throw SubmissionError.invalidPlan }
        var buildBuffer = [CChar](repeating: 0, count: 256), buildSize = 256
        guard sysctlbyname("kern.osversion", &buildBuffer, &buildSize, nil, 0) == 0,
              buildSize > 1, buildSize <= buildBuffer.count else { throw SubmissionError.invalidPlan }
        let osBuild = String(cString: buildBuffer)
        guard osBuild.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              plan.expectedOSBuild == nil || plan.expectedOSBuild == osBuild else { throw SubmissionError.invalidPlan }
        let runner = Runner(pid: getpid(), startIdentity: "\(kernel.kp_proc.p_un.__p_starttime.tv_sec):\(kernel.kp_proc.p_un.__p_starttime.tv_usec)", executablePath: executablePath)
        var receipt = Receipt(runner: runner, runID: plan.runID, attemptID: plan.attemptID, segmentID: plan.segmentID,
            leaseGeneration: plan.leaseGeneration, bundleID: plan.bundleID, productDigest: plan.productDigest,
            productDigestVersion: plan.productDigestVersion, requestDigest: SHA256.hash(data: Data(plan.request.utf8)).map { String(format: "%02x", $0) }.joined(), osBuild: osBuild)
        attach("intents-siri-dispatch", receipt)
        // XCTest owns the activation wait. Aborts retain the checkpoint and no returned receipt.
        // Permission prompts and disambiguation remain visible for the operator.
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: plan.request)
        receipt.submissionReturned = true
        attach("intents-siri-submission", receipt)
        #else
        throw SubmissionError.invalidPlan
        #endif
    }
    private func attach(_ name: String, _ receipt: Receipt) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
