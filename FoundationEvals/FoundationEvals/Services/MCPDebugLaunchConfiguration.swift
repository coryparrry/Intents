#if DEBUG
import Foundation

/// Explicit isolated verification may read a credential that already exists.
/// Hosted tests remain unable to read the real Keychain even with this flag.
enum MCPDebugLaunchConfiguration {
    static let existingCredentialArgument = "--mcp-use-existing-credential"

    static func requestsExistingCredential(arguments: [String]) -> Bool {
        arguments.contains(existingCredentialArgument)
    }

    static func usesExistingCredential(
        arguments: [String], environment: [String: String], isolatedStorage: URL?
    ) -> Bool {
        isolatedStorage != nil && requestsExistingCredential(arguments: arguments)
            && !isHostedTest(environment)
    }

    static func credentialStore(
        arguments: [String], environment: [String: String], isolatedStorage: URL?,
        existing: MCPCredentialStore
    ) -> MCPCredentialStore {
        guard isolatedStorage != nil || isHostedTest(environment)
                || requestsExistingCredential(arguments: arguments) else { return existing }
        let load: () throws -> String? = usesExistingCredential(
            arguments: arguments, environment: environment, isolatedStorage: isolatedStorage
        ) ? existing.load : { nil }
        return .init(load: load,
                     save: { _ in throw MCPSettingsAccessError.configurationReadOnly },
                     remove: { throw MCPSettingsAccessError.configurationReadOnly })
    }

    private static func isHostedTest(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}
#endif
