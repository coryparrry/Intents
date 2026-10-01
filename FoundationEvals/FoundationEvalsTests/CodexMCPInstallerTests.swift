import Foundation
import Testing
@testable import FoundationEvals

struct CodexMCPInstallerTests {
    @Test func managedInstallUpdateAndRemovalPreserveUnrelatedConfiguration() throws {
        let original = """
        # user setting
        model = "gpt-5"

        [features]
        shell_tool = true
        """ + "\n"
        let first = try CodexMCPInstaller.installing(
            configuration: CodexMCPConfiguration(port: 19_001),
            into: original
        )

        #expect(first.hasPrefix(original))
        #expect(first.components(separatedBy: CodexMCPInstaller.beginMarker).count == 2)
        #expect(first.contains("http://127.0.0.1:19001/mcp"))
        #expect(!first.contains("http_headers"))
        #expect(!first.contains("approval_mode"))

        let identical = try CodexMCPInstaller.installing(
            configuration: CodexMCPConfiguration(port: 19_001),
            into: first
        )
        #expect(identical == first)

        let updated = try CodexMCPInstaller.installing(
            configuration: CodexMCPConfiguration(),
            into: first
        )
        #expect(updated.hasPrefix(original))
        #expect(updated.contains("http://127.0.0.1:17873/mcp"))
        #expect(!updated.contains("http://127.0.0.1:19001/mcp"))

        let removed = try CodexMCPInstaller.removingManagedBlock(from: updated)
        #expect(removed == original)
    }

    @Test func unmanagedEquivalentEntriesAreRefusedAcrossSupportedTOMLLayouts() throws {
        let configuration = try CodexMCPConfiguration()
        let conflicts = [
            "[mcp_servers.foundation-evals]\nurl = \"http://example\"\n",
            "[mcp_servers]\nfoundation-evals = { url = \"http://example\" }\n",
            "mcp_servers.foundation-evals.url = \"http://example\"\n",
            "mcp_servers = { foundation-evals = { url = \"http://example\" } }\n",
            "[\"mcp_servers\".\"foundation-evals\"]\nurl = \"http://example\"\n",
        ]

        for conflict in conflicts {
            #expect(throws: CodexMCPInstallerError.conflictingConfiguration) {
                try CodexMCPInstaller.installing(configuration: configuration, into: conflict)
            }
        }

