import Foundation
import Testing
@testable import FoundationEvals

struct AppLaunchIsolationTests {
    private let support = URL(filePath: "/fixture/Application Support")
    private let temporary = URL(filePath: "/fixture/tmp")

    @Test func ordinaryLaunchKeepsDefaultStorage() {
        let value = AppLaunchIsolation.resolve(arguments: ["Intents"], environment: [:],
            applicationSupport: support, temporaryDirectory: temporary)
        #expect(!value.isHostedTest)
        #expect(value.storageDirectory == nil)
    }

    @Test func hostedTestsOverrideInheritedStorageArguments() throws {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath"] {
            let first = AppLaunchIsolation.resolve(arguments: ["Intents", "--evaluation-storage", support.path],
                environment: [key: "fixture"], applicationSupport: support, temporaryDirectory: temporary)
            let second = AppLaunchIsolation.resolve(arguments: [], environment: [key: "fixture"],
                applicationSupport: support, temporaryDirectory: temporary)
            #expect(first.isHostedTest)
            #expect(!first.shouldLaunchProductionWorker(requested: true))
            #expect(try #require(first.storageDirectory).path.hasPrefix(temporary.path + "/IntentsHostedTests/"))
            #expect(first.storageDirectory != second.storageDirectory)
        }
    }

    @Test func explicitVerificationStorageIsPreservedOutsideHostedTests() {
        let id = UUID()
        let named = AppLaunchIsolation.resolve(arguments: ["--evaluation-storage-name", id.uuidString],
            environment: [:], applicationSupport: support, temporaryDirectory: temporary)
        #expect(named.storageDirectory?.path == support.appending(path: "FoundationEvalsUITests/\(id.uuidString)").path)
        let explicit = AppLaunchIsolation.resolve(arguments: ["--evaluation-storage", temporary.path],
            environment: [:], applicationSupport: support, temporaryDirectory: temporary)
        #expect(explicit.storageDirectory?.path == temporary.path)
        let invalid = AppLaunchIsolation.resolve(arguments: ["--evaluation-storage", "relative"],
            environment: [:], applicationSupport: support, temporaryDirectory: temporary)
        #expect(invalid.storageDirectory == nil)
        #expect(invalid.shouldLaunchProductionWorker(requested: true))
        #expect(!invalid.shouldLaunchProductionWorker(requested: false))
    }

    #if !SWIFT_PACKAGE
    @MainActor @Test func hostedBootstrapLeavesNormalWorkspaceBytesUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = root.appending(path: "NormalWorkspace")
        try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: true)
        let sentinel = normal.appending(path: "workspace.json")
        let bytes = Data("preserve developer data".utf8)
        try bytes.write(to: sentinel)
        let configuration = AppLaunchIsolation.resolve(arguments: ["--evaluation-storage", normal.path],
            environment: ["XCTestBundlePath": "fixture"], applicationSupport: normal, temporaryDirectory: root)
        let isolated = try #require(configuration.storageDirectory)
        let store = EvaluationStore(supportDirectory: isolated)
        #expect(store.overviewStorageDirectory.standardizedFileURL == isolated.standardizedFileURL)
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: normal.path) == ["workspace.json"])
    }
    #endif
}
