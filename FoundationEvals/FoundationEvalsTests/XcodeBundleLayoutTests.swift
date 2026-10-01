import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

struct XcodeBundleLayoutTests {
    @Test(arguments: BundleLayout.allCases)
    func productMetadataFingerprintSurvivesBuildDirectoryChanges(layout: BundleLayout) throws {
        let first = try BundleFixture(layout: layout)
        defer { first.remove() }
        let second = try BundleFixture(layout: layout)
        defer { second.remove() }

        #expect(first.paths.appBundleURL != second.paths.appBundleURL)
        #expect(XcodeTestExecutor.productMetadataDigest(products: first.paths)
            == XcodeTestExecutor.productMetadataDigest(products: second.paths))
    }

    @Test(arguments: BundleLayout.allCases)
    func nativeAndFlatProductsVerifyAndReuseConnection(layout: BundleLayout) async throws {
        let fixture = try BundleFixture(layout: layout)
        defer { fixture.remove() }
        let products = try await fixture.executor.verifyBuiltProducts(
            definition: fixture.definition, configuration: fixture.configuration, paths: fixture.paths
        )

        #expect(products.app.bundleIdentifier == fixture.definition.target.bundleIdentifier)
        #expect(products.test.bundleIdentifier == fixture.configuration.testBundleIdentifier)
        #expect(products.app.executableName == "FixtureExecutable")
        #expect(products.test.executableName == "FixtureTestsExecutable")
        #expect(products.app.sha256 == BundleFixture.digest(Data("app executable".utf8)))
        #expect(products.test.sha256 == BundleFixture.digest(Data("test executable".utf8)))
        let connection = try await fixture.connection()
        #expect(await fixture.executor.connectionMatches(
            connection, definition: fixture.definition, configuration: fixture.configuration
        ))
        #expect(await fixture.executor.connectionMatches(
            connection, definition: fixture.definition, configuration: fixture.configuration
        ))
    }

    @Test(arguments: BundleMutation.allCases)
    func nativeBundleChangesInvalidateVerifiedConnection(mutation: BundleMutation) async throws {
        let fixture = try BundleFixture(layout: .nativeMac)
        defer { fixture.remove() }
        let connection = try await fixture.connection()
        #expect(await fixture.executor.connectionMatches(
            connection, definition: fixture.definition, configuration: fixture.configuration
        ))
        try fixture.mutate(mutation)

        #expect(!(await fixture.executor.connectionMatches(
            connection, definition: fixture.definition, configuration: fixture.configuration
        )))
        switch mutation {
        case .appExecutable, .testExecutable:
            let products = try await fixture.executor.verifyBuiltProducts(
                definition: fixture.definition, configuration: fixture.configuration, paths: fixture.paths
            )
            if mutation == .appExecutable { #expect(products.app != connection.appProduct) }
            else { #expect(products.test != connection.testProduct) }
        case .declaration:
            #expect(try XcodeTestExecutor.buildInputsDigest(
                configuration: fixture.configuration, products: fixture.paths
            ) != connection.buildInputsDigest)
        default:
            #expect(try XcodeTestExecutor.buildInputsDigest(
                configuration: fixture.configuration, products: fixture.paths
            ) != connection.buildInputsDigest)
            #expect(XcodeTestExecutor.productMetadataDigest(products: fixture.paths) != connection.productMetadataDigest)
        }
    }

    @Test(arguments: [true, false])
    func nativeBundleRejectsChangedAppOrTestIdentifier(changeApp: Bool) async throws {
        let fixture = try BundleFixture(layout: .nativeMac)
        defer { fixture.remove() }
        let connection = try await fixture.connection()
        let bundle = changeApp ? fixture.paths.appBundleURL : fixture.paths.testBundleURL
        try fixture.writeInfo(
            bundle: bundle, identifier: "dev.example.WrongProduct",
            executable: changeApp ? "FixtureExecutable" : "FixtureTestsExecutable"
        )

        await #expect(throws: XcodeTestExecutorError.self) {
            _ = try await fixture.executor.verifyBuiltProducts(
                definition: fixture.definition, configuration: fixture.configuration, paths: fixture.paths
            )
        }
        #expect(!(await fixture.executor.connectionMatches(
            connection, definition: fixture.definition, configuration: fixture.configuration
        )))
    }

    @Test func nativeBundleReadsChangedExecutableNameWithoutCachedInfo() async throws {
        let fixture = try BundleFixture(layout: .nativeMac)
        defer { fixture.remove() }
        let connection = try await fixture.connection()
        try fixture.writeInfo(
            bundle: fixture.paths.appBundleURL, identifier: fixture.definition.target.bundleIdentifier,
            executable: "ReplacementExecutable"
        )
        try fixture.write(Data("replacement executable".utf8), to: fixture.layout.executableURL(
            bundle: fixture.paths.appBundleURL, name: "ReplacementExecutable"
        ))
        let products = try await fixture.executor.verifyBuiltProducts(
            definition: fixture.definition, configuration: fixture.configuration, paths: fixture.paths
        )

        #expect(products.app.executableName == "ReplacementExecutable")
        #expect(products.app.sha256 == BundleFixture.digest(Data("replacement executable".utf8)))
        #expect(!(await fixture.executor.connectionMatches(
            connection, definition: fixture.definition, configuration: fixture.configuration
        )))
    }

    @Test func nativeBundleDoesNotAcceptFlatExecutableOrDeclarationDecoys() async throws {
        let fixture = try BundleFixture(layout: .nativeMac)
        defer { fixture.remove() }
        let connection = try await fixture.connection()
        let declaration = fixture.layout.declarationURL(bundle: fixture.paths.testBundleURL)
        let originalDeclaration = try Data(contentsOf: declaration)
        try FileManager.default.removeItem(at: declaration)
        try fixture.write(originalDeclaration, to: fixture.paths.testBundleURL.appending(path: "IntentLabIntegration.json"))
        #expect(!(await fixture.executor.connectionMatches(
            connection, definition: fixture.definition, configuration: fixture.configuration
        )))

        let executable = fixture.layout.executableURL(bundle: fixture.paths.appBundleURL, name: "FixtureExecutable")
        try FileManager.default.removeItem(at: executable)
        try fixture.write(Data("app executable".utf8), to: fixture.paths.appBundleURL.appending(path: "FixtureExecutable"))
        await #expect(throws: XcodeTestExecutorError.self) {
            _ = try await fixture.executor.verifyBuiltProducts(
                definition: fixture.definition, configuration: fixture.configuration, paths: fixture.paths
            )
        }
    }
}

