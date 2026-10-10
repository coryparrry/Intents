import Foundation

public struct AutomationImportedSiriSubmission: Sendable {
    public let runner: AutomationProcessIdentity
    public let executablePath: String
    public let requestDigest: String
    public let osBuild: String?
}

/// A returned XCTest submission is neither recognised speech nor an observed app invocation.
public enum AutomationSiriSubmissionReceipt {
    public static func importReceipt(_ data: Data, scope: AutomationScope, app: AppIdentity,
                                     program: AutomationSiriTextProgram) throws -> AutomationImportedSiriSubmission {
        try scope.validate()
        guard data.count <= 16_384, app.platform == "ios",
              app.productDigestVersion == nil || app.productDigestVersion == 1,
              let digest = app.productDigest, digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              let root = try JSONDecoder().decode(AutomationJSON.self, from: data).object else {
            throw AutomationContractError.invalidIdentity
        }
        var keys: Set<String> = ["schemaVersion", "runner", "runID", "attemptID", "segmentID", "leaseGeneration",
            "bundleID", "productDigest", "requestDigest", "submissionStarted", "submissionReturned"]
        if app.productDigestVersion != nil { keys.insert("productDigestVersion") }
        let version = root["schemaVersion"]
        if version == .number(2) { keys.insert("osBuild") }
        let osBuild: String?
        if version == .number(2), case .string(let build) = root["osBuild"],
           build.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil { osBuild = build }
        else if version == .number(1) { osBuild = nil }
        else { throw AutomationContractError.invalidIdentity }
        guard Set(root.keys) == keys,
              root["runID"] == .string(scope.runId), root["attemptID"] == .string(scope.attemptId),
              root["segmentID"] == .string(scope.segmentId), root["leaseGeneration"] == .number(Double(scope.leaseGeneration)),
              root["bundleID"] == .string(app.bundleID), root["productDigest"] == .string(digest),
              root["productDigestVersion"] == app.productDigestVersion.map { .number(Double($0)) },
              root["requestDigest"] == .string(program.requestDigest), root["submissionStarted"] == .bool(true),
              root["submissionReturned"] == .bool(true), let runner = root["runner"]?.object,
              Set(runner.keys) == ["pid", "startIdentity", "executablePath"],
              case .number(let pid) = runner["pid"], pid > 0, pid <= Double(Int32.max), pid.rounded() == pid,
              case .string(let start) = runner["startIdentity"], start.range(of: #"^[0-9]{1,20}:[0-9]{1,6}$"#, options: .regularExpression) != nil,
              case .string(let path) = runner["executablePath"], path.hasPrefix("/"), path.utf16.count <= 4096,
              !path.contains("\0"), !path.contains("\n") else { throw AutomationContractError.invalidIdentity }
        return .init(runner: .init(pid: Int32(pid), startIdentity: start), executablePath: path, requestDigest: program.requestDigest, osBuild: osBuild)
    }
}
