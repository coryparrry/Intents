import Foundation
import Testing
@testable import FoundationEvals

struct CodexMCPInstallerTests {
    /// Keeps LF and CRLF configuration byte-stable across install, inspection, repeated update, and removal.
    @Test(arguments: ["\n", "\r\n"])
    func managedLifecyclePreservesLineEndings(newline: String) throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let original = "# retained configuration" + newline + "model = 'custom'" + newline
        let installed = try CodexMCPInstaller.installing(configuration: configuration, into: original)
        let block = configuration.tomlBlock.replacingOccurrences(of: "\n", with: newline)
        #expect(installed == original + newline + block + newline)
        #expect(try CodexMCPInstaller.installing(configuration: configuration, into: installed) == installed)

        let changed = try CodexMCPConfiguration(port: 19_001, credential: testMCPCredential)
        let updated = try CodexMCPInstaller.installing(configuration: changed, into: installed)
        #expect(updated.components(separatedBy: "[mcp_servers.foundation-evals]").count == 2)
        #expect(updated.contains("http://127.0.0.1:19001/mcp"))
        #expect(try CodexMCPInstaller.removingManagedBlock(from: updated) == original)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.toml")
        try Data(installed.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try CodexMCPInstaller().isInstalled(in: directory))
        #expect(try CodexMCPInstaller().isInstalled(in: directory, matching: configuration))
        #expect(try !CodexMCPInstaller().isInstalled(in: directory, matching: changed))
    }

    /// Finds unmanaged server conflicts after CRLF comments without treating multiline marker examples as ownership.
    @Test func crlfConflictsAndMultilineMarkerExamplesUsePhysicalLines() throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let conflict = "# retained comment\r\n[mcp_servers.foundation-evals]\r\nurl = 'manual'\r\n"
        #expect(throws: CodexMCPInstallerError.conflictingConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: conflict)
        }
        let example = "notes = '''\r\n" + CodexMCPInstaller.beginMarker + "\r\n"
            + CodexMCPInstaller.endMarker + "\r\n'''\r\n"
        let installed = try CodexMCPInstaller.installing(configuration: configuration, into: example)
        #expect(installed.hasPrefix(example))
        #expect(try CodexMCPInstaller.removingManagedBlock(from: installed) == example)
    }

    /// Refuses unmanaged settings extending the managed section without changing their scope, bytes, or backups.
    @Test(arguments: ["http_headers = { Authorization = 'Bearer synthetic' }", "startup_timeout_sec = 30"])
    func unmanagedManagedSectionTailIsPreservedByRefusal(setting: String) throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let legacy = CodexMCPInstaller.beginMarker + "\n[mcp_servers.foundation-evals]\n"
            + "url = 'http://127.0.0.1:19001/mcp'\n" + CodexMCPInstaller.endMarker + "\n"
            + "# independently maintained setting\n" + setting + "\n"
        #expect(throws: CodexMCPInstallerError.conflictingConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: legacy)
        }
        #expect(throws: CodexMCPInstallerError.conflictingConfiguration) {
            try CodexMCPInstaller.removingManagedBlock(from: legacy)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.toml")
        let originalBytes = Data(legacy.utf8)
        try originalBytes.write(to: file)
        #expect(throws: CodexMCPInstallerError.conflictingConfiguration) {
            try CodexMCPInstaller().installOrUpdate(in: directory, configuration: configuration)
        }
        #expect(try Data(contentsOf: file) == originalBytes)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "config.toml.foundation-evals.backup").path
        ))
    }

    /// Preserves unmanaged sibling tables following the managed block when updating or removing its entry.
    @Test func unmanagedTableAfterManagedBlockRetainsItsScope() throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let sibling = "# retained sibling\n[mcp_servers.other]\nhttp_headers = { Example = 'retained' }\n"
        let original = configuration.tomlBlock + "\n" + sibling
        let changed = try CodexMCPConfiguration(port: 19_001, credential: testMCPCredential)
        let updated = try CodexMCPInstaller.installing(configuration: changed, into: original)
        #expect(updated.hasSuffix(sibling))
        #expect(try CodexMCPInstaller.removingManagedBlock(from: updated) == sibling)
    }

    @Test func managedInstallUpdateAndRemovalPreserveUnrelatedConfiguration() throws {
        let original = """
        # user setting
        model = "gpt-5"

        [features]
        shell_tool = true
        """ + "\n"
        let first = try CodexMCPInstaller.installing(
            configuration: CodexMCPConfiguration(port: 19_001, credential: testMCPCredential),
            into: original
        )

        #expect(first.hasPrefix(original))
        #expect(first.components(separatedBy: CodexMCPInstaller.beginMarker).count == 2)
        #expect(first.contains("http://127.0.0.1:19001/mcp"))
        #expect(first.contains("http_headers = { Authorization = \"Bearer \(testMCPCredential)\" }"))
        #expect(!first.contains("approval_mode"))

        let identical = try CodexMCPInstaller.installing(
            configuration: CodexMCPConfiguration(port: 19_001, credential: testMCPCredential),
            into: first
        )
        #expect(identical == first)

        let updated = try CodexMCPInstaller.installing(
            configuration: CodexMCPConfiguration(credential: testMCPCredential),
            into: first
        )
        #expect(updated.hasPrefix(original))
        #expect(updated.contains("http://127.0.0.1:17873/mcp"))
        #expect(!updated.contains("http://127.0.0.1:19001/mcp"))

        let removed = try CodexMCPInstaller.removingManagedBlock(from: updated)
        #expect(removed == original)
    }

    @Test func unmanagedEquivalentEntriesAreRefusedAcrossSupportedTOMLLayouts() throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let conflicts = [
            "[mcp_servers.foundation-evals]\nurl = \"http://example\"\n",
            "[mcp_servers]\nfoundation-evals = { url = \"http://example\" }\n",
            "mcp_servers.foundation-evals.url = \"http://example\"\n",
            "mcp_servers = { foundation-evals = { url = \"http://example\" } }\n",
            "[\"mcp_servers\".\"foundation-evals\"]\nurl = \"http://example\"\n",
            "[mcp_servers.'foundation-evals'.http_headers]\nAuthorization = 'example'\n",
            "'mcp_servers'.\"foundation-evals\".url = 'http://example'\n",
            "[[mcp_servers.foundation-evals]]\nurl = 'http://example'\n",
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

    /// Verifies structural failures precede deferred conflicts, while valid input retains the first
    /// installation error. Every rejected filesystem update must preserve its exact original bytes.
    @Test(arguments: [
        ("model = 'one'\nmodel = 'two'\n[mcp_servers.foundation-evals]\n", CodexMCPInstallerError.malformedConfiguration),
        ("[mcp_servers.foundation-evals]\nurl = 'one'\nurl = 'two'\n", .malformedConfiguration),
        ("[skills]\n[skills]\n[mcp_servers.foundation-evals]\n", .malformedConfiguration),
        ("[mcp_servers.foundation-evals]\n[skills]\n[skills]\n", .malformedConfiguration),
        ("[skills.]\n[mcp_servers.foundation-evals]\n", .malformedConfiguration),
        ("[mcp_servers.foundation-evals]\n[skills.]\n", .malformedConfiguration),
        ("[mcp_servers.foundation-evals]\n[skills]\n[[skills]]\n", .malformedConfiguration),
        ("[[mcp_servers.foundation-evals]]\n[skills]\nvalue = nope nope\n", .malformedConfiguration),
        ("'mcp_servers'.\"foundation-evals\".url = 'example'\nmodel = 'one'\nmodel = 'two'\n", .malformedConfiguration),
        ("mcp_servers = { other = {} }\n[skills]\n[skills]\n", .malformedConfiguration),
        ("[skills]\n[skills]\n[mcp_servers]\nfoundation-evals = {}\n", .malformedConfiguration),
        ("[mcp_servers.foundation-evals]\n[\"escaped\\u002Dkey\"]\n", .unsupportedConfiguration),
        ("[\"escaped\\u002Dkey\"]\n[mcp_servers.foundation-evals]\n", .unsupportedConfiguration),
        ("mcp_servers.foundation-evals.url = 'example'\nmcp_servers = { other = {} }\n", .conflictingConfiguration),
        ("mcp_servers = { other = {} }\nmcp_servers.foundation-evals.url = 'example'\n", .unsupportedConfiguration),
    ])
    func installationInspectionPreservesFailurePrecedenceAndBytes(
        original: String,
        expectedError: CodexMCPInstallerError
    ) throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        #expect(throws: expectedError) {
            try CodexMCPInstaller.installing(configuration: configuration, into: original)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config.toml")
        let originalBytes = Data(original.utf8)
        try originalBytes.write(to: configURL)

        #expect(throws: expectedError) {
            try CodexMCPInstaller().installOrUpdate(in: directory, configuration: configuration)
        }
        #expect(try Data(contentsOf: configURL) == originalBytes)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "config.toml.foundation-evals.backup").path
        ))
    }

    /// Checks install, replacement, and removal preserve supported unmanaged bytes, including marker
    /// text in multiline values and quoted or repeated table layouts.
    @Test(arguments: [
        "# retained café setting  \nmodel  =  'custom' # retained comment\n",
        "[\"mcp_servers\".'other.server']\nurl = 'http://example.invalid/mcp'\n",
        "[[skills.config]]\npath = 'first'\n[[skills.config]]\npath = 'second'\n",
        "notes = \"\"\"\n# BEGIN FOUNDATION EVALS MANAGED MCP\n[mcp_servers.foundation-evals]\n# END FOUNDATION EVALS MANAGED MCP\n\"\"\"\n",
        "notes = '''\n# BEGIN FOUNDATION EVALS MANAGED MCP\n[mcp_servers.foundation-evals]\n# END FOUNDATION EVALS MANAGED MCP\n'''\n",
    ])
    func installationInspectionPreservesSupportedUnmanagedBytes(original: String) throws {
        let firstConfiguration = try CodexMCPConfiguration(port: 19_001, credential: testMCPCredential)
        let updatedConfiguration = try CodexMCPConfiguration(credential: testMCPCredential)
        let installed = try CodexMCPInstaller.installing(configuration: firstConfiguration, into: original)
        let updated = try CodexMCPInstaller.installing(configuration: updatedConfiguration, into: installed)

        #expect(Data(installed.utf8).starts(with: Data(original.utf8)))
        #expect(Data(updated.utf8).starts(with: Data(original.utf8)))
        #expect(try Data(CodexMCPInstaller.removingManagedBlock(from: updated).utf8) == Data(original.utf8))
    }

    /// Ensures removal validates structure without rejecting unmanaged entries that prevent installs.
    @Test(arguments: [
        "mcp_servers = { other = {} }\n",
        "mcp_servers = { 'foundation-evals' = {} }\n",
        "[mcp_servers.foundation-evals]\nurl = 'example'\n",
    ])
    func removalIgnoresDeferredInstallationErrors(unmanaged: String) throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let original = unmanaged + "\n" + configuration.tomlBlock + "\n"

        #expect(try CodexMCPInstaller.removingManagedBlock(from: original) == unmanaged)
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
            configuration: CodexMCPConfiguration(credential: testMCPCredential),
            into: original
        )

        #expect(installed.hasPrefix(original))
        #expect(installed.contains(CodexMCPInstaller.beginMarker))
    }

    @Test(arguments: ["\"\"\"", "'''"])
    func managedMarkersInsideMultilineStringsArePreserved(delimiter: String) throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let original = "developer_instructions = \(delimiter)\nKeep this example:\n"
            + configuration.tomlBlock + "\nEnd example.\n\(delimiter)\n"
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config.toml")
        try Data(original.utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        let installer = CodexMCPInstaller()

        #expect(!(try installer.isInstalled(in: directory)))
        #expect(!(try installer.isInstalled(in: directory, matching: configuration)))
        #expect(try CodexMCPInstaller.removingManagedBlock(from: original) == original)
        let updated = try CodexMCPInstaller.installing(configuration: configuration, into: original)
        #expect(updated.hasPrefix(original))
        #expect(updated.hasSuffix(configuration.tomlBlock + "\n"))
        #expect(try CodexMCPInstaller.removingManagedBlock(from: updated) == original)
    }

    @Test(arguments: [1, 2])
    func managedMarkersInsideArraysArePreserved(depth: Int) throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let original = "tools = " + String(repeating: "[", count: depth) + "\n"
            + CodexMCPInstaller.beginMarker + "\n\"retained-tool\",\n"
            + CodexMCPInstaller.endMarker + "\n" + String(repeating: "]", count: depth) + "\n"
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config.toml")
        try Data(original.utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        let installer = CodexMCPInstaller()

        #expect(!(try installer.isInstalled(in: directory)))
        #expect(!(try installer.isInstalled(in: directory, matching: configuration)))
        #expect(try CodexMCPInstaller.removingManagedBlock(from: original) == original)
        let updated = try CodexMCPInstaller.installing(configuration: configuration, into: original)
        #expect(updated.hasPrefix(original))
        #expect(updated.hasSuffix(configuration.tomlBlock + "\n"))
        #expect(try CodexMCPInstaller.removingManagedBlock(from: updated) == original)

        try Data(updated.utf8).write(to: configURL)
        #expect(try installer.isInstalled(in: directory))
        #expect(try installer.isInstalled(in: directory, matching: configuration))
    }

    @Test(arguments: ["mcp_servers", "\"mcp_servers\"", "'mcp_servers'"])
    func inlineMCPNamespaceIsRefusedWithoutChangingTheFile(key: String) throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let original = "\(key) = { other = { url = \"http://example.invalid/mcp\" } }\n"
        #expect(throws: CodexMCPInstallerError.unsupportedConfiguration) {
            try CodexMCPInstaller.installing(configuration: configuration, into: original)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config.toml")
        try Data(original.utf8).write(to: configURL)

        #expect(throws: CodexMCPInstallerError.unsupportedConfiguration) {
            try CodexMCPInstaller().installOrUpdate(in: directory, configuration: configuration)
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "config.toml.foundation-evals.backup").path
        ))
    }

    @Test(arguments: [
        "mcp_servers.other = { url = \"http://example.invalid/mcp\" }\n",
        "\"mcp_servers\".'other.server' = { url = \"http://example.invalid/mcp\" }\n",
        "[mcp_servers.other]\nurl = \"http://example.invalid/mcp\"\n",
    ])
    func siblingMCPEntriesRemainSupported(original: String) throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let updated = try CodexMCPInstaller.installing(configuration: configuration, into: original)
        #expect(updated.hasPrefix(original))
        #expect(try CodexMCPInstaller.removingManagedBlock(from: updated) == original)
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
            configuration: CodexMCPConfiguration(credential: testMCPCredential),
            into: original
        )

        #expect(installed.hasPrefix(original))
    }

    @Test func malformedConfigurationsAreLeftUntouched() throws {
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)

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
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
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
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        let installed = try installer.installOrUpdate(in: directory, configuration: configuration)

        #expect(installed.change == .installed)
        #expect(try installer.isInstalled(in: directory))
        #expect(installed.backupURL != nil)
        #expect(try Data(contentsOf: installed.backupURL!) == original)
        let backupMode = try fileMode(at: installed.backupURL!)
        #expect(backupMode == 0o600)
        #expect(try fileMode(at: configURL) == 0o600)
        #expect(try installer.isInstalled(in: directory, matching: configuration))

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
            configuration: CodexMCPConfiguration(credential: testMCPCredential)
        )

        #expect(receipt.change == .installed)
        #expect(receipt.backupURL == nil)
        #expect(try fileMode(at: directory) == 0o700)
        #expect(try fileMode(at: receipt.configURL) == 0o600)
    }

    @Test func oldOrLooseManagedConfigurationRequiresRepair() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config.toml")
        let legacy = """
        \(CodexMCPInstaller.beginMarker)
        [mcp_servers.foundation-evals]
        url = "http://127.0.0.1:17873/mcp"
        \(CodexMCPInstaller.endMarker)
        """ + "\n"
        try Data(legacy.utf8).write(to: configURL)
        let installer = CodexMCPInstaller()
        let configuration = try CodexMCPConfiguration(credential: testMCPCredential)
        #expect(try installer.isInstalled(in: directory))
        #expect(!(try installer.isInstalled(in: directory, matching: configuration)))

        _ = try installer.installOrUpdate(in: directory, configuration: configuration)
        #expect(try installer.isInstalled(in: directory, matching: configuration))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: configURL.path)
        #expect(!(try installer.isInstalled(in: directory, matching: configuration)))
        _ = try installer.installOrUpdate(in: directory, configuration: configuration)
        #expect(try fileMode(at: configURL) == 0o600)
    }

    @Test func credentialStoreGeneratesAStablePerInstallSecret() throws {
        final class MemoryStorage {
            var value: String?
        }
        let storage = MemoryStorage()
        let store = MCPCredentialStore(
            load: { storage.value },
            save: { storage.value = $0 },
            remove: { storage.value = nil }
        )
        let first = try store.loadOrCreate()
        #expect(first.count == 43)
        #expect(try CodexMCPConfiguration(credential: first).credential == first)
        #expect(try store.loadOrCreate() == first)
        try store.remove()
        let second = try store.loadOrCreate()
        #expect(second != first)
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
                configuration: CodexMCPConfiguration(credential: testMCPCredential)
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
                configuration: CodexMCPConfiguration(credential: testMCPCredential)
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
                configuration: CodexMCPConfiguration(credential: testMCPCredential)
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

private let testMCPCredential = String(repeating: "A", count: 43)