        let commented = "# [mcp_servers.foundation-evals]\nmodel = \"foundation-evals in a value\"\n"
        let installed = try CodexMCPInstaller.installing(configuration: configuration, into: commented)
        #expect(installed.hasPrefix(commented))
    }

    @Test func multilineStringsArePreservedDuringInstallation() throws {
        let original = #"""
        developer_instructions = """
        Keep [mcp_servers.foundation-evals], # signs, and { braces } inside this string.
        A quoted ending is valid here.""""
        literal_instructions = '''
        Keep [this.literal.table] inside the literal string too.
        '''
        """# + "\n"

        let installed = try CodexMCPInstaller.installing(
            configuration: CodexMCPConfiguration(),
            into: original
        )

        #expect(installed.hasPrefix(original))
        #expect(installed.contains(CodexMCPInstaller.beginMarker))
    }

    @Test func repeatedArrayTablesArePreservedDuringInstallation() throws {
        let original = """
        [[skills.config]]
        path = "first"
        enabled = true
        [[skills.config]]
        path = "second"
        enabled = false
        """ + "\n"

        let installed = try CodexMCPInstaller.installing(
            configuration: CodexMCPConfiguration(),
            into: original
        )

        #expect(installed.hasPrefix(original))
    }

    @Test func malformedConfigurationsAreLeftUntouched() throws {
        let configuration = try CodexMCPConfiguration()

        #expect(throws: CodexMCPInstallerError.malformedManagedBlock) {
            try CodexMCPInstaller.installing(
                configuration: configuration,
                into: CodexMCPInstaller.beginMarker + "\n"
            )
        }
        #expect(throws: CodexMCPInstallerError.malformedConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: "model = \"unterminated\n")
        }
        #expect(throws: CodexMCPInstallerError.malformedConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: "notes = \"\"\"unterminated\n")
        }
        #expect(throws: CodexMCPInstallerError.malformedConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: "model = nope nope\n")
        }
        #expect(throws: CodexMCPInstallerError.malformedConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: "model = \"one\"\nmodel = \"two\"\n")
        }
        #expect(throws: CodexMCPInstallerError.malformedConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: "[skills]\nname = \"one\"\n[[skills]]\nname = \"two\"\n")
        }
        #expect(throws: CodexMCPInstallerError.malformedConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: "[[skills]]\nname = \"one\"\n[skills]\nname = \"two\"\n")
        }
    }

    @Test func escapedQuotedKeyIsRefusedAsUnsupported() throws {
        let configuration = try CodexMCPConfiguration()
        let escapedConflict = "[\"mcp_servers\".\"foundation\\u002Devals\"]\nurl = \"http://example\"\n"

        #expect(throws: CodexMCPInstallerError.unsupportedConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: escapedConflict)
        }
    }

    @Test func filesystemInstallCreatesRestrictedBackupAndRoundTrips() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config.toml")
        let original = Data("model = \"gpt-5\"\n".utf8)
        try original.write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: configURL.path)

        let installer = CodexMCPInstaller()
        let configuration = try CodexMCPConfiguration()
        let installed = try installer.installOrUpdate(in: directory, configuration: configuration)

        #expect(installed.change == .installed)
        #expect(try installer.isInstalled(in: directory))
        #expect(installed.backupURL != nil)
        #expect(try Data(contentsOf: installed.backupURL!) == original)
        let backupMode = try fileMode(at: installed.backupURL!)
        #expect(backupMode == 0o600)
        #expect(try fileMode(at: configURL) == 0o640)

        let unchanged = try installer.installOrUpdate(in: directory, configuration: configuration)
        #expect(unchanged.change == .unchanged)

        let removed = try installer.remove(from: directory)
        #expect(removed.change == .removed)
        #expect(try Data(contentsOf: configURL) == original)
        #expect(!(try installer.isInstalled(in: directory)))
    }

    @Test func newConfigurationUsesOwnerOnlyPermissions() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appending(path: ".codex", directoryHint: .isDirectory)

        let receipt = try CodexMCPInstaller().installOrUpdate(
            in: directory,
            configuration: CodexMCPConfiguration()
        )

        #expect(receipt.change == .installed)
        #expect(receipt.backupURL == nil)
        #expect(try fileMode(at: directory) == 0o700)
        #expect(try fileMode(at: receipt.configURL) == 0o600)
    }

    @Test func symbolicConfigurationDirectoryIsRefused() throws {
        let parent = try temporaryDirectory()
        let outsideDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let directory = parent.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outsideDirectory)

        #expect(throws: CodexMCPInstallerError.unsafeFile) {
            try CodexMCPInstaller().installOrUpdate(
                in: directory,
                configuration: CodexMCPConfiguration()
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outsideDirectory.appending(path: "config.toml").path))
    }

    @Test func symbolicConfigTargetIsRefused() throws {
        let directory = try temporaryDirectory()
        let outsideDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let outside = outsideDirectory.appending(path: "outside.toml")
        let outsideData = Data("model = \"untouched\"\n".utf8)
        try outsideData.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "config.toml"),
            withDestinationURL: outside
        )

        #expect(throws: CodexMCPInstallerError.unsafeFile) {
            try CodexMCPInstaller().installOrUpdate(
                in: directory,
                configuration: CodexMCPConfiguration()
            )
        }
        #expect(try Data(contentsOf: outside) == outsideData)
    }

    @Test func concurrentConfigChangeIsNotOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config.toml")
        try Data("model = \"before\"\n".utf8).write(to: configURL)
        let concurrent = Data("model = \"changed elsewhere\"\n".utf8)
        let installer = CodexMCPInstaller { observedConfigURL in
            #expect(observedConfigURL == configURL)
            try concurrent.write(to: observedConfigURL, options: .atomic)
        }

        #expect(throws: CodexMCPInstallerError.concurrentModification) {
            try installer.installOrUpdate(
                in: directory,
                configuration: CodexMCPConfiguration()
            )
        }
        #expect(try Data(contentsOf: configURL) == concurrent)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CodexMCPInstallerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