enum BundleLayout: CaseIterable, Sendable {
    case nativeMac, flatIOS

    func contentsURL(bundle: URL) -> URL {
        self == .nativeMac ? bundle.appending(path: "Contents") : bundle
    }

    func executableURL(bundle: URL, name: String) -> URL {
        let contents = contentsURL(bundle: bundle)
        return (self == .nativeMac ? contents.appending(path: "MacOS") : contents).appending(path: name)
    }

    func declarationURL(bundle: URL) -> URL {
        let contents = contentsURL(bundle: bundle)
        return (self == .nativeMac ? contents.appending(path: "Resources") : contents)
            .appending(path: "IntentLabIntegration.json")
    }
}

enum BundleMutation: CaseIterable, Sendable {
    case appInfo, testInfo, appSignature, testSignature, appProfile, testProfile
    case declaration, appExecutable, testExecutable
}

private struct BundleFixture {
    let root: URL
    let layout: BundleLayout
    let project: URL
    let configuration: XcodeTestConfiguration
    let definition: ScenarioDefinition
    let paths: XCTestRunProductPaths
    let executor: XcodeTestExecutor

    init(layout: BundleLayout) throws {
        self.layout = layout
        root = FileManager.default.temporaryDirectory.appending(path: "BundleLayout-\(UUID().uuidString)")
        project = root.appending(path: "Source/Fixture.xcodeproj")
        // Products are outside the source tree so source scanning cannot hide
        // missing product metadata or resource fingerprinting.
        let products = root.appending(path: "DerivedData/Build/Products")
        paths = .init(
            sourceURL: products.appending(path: "Fixture.xctestrun"),
            appBundleURL: products.appending(path: "Fixture.app"),
            testHostURL: products.appending(path: "FixtureUITests-Runner.app"),
            testBundleURL: products.appending(path: "FixtureUITests-Runner.app/PlugIns/FixtureUITests.xctest")
        )
        configuration = .init(
            containerPath: project.path, isWorkspace: false, scheme: "Fixture", testTarget: "FixtureUITests",
            testBundleIdentifier: "dev.example.FixtureUITests", destinationIdentifier: "mac-fixture",
            generatedResourceDirectory: root.appending(path: "Generated").path, xcodebuildPath: "/bin/echo",
            selectedTestProductID: "\(project.path)#TEST-TARGET"
        )
        let declaration = Data("{\"id\":\"fixture\",\"version\":\"1\"}".utf8)
        var scenario = ScenarioDefinition.starter()
        scenario.schemaVersion = ScenarioDefinition.reusableSchemaVersion
        scenario.target.bundleIdentifier = "dev.example.Fixture"
        scenario.target.projectPath = project.path
        scenario.target.testTarget = configuration.testTarget
        scenario.target.destinationIdentifier = configuration.destinationIdentifier
        scenario.goal = .init(requestText: "", languageCode: "", expectedBehavior: "")
        scenario.fixture = .init(id: "", version: "", digest: "", isSynthetic: false, preparationOperation: "", cleanupOperation: "")
        scenario.assertions = []
        scenario.directControl.outputFields = []
        scenario.coverage.appFeature = .notApplicable
        scenario.coverage.siri = .notApplicable
        scenario.purpose = .exploratory
        scenario.checkMode = .basic
        scenario.requiredClaims = [.executionCompleted]
        scenario.observationPlan = []
        scenario.integration = .init(id: "fixture", version: "1", digest: Self.digest(declaration))
        definition = try scenario.frozen()
        executor = XcodeTestExecutor(
            workDirectory: root.appending(path: "Executor"),
            persistence: ScenarioPersistence(rootDirectory: root.appending(path: "Persistence"))
        )
        try write(Data("project".utf8), to: project.appending(path: "project.pbxproj"))
        try write(Data("test run".utf8), to: paths.sourceURL)
        for (bundle, identifier, executable, bytes) in [
            (paths.appBundleURL, definition.target.bundleIdentifier, "FixtureExecutable", "app executable"),
            (paths.testBundleURL, configuration.testBundleIdentifier, "FixtureTestsExecutable", "test executable")
        ] {
            try writeInfo(bundle: bundle, identifier: identifier, executable: executable)
            try write(Data(bytes.utf8), to: layout.executableURL(bundle: bundle, name: executable))
            try write(Data("signature".utf8), to: layout.contentsURL(bundle: bundle).appending(path: "_CodeSignature/CodeResources"))
            let profile = layout == .nativeMac ? "embedded.provisionprofile" : "embedded.mobileprovision"
            try write(Data("profile".utf8), to: layout.contentsURL(bundle: bundle).appending(path: profile))
        }
        try write(declaration, to: layout.declarationURL(bundle: paths.testBundleURL))
    }

