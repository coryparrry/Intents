import Foundation
@testable import IntentsAutomationCore

/// Authored throwaway source only; never consumes an arbitrary project or intent.
enum AutomationMacInputProbeFixture {
    struct Fixture { let project: URL; let targetID: String; let projectData: Data }
    enum SourceKind { case host, input, nestedArrays }
    static let hostSource = """
    import SwiftUI
    import AppIntents
    @main struct SubjectApp: App {
        var body: some Scene { WindowGroup { Text("Mac associated host fixture") } }
    }
    struct HostProbeIntent: AppIntent {
        static let title: LocalizedStringResource = "Host probe"
        func perform() async throws -> some IntentResult { .result() }
    }
    """
    static let source = """
    import SwiftUI
    import AppIntents
    @main struct SubjectApp: App {
        var body: some Scene { WindowGroup { Text("Intents input adapter fixture") } }
    }
    struct HostProbeIntent: AppIntent {
        static let title: LocalizedStringResource = "Host input probe"
        static let openAppWhenRun = false
        @Parameter(title: "Sample") var sample: String
        func perform() async throws -> some IntentResult {
            try rejectBusinessDispatch()
            return .result()
        }
        private func rejectBusinessDispatch() throws { throw ProbePerformForbidden() }
    }
    struct ProbePerformForbidden: Error {}
    """
    static let nestedSource = source.replacingOccurrences(of: "@Parameter(title: \"Sample\") var sample: String", with: """
    @Parameter(title: "Texts") var texts: [[String]]
    @Parameter(title: "Flags") var flags: [[Bool]]
    @Parameter(title: "Counts") var counts: [[Int]]
    @Parameter(title: "Amounts") var amounts: [[Double]]
    @Parameter(title: "Dates") var dates: [[Date]]
    """) + """

    struct TextNestedResultIntent: AppIntent {
        static let title: LocalizedStringResource = "Nested text result"
        func perform() async throws -> some IntentResult & ReturnsValue<[[String]]> { .result(value: [[String]]()) }
    }
    struct BoolNestedResultIntent: AppIntent {
        static let title: LocalizedStringResource = "Nested bool result"
        func perform() async throws -> some IntentResult & ReturnsValue<[[Bool]]> { .result(value: [[Bool]]()) }
    }
    struct IntegerNestedResultIntent: AppIntent {
        static let title: LocalizedStringResource = "Nested integer result"
        func perform() async throws -> some IntentResult & ReturnsValue<[[Int]]> { .result(value: [[Int]]()) }
    }
    struct DecimalNestedResultIntent: AppIntent {
        static let title: LocalizedStringResource = "Nested decimal result"
        func perform() async throws -> some IntentResult & ReturnsValue<[[Double]]> { .result(value: [[Double]]()) }
    }
    struct DateNestedResultIntent: AppIntent {
        static let title: LocalizedStringResource = "Nested date result"
        func perform() async throws -> some IntentResult & ReturnsValue<[[Date]]> { .result(value: [[Date]]()) }
    }
    """
    static func write(at original: URL, sourceKind: SourceKind = .input) throws -> Fixture {
        guard !FileManager.default.fileExists(atPath: original.path) else { throw AutomationContractError.conflictingOperation }
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let project = original.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let ids = (1...13).map { String(format: "%024X", $0) }
        let (projectID, main, products, app, appFile, product, buildFile, sources, frameworks, projectConfigs, projectConfig, appConfigs, appConfig) =
            (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7], ids[8], ids[9], ids[10], ids[11], ids[12])
        let objects: [String: Any] = [
            projectID: ["isa": "PBXProject", "mainGroup": main, "productRefGroup": products, "targets": [app],
                        "buildConfigurationList": projectConfigs, "compatibilityVersion": "Xcode 14.0", "developmentRegion": "en", "knownRegions": ["en", "Base"]],
            main: ["isa": "PBXGroup", "sourceTree": "<group>", "children": [appFile, products]],
            products: ["isa": "PBXGroup", "name": "Products", "sourceTree": "<group>", "children": [product]],
            appFile: ["isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift", "path": "Subject.swift", "sourceTree": "<group>"],
            product: ["isa": "PBXFileReference", "explicitFileType": "wrapper.application", "path": "Subject.app", "sourceTree": "BUILT_PRODUCTS_DIR"],
            buildFile: ["isa": "PBXBuildFile", "fileRef": appFile],
            sources: ["isa": "PBXSourcesBuildPhase", "buildActionMask": 2147483647, "files": [buildFile], "runOnlyForDeploymentPostprocessing": 0],
            frameworks: ["isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647, "files": [String](), "runOnlyForDeploymentPostprocessing": 0],
            app: ["isa": "PBXNativeTarget", "name": "Subject", "productName": "Subject", "productReference": product,
                  "productType": "com.apple.product-type.application", "buildConfigurationList": appConfigs,
                  "buildPhases": [sources, frameworks], "buildRules": [String](), "dependencies": [String]()],
            projectConfigs: ["isa": "XCConfigurationList", "buildConfigurations": [projectConfig], "defaultConfigurationName": "Debug", "defaultConfigurationIsVisible": 0],
            appConfigs: ["isa": "XCConfigurationList", "buildConfigurations": [appConfig], "defaultConfigurationName": "Debug", "defaultConfigurationIsVisible": 0],
            projectConfig: ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": ["SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "27.0", "SWIFT_VERSION": "6.0"]],
            appConfig: ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": "com.intents.fixture.mac-host", "PRODUCT_NAME": "$(TARGET_NAME)", "GENERATE_INFOPLIST_FILE": "YES", "SUPPORTED_PLATFORMS": "macosx", "CODE_SIGN_STYLE": "Automatic"]]
        ]
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["archiveVersion": "1", "objectVersion": "56", "classes": [String: String](), "rootObject": projectID, "objects": objects], format: .xml, options: 0)
        try bytes.write(to: project.appendingPathComponent("project.pbxproj"), options: .withoutOverwriting)
        let selected: String = switch sourceKind { case .host: hostSource; case .input: source; case .nestedArrays: nestedSource }
        try Data(selected.utf8).write(to: original.appendingPathComponent("Subject.swift"), options: .withoutOverwriting)
        return .init(project: project, targetID: app, projectData: bytes)
    }
    static func validateCatalog(_ catalog: ApplicationSurfaceCatalog, app: AppIdentity) throws -> String {
        guard catalog.app == app, app.bundleID == "com.intents.fixture.mac-host", app.platform == "macos",
              catalog.systemActions.count == 1, let action = catalog.systemActions.first,
              action.id == "HostProbeIntent", action.compiled, action.parametersComplete, !action.executed, !action.registered,
              action.parameters.count == 1, action.parameters[0].name == "sample", action.parameters[0].family == "text",
              !action.parameters[0].optional, action.parameters[0].typeID == nil else {
            throw AutomationContractError.conflictingOperation
        }
        return action.id
    }
    static func validateSource(_ manifest: AutomationSourceManifest, fixture: Fixture, original: URL, frozenRoot: URL) throws {
        let expected = ["Subject.swift": Data(source.utf8), "Subject.xcodeproj/project.pbxproj": fixture.projectData]
        guard manifest.sourceRoot == original.path, manifest.files.count == expected.count else { throw AutomationContractError.conflictingOperation }
        for (path, bytes) in expected {
            let matching = manifest.files.filter { $0.relativePath == path }
            guard matching.count == 1, let file = matching.first, file.symbolicLink == nil, file.frozenSymbolicLink == nil,
                  file.sha256 == AutomationArtifactRegistry.digest(bytes), file.bytes == bytes.count,
                  try AutomationReadOnlyFile.read(root: original, relativePath: path, maximumBytes: 65536) == bytes else {
                throw AutomationContractError.conflictingOperation
            }
            // Preparation intentionally expands the isolated PBX project with
            // the SDK host. App source bytes must still match the authored input.
            if path == "Subject.swift", try AutomationReadOnlyFile.read(root: frozenRoot, relativePath: path, maximumBytes: 65536) != bytes {
                throw AutomationContractError.conflictingOperation
            }
        }
        try AutomationSourceSnapshot.verifyOriginal(manifest)
    }
}
