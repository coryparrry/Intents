import Foundation

enum XCTestRunInvocationTransportError: LocalizedError, Sendable {
    case testRunMissing
    case ambiguousTestRuns
    case unsupportedLayout
    case targetMissing(String)
    case ambiguousTarget(String)
    case productPathMissing(String)
    case productPathEscapesRoot(String)
    case payloadTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .testRunMissing:
            "Xcode did not produce an .xctestrun file for the selected scheme."
        case .ambiguousTestRuns:
            "More than one generated .xctestrun contains the selected UI-test target. Choose an explicit scheme or configuration."
        case .unsupportedLayout:
            "The generated .xctestrun uses an unsupported layout."
        case .targetMissing(let target):
            "The generated .xctestrun does not contain the \(target) UI-test target."
        case .ambiguousTarget(let target):
            "The generated .xctestrun contains more than one \(target) configuration."
        case .productPathMissing(let name):
            "The generated .xctestrun does not declare \(name)."
        case .productPathEscapesRoot(let path):
            "The generated test product path escapes the isolated build directory: \(path)"
        case .payloadTooLarge(let byteCount):
            "The frozen Intent Lab invocation is \(byteCount) bytes, above the 256 KiB transport limit."
        }
    }
}

struct XCTestRunProductPaths: Equatable, Sendable {
    var sourceURL: URL
    var appBundleURL: URL
    var testHostURL: URL
    var testBundleURL: URL
}

enum XCTestRunInvocationTransport {
    static let scenarioEnvironmentKey = "FOUNDATION_EVALS_INTENT_LAB_SCENARIO_B64"
    static let invocationEnvironmentKey = "FOUNDATION_EVALS_INTENT_LAB_INVOCATION_B64"
    static let maximumPayloadBytes = 256 * 1_024

    static func resolveProducts(
        derivedData: URL,
        testTarget: String,
        fileManager: FileManager = .default
    ) throws -> XCTestRunProductPaths {
        let products = derivedData.appending(path: "Build/Products", directoryHint: .isDirectory)
        let candidates = try fileManager.contentsOfDirectory(
            at: products,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "xctestrun" }

        var matches: [XCTestRunProductPaths] = []
        for candidate in candidates {
            guard let root = try propertyList(at: candidate),
                  let target = try matchingTarget(in: root, named: testTarget, requireMatch: false) else {
                continue
            }
            matches.append(try productPaths(from: target, testRunURL: candidate))
        }
        guard !matches.isEmpty else { throw XCTestRunInvocationTransportError.testRunMissing }
        guard matches.count == 1 else { throw XCTestRunInvocationTransportError.ambiguousTestRuns }
        return matches[0]
    }

