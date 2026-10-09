#if os(macOS)
import Foundation
import Darwin

/// Independent disk/kernel validation. This value is not capability authority.
struct AutomationMacAppleRuntimeSnapshot: Equatable, Sendable {
    let observation: AutomationAppleRuntimeObservation
    let developerDirectory: URL
    let xcodeVersionDigest: String, sdkVersionDigest: String, hostInfoDigest: String

    static func observe(host: AutomationPreparedAppleHost, developerDirectory: URL,
                        observation: AutomationAppleRuntimeObservation) throws -> Self {
        guard host.target.kind == .nativeMac, host.app.platform == "macos", host.hostProductDigestVersion == 2,
              host.app.productDigestVersion == 2 else { throw AutomationContractError.invalidIdentity }
        try AutomationMacGUIIdentity.validate(host.target)
        try validatePreparedArtifacts(host)
        let developer = try AutomationPath.canonical(developerDirectory)
        guard developer == developerDirectory, observation.processOSBuild == (try kernelBuild()),
              observation.processOSVersion == ProcessInfo.processInfo.operatingSystemVersionString else {
            throw AutomationContractError.conflictingOperation
        }
        let framework = try AutomationPath.canonical(developer.appendingPathComponent(
            "Platforms/MacOSX.platform/Developer/Library/Frameworks/AppIntentsTesting.framework/AppIntentsTesting"))
        guard framework.path.hasPrefix(developer.path + "/"), framework.path == observation.frameworkPath else {
            throw AutomationContractError.conflictingOperation
        }
        let frameworkData = try AutomationReadOnlyFile.read(framework, maximumBytes: 134_217_728)
        guard AutomationArtifactRegistry.digest(frameworkData) == observation.frameworkSHA256,
              try AutomationMachOLoadedImageIdentity.images(in: frameworkData).filter({
                  $0.cpu == observation.frameworkCPUType && $0.subtype == observation.frameworkCPUSubtype
              }) == [.init(uuid: observation.frameworkUUID, cpu: observation.frameworkCPUType, subtype: observation.frameworkCPUSubtype)] else {
            throw AutomationContractError.conflictingOperation
        }
        let executable = try AutomationMacAssociatedHostReleaseVerifier.profile(host).executable
        let hostData = try AutomationReadOnlyFile.read(executable, maximumBytes: 134_217_728)
        guard try AutomationMachOLoadedImageIdentity.images(in: hostData).contains(where: { $0.cpu == observation.frameworkCPUType }),
              host.app.architecture == nil || host.app.architecture == observation.architecture else {
            throw AutomationContractError.conflictingOperation
        }
        let hostInfo = try AutomationProductDigest.readFile(bundle: URL(fileURLWithPath: host.hostBundlePath),
            relativePath: "Contents/Info.plist", maximumBytes: 1_048_576, version: 2, expectedDigest: host.hostProductDigest)
        let hostFields = try plist(hostInfo)
        guard hostFields["DTPlatformName"] as? String == observation.sdkPlatform,
              hostFields["DTXcodeBuild"] as? String == observation.xcodeBuild,
              hostFields["DTSDKBuild"] as? String == observation.sdkBuild else { throw AutomationContractError.conflictingOperation }
        let xcodeVersion = try AutomationReadOnlyFile.read(developer.deletingLastPathComponent().appendingPathComponent("version.plist"), maximumBytes: 1_048_576)
        let sdkFile = try AutomationPath.canonical(developer.appendingPathComponent(
            "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/CoreServices/SystemVersion.plist"))
        guard sdkFile.path.hasPrefix(developer.path + "/") else { throw AutomationContractError.invalidIdentity }
        let sdkVersion = try AutomationReadOnlyFile.read(sdkFile, maximumBytes: 1_048_576)
        guard try plist(xcodeVersion)["ProductBuildVersion"] as? String == observation.xcodeBuild,
              try plist(sdkVersion)["ProductBuildVersion"] as? String == observation.sdkBuild else {
            throw AutomationContractError.conflictingOperation
        }
        return .init(observation: observation, developerDirectory: developer,
            xcodeVersionDigest: AutomationArtifactRegistry.digest(xcodeVersion), sdkVersionDigest: AutomationArtifactRegistry.digest(sdkVersion),
            hostInfoDigest: AutomationArtifactRegistry.digest(hostInfo))
    }
    func validate(host: AutomationPreparedAppleHost) throws {
        guard try Self.observe(host: host, developerDirectory: developerDirectory, observation: observation) == self else {
            throw AutomationContractError.conflictingOperation
        }
    }
    static func kernelBuild() throws -> String {
        var bytes = [CChar](repeating: 0, count: 256), count = 256
        guard sysctlbyname("kern.osversion", &bytes, &count, nil, 0) == 0, count > 1, count <= bytes.count,
              bytes[count - 1] == 0, let result = String(validating: bytes.prefix(count - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self), !result.isEmpty else {
            throw AutomationContractError.missingEvidence("Mac kernel build is unavailable")
        }
        return result
    }
    static func validatePreparedArtifacts(_ host: AutomationPreparedAppleHost) throws {
        let subject = URL(fileURLWithPath: host.subjectProductPath), test = URL(fileURLWithPath: host.xctestrunPath)
        guard try AutomationPath.canonical(subject) == subject,
              try AutomationProductDigest.compute(bundle: subject, version: 2) == host.app.productDigest,
              try AutomationPath.canonical(test) == test,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(test, maximumBytes: 4_194_304)) == host.xctestrunDigest else {
            throw AutomationContractError.conflictingOperation
        }
        _ = try AutomationMacAssociatedHostReleaseVerifier.profile(host)
    }
    private static func plist(_ data: Data) throws -> [String: Any] {
        guard let fields = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AutomationContractError.invalidIdentity
        }
        return fields
    }
}
#endif
