#if DEBUG
import Foundation
import Testing
@testable import FoundationEvals

struct MCPDebugLaunchConfigurationTests {
    @MainActor
    @Test func explicitIsolatedModeLoadsExistingCredentialAndCannotChangeConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appending(path: "config.toml")
        let original = Data("model = \"fixture-model\"\n".utf8)
        try original.write(to: config)
        let suiteName = "MCPDebugLaunchConfigurationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(19_001, forKey: "mcp.server.port")
        defaults.set(Data("fixture-bookmark".utf8), forKey: "mcp.codex.configuration-directory-bookmark")
        let beforeDefaults = defaults.persistentDomain(forName: suiteName) ?? [:]
        var loads = 0
        var saves = 0
        var removes = 0
        var starts = 0
        var stops = 0
        let existing = MCPCredentialStore(load: {
            loads += 1
            return String(repeating: "A", count: 43)
        }, save: { _ in saves += 1 }, remove: { removes += 1 })
        let credentials = MCPDebugLaunchConfiguration.credentialStore(
            arguments: [MCPDebugLaunchConfiguration.existingCredentialArgument], environment: [:],
            isolatedStorage: root, existing: existing)
        let controller = MCPSettingsController(serverControl: .init(start: { configuration in
            #expect(configuration.port == CodexMCPConfiguration.defaultPort)
            starts += 1
        }, stop: { stops += 1 }), userDefaults: defaults, credentialStore: credentials,
            existingCredentialOnly: true, configurationDirectory: root)
        #expect(loads == 0)
        await controller.startServer()
        #expect(controller.serverState == .running)
        #expect(starts == 1)
        #expect(loads == 1)
        await controller.installOrUpdateCodex()
        await controller.removeFromCodex()
        await controller.copyManualConfiguration()
        controller.refreshInstallationState()
        #expect(saves == 0)
        #expect(removes == 0)
        #expect(stops == 0)
        #expect(loads == 1)
        #expect(try Data(contentsOf: config) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["config.toml"])
        #expect(NSDictionary(dictionary: beforeDefaults).isEqual(to: defaults.persistentDomain(forName: suiteName) ?? [:]))
        #expect(throws: MCPSettingsAccessError.self) { try credentials.save("unused") }
        #expect(throws: MCPSettingsAccessError.self) { try credentials.remove() }
        #expect(saves == 0)
        #expect(removes == 0)
    }

    @MainActor
    @Test func missingOrInvalidExistingCredentialNeverStartsOrCreatesOne() async throws {
        for saved in [nil, "invalid"] as [String?] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let config = root.appending(path: "config.toml")
            let original = Data("model = \"fixture-model\"\n".utf8)
            try original.write(to: config)
            let suiteName = "MCPDebugLaunchConfigurationTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var loads = 0
            var saves = 0
            var removes = 0
            var starts = 0
            let credentials = MCPDebugLaunchConfiguration.credentialStore(
                arguments: [MCPDebugLaunchConfiguration.existingCredentialArgument], environment: [:],
                isolatedStorage: root, existing: .init(load: { loads += 1; return saved },
                    save: { _ in saves += 1 }, remove: { removes += 1 }))
            let controller = MCPSettingsController(serverControl: .init(start: { _ in starts += 1 }, stop: {}),
                userDefaults: defaults, credentialStore: credentials, existingCredentialOnly: true,
                configurationDirectory: root)
            await controller.startServer()
            #expect(starts == 0)
            #expect(controller.serverState == .stopped)
            #expect(controller.notice != nil)
            #expect(loads == 1)
            #expect(saves == 0)
            #expect(removes == 0)
            #expect(try Data(contentsOf: config) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["config.toml"])
            #expect((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)
        }
    }

    @MainActor
    @Test func rejectedExplicitLaunchKeepsReadOnlyGateAndNeverLoadsCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appending(path: "config.toml")
        let original = Data("model = \"fixture-model\"\n".utf8)
        try original.write(to: config)
        let requests: [(URL?, [String: String])] = [
            (nil, [:]), (root, ["XCTestBundlePath": "fixture"]),
            (root, ["XCTestConfigurationFilePath": "fixture"])
        ]
        for (storage, environment) in requests {
            let suiteName = "MCPDebugLaunchConfigurationTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(19_001, forKey: "mcp.server.port")
            let before = defaults.persistentDomain(forName: suiteName) ?? [:]
            var loads = 0
            var saves = 0
            var removes = 0
            var starts = 0
            let arguments = [MCPDebugLaunchConfiguration.existingCredentialArgument]
            let credentials = MCPDebugLaunchConfiguration.credentialStore(arguments: arguments, environment: environment,
                isolatedStorage: storage, existing: .init(load: { loads += 1; return String(repeating: "A", count: 43) },
                    save: { _ in saves += 1 }, remove: { removes += 1 }))
            let controller = MCPSettingsController(serverControl: .init(start: { _ in starts += 1 }, stop: {}),
                userDefaults: defaults, credentialStore: credentials,
                existingCredentialOnly: MCPDebugLaunchConfiguration.requestsExistingCredential(arguments: arguments),
                configurationDirectory: root)
            await controller.startServer()
            await controller.installOrUpdateCodex()
            await controller.removeFromCodex()
            controller.refreshInstallationState()
            #expect(loads == 0)
            #expect(saves == 0)
            #expect(removes == 0)
            #expect(starts == 0)
            #expect(controller.serverState == .stopped)
            #expect(try Data(contentsOf: config) == original)
            #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suiteName) ?? [:]))
        }
    }

    @MainActor
    @Test func hostedTestsAndDefaultIsolationNeverLoadTheUsersCredential() throws {
        let root = URL(filePath: "/fixture-isolated-storage")
        var loads = 0
        let existing = MCPCredentialStore(load: { loads += 1; return String(repeating: "A", count: 43) },
            save: { _ in Issue.record("Unexpected save") }, remove: { Issue.record("Unexpected removal") })
        let flag = MCPDebugLaunchConfiguration.existingCredentialArgument
        #expect(!MCPDebugLaunchConfiguration.usesExistingCredential(arguments: [flag], environment: [:], isolatedStorage: nil))
        #expect(!MCPDebugLaunchConfiguration.usesExistingCredential(arguments: [], environment: [:], isolatedStorage: root))
        for environment in [["XCTestBundlePath": "fixture"], ["XCTestConfigurationFilePath": "fixture"]] {
            #expect(!MCPDebugLaunchConfiguration.usesExistingCredential(arguments: [flag], environment: environment, isolatedStorage: root))
            let credentials = MCPDebugLaunchConfiguration.credentialStore(arguments: [flag], environment: environment,
                isolatedStorage: root, existing: existing)
            #expect(try credentials.load() == nil)
        }
        let isolated = MCPDebugLaunchConfiguration.credentialStore(arguments: [], environment: [:], isolatedStorage: root, existing: existing)
        #expect(try isolated.load() == nil)
        let invalidLaunch = MCPDebugLaunchConfiguration.credentialStore(arguments: [flag], environment: [:],
            isolatedStorage: nil, existing: existing)
        #expect(MCPDebugLaunchConfiguration.requestsExistingCredential(arguments: [flag]))
        #expect(try invalidLaunch.load() == nil)
        #expect(throws: MCPSettingsAccessError.self) { try invalidLaunch.save("unused") }
        #expect(throws: MCPSettingsAccessError.self) { try invalidLaunch.remove() }
        #expect(loads == 0)
    }
}
#endif