    func connection() async throws -> ScenarioVerifiedConnection {
        let products = try await executor.verifyBuiltProducts(definition: definition, configuration: configuration, paths: paths)
        return .init(
            receipt: .init(
                schemaVersion: 1, integration: try #require(definition.integration),
                targetBundleIdentifier: definition.target.bundleIdentifier, projectIdentity: project.lastPathComponent,
                targetIdentity: configuration.testTarget, testBundleIdentifier: configuration.testBundleIdentifier,
                harnessProtocol: ScenarioInvocationIdentity.reusableHarnessVersion, runnerPackageVersion: "fixture",
                capabilities: ScenarioHarnessCapabilities.required(for: definition).sorted(), inspectedAt: Date()
            ),
            configuration: configuration, appProduct: products.app, testProduct: products.test,
            appBundleURL: paths.appBundleURL, testBundleURL: paths.testBundleURL, testRunURL: paths.sourceURL,
            selectedTestProjectURL: project,
            buildInputsDigest: try XcodeTestExecutor.buildInputsDigest(configuration: configuration, products: paths),
            productMetadataDigest: XcodeTestExecutor.productMetadataDigest(products: paths)
        )
    }

    func mutate(_ mutation: BundleMutation) throws {
        switch mutation {
        case .appInfo, .testInfo:
            let app = mutation == .appInfo
            try writeInfo(
                bundle: app ? paths.appBundleURL : paths.testBundleURL,
                identifier: app ? definition.target.bundleIdentifier : configuration.testBundleIdentifier,
                executable: app ? "FixtureExecutable" : "FixtureTestsExecutable", version: "2"
            )
        case .appSignature, .testSignature, .appProfile, .testProfile:
            let app = mutation == .appSignature || mutation == .appProfile
            let signature = mutation == .appSignature || mutation == .testSignature
            let name = signature ? "_CodeSignature/CodeResources" : "embedded.provisionprofile"
            try write(Data("changed metadata".utf8), to: layout.contentsURL(
                bundle: app ? paths.appBundleURL : paths.testBundleURL
            ).appending(path: name))
        case .declaration:
            try write(Data("changed declaration".utf8), to: layout.declarationURL(bundle: paths.testBundleURL))
        case .appExecutable, .testExecutable:
            let app = mutation == .appExecutable
            try write(Data("changed executable".utf8), to: layout.executableURL(
                bundle: app ? paths.appBundleURL : paths.testBundleURL,
                name: app ? "FixtureExecutable" : "FixtureTestsExecutable"
            ))
        }
    }

    func writeInfo(bundle: URL, identifier: String, executable: String, version: String = "1") throws {
        try write(PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
            "CFBundlePackageType": bundle.pathExtension == "app" ? "APPL" : "BNDL", "CFBundleVersion": version
        ], format: .xml, options: 0), to: layout.contentsURL(bundle: bundle).appending(path: "Info.plist"))
    }

    func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
