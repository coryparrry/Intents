import Foundation
import Testing
@testable import FoundationEvals

struct ExecutorSimplificationTests {
    @Test func stdoutProjectionsPreserveDifferentByteBounds() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "output")
        for count in [15_999, 16_000, 999_999, 1_000_000, 1_000_001] {
            let bytes = Data(repeating: 65, count: count)
            try bytes.write(to: output)
            let text = XcodeTestExecutor.commandOutput("/bin/cat", [output.path])
            let data = XcodeTestExecutor.commandData("/bin/cat", [output.path])
            #expect(text == (count < 16_000 ? String(decoding: bytes, as: UTF8.self) : nil))
            #expect(data == (count <= 1_000_000 ? bytes : nil))
        }
    }

    @Test func stdoutProjectionsPreserveEmptyLossyAndTrimmedOutput() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "output")
        for bytes in [Data(), Data(" \n\t".utf8), Data([32, 10, 0xFF, 65, 9, 10])] {
            try bytes.write(to: output)
            let expected = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(XcodeTestExecutor.commandOutput("/bin/cat", [output.path])
                    == (expected.isEmpty ? nil : expected))
            #expect(XcodeTestExecutor.commandData("/bin/cat", [output.path]) == bytes)
        }
    }

    @Test func stdoutProjectionsDiscardStderrAndRejectLaunchAndNonzeroFailures() {
        let command = "printf 'stdout'; printf 'stderr' >&2"
        #expect(XcodeTestExecutor.commandOutput("/bin/sh", ["-c", command]) == "stdout")
        #expect(XcodeTestExecutor.commandData("/bin/sh", ["-c", command]) == Data("stdout".utf8))
        #expect(XcodeTestExecutor.commandOutput("/bin/sh", ["-c", command + "; exit 9"]) == nil)
        #expect(XcodeTestExecutor.commandData("/bin/sh", ["-c", command + "; exit 9"]) == nil)
        #expect(XcodeTestExecutor.commandOutput("/intentlab-nonexistent-executable", []) == nil)
        #expect(XcodeTestExecutor.commandData("/intentlab-nonexistent-executable", []) == nil)
    }

    @Test func signingProjectionsRepeatStrictVerificationInOrderAndUseStderr() throws {
        let fixture = try SigningFixture()
        defer { fixture.remove() }
        try fixture.writeInspection(Data("TeamIdentifier= TEAM \nSignature=adhoc\n".utf8))
        #expect(XcodeTestExecutor.signingTeamIdentifier(of: fixture.bundle, codesignPath: fixture.executable.path) == "TEAM")
        #expect(XcodeTestExecutor.validAdHocSignature(of: fixture.bundle, codesignPath: fixture.executable.path))
        #expect(try fixture.commands() == [
            "--verify --strict \(fixture.bundle.path)", "-dv --verbose=4 \(fixture.bundle.path)",
            "--verify --strict \(fixture.bundle.path)", "-dv --verbose=4 \(fixture.bundle.path)"
        ])
    }

    @Test func signingProjectionsKeepExclusiveInspectionByteBound() throws {
        let fixture = try SigningFixture()
        defer { fixture.remove() }
        let header = Data("TeamIdentifier=TEAM\nSignature=adhoc\n".utf8)
        for count in [15_999, 16_000, 16_001] {
            try fixture.writeInspection(header + Data(repeating: 65, count: count - header.count))
            #expect(XcodeTestExecutor.signingTeamIdentifier(of: fixture.bundle, codesignPath: fixture.executable.path)
                    == (count < 16_000 ? "TEAM" : nil))
            #expect(XcodeTestExecutor.validAdHocSignature(of: fixture.bundle, codesignPath: fixture.executable.path)
                    == (count < 16_000))
        }
    }

    @Test func signingTeamKeepsFirstLineAndMissingOrNotSetPolicy() throws {
        let fixture = try SigningFixture()
        defer { fixture.remove() }
        for (inspection, expected) in [
            ("Signature=adhoc\n", nil), ("TeamIdentifier=\n", nil),
            ("TeamIdentifier= \t\n", nil), ("TeamIdentifier= not set \n", nil),
            ("TeamIdentifier=FIRST\nTeamIdentifier=SECOND\n", "FIRST"),
            ("TeamIdentifier=Not Set\n", "Not Set")
        ] as [(String, String?)] {
            try fixture.writeInspection(Data(inspection.utf8))
            #expect(XcodeTestExecutor.signingTeamIdentifier(of: fixture.bundle, codesignPath: fixture.executable.path) == expected)
        }
        try fixture.writeInspection(Data([0xFF, 10]) + Data("TeamIdentifier=TEAM\n".utf8))
        #expect(XcodeTestExecutor.signingTeamIdentifier(of: fixture.bundle, codesignPath: fixture.executable.path) == "TEAM")
    }

    @Test func signingAdHocMarkerRemainsExactAndEmptyInspectionIsRejected() throws {
        let fixture = try SigningFixture()
        defer { fixture.remove() }
        for inspection in ["", "Signature=adhoc ", " Signature=adhoc", "Signature=adhoc\r\n", "Signature=Adhoc"] {
            try fixture.writeInspection(Data(inspection.utf8))
            #expect(!XcodeTestExecutor.validAdHocSignature(of: fixture.bundle, codesignPath: fixture.executable.path))
        }
        try fixture.writeInspection(Data("\nSignature=adhoc\n\n".utf8))
        #expect(XcodeTestExecutor.validAdHocSignature(of: fixture.bundle, codesignPath: fixture.executable.path))
    }

    @Test func signingProjectionsStopAfterVerifyFailureAndRejectInspectionFailure() throws {
        let fixture = try SigningFixture()
        defer { fixture.remove() }
        try fixture.writeInspection(Data("TeamIdentifier=TEAM\nSignature=adhoc\n".utf8))
        try Data("7".utf8).write(to: fixture.verifyStatus)
        #expect(XcodeTestExecutor.signingTeamIdentifier(of: fixture.bundle, codesignPath: fixture.executable.path) == nil)
        #expect(!XcodeTestExecutor.validAdHocSignature(of: fixture.bundle, codesignPath: fixture.executable.path))
        #expect(try fixture.commands() == Array(repeating: "--verify --strict \(fixture.bundle.path)", count: 2))
        try Data("0".utf8).write(to: fixture.verifyStatus)
        try Data("8".utf8).write(to: fixture.inspectStatus)
        #expect(XcodeTestExecutor.signingTeamIdentifier(of: fixture.bundle, codesignPath: fixture.executable.path) == nil)
        #expect(!XcodeTestExecutor.validAdHocSignature(of: fixture.bundle, codesignPath: fixture.executable.path))
        #expect(try fixture.commands().count == 6)
    }

    @Test func signingProjectionsRejectVerifyAndInspectLaunchFailures() throws {
        let fixture = try SigningFixture()
        defer { fixture.remove() }
        #expect(XcodeTestExecutor.signingTeamIdentifier(of: fixture.bundle, codesignPath: "/intentlab-nonexistent-codesign") == nil)
        #expect(!XcodeTestExecutor.validAdHocSignature(of: fixture.bundle, codesignPath: "/intentlab-nonexistent-codesign"))
        for teamProjection in [true, false] {
            try fixture.installExecutable(deleteAfterVerify: true)
            if teamProjection {
                #expect(XcodeTestExecutor.signingTeamIdentifier(of: fixture.bundle, codesignPath: fixture.executable.path) == nil)
            } else {
                #expect(!XcodeTestExecutor.validAdHocSignature(of: fixture.bundle, codesignPath: fixture.executable.path))
            }
        }
        #expect(try fixture.commands() == Array(repeating: "--verify --strict \(fixture.bundle.path)", count: 2))
    }

    @Test func readinessPreservesSimulatorAndMatchingTeamPolicy() {
        var configuration = XcodeTestConfiguration(
            containerPath: "/Fixture.xcodeproj", isWorkspace: false, scheme: "Fixture", testTarget: "FixtureTests",
            testBundleIdentifier: "fixture.tests", destinationIdentifier: "device", generatedResourceDirectory: "/Resources"
        )
        configuration.destinationPlatform = .iOSSimulator
        #expect(XcodeTestExecutor.signingAcceptedForReadiness(
            configuration: configuration, runtimePlatform: .iOSSimulator,
            appTeam: nil, hostTeam: nil, testTeam: nil, adHocSignaturesValid: true
        ))
        for runtime in [IntentLabDestinationPlatform.iOS, .macOS, nil] {
            #expect(!XcodeTestExecutor.signingAcceptedForReadiness(
                configuration: configuration, runtimePlatform: runtime,
                appTeam: "TEAM", hostTeam: "TEAM", testTeam: "TEAM", adHocSignaturesValid: true
            ))
        }
        #expect(!XcodeTestExecutor.signingAcceptedForReadiness(
            configuration: configuration, runtimePlatform: .iOSSimulator,
            appTeam: "TEAM", hostTeam: "TEAM", testTeam: "TEAM", adHocSignaturesValid: false
        ))
        configuration.destinationPlatform = .iOS
        for (app, host, test, expected) in [
            ("TEAM", "TEAM", "TEAM", true), (nil, "TEAM", "TEAM", false),
            ("TEAM", nil, "TEAM", false), ("TEAM", "TEAM", nil, false),
            ("", "", "", false), ("TEAM", "OTHER", "TEAM", false), ("TEAM", "TEAM", "OTHER", false)
        ] as [(String?, String?, String?, Bool)] {
            #expect(XcodeTestExecutor.signingAcceptedForReadiness(
                configuration: configuration, runtimePlatform: .iOS,
                appTeam: app, hostTeam: host, testTeam: test, adHocSignaturesValid: true
            ) == expected)
        }
    }

    @Test func logTailMatchesPreviousByteAndLineProjection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "build.log")
        let fixtures = [
            Data(), Data("first\nlast".utf8), Data("\n\nfirst\n\nlast\n\n".utf8),
            Data("first\r\nsecond\r\nthird\r".utf8), Data("single line without newline".utf8),
            Data((0..<50).map { "line \($0)\n" }.joined().utf8),
            Data(repeating: 65, count: 50_000) + Data("\nlast\n".utf8),
            Data(repeating: 65, count: 8_001) + Data("😀é\nlast".utf8), Data([0xFF, 10, 65])
        ]
        for bytes in fixtures {
            try bytes.write(to: log)
            for bound in [0, 1, 2, 3, 8, 8_000] {
                let previous = String(decoding: bytes.suffix(bound), as: UTF8.self)
                    .split(separator: "\n").suffix(20).joined(separator: "\n")
                #expect(XcodeTestExecutor.tail(of: log, maximumBytes: bound) == previous)
            }
        }
    }

    @Test func logTailHandlesMissingUnreadableAndLargeSparseLogs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "build.log")
        #expect(XcodeTestExecutor.tail(of: log) == "See the retained build log.")
        #expect(XcodeTestExecutor.tail(of: root) == "See the retained build log.")
        try Data().write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: log.path)
        #expect(XcodeTestExecutor.tail(of: log) == "See the retained build log.")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seek(toOffset: 1_000_000_000)
        let suffix = Data(repeating: 65, count: 8_000)
        try handle.write(contentsOf: suffix)
        try handle.close()
        #expect(XcodeTestExecutor.tail(of: log) == String(decoding: suffix, as: UTF8.self))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ExecutorSimplification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct SigningFixture {
    let root: URL
    var executable: URL { root.appending(path: "codesign") }
    var bundle: URL { root.appending(path: "Fixture.app") }
    var verifyStatus: URL { root.appending(path: "verify-status") }
    var inspectStatus: URL { root.appending(path: "inspect-status") }
    private var inspection: URL { root.appending(path: "inspection") }
    private var commandLog: URL { root.appending(path: "commands") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ExecutorSigning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("0".utf8).write(to: verifyStatus)
        try Data("0".utf8).write(to: inspectStatus)
        try Data().write(to: inspection)
        try installExecutable()
    }

    func installExecutable(deleteAfterVerify: Bool = false) throws {
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(quote(commandLog.path))
        if [ "$1" = '--verify' ]; then
          \(deleteAfterVerify ? "/bin/rm \(quote(executable.path))" : ":")
          exit "$(/bin/cat \(quote(verifyStatus.path)))"
        fi
        printf 'TeamIdentifier=STDOUT-DECOY\\nSignature=adhoc\\n'
        /bin/cat \(quote(inspection.path)) >&2
        exit "$(/bin/cat \(quote(inspectStatus.path)))"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func writeInspection(_ data: Data) throws { try data.write(to: inspection) }
    func commands() throws -> [String] {
        try String(contentsOf: commandLog, encoding: .utf8).split(separator: "\n").map(String.init)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
