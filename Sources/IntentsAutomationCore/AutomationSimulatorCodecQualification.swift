#if os(macOS)
import Foundation

/// Adapter canaries are independent of the subject app. Admission still checks
/// the exact host template, Apple tooling, runtime, architecture and signing mode.
enum AutomationSimulatorCodecQualification {
    struct Context: Equatable, Sendable {
        var hostTemplate: String
        var macOSBuild: String
        var architecture: String
        var xcodeBuild: String
        var sdkBuild: String
        var runnerBuild: String
        var runtimeBuild: String
        var frameworkDigest: String
        var signing: String
    }
    struct Qualification: Sendable {
        let context: Context
        let families: Set<String>
        let reports: [String]
        let probeVersion: String
    }
    // Actual no-write App Intent dispatch, exact returned values, and released
    // ownership are retained in Verification/Automation/simulator-codec-qualification-1.json.
    static let legacyQualified = Qualification(context: Context(
        hostTemplate: "0f812ac7ade31b1bea3056261569882341ac1df5d6bc21decba5d84f570a29e5",
        macOSBuild: "26B5101f", architecture: "arm64", xcodeBuild: "27A266a",
        sdkBuild: "24A430", runnerBuild: "27A252a", runtimeBuild: "24A434",
        frameworkDigest: "ab81429acdc990f72c908ce727693c4a0f4ffd73b0d61d27d14814b8e2de1ce3",
        signing: "simulator-ad-hoc"), families: ["integerArray"],
        reports: ["98f22d9e7c65ee9501d960c35454b99e85b647bd496b01c004a0344ac13db996"], probeVersion: "simulator-codec-canary-1")

    // Version 2 retains the corrected Int readers and ten exact live outputs.
    static let qualified: Qualification = {
        var context = legacyQualified.context
        context.hostTemplate = "3d754425fdbc87d8fb542b5e930bcc4b055af679caed5344c6f7cf16abe5eb77"
        return Qualification(context: context, families: ["text", "bool", "integer", "decimal", "enum", "entity", "integerArray"],
            reports: ["a6eb54a0435dd12c9bf624e7b43803f15e399c3a58949217162e0f19d564f474"], probeVersion: "simulator-codec-canary-2")
    }()

    static func applying(_ qualification: Qualification, context: Context,
                         to capabilities: CapabilityProfile) -> CapabilityProfile {
        guard context == qualification.context else { return capabilities }
        var result = capabilities
        for family in qualification.families {
            let key = "apple.codec." + family
            // A caller's explicit veto or consent requirement is never overridden.
            guard result.records[key] == nil || result.records[key]?.state == .unknown else { continue }
            result.records[key] = .init(state: .available,
                reason: "Independent adapter canaries passed for this Apple host template and runtime",
                probeVersion: qualification.probeVersion, evidence: qualification.reports)
        }
        return result
    }

    static func enrich(_ capabilities: CapabilityProfile, prepared: AutomationPreparedApplication) async throws -> CapabilityProfile {
        try Task.checkCancellation()
        try AutomationPreparedCodecAuthority.verify(prepared)
        var result = capabilities
        for family in AutomationCodecRegistry.parameterFamilies {
            let key = "apple.codec." + family
            // Preserve a caller's explicit veto and consent requirement.
            guard result.records[key] == nil || result.records[key]?.state == .unknown else { continue }
            result.records[key] = .init(state: .available,
                reason: "Prepared host implements this conversion and its saved files match",
                probeVersion: "prepared-host-codecs-v1",
                evidence: [prepared.generatedHost.templateDigest, prepared.host.hostProductDigest, prepared.host.xctestrunDigest])
        }
        try Task.checkCancellation()
        return result
    }

    static func enrich(_ capabilities: CapabilityProfile, prepared: AutomationPreparedApplication,
                       requiredCapabilities: Set<String>, developerDirectory: URL, workspace: URL) async throws -> CapabilityProfile {
        try await enrich(capabilities, prepared: prepared)
    }

    static func supportsQualifiedArchitecture(_ slices: String) -> Bool {
        Set(slices.split(whereSeparator: \.isWhitespace).map(String.init)).contains(qualified.context.architecture)
    }

    static func verifiesSignature(_ product: URL, developer: URL, workspace: URL) async throws -> Bool {
        let verification = try await command("/usr/bin/codesign", ["--verify", "--strict", product.path], developer, workspace)
        return verification.exitStatus == 0 && !verification.logsTruncated
    }

    private static func plist(_ url: URL) throws -> [String: Any] {
        let data = try AutomationReadOnlyFile.read(url.resolvingSymlinksInPath(), maximumBytes: 1_048_576)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AutomationContractError.invalidIdentity
        }
        return value
    }
    private static func command(_ executable: String, _ arguments: [String], _ developer: URL,
                                _ workspace: URL) async throws -> AutomationOwnedCommand.Result {
        try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: executable), arguments: arguments,
            directory: workspace, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path,
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()], timeout: .seconds(15))
    }
}
#endif
