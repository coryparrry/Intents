import CryptoKit
import Foundation
import Testing
@testable import MacIntentTesting

/// Checks compatibility selection and certificate-team matching without accessing the user's keychain.
@MainActor struct SiriStudioSetupTests {
    /// Reads a synthetic public certificate; its private key is never stored in the repository.
    private func certificate() throws -> (pem: String, fingerprint: String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pem = try String(contentsOf: root.appending(path: "Fixtures/SiriStudio/SetupDevelopmentCertificate.pem"), encoding: .utf8)
        let encoded = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----")[1]
            .components(separatedBy: "-----END CERTIFICATE-----")[0]
        let bytes = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let fingerprint = Insecure.SHA1.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
        return (pem, fingerprint)
    }

    /// Uses certificate OU rather than the different identifier in the display name, and excludes unavailable private-key identities.
    @Test func certificateTeamAndValidIdentityAreRequired() throws {
        let cert = try certificate()
        let valid = "1) \(cert.fingerprint) \"Apple Development: Synthetic Developer (PERSON1234)\"\n1 valid identities found"
        let identities = SiriStudioSetupDiscovery.developmentIdentities(validOutput: valid, pem: cert.pem)
        #expect(identities.count == 1)
        #expect(identities.first?.team == "TEAM123456")
        #expect(identities.first?.fingerprint == cert.fingerprint)
        #expect(SiriStudioSetupDiscovery.developmentIdentities(validOutput: "0 valid identities found", pem: cert.pem).isEmpty)
        #expect(SiriStudioSetupDiscovery.developmentIdentities(validOutput: valid, pem: "malformed certificate").isEmpty)
    }

    /// Never chooses another app's team and selects a concrete fingerprint when development certificates share a name.
    @Test func signingSelectionMatchesAppTeamAndDisambiguatesNames() {
        let a = SiriStudioSigningIdentity(fingerprint: "AAAA", name: "Shared name", team: "TEAM-A")
        let b = SiriStudioSigningIdentity(fingerprint: "BBBB", name: "Shared name", team: "TEAM-A")
        let c = SiriStudioSigningIdentity(fingerprint: "CCCC", name: "Other team", team: "TEAM-B")
        #expect(SiriStudioSetupDiscovery.chooseIdentity([a,b,c], team: "TEAM-A", preferred: "bbbb") == b)
        #expect(SiriStudioSetupDiscovery.chooseIdentity([a,b,c], team: "TEAM-A", preferred: "CCCC") == a)
        #expect(SiriStudioSetupDiscovery.chooseIdentity([a,b,c], team: "TEAM-C", preferred: "") == nil)
        #expect(SiriStudioSetupDiscovery.chooseIdentity([a,b,c], team: nil, preferred: "") == nil)
    }

    /// Rejects old or incomplete Xcodes, resolves duplicate paths, and prefers a compatible selected or explicit installation.
    @Test func xcodeDiscoveryChecksVersionAndFramework() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try xcode("Old", version: "27.0", framework: true, root: root)
        let incomplete = try xcode("Incomplete", version: "27.3", framework: false, root: root)
        let beta = try xcode("Beta", version: "27.3", framework: true, root: root)
        let future = try xcode("Future", version: "28.0", framework: true, root: root)
        let found = SiriStudioSetupDiscovery.compatibleXcodes([old, incomplete, beta, beta, future], trusted: { _ in true })
        #expect(found.map(\.version) == ["28.0", "27.3"])
        #expect(SiriStudioSetupDiscovery.compatibleXcodes([beta]).isEmpty)
        #expect(SiriStudioSetupDiscovery.chooseXcode(found, preferred: old, selected: old)?.developerDirectory == future)
        #expect(SiriStudioSetupDiscovery.chooseXcode(found, preferred: old, selected: beta)?.developerDirectory == beta)
        #expect(SiriStudioSetupDiscovery.chooseXcode(found, preferred: future, selected: beta)?.developerDirectory == future)
    }

    /// Creates just the bundle metadata and executable markers needed to exercise discovery on isolated paths.
    private func xcode(_ name: String, version: String, framework: Bool, root: URL) throws -> String {
        let developer = root.appending(path: "\(name).app/Contents/Developer")
        let executable = developer.appending(path: "usr/bin/xcodebuild")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString":version], format: .xml, options: 0)
        try data.write(to: developer.deletingLastPathComponent().appending(path: "version.plist"))
        if framework {
            try FileManager.default.createDirectory(at: developer.appending(path: "Platforms/MacOSX.platform/Developer/Library/Frameworks/SiriEvaluations.framework"), withIntermediateDirectories: true)
        }
        return developer.resolvingSymlinksInPath().path
    }
}
