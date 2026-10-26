import Foundation

/// Resolve storage before composing any store or service. Hosted tests always get
/// a fresh process workspace, including when a scheme inherits developer arguments.
struct AppLaunchIsolation: Sendable {
    let isHostedTest: Bool
    let storageDirectory: URL?

    /// Allows a requested production worker only outside a hosted XCTest process.
    func shouldLaunchProductionWorker(requested: Bool) -> Bool {
        requested && !isHostedTest
    }

    /// Resolves hosted-test isolation before UI-test storage arguments; returns nil storage for an ordinary launch.
    /// The supplied ID names a fresh hosted-test directory, and explicit storage paths must be absolute.
    static func resolve(arguments: [String], environment: [String: String],
                        applicationSupport: URL, temporaryDirectory: URL, id: UUID = UUID()) -> Self {
        let hosted = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
        if hosted {
            return Self(isHostedTest: true, storageDirectory: temporaryDirectory
                .appending(path: "IntentsHostedTests", directoryHint: .isDirectory)
                .appending(path: id.uuidString, directoryHint: .isDirectory))
        }
        if let index = arguments.firstIndex(of: "--evaluation-storage-name"),
           arguments.indices.contains(index + 1), let name = UUID(uuidString: arguments[index + 1]) {
            return Self(isHostedTest: false, storageDirectory: applicationSupport
                .appending(path: "FoundationEvalsUITests", directoryHint: .isDirectory)
                .appending(path: name.uuidString, directoryHint: .isDirectory))
        }
        if let index = arguments.firstIndex(of: "--evaluation-storage"),
           arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") {
            return Self(isHostedTest: false, storageDirectory: URL(filePath: arguments[index + 1], directoryHint: .isDirectory))
        }
        return Self(isHostedTest: false, storageDirectory: nil)
    }
}
