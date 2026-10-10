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

    static func enrich(_ capabilities: CapabilityProfile, prepared: AutomationPreparedApplication,
                       requiredCapabilities: Set<String>, developerDirectory: URL, workspace: URL) async throws -> CapabilityProfile {
        // A preflight snapshot is data, not continuing authority. Remove this
        // verifier's previous grants before checking the current environment.
        // Explicit caller vetoes, consent and unrelated evidence stay intact.
        var capabilities = capabilities
        for qualification in [qualified, legacyQualified] {
            for family in qualification.families {
                let key = "apple.codec." + family
                if let record = capabilities.records[key], record.state == .available,
                   record.probeVersion == qualification.probeVersion, record.evidence == qualification.reports {
                    capabilities.records.removeValue(forKey: key)
                }
            }
        }
        guard prepared.host.target.kind == .simulator, prepared.host.app.platform == "ios",
              let qualification = [qualified, legacyQualified].first(where: { $0.context.hostTemplate == prepared.generatedHost.templateDigest }),
              qualification.families.contains(where: {
                  requiredCapabilities.contains("apple.codec." + $0) &&
                  (capabilities.records["apple.codec." + $0] == nil || capabilities.records["apple.codec." + $0]?.state == .unknown)
              }) else { return capabilities }
        guard await AutomationPreparedCodecAuthority.shared.contains(prepared) else { return capabilities }
        try Task.checkCancellation()
        let developer = try AutomationPath.canonical(developerDirectory)
        let version = try plist(developer.deletingLastPathComponent().appendingPathComponent("version.plist"))
        guard version["ProductBuildVersion"] as? String == qualification.context.xcodeBuild else { return capabilities }
        let subject = URL(fileURLWithPath: prepared.host.subjectProductPath)
        let host = URL(fileURLWithPath: prepared.host.hostBundlePath)
        let tests = host.appendingPathComponent("PlugIns/" + prepared.host.testTarget + ".xctest")
        let subjectInfo = try plist(subject.appendingPathComponent("Info.plist"))
        let testInfo = try plist(tests.appendingPathComponent("Info.plist"))
        let hostInfo = try plist(host.appendingPathComponent("Info.plist"))
        guard [subjectInfo, testInfo].allSatisfy({
            $0["DTPlatformName"] as? String == "iphonesimulator" &&
            $0["DTXcodeBuild"] as? String == qualification.context.xcodeBuild &&
            $0["DTSDKBuild"] as? String == qualification.context.sdkBuild
        }), hostInfo["DTPlatformName"] as? String == "iphonesimulator" else { return capabilities }
        let framework = developer.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/AppIntentsTesting.framework/AppIntentsTesting")
        let frameworkBytes = try AutomationReadOnlyFile.read(framework.resolvingSymlinksInPath(), maximumBytes: 134_217_728)
        let inventory = try await command("/usr/bin/xcrun", ["simctl", "list", "--json"], developer, workspace)
        guard !inventory.logsTruncated, inventory.exitStatus == 0,
              let root = try JSONSerialization.jsonObject(with: inventory.stdout) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]],
              let runtimes = root["runtimes"] as? [[String: Any]] else {
            throw AutomationContractError.missingEvidence("Cannot inspect the selected simulator runtime for input conversion")
        }
        let matches = devices.filter { _, devices in devices.contains {
            $0["udid"] as? String == prepared.host.target.id && $0["isAvailable"] as? Bool == true
        } }
        guard matches.count == 1, let runtimeID = matches.keys.first else { return capabilities }
        let runtime = runtimes.filter { $0["identifier"] as? String == runtimeID && $0["isAvailable"] as? Bool == true }
        guard runtime.count == 1, let runtimeBuild = runtime[0]["buildversion"] as? String else { return capabilities }
        for product in [subject, host, tests] {
            guard try await verifiesSignature(product, developer: developer, workspace: workspace) else { return capabilities }
            let signature = try await command("/usr/bin/codesign", ["-dv", product.path], developer, workspace)
            let lines = Set(String(decoding: signature.stderr, as: UTF8.self).split(separator: "\n").map(String.init))
            guard signature.exitStatus == 0, !signature.logsTruncated,
                  lines.contains("Signature=adhoc"), lines.contains("TeamIdentifier=not set") else { return capabilities }
            let info = try plist(product.appendingPathComponent("Info.plist"))
            guard let executable = info["CFBundleExecutable"] as? String,
                  !executable.isEmpty, executable == URL(fileURLWithPath: executable).lastPathComponent else { return capabilities }
            let slices = try await command("/usr/bin/lipo", ["-archs", product.appendingPathComponent(executable).path], developer, workspace)
            guard slices.exitStatus == 0, !slices.logsTruncated,
                  supportsQualifiedArchitecture(String(decoding: slices.stdout, as: UTF8.self)) else { return capabilities }
        }
        guard try AutomationProductDigest.compute(bundle: subject, version: prepared.host.app.productDigestVersion) == prepared.host.app.productDigest,
              try AutomationProductDigest.compute(bundle: host) == prepared.host.hostProductDigest,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(URL(fileURLWithPath: prepared.host.xctestrunPath), maximumBytes: 4_194_304)) == prepared.host.xctestrunDigest else {
            throw AutomationContractError.conflictingOperation
        }
        let os = try plist(URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"))
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unqualified"
        #endif
        let context = Context(hostTemplate: prepared.generatedHost.templateDigest,
            macOSBuild: os["ProductBuildVersion"] as? String ?? "", architecture: architecture,
            xcodeBuild: version["ProductBuildVersion"] as? String ?? "",
            sdkBuild: testInfo["DTSDKBuild"] as? String ?? "", runnerBuild: hostInfo["DTXcodeBuild"] as? String ?? "",
            runtimeBuild: runtimeBuild, frameworkDigest: AutomationArtifactRegistry.digest(frameworkBytes), signing: "simulator-ad-hoc")
        try Task.checkCancellation()
        return applying(qualification, context: context, to: capabilities)
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