    static func materialize(
        products: XCTestRunProductPaths,
        testTarget: String,
        definition: ScenarioDefinition,
        invocation: ScenarioInvocationIdentity,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard var root = try propertyList(at: products.sourceURL) else {
            throw XCTestRunInvocationTransportError.unsupportedLayout
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let scenarioData = try encoder.encode(definition)
        let invocationData = try encoder.encode(invocation)
        let payloadBytes = scenarioData.count + invocationData.count
        guard payloadBytes <= maximumPayloadBytes else {
            throw XCTestRunInvocationTransportError.payloadTooLarge(payloadBytes)
        }
        let injected = [
            scenarioEnvironmentKey: scenarioData.base64EncodedString(),
            invocationEnvironmentKey: invocationData.base64EncodedString(),
        ]
        try updateMatchingTarget(in: &root, named: testTarget) { target in
            var environment = target["EnvironmentVariables"] as? [String: Any] ?? [:]
            injected.forEach { environment[$0.key] = $0.value }
            target["EnvironmentVariables"] = environment
        }

        let outputURL = products.sourceURL.deletingLastPathComponent().appending(
            path: "IntentLab-\(invocation.id.uuidString).xctestrun"
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0
        )
        try data.write(to: outputURL, options: .withoutOverwriting)
        return outputURL
    }

    private static func propertyList(at url: URL) throws -> [String: Any]? {
        try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private static func productPaths(
        from target: [String: Any],
        testRunURL: URL
    ) throws -> XCTestRunProductPaths {
        let testRoot = testRunURL.deletingLastPathComponent().standardizedFileURL
        guard let appPath = target["UITargetAppPath"] as? String else {
            throw XCTestRunInvocationTransportError.productPathMissing("the app-under-test path")
        }
        guard let hostPath = target["TestHostPath"] as? String else {
            throw XCTestRunInvocationTransportError.productPathMissing("the UI-test runner path")
        }
        let testHost = try resolved(path: hostPath, testRoot: testRoot, testHost: nil)
        guard let bundlePath = target["TestBundlePath"] as? String else {
            throw XCTestRunInvocationTransportError.productPathMissing("the UI-test bundle path")
        }
        return .init(
            sourceURL: testRunURL,
            appBundleURL: try resolved(path: appPath, testRoot: testRoot, testHost: testHost),
            testHostURL: testHost,
            testBundleURL: try resolved(path: bundlePath, testRoot: testRoot, testHost: testHost)
        )
    }

    private static func resolved(path: String, testRoot: URL, testHost: URL?) throws -> URL {
        let expanded: String
        if path.hasPrefix("__TESTROOT__/") {
            expanded = testRoot.path + String(path.dropFirst("__TESTROOT__".count))
        } else if path == "__TESTROOT__" {
            expanded = testRoot.path
        } else if path.hasPrefix("__TESTHOST__/") {
            guard let testHost else {
                throw XCTestRunInvocationTransportError.productPathMissing(path)
            }
            expanded = testHost.path + String(path.dropFirst("__TESTHOST__".count))
        } else if path == "__TESTHOST__", let testHost {
            expanded = testHost.path
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            expanded = testRoot.appending(path: path).path
        }
        let url = URL(filePath: expanded).standardizedFileURL
        guard url.path == testRoot.path || url.path.hasPrefix(testRoot.path + "/") else {
            throw XCTestRunInvocationTransportError.productPathEscapesRoot(path)
        }
        return url
    }

    private static func matchingTarget(
        in root: [String: Any],
        named name: String,
        requireMatch: Bool
    ) throws -> [String: Any]? {
        let targets = targets(in: root).filter { targetMatches($0, name: name) }
        if targets.isEmpty {
            if requireMatch { throw XCTestRunInvocationTransportError.targetMissing(name) }
            return nil
        }
        guard targets.count == 1 else { throw XCTestRunInvocationTransportError.ambiguousTarget(name) }
        return targets[0]
    }

    private static func targets(in root: [String: Any]) -> [[String: Any]] {
        if let configurations = root["TestConfigurations"] as? [[String: Any]] {
            return configurations.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
        }
        return root.compactMap { key, value in
            guard key != "__xctestrun_metadata__" else { return nil }
            return value as? [String: Any]
        }
    }

    private static func targetMatches(_ target: [String: Any], name: String) -> Bool {
        target["BlueprintName"] as? String == name || target["ProductModuleName"] as? String == name
    }

    private static func updateMatchingTarget(
        in root: inout [String: Any],
        named name: String,
        update: (inout [String: Any]) -> Void
    ) throws {
        if var configurations = root["TestConfigurations"] as? [[String: Any]] {
            var matches: [(Int, Int)] = []
            for configurationIndex in configurations.indices {
                let testTargets = configurations[configurationIndex]["TestTargets"] as? [[String: Any]] ?? []
                for targetIndex in testTargets.indices where targetMatches(testTargets[targetIndex], name: name) {
                    matches.append((configurationIndex, targetIndex))
                }
            }
            guard !matches.isEmpty else { throw XCTestRunInvocationTransportError.targetMissing(name) }
            guard matches.count == 1 else { throw XCTestRunInvocationTransportError.ambiguousTarget(name) }
            let (configurationIndex, targetIndex) = matches[0]
            var testTargets = configurations[configurationIndex]["TestTargets"] as? [[String: Any]] ?? []
            update(&testTargets[targetIndex])
            configurations[configurationIndex]["TestTargets"] = testTargets
            root["TestConfigurations"] = configurations
            return
        }

        let matchingKeys = root.compactMap { key, value -> String? in
            guard key != "__xctestrun_metadata__",
                  let target = value as? [String: Any],
                  targetMatches(target, name: name) else { return nil }
            return key
        }
        guard !matchingKeys.isEmpty else { throw XCTestRunInvocationTransportError.targetMissing(name) }
        guard matchingKeys.count == 1, let key = matchingKeys.first,
              var target = root[key] as? [String: Any] else {
            throw XCTestRunInvocationTransportError.ambiguousTarget(name)
        }
        update(&target)
        root[key] = target
    }
}
