#if DEBUG
import Foundation

/// Explicit isolated verification may read a credential that already exists.
/// Hosted tests remain unable to read the real Keychain even with this flag.
enum MCPDebugLaunchConfiguration {
    static let existingCredentialArgument = "--mcp-use-existing-credential"

    /// Checks for the explicit debug launch argument permitting use of an existing credential.
    static func requestsExistingCredential(arguments: [String]) -> Bool {
        arguments.contains(existingCredentialArgument)
    }

    /// Requires read-only credential/configuration access for isolated storage, hosted tests, or the
    /// explicit existing-credential flag.
    static func requiresReadOnlyAccess(
        arguments: [String], environment: [String: String], isolatedStorage: URL?
    ) -> Bool {
        isolatedStorage != nil || isHostedTest(environment)
            || requestsExistingCredential(arguments: arguments)
    }

    /// Allows loading the existing credential only when isolated storage and the explicit flag are
    /// present outside a hosted test.
    static func usesExistingCredential(
        arguments: [String], environment: [String: String], isolatedStorage: URL?
    ) -> Bool {
        isolatedStorage != nil && requestsExistingCredential(arguments: arguments)
            && !isHostedTest(environment)
    }

    /// Returns the normal credential store for ordinary launches or a read-only wrapper for
    /// isolated/test launches. The wrapper loads a real credential only for explicit isolated
    /// verification and rejects save/remove operations.
    static func credentialStore(
        arguments: [String], environment: [String: String], isolatedStorage: URL?,
        existing: MCPCredentialStore
    ) -> MCPCredentialStore {
        guard requiresReadOnlyAccess(arguments: arguments, environment: environment,
                                     isolatedStorage: isolatedStorage) else { return existing }
        let load: () throws -> String? = usesExistingCredential(
            arguments: arguments, environment: environment, isolatedStorage: isolatedStorage
        ) ? existing.load : { nil }
        return .init(load: load,
                     save: { _ in throw MCPSettingsAccessError.configurationReadOnly },
                     remove: { throw MCPSettingsAccessError.configurationReadOnly })
    }

    /// Recognizes hosted test launches by XCTest configuration or bundle environment keys.
    private static func isHostedTest(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}
#endif
