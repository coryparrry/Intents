import Foundation
import CryptoKit
import Darwin

/// Published package commit verified by a clean external SwiftPM consumer.
enum IntentLabPackageRevisionManifest {
    static let packageURL = URL(string: "https://github.com/coryparrry/Intents.git")!
    static let verifiedRevision: String? = "32ee15ecb982a850c89168e4053e513936e554fe"
    static let product = "IntentLabTesting"
}

struct IntentLabInstallationRequest: Sendable {
    let projectURL: URL
    let workspaceURL: URL?
    let scheme: String
    let applicationTargetID: String
    let uiTestTargetID: String?
    let packageURL: URL
    let packageRevision: String?
    let packageProduct: String
    let consumerSource: String
    let declarationData: Data

    init(projectURL: URL, workspaceURL: URL? = nil,
         scheme: String, applicationTargetID: String,
         uiTestTargetID: String? = nil, packageURL: URL, packageRevision: String? = nil,
         packageProduct: String,
         consumerSource: String, declarationData: Data) {
        self.projectURL = projectURL
        self.workspaceURL = workspaceURL
        self.scheme = scheme
        self.applicationTargetID = applicationTargetID
        self.uiTestTargetID = uiTestTargetID
        self.packageURL = packageURL
        if packageURL == IntentLabPackageRevisionManifest.packageURL,
           packageProduct == IntentLabPackageRevisionManifest.product,
           packageRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let verifiedRevision = IntentLabPackageRevisionManifest.verifiedRevision {
            self.packageRevision = verifiedRevision
        } else {
            self.packageRevision = packageRevision
        }
        self.packageProduct = packageProduct
        self.consumerSource = consumerSource
        self.declarationData = declarationData
    }
}

struct IntentLabInstallationChange: Sendable {
    let url: URL
    let summary: String
    let previous: Data?
    let proposed: Data

    var beforeDigest: String? { previous.map(IntentLabProjectInstaller.digest) }
    var afterDigest: String { IntentLabProjectInstaller.digest(proposed) }
}

struct IntentLabInstallationPlan: Sendable {
    let projectURL: URL
    let workspaceURL: URL?
    let targetName: String
    let changes: [IntentLabInstallationChange]
    let manualSteps: [String]
    let supported: Bool
    let packageSourceDescription: String
    let declarationDigest: String?
    let manualFiles: [IntentLabManualIntegrationFile]
}

struct IntentLabManualIntegrationFile: Sendable {
    let filename: String
    let purpose: String
    let data: Data
}

struct IntentLabProjectTarget: Sendable, Identifiable {
    let id: String
    let name: String
}

struct IntentLabProjectInspection: Sendable {
    let applications: [IntentLabProjectTarget]
    let uiTestTargets: [IntentLabProjectTarget]
    let sharedSchemes: [String]
    let schemeLocations: [String: [URL]]
}

struct IntentLabValidatedDeclaration: Sendable {
    let id: String
    let version: String
    let targetBundleIdentifier: String
    let targetIdentity: String
    let capabilities: [String]
    let hasFixtureContentObserver: Bool
    let digest: String
}

struct IntentLabInstallationReceipt: Sendable {
    let changedFiles: [URL]
    let alreadyInstalled: Bool
    let journalURL: URL?
    let declarationDigest: String?
}

struct IntentLabInstallationVerification: Sendable {
    let installed: Bool
    let missing: [String]
}

struct IntentLabRemovalPreview: Sendable {
    let automated: Bool
    let filesToReview: [URL]
    let steps: [String]
}

enum IntentLabProjectInstallerError: LocalizedError {
    case unsupported(String)
    case conflict(URL)
    case unreadableFile(URL)
    case incompleteManualExport(URL)
    case unsafePath(URL)
    case interruptedTransaction(URL)

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): reason
        case .conflict(let url): "The project changed since preview: \(url.lastPathComponent). Refresh the preview."
        case .unreadableFile(let url): "An existing file could not be read: \(url.path). Intent Lab will not treat it as missing or overwrite it. Check access and refresh the preview."
        case .incompleteManualExport(let url): "A manual export stopped while writing \(url.path). Inspect that file before retrying; Intent Lab left its contents intact."
        case .unsafePath(let url): "The integration path is outside the selected project: \(url.path)."
        case .interruptedTransaction(let url): "An interrupted setup needs recovery before applying changes: \(url.path)."
        }
    }
}

/// Static inspection and mutation only. Builds, package resolution, and scripts remain
/// behind the app's existing explicit project execution approval.
struct IntentLabProjectInstaller: Sendable {
    /// Compiles without business knowledge. A developer must implement each
    /// operation and explicitly replace Basic integration at the entry point.
    static let appAdapterScaffold = """
        import Foundation
        import IntentLabContracts
        import IntentLabTesting
        import XCTest

        @available(macOS 27.0, iOS 27.0, *)
        @MainActor
        struct IntentLabAppAdapter: IntentLabIntegration {
            var supportedCapabilities: Set<String> { [] }

            func prepare(bundleIdentifier: String, context: String,
                         operationID: String) throws -> XCUIApplication {
                throw IntentLabIntegrationError.unsupportedPreparation(operationID)
            }

            func observe(application: XCUIApplication) throws -> [String: IntentLabValue] {
                throw IntentLabAppAdapterError.unimplementedObservation
            }

            func completed(observations: [String: IntentLabValue], context: String) -> Bool {
                false
            }
        }

        private enum IntentLabAppAdapterError: LocalizedError {
            case unimplementedObservation

            var errorDescription: String? {
                "Implement an app-owned observer before claiming an application result."
            }
        }
        """

    /// App-target counterpart for project-local feature checks. It links only the
    /// portable contracts product; the test runner remains in the UI-test target.
    static let appFeatureTestSupportScaffold = """
        #if DEBUG && INTENT_LAB_TEST_SUPPORT
        import AppIntents
        import Foundation
        import IntentLabContracts

        /// Register only explicit production service operations here. Each operation
        /// must call the app's production service and record a productionService receipt
        /// at that service entry point. Never synthesize a receipt in the wrapper.
        protocol IntentLabFeatureTestSupport: Sendable {
            var supportedOperationIDs: Set<String> { get }
            func prepare(operationID: String, context: String) async throws
            func invokeFeature(operationID: String, businessInput: String, context: String) async throws -> String
            func snapshot(operationID: String, context: String) async throws -> String
            func cleanup(operationID: String, context: String) async throws
        }

        /// Install the app-owned adapter during app startup before the test intent runs.
        enum IntentLabFeatureTestSupportRegistry {
            private static let store = IntentLabFeatureTestSupportStore()

            static var current: (any IntentLabFeatureTestSupport)? { store.current }

            static func install(_ support: any IntentLabFeatureTestSupport) {
                store.install(support)
            }
        }

        private final class IntentLabFeatureTestSupportStore: @unchecked Sendable {
            private let lock = NSLock()
            private var value: (any IntentLabFeatureTestSupport)?

            var current: (any IntentLabFeatureTestSupport)? {
                lock.lock()
                defer { lock.unlock() }
                return value
            }

            func install(_ support: any IntentLabFeatureTestSupport) {
                lock.lock()
                defer { lock.unlock() }
                value = support
            }
        }

        @available(iOS 27.0, macOS 27.0, *)
        struct IntentLabInvokeFeatureIntent: AppIntent {
            static let title: LocalizedStringResource = "Invoke Intent Lab feature"
            static let isDiscoverable = false
            static let openAppWhenRun = true

            @Parameter(title: "Operation") var operationID: String
            @Parameter(title: "Business input") var businessInput: String
            @Parameter(title: "Intent Lab context") var context: String

            func perform() async throws -> some IntentResult & ReturnsValue<IntentLabFeatureTestResult> {
                guard let support = IntentLabFeatureTestSupportRegistry.current else {
                    throw IntentLabFeatureTestSupportError.notRegistered
                }
                guard support.supportedOperationIDs.contains(operationID) else {
                    throw IntentLabFeatureTestSupportError.unsupportedOperation(operationID)
                }
                let response = try await support.invokeFeature(
                    operationID: operationID,
                    businessInput: businessInput,
                    context: context
                )
                return .result(value: IntentLabFeatureTestResult(response: response))
            }
        }

        @available(iOS 27.0, macOS 27.0, *)
        struct IntentLabFeatureTestResult: AppEntity, Identifiable {
            var id: String { response }
            @Property(title: "Response") var response: String

            static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intent Lab feature response"
            static let defaultQuery = IntentLabFeatureTestResultQuery()
            var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\\(response)") }

            init(response: String) { self.response = response }
        }

        @available(iOS 27.0, macOS 27.0, *)
        struct IntentLabFeatureTestResultQuery: EntityQuery {
            func entities(for identifiers: [String]) async throws -> [IntentLabFeatureTestResult] { [] }
        }

        private enum IntentLabFeatureTestSupportError: LocalizedError {
            case notRegistered
            case unsupportedOperation(String)

            var errorDescription: String? {
                switch self {
                case .notRegistered: "Register the app-owned Intent Lab feature support before invoking the test intent."
                case .unsupportedOperation(let operationID): "The app does not support local feature operation \\(operationID)."
                }
            }
        }
        #endif
        """

    /// Harmless readiness intent. It is isolated from feature operations and
    /// returns a typed result plus a caller context echo for freshness checking.
    static let appReadinessTestSupportScaffold = """
        #if DEBUG && INTENT_LAB_TEST_SUPPORT
        import AppIntents
        import Foundation

        @available(iOS 27.0, macOS 27.0, *)
        struct IntentLabReadinessIntent: AppIntent {
            static let title: LocalizedStringResource = "Check Intent Lab app readiness"
            static let isDiscoverable = false
            static let openAppWhenRun = true

            @Parameter(title: "Intent Lab context") var context: String

            func perform() async throws -> some IntentResult & ReturnsValue<IntentLabReadinessTestResult> {
                guard !context.isEmpty else {
                    throw IntentLabReadinessTestSupportError.invalidContext
                }
                return .result(value: IntentLabReadinessTestResult(ready: true, context: context))
            }
        }

        /// A successful response proves this Debug-only support intent is present
        /// in the selected app build. It does not claim that any Feature ran.
        @available(iOS 27.0, macOS 27.0, *)
        struct IntentLabReadinessTestResult: AppEntity, Identifiable {
            var id: String { context }
            @Property(title: "Ready") var ready: Bool
            @Property(title: "Context") var context: String

            static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intent Lab app readiness"
            static let defaultQuery = IntentLabReadinessTestResultQuery()
            var displayRepresentation: DisplayRepresentation {
                DisplayRepresentation(title: ready ? "Ready" : "Not ready")
            }

            init(ready: Bool, context: String) {
                self.ready = ready
                self.context = context
            }
        }

        @available(iOS 27.0, macOS 27.0, *)
        struct IntentLabReadinessTestResultQuery: EntityQuery {
            func entities(for identifiers: [String]) async throws -> [IntentLabReadinessTestResult] { [] }
        }

        private enum IntentLabReadinessTestSupportError: LocalizedError {
            case invalidContext

            var errorDescription: String? {
                "The Intent Lab readiness check requires a non-empty context."
            }
        }
        #endif
        """

    /// Siri-only adapter scaffold. CoreTesting stays independent of AppIntentsTesting.
    static let siriAppAdapterScaffold = """
        import Foundation
        import IntentLabContracts
        import IntentLabCoreTesting
        import XCTest

        @available(macOS 27.0, iOS 27.0, *)
        @MainActor
        struct IntentLabAppAdapter: IntentLabSiriIntegration {
            var supportedCapabilities: Set<String> { [] }
            var supportsMutatingChecks: Bool { false }

            func prepare(bundleIdentifier: String, context: String,
                         operationID: String) throws -> XCUIApplication {
                throw IntentLabExecutionPathError.unsafePreparation
            }

            func cleanup(bundleIdentifier: String, context: String,
                         operationID: String) throws {
                throw IntentLabExecutionPathError.cleanupUnsupported(operationID)
            }

            func observe(application: XCUIApplication) throws -> [String: IntentLabValue] {
                throw IntentLabAppAdapterError.unimplementedObservation
            }

            func completed(observations: [String: IntentLabValue], context: String) -> Bool {
                false
            }
        }

        private enum IntentLabAppAdapterError: LocalizedError {
            case unimplementedObservation

            var errorDescription: String? {
                "Implement a Siri-only app-owned observer before claiming an application result."
            }
        }
        """

    private static func adapterScaffold(for packageProduct: String) -> String {
        packageProduct == "IntentLabCoreTesting" ? siriAppAdapterScaffold : appAdapterScaffold
    }

    /// Validates the exact installed declaration bytes, including its binding to the
    /// selected application and UI-test target. The digest must not be recomputed from
    /// a parsed or generated JSON object because edits and byte order are significant.
    static func validateDeclaration(_ data: Data, targetBundleIdentifier: String,
                                    testTargetName: String) throws -> IntentLabValidatedDeclaration {
        guard let declaration = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              declaration["schemaVersion"] as? Int == 1,
              let id = declaration["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let version = declaration["version"] as? String, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              declaration["targetBundleIdentifier"] as? String == targetBundleIdentifier,
              declaration["targetIdentity"] as? String == testTargetName,
              let projectIdentity = declaration["projectIdentity"] as? String,
              !projectIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (declaration["supportedHarnessProtocols"] as? [String])?.contains("intent-lab-v2") == true,
              declaration["actions"] is [[String: Any]],
              declaration["resultProjections"] is [[String: Any]],
              declaration["preparationOperations"] is [String],
              let observers = declaration["observers"] as? [[String: Any]],
              declaration["isolation"] is [String: Any],
              let capabilities = declaration["capabilities"] as? [String],
              !capabilities.isEmpty,
              capabilities.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }),
              Set(capabilities).count == capabilities.count else {
            throw IntentLabProjectInstallerError.unsupported(
                "Choose a schema v1 declaration for this app and UI-test target with intent-lab-v2 support and complete capabilities."
            )
        }
        let fixtureObserverIDs: Set<String> = ["intentlab.fixtureDigest", "summarySourceContentDigest"]
        let hasFixtureContentObserver = observers.contains {
            guard let observerID = $0["id"] as? String else { return false }
            return fixtureObserverIDs.contains(observerID)
        }
        return .init(id: id, version: version, targetBundleIdentifier: targetBundleIdentifier,
                     targetIdentity: testTargetName, capabilities: capabilities,
                     hasFixtureContentObserver: hasFixtureContentObserver, digest: digest(data))
    }

    /// The receipt matcher resolves workspace identities relative to the workspace's
    /// containing directory. A relative path keeps equal project basenames distinct.
    static func declarationProjectIdentity(projectURL: URL, workspaceURL: URL?) -> String {
        let project = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let workspaceURL else { return project.lastPathComponent }
        let base = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let targetParts = project.pathComponents
        let baseParts = base.pathComponents
        let shared = zip(targetParts, baseParts).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: baseParts.count - shared)
            + targetParts.dropFirst(shared)).joined(separator: "/")
    }

    private struct JournalEntry: Codable {
        let path: String
        let before: Data?
        let after: Data
    }

    private struct Journal: Codable {
        let entries: [JournalEntry]
        let workspacePath: String?
    }

    private enum AppPlatform: String {
        case macOS
        case iOS

        var deploymentSetting: String {
            switch self {
            case .macOS: "MACOSX_DEPLOYMENT_TARGET"
            case .iOS: "IPHONEOS_DEPLOYMENT_TARGET"
            }
        }

        var sdkRoot: String {
            switch self {
            case .macOS: "macosx"
            case .iOS: "auto"
            }
        }
    }

    private struct AppConfiguration {
        let name: String
        let platform: AppPlatform
        let deployment: String
        let bundleIdentifier: String
        let developmentTeam: String?
        let supportedPlatforms: String
    }

    static func inspect(projectURL: URL, workspaceURL: URL? = nil) throws -> IntentLabProjectInspection {
        let project = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        guard project.pathExtension == "xcodeproj" else {
            throw IntentLabProjectInstallerError.unsupported("Choose an owning .xcodeproj for static inspection.")
        }
        let data = try Data(contentsOf: project.appending(path: "project.pbxproj"))
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]] else {
            throw IntentLabProjectInstallerError.unsupported("The project has no readable targets.")
        }
        let targets = objects.compactMap { id, object -> (String, IntentLabProjectTarget)? in
            guard object["isa"] as? String == "PBXNativeTarget",
                  let type = object["productType"] as? String,
                  let name = object["name"] as? String else { return nil }
            return (type, .init(id: id, name: name))
        }
        let workspace = workspaceURL?.standardizedFileURL.resolvingSymlinksInPath()
        if let workspace {
            guard workspace.pathExtension == "xcworkspace",
                  (try? XcodeConnectionDiscoveryService.workspaceProjectURLs(workspace: workspace))?.contains(project) == true else {
                throw IntentLabProjectInstallerError.unsupported("The workspace does not reference this owning project.")
            }
        }
        var schemeLocations: [String: [URL]] = [:]
        for container in [project] + (workspace.map { [$0] } ?? []) {
            let directory = container.appending(path: "xcshareddata/xcschemes")
            let schemes = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)) ?? []
            for url in schemes where url.pathExtension == "xcscheme" {
                schemeLocations[url.deletingPathExtension().lastPathComponent, default: []].append(url)
            }
        }
        return .init(
            applications: targets.filter { $0.0 == "com.apple.product-type.application" }.map(\.1).sorted { $0.name < $1.name },
            uiTestTargets: targets.filter { $0.0 == "com.apple.product-type.bundle.ui-testing" }.map(\.1).sorted { $0.name < $1.name },
            sharedSchemes: schemeLocations.keys.sorted(),
            schemeLocations: schemeLocations
        )
    }

    func preview(_ request: IntentLabInstallationRequest) throws -> IntentLabInstallationPlan {
        let project = request.projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let projectRoot = project.deletingLastPathComponent()
        let workspace = request.workspaceURL?.standardizedFileURL.resolvingSymlinksInPath()
        if request.packageURL == IntentLabPackageRevisionManifest.packageURL,
           request.packageProduct == "IntentLabCoreTesting",
           request.packageRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            return manual(project, request: request,
                          "IntentLabCoreTesting is not included in the verified default revision for IntentLabTesting. Select a local development checkout or enter a published exact 40-character revision that includes IntentLabCoreTesting, then preview again.")
        }
        if request.packageURL == IntentLabPackageRevisionManifest.packageURL,
           request.packageRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            return manual(project, request: request,
                          "This Intents build has no verified default package revision. Select a local development checkout or enter a published exact 40-character revision, then preview again.")
        }
        guard project.pathExtension == "xcodeproj", FileManager.default.fileExists(atPath: project.path),
              (request.packageURL.isFileURL
                ? FileManager.default.fileExists(atPath: request.packageURL.path)
                : request.packageURL.scheme == "https" && validRevision(request.packageRevision)) else {
            return manual(project, request: request, "Select an existing .xcodeproj and a local package checkout, or a HTTPS Git repository with an exact 40-character revision.")
        }
        guard !["project.yml", "project.yaml", "project.json", "Tuist.swift"].contains(where: {
            FileManager.default.fileExists(atPath: projectRoot.appending(path: $0).path)
        }) else {
            return manual(project, request: request, "This project is generator-managed. Add the package, test target, and entry point in the generator source, then verify the built integration.")
        }
        if let workspace {
            guard workspace.pathExtension == "xcworkspace",
                  FileManager.default.fileExists(atPath: workspace.path),
                  (try? XcodeConnectionDiscoveryService.workspaceProjectURLs(workspace: workspace))?.contains(project) == true else {
                return manual(project, request: request, "The selected workspace does not unambiguously reference this owning project.")
            }
        }
        let pbxURL = project.appending(path: "project.pbxproj")
        guard let existing = try readableContents(at: pbxURL) else {
            return manual(project, request: request, "The selected Xcode project has no project.pbxproj file.")
        }
        var document = try OpenStepProjectDocument(existing)
        guard let declaration = try? JSONSerialization.jsonObject(with: request.declarationData) as? [String: Any],
              declaration["schemaVersion"] as? Int == 1,
              ["id", "version", "targetBundleIdentifier", "projectIdentity", "targetIdentity"]
                .allSatisfy({ key in
                    guard let value = declaration[key] as? String else { return false }
                    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }),
              (declaration["supportedHarnessProtocols"] as? [String])?.contains("intent-lab-v2") == true,
              declaration["actions"] is [[String: Any]],
              declaration["resultProjections"] is [[String: Any]],
              declaration["preparationOperations"] is [String],
              declaration["observers"] is [[String: Any]],
              declaration["isolation"] is [String: Any],
              let declaredCapabilities = declaration["capabilities"] as? [String],
              !declaredCapabilities.isEmpty,
              declaredCapabilities.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isWhitespace }) }),
              Set(declaredCapabilities).count == declaredCapabilities.count else {
            return manual(project, request: request, "The integration declaration needs schema v1 identity, intent-lab-v2 support, action and observation lists, isolation, and unique capabilities before setup can advertise build support.")
        }
        let hasLocalFeatureControls = (declaration["localFeatureControls"] as? [[String: Any]])?.isEmpty == false
        let hasReadinessKey = declaration["readinessControl"] != nil
        let readinessControl = declaration["readinessControl"] as? [String: Any]
        guard !hasReadinessKey || readinessControl.map(Self.validReadinessControl) == true else {
            return manual(project, request: request,
                          "Declare readinessControl with the fixed harmless IntentLabReadinessIntent and typed readiness.ready Boolean response.")
        }
        let hasReadinessControl = readinessControl != nil
        let requiresTestOnlyIntent = hasLocalFeatureControls || hasReadinessControl
        guard hasLocalFeatureControls == declaredCapabilities.contains("local-feature-controls"),
              requiresTestOnlyIntent == declaredCapabilities.contains("test-only-intent") else {
            return manual(project, request: request,
                          "Declare local feature controls with local-feature-controls, and declare test-only-intent when local Feature or readiness support is present.")
        }
        if requiresTestOnlyIntent && request.packageProduct != "IntentLabTesting" {
            return manual(project, request: request,
                          "Project-local Feature and readiness controls require the IntentLabTesting product. CoreTesting remains Siri-only.")
        }
        if request.packageProduct == "IntentLabCoreTesting" {
            let sourceImports = request.consumerSource
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard sourceImports.contains("import IntentLabCoreTesting"),
                  !sourceImports.contains("import IntentLabTesting"),
                  request.consumerSource.contains("IntentLabSiriScenarioRunner") else {
                return manual(project, request: request,
                              "The IntentLabCoreTesting product is Siri-only. Import IntentLabCoreTesting and use IntentLabSiriScenarioRunner in the consumer XCTest source; do not import IntentLabTesting.")
            }
            let unsupportedCapabilities: Set<String> = [
                "direct-intent-execution", "direct-intent-output", "entity-query", "value-query"
            ]
            if !Set(declaredCapabilities).isDisjoint(with: unsupportedCapabilities) {
                return manual(project, request: request,
                              "IntentLabCoreTesting supports Siri-only execution. Remove direct Intent and entity/value query capabilities, or select IntentLabTesting.")
            }
            let hasTypedAppOwnedSiriObserver = (declaration["observers"] as? [[String: Any]] ?? []).contains {
                guard let id = $0["id"] as? String,
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      $0["source"] as? String == "uiElement",
                      let selector = $0["selector"] as? String,
                      !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      $0["type"] is [String: Any] else { return false }
                return true
            }
            guard hasTypedAppOwnedSiriObserver else {
                return manual(project, request: request,
                              "Declare at least one typed app-owned observer with source uiElement and a stable selector for the Siri state outcome, then implement that observation in IntentLabAppAdapter.observe and preview again.")
            }
        }
        let needsAppAdapter = !Set(declaredCapabilities).isDisjoint(with: [
            "siri", "siri-completion", "accessible-result", "preparation", "invocation-correlation"
        ]) || ((declaration["isolation"] as? [String: Any])?["kind"] as? String != "readOnly")
        if request.consumerSource.contains("IntentLabBasicIntegration"), needsAppAdapter {
            return manual(project, request: request,
                          "Basic support cannot prove app state, Siri completion, or isolated mutation. Implement the exported IntentLabAppAdapter.swift in the owning UI-test target, change the entry point to use it, and verify the compiled connection receipt.")
        }
        guard let root = try PropertyListSerialization.propertyList(from: existing, format: nil) as? [String: Any],
              let objectVersion = Int(root["objectVersion"] as? String ?? ""), (60...110).contains(objectVersion),
              let objects = root["objects"] as? [String: [String: Any]],
              let app = objects[request.applicationTargetID],
              app["productType"] as? String == "com.apple.product-type.application",
              let appName = app["name"] as? String,
              let appProductID = app["productReference"] as? String,
              let appProductName = objects[appProductID]?["path"] as? String,
              let projectID = root["rootObject"] as? String,
              let projectObject = objects[projectID],
              let mainGroup = projectObject["mainGroup"] as? String else {
            return manual(project, request: request, "Unsupported project object version or application target. Choose a conventional project and explicit target.")
        }
        let requestedTarget = request.uiTestTargetID.flatMap { objects[$0] }
        if request.uiTestTargetID != nil,
           requestedTarget?["productType"] as? String != "com.apple.product-type.bundle.ui-testing" {
            return manual(project, request: request, "The selected target is not a UI-test bundle.")
        }
        let namedExisting = objects.first { $0.value["isa"] as? String == "PBXNativeTarget"
            && $0.value["name"] as? String == "IntentLabUITests"
            && $0.value["productType"] as? String == "com.apple.product-type.bundle.ui-testing" }
        let targetID = request.uiTestTargetID ?? namedExisting?.key ?? id("target", project)
        let targetName = requestedTarget?["name"] as? String ?? namedExisting?.value["name"] as? String ?? "IntentLabUITests"
        let created = objects[targetID] == nil
        let projectSchemeURL = project.appending(path: "xcshareddata/xcschemes/\(request.scheme).xcscheme")
        let workspaceSchemeURL = workspace?.appending(path: "xcshareddata/xcschemes/\(request.scheme).xcscheme")
        guard !request.scheme.contains("/"), !request.scheme.contains("..") else {
            return manual(project, request: request, "Choose a shared scheme with a simple name.")
        }
        let projectSchemeData: Data?
        let workspaceSchemeData: Data?
        do {
            projectSchemeData = try readableContents(at: projectSchemeURL)
            workspaceSchemeData = try workspaceSchemeURL.map { try readableContents(at: $0) } ?? nil
        } catch let error as IntentLabProjectInstallerError {
            return manual(project, request: request, error.localizedDescription)
        }
        let projectSchemeExists = projectSchemeData != nil
        let workspaceSchemeExists = workspaceSchemeData != nil
        if projectSchemeExists && workspaceSchemeExists {
            return manual(project, request: request, "Both the workspace and owning project contain a shared scheme named \(request.scheme). Select or consolidate the scheme manually before installation.")
        }
        let schemeURL = workspaceSchemeExists ? workspaceSchemeURL! :
            (projectSchemeExists ? projectSchemeURL : workspaceSchemeURL ?? projectSchemeURL)
        let schemeData = workspaceSchemeExists ? workspaceSchemeData : projectSchemeData
        if schemeData == nil, !created {
            return manual(project, request: request, "Share the selected scheme in Xcode before automatic setup.")
        }
        let integrationDir = projectRoot.appending(path: "IntentLabIntegration/\(targetName)")
        let sourceURL = integrationDir.appending(path: "IntentLabScenarioTests.swift")
        let declarationURL = integrationDir.appending(path: "IntentLabIntegration.json")
        let adapterURL = integrationDir.appending(path: "IntentLabAppAdapter.swift")
        let featureSupportURL = projectRoot.appending(path: "IntentLabIntegration/\(appName)/IntentLabFeatureTestSupport.swift")
        let readinessSupportURL = projectRoot.appending(path: "IntentLabIntegration/\(appName)/IntentLabReadinessTestSupport.swift")
        let hasAppTestSupport = hasLocalFeatureControls || hasReadinessControl
        let safeURLs = [pbxURL, schemeURL, sourceURL, declarationURL, adapterURL]
            + (hasLocalFeatureControls ? [featureSupportURL] : [])
            + (hasReadinessControl ? [readinessSupportURL] : [])
        try ensureSafe(safeURLs,
                       roots: [projectRoot] + (workspace.map { [$0] } ?? []))
        if !created {
            if let existingReference = compiledScenarioReference(in: objects, targetID: targetID,
                excludingFileReference: id("source-file-\(targetName)", project)) {
                return manual(project, request: request, "The selected UI-test target already compiles \(existingReference). Review a v1-to-v2 migration before adding another IntentLabScenarioTests class.")
            }
            do {
                if let legacySource = try existingScenarioEntryPoint(in: projectRoot,
                                                                     excluding: sourceURL) {
                    return manual(project, request: request, "An existing IntentLabScenarioTests entry point appears in \(legacySource.path). Review a v1-to-v2 migration or choose a dedicated UI-test target; adding another class could collide.")
                }
            } catch let error as IntentLabProjectInstallerError {
                return manual(project, request: request, error.localizedDescription)
            }
        }
        for (url, proposed) in [(sourceURL, Data(request.consumerSource.utf8)),
                                (declarationURL, request.declarationData)] {
            do {
                if let current = try readableContents(at: url), current != proposed {
                    return manual(project, request: request, "The developer-owned \(url.lastPathComponent) differs from the proposed content. Review it manually; setup will not overwrite it.")
                }
            } catch let error as IntentLabProjectInstallerError {
                return manual(project, request: request, error.localizedDescription)
            }
        }
        if hasLocalFeatureControls {
            do {
                if let current = try readableContents(at: featureSupportURL),
                   current != Data(Self.appFeatureTestSupportScaffold.utf8) {
                    return manual(project, request: request,
                                  "The app-owned IntentLabFeatureTestSupport.swift differs from the proposed scaffold. Review it manually; setup will not overwrite it.")
                }
            } catch let error as IntentLabProjectInstallerError {
                return manual(project, request: request, error.localizedDescription)
            }
        }
        if hasReadinessControl {
            do {
                if let current = try readableContents(at: readinessSupportURL),
                   current != Data(Self.appReadinessTestSupportScaffold.utf8) {
                    return manual(project, request: request,
                                  "The app-owned IntentLabReadinessTestSupport.swift differs from the proposed scaffold. Review it manually; setup will not overwrite it.")
                }
            } catch let error as IntentLabProjectInstallerError {
                return manual(project, request: request, error.localizedDescription)
            }
        }
        let nextScheme: Data
        do {
            if created {
                try addUITestTarget(to: &document, project: project, projectID: projectID,
                                    mainGroup: mainGroup, appID: request.applicationTargetID,
                                    appName: appName, targetID: targetID, targetName: targetName,
                                    objects: objects, supportsSynchronizedGroups: objectVersion >= 77)
            }
            let productsToInstall: [String]
            switch request.packageProduct {
            case "IntentLabTesting", "IntentLabCoreTesting":
                productsToInstall = [request.packageProduct, "IntentLabContracts"]
            default:
                productsToInstall = [request.packageProduct]
            }
            for product in productsToInstall {
                try addPackage(to: &document, project: project, targetID: targetID,
                               product: product, packageURL: request.packageURL,
                               revision: request.packageRevision)
            }
            if hasLocalFeatureControls {
                try addPackage(to: &document, project: project,
                               targetID: request.applicationTargetID,
                               product: "IntentLabContracts", packageURL: request.packageURL,
                               revision: request.packageRevision)
            }
            if hasAppTestSupport {
                try setFeatureTestSupportHint(in: &document, targetID: request.applicationTargetID)
                try attachAppTestSupportSources(
                    to: &document, project: project, targetID: request.applicationTargetID,
                    appName: appName, mainGroup: mainGroup,
                    fileNames: (hasLocalFeatureControls ? ["IntentLabFeatureTestSupport.swift"] : [])
                        + (hasReadinessControl ? ["IntentLabReadinessTestSupport.swift"] : [])
                )
            }
            try setHarnessHints(in: &document, targetID: targetID,
                                declaredCapabilities: declaredCapabilities)
            try attachSources(to: &document, project: project, targetID: targetID,
                              targetName: targetName, mainGroup: mainGroup)
            nextScheme = try scheme(existing: schemeData, project: project, scheme: request.scheme,
                                    appID: request.applicationTargetID, appName: appName,
                                    appProductName: appProductName,
                                    targetID: targetID, targetName: targetName,
                                    schemeContainer: schemeURL.deletingLastPathComponent()
                                        .deletingLastPathComponent().deletingLastPathComponent()
                                        .deletingLastPathComponent())
        } catch let error as IntentLabProjectInstallerError {
            return manual(project, request: request, error.localizedDescription)
        } catch let error as OpenStepProjectDocument.Error {
            return manual(project, request: request, error.localizedDescription)
        }
        let candidates: [(URL, String, Data)] = [
            (pbxURL, "Add UI-test support and \(packageDescription(request)) to the test target", document.data),
            (schemeURL, "Include the UI-test target in the shared scheme", nextScheme),
            (sourceURL, "Add the consumer-owned XCTest entry point", Data(request.consumerSource.utf8)),
            (declarationURL, "Add the integration declaration", request.declarationData),
        ]
        let adapterData = Data(Self.adapterScaffold(for: request.packageProduct).utf8)
        let adapterExists = try readableContents(at: adapterURL) != nil
        let appFeatureSupport = hasLocalFeatureControls ? [
            (featureSupportURL, "Add the Debug-only app-owned local feature test support scaffold",
             Data(Self.appFeatureTestSupportScaffold.utf8))
        ] : []
        let appReadinessSupport = hasReadinessControl ? [
            (readinessSupportURL, "Add the Debug-only harmless app readiness test intent scaffold",
             Data(Self.appReadinessTestSupportScaffold.utf8))
        ] : []
        let allCandidates = candidates + (adapterExists ? [] : [
            (adapterURL, "Scaffold an app-owned adapter that fails until implemented", adapterData)
        ]) + appFeatureSupport + appReadinessSupport
        let changes: [IntentLabInstallationChange]
        do {
            changes = try allCandidates.compactMap { url, summary, proposed -> IntentLabInstallationChange? in
                let previous = try readableContents(at: url)
                guard previous != proposed else { return nil }
                return .init(url: url, summary: summary, previous: previous, proposed: proposed)
            }
        } catch let error as IntentLabProjectInstallerError {
            return manual(project, request: request, error.localizedDescription)
        }
        return .init(projectURL: project, workspaceURL: workspace, targetName: targetName, changes: changes,
                     manualSteps: [], supported: true,
                     packageSourceDescription: packageDescription(request),
                     declarationDigest: Self.digest(request.declarationData), manualFiles: [])
    }

    func apply(
        _ plan: IntentLabInstallationPlan,
        writeChange: (Data, URL, Data.WritingOptions) throws -> Void = { data, url, options in
            try data.write(to: url, options: options)
        }
    ) throws -> IntentLabInstallationReceipt {
        guard plan.supported else { throw IntentLabProjectInstallerError.unsupported(plan.manualSteps.joined(separator: " ")) }
        let projectRoot = plan.projectURL.deletingLastPathComponent()
        let journalURL = projectRoot.appending(path: ".intent-lab-install-journal.json")
        let roots = [projectRoot] + (plan.workspaceURL.map { [$0] } ?? [])
        try ensureSafe(plan.changes.map(\.url) + [journalURL], roots: roots)
        guard try readableContents(at: journalURL) == nil else {
            throw IntentLabProjectInstallerError.interruptedTransaction(journalURL)
        }
        for change in plan.changes {
            guard try readableContents(at: change.url) == change.previous else {
                throw IntentLabProjectInstallerError.conflict(change.url)
            }
        }
        if plan.changes.isEmpty { return .init(changedFiles: [], alreadyInstalled: true,
                                              journalURL: nil, declarationDigest: plan.declarationDigest) }
        let journal = Journal(entries: plan.changes.map {
            .init(path: $0.url.path, before: $0.previous, after: $0.proposed)
        }, workspacePath: plan.workspaceURL?.path)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .withoutOverwriting)
        var written: [IntentLabInstallationChange] = []
        var attemptedChange: IntentLabInstallationChange?
        do {
            for change in plan.changes {
                try ensureSafe([change.url], roots: roots)
                guard try readableContents(at: change.url) == change.previous else {
                    throw IntentLabProjectInstallerError.conflict(change.url)
                }
                try FileManager.default.createDirectory(at: change.url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                attemptedChange = change
                try writeChange(change.proposed, change.url,
                                change.previous == nil ? .withoutOverwriting : .atomic)
                written.append(change)
                attemptedChange = nil
            }
            try FileManager.default.removeItem(at: journalURL)
            return .init(changedFiles: plan.changes.map(\.url), alreadyInstalled: false,
                         journalURL: nil, declarationDigest: plan.declarationDigest)
        } catch {
            var rollbackConflict = false
            for change in (written + (attemptedChange.map { [$0] } ?? [])).reversed() {
                do {
                    let current = try readableContents(at: change.url)
                    if current == change.previous { continue }
                    guard current == change.proposed else {
                        // A failed exclusive write may have left partial bytes, or
                        // another process may have created the file. Keep the journal
                        // so neither case is silently treated as rolled back.
                        rollbackConflict = true
                        continue
                    }
                    if let previous = change.previous {
                        try previous.write(to: change.url, options: .atomic)
                    } else {
                        try FileManager.default.removeItem(at: change.url)
                    }
                } catch {
                    rollbackConflict = true
                }
            }
            if !rollbackConflict { try? FileManager.default.removeItem(at: journalURL) }
            throw error
        }
    }

    /// Reverses only bytes written by this transaction. A changed user file is left intact.
    @discardableResult
    func recover(projectURL: URL, workspaceURL: URL? = nil) throws -> [URL] {
        let project = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let root = project.deletingLastPathComponent()
        let journalURL = root.appending(path: ".intent-lab-install-journal.json")
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        let workspace = workspaceURL?.standardizedFileURL.resolvingSymlinksInPath()
        guard journal.workspacePath == workspace?.path else {
            throw IntentLabProjectInstallerError.unsupported("Recover with the same approved workspace selection used for installation.")
        }
        let urls = journal.entries.map { URL(fileURLWithPath: $0.path) }
        try ensureSafe(urls + [journalURL], roots: [root] + (workspace.map { [$0] } ?? []))
        var conflicts: [URL] = []
        for entry in journal.entries.reversed() {
            let url = URL(fileURLWithPath: entry.path)
            let current = try readableContents(at: url)
            if current == entry.after {
                if let before = entry.before { try before.write(to: url, options: .atomic) }
                else { try FileManager.default.removeItem(at: url) }
            } else if current != entry.before {
                conflicts.append(url)
            }
        }
        if let conflict = conflicts.first { throw IntentLabProjectInstallerError.conflict(conflict) }
        try FileManager.default.removeItem(at: journalURL)
        return urls
    }

    func verify(_ request: IntentLabInstallationRequest) throws -> IntentLabInstallationVerification {
        let plan = try preview(request)
        return .init(installed: plan.supported && plan.changes.isEmpty,
                     missing: plan.supported ? plan.changes.map(\.summary) : plan.manualSteps)
    }

    func repair(_ request: IntentLabInstallationRequest) throws -> IntentLabInstallationReceipt {
        try apply(preview(request))
    }

    /// Exports the same reviewable entry point and declaration shown in an
    /// unsupported-project preview. Existing differing files cause a conflict.
    func exportManualFiles(
        _ plan: IntentLabInstallationPlan,
        to directory: URL,
        writeFile: (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .withoutOverwriting)
        }
    ) throws -> [URL] {
        guard !plan.supported, !plan.manualFiles.isEmpty else {
            throw IntentLabProjectInstallerError.unsupported("There are no manual integration files to export.")
        }
        let destination = directory.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = plan.manualFiles.map { ($0, destination.appending(path: $0.filename)) }
        try ensureSafe(files.map(\.1), root: destination)
        for (file, url) in files {
            if let previous = try readableContents(at: url), previous != file.data {
                throw IntentLabProjectInstallerError.conflict(url)
            }
        }
        var created: [(URL, Data)] = []
        do {
            for (file, url) in files {
                if let current = try readableContents(at: url) {
                    guard current == file.data else { throw IntentLabProjectInstallerError.conflict(url) }
                    continue
                }
                do {
                    // withoutOverwriting uses exclusive creation; a concurrent
                    // developer write cannot be replaced after the preview check.
                    try writeFile(file.data, url)
                } catch {
                    if let current = try readableContents(at: url) {
                        guard current == file.data else {
                            throw IntentLabProjectInstallerError.incompleteManualExport(url)
                        }
                        continue
                    }
                    throw error
                }
                created.append((url, file.data))
            }
        } catch {
            for (url, data) in created {
                if (try? readableContents(at: url)) == data {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            throw error
        }
        return files.map(\.1)
    }

    /// Removing an existing target or developer-edited adapter cannot be inferred
    /// safely from Xcode's project graph alone. Expose exact review locations and
    /// require the same verification after a manual change.
    func previewRemoval(_ request: IntentLabInstallationRequest) throws -> IntentLabRemovalPreview {
        let project = request.projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let workspace = request.workspaceURL?.standardizedFileURL.resolvingSymlinksInPath()
        let inspection = try Self.inspect(projectURL: project, workspaceURL: request.workspaceURL)
        let targetName = inspection.uiTestTargets.first { $0.id == request.uiTestTargetID }?.name
            ?? inspection.uiTestTargets.first { $0.name == "IntentLabUITests" }?.name
            ?? "IntentLabUITests"
        let integrationDir = project.deletingLastPathComponent()
            .appending(path: "IntentLabIntegration/\(targetName)")
        let projectScheme = project.appending(path: "xcshareddata/xcschemes/\(request.scheme).xcscheme")
        let workspaceScheme = workspace?.appending(path: "xcshareddata/xcschemes/\(request.scheme).xcscheme")
        let scheme = workspaceScheme.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? projectScheme
        let declaration = (try? JSONSerialization.jsonObject(with: request.declarationData)) as? [String: Any]
        let hasLocalFeatureControls = (declaration?["localFeatureControls"] as? [[String: Any]])?.isEmpty == false
        let hasReadinessControl = declaration?["readinessControl"] is [String: Any]
        let appName = inspection.applications.first?.name ?? "App"
        let files = [project.appending(path: "project.pbxproj"),
                     scheme,
                     integrationDir.appending(path: "IntentLabScenarioTests.swift"),
                     integrationDir.appending(path: "IntentLabIntegration.json"),
                     integrationDir.appending(path: "IntentLabAppAdapter.swift")]
            + (hasLocalFeatureControls ? [
                project.deletingLastPathComponent()
                    .appending(path: "IntentLabIntegration/\(appName)/IntentLabFeatureTestSupport.swift")
            ] : [])
            + (hasReadinessControl ? [
                project.deletingLastPathComponent()
                    .appending(path: "IntentLabIntegration/\(appName)/IntentLabReadinessTestSupport.swift")
            ] : [])
        try ensureSafe(files, roots: [project.deletingLastPathComponent()] + (workspace.map { [$0] } ?? []))
        return .init(automated: false, filesToReview: files, steps: [
            "Remove only Intent Lab test-source and declaration references from \(targetName), preserving edited adapters.",
            "If \(targetName) is the dedicated Intent Lab target, remove it from the project and shared scheme; preserve existing test targets and other package consumers.",
            "Remove the package reference only when no other target uses it. Rebuild and verify the remaining integration state."
        ])
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validReadinessControl(_ control: [String: Any]) -> Bool {
        guard control["operationID"] as? String == "intentLabReadiness",
              control["testIntentIdentifier"] as? String == "IntentLabReadinessIntent",
              let response = control["response"] as? [String: Any],
              response["id"] as? String == "readiness.ready",
              let type = response["type"] as? [String: Any],
              let boolean = type["primitive"] as? [String: Any],
              boolean["_0"] as? String == "boolean",
              let path = response["path"] as? [[String: Any]], path.count == 2 else {
            return false
        }
        return path[0]["kind"] as? String == "property"
            && path[0]["name"] as? String == "value"
            && path[0]["index"] == nil
            && path[1]["kind"] as? String == "property"
            && path[1]["name"] as? String == "ready"
            && path[1]["index"] == nil
    }

    private func manual(_ project: URL, request: IntentLabInstallationRequest,
                        _ instruction: String) -> IntentLabInstallationPlan {
        let package = packageDescription(request)
        let declaration = (try? JSONSerialization.jsonObject(with: request.declarationData)) as? [String: Any]
        let hasLocalFeatureControls = (declaration?["localFeatureControls"] as? [[String: Any]])?.isEmpty == false
        let hasReadinessControl = declaration?["readinessControl"] is [String: Any]
        let instructions = """
        # Intent Lab manual integration

        1. Review the supplied IntentLabScenarioTests.swift, IntentLabIntegration.json, and IntentLabAppAdapter.swift before adding them to a suitable signed UI-test target.
        2. Add \(request.packageProduct) and IntentLabContracts to the UI-test target. For local feature controls, add only IntentLabContracts to the app target. Package source: \(request.packageURL.isFileURL ? "choose a local package checkout" : package).
        3. Add the UI-test target to a shared test scheme, preserve custom test plans and signing, and set INTENT_LAB_HARNESS_VERSION to intent-lab-v2. Set INTENT_LAB_HARNESS_CAPABILITIES to the capabilities declared in IntentLabIntegration.json.
        4. For local feature controls, add IntentLabFeatureTestSupport.swift to the app target and compile it only in Debug with INTENT_LAB_TEST_SUPPORT. Each operation must call the production service and record its productionService receipt there.
        5. For declared readiness support, add IntentLabReadinessTestSupport.swift to the app target and compile it only in Debug with INTENT_LAB_TEST_SUPPORT. This harmless intent checks that app-target test support was built; it never runs a Feature.
        6. The XCTest adapter deliberately throws for preparation and observation and reports no supported capabilities. Implement real app-owned operations and change the entry point before claiming app-state or Siri completion. Never fill observations from expected answers.
        7. Build and run the separate integration receipt check before running scenarios. Static setup alone does not prove the compiled integration is ready.

        Automatic setup stopped because: \(instruction)
        """
        let files = [
            IntentLabManualIntegrationFile(filename: "IntentLabScenarioTests.swift",
                                           purpose: "Consumer XCTest entry point",
                                           data: Data(request.consumerSource.utf8)),
            IntentLabManualIntegrationFile(filename: "IntentLabIntegration.json",
                                           purpose: "Versioned integration declaration",
                                           data: request.declarationData),
            IntentLabManualIntegrationFile(filename: "IntentLabAppAdapter.swift",
                                           purpose: "App-owned adapter scaffold; all business operations fail until implemented",
                                           data: Data(Self.adapterScaffold(for: request.packageProduct).utf8)),
            IntentLabManualIntegrationFile(filename: "IntentLabManualSetup.md",
                                           purpose: "Project and scheme setup instructions",
                                           data: Data(instructions.utf8)),
        ] + (hasLocalFeatureControls ? [
            IntentLabManualIntegrationFile(filename: "IntentLabFeatureTestSupport.swift",
                                           purpose: "Debug-only app test-intent and production-service registry scaffold",
                                           data: Data(Self.appFeatureTestSupportScaffold.utf8))
        ] : []) + (hasReadinessControl ? [
            IntentLabManualIntegrationFile(filename: "IntentLabReadinessTestSupport.swift",
                                           purpose: "Debug-only harmless app readiness intent scaffold",
                                           data: Data(Self.appReadinessTestSupportScaffold.utf8))
        ] : [])
        return .init(projectURL: project, workspaceURL: request.workspaceURL,
                     targetName: "", changes: [], manualSteps: [instruction],
                     supported: false, packageSourceDescription: package,
                     declarationDigest: Self.digest(request.declarationData), manualFiles: files)
    }

    private func validRevision(_ value: String?) -> Bool {
        guard let value, value.count == 40 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private func packageDescription(_ request: IntentLabInstallationRequest) -> String {
        request.packageURL.isFileURL
            ? "local package \(request.packageURL.path)"
            : "package \(request.packageURL.absoluteString) at revision \(request.packageRevision ?? "")"
    }

    /// Returns nil only when the directory entry is proven absent. A present but
    /// unreadable file must never be treated as a new destination.
    private func readableContents(at url: URL) throws -> Data? {
        var information = stat()
        let result = url.path.withCString { lstat($0, &information) }
        guard result == 0 else {
            guard errno == ENOENT else { throw IntentLabProjectInstallerError.unreadableFile(url) }
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw IntentLabProjectInstallerError.unreadableFile(url)
        }
    }

    private func ensureSafe(_ urls: [URL], root: URL) throws {
        try ensureSafe(urls, roots: [root])
    }

    private func ensureSafe(_ urls: [URL], roots: [URL]) throws {
        let approved = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        for url in urls {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard approved.contains(where: { path.hasPrefix($0) }) else {
                throw IntentLabProjectInstallerError.unsafePath(url)
            }
        }
    }

    private func existingScenarioEntryPoint(in projectRoot: URL, excluding generated: URL) throws -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let expression = try NSRegularExpression(pattern: #"\bclass\s+IntentLabScenarioTests\b"#)
        var scanned = 0
        while let url = enumerator.nextObject() as? URL {
            if [".build", "DerivedData", "Pods"].contains(url.lastPathComponent)
                || ["xcodeproj", "xcworkspace"].contains(url.pathExtension) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift",
                  url.standardizedFileURL.resolvingSymlinksInPath() != generated.standardizedFileURL.resolvingSymlinksInPath() else {
                continue
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(projectRoot.path + "/") else {
                throw IntentLabProjectInstallerError.unsupported("A Swift source symlink leaves the owning project. Review the UI-test entry point manually.")
            }
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true else { continue }
            scanned += 1
            if scanned > 512 {
                throw IntentLabProjectInstallerError.unsupported("The project contains too many Swift files for bounded entry-point inspection. Review existing UI-test classes manually.")
            }
            guard (attributes.fileSize ?? 0) <= 512_000 else {
                throw IntentLabProjectInstallerError.unsupported("A Swift source is too large for bounded entry-point inspection. Review it manually before installing another test class.")
            }
            guard let data = try readableContents(at: url) else { continue }
            let source = String(decoding: data, as: UTF8.self)
            if expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                return url
            }
        }
        return nil
    }

    private func compiledScenarioReference(in objects: [String: [String: Any]], targetID: String,
                                           excludingFileReference ownedID: String) -> String? {
        guard let target = objects[targetID],
              let phases = target["buildPhases"] as? [String] else { return nil }
        for phaseID in phases where objects[phaseID]?["isa"] as? String == "PBXSourcesBuildPhase" {
            for buildID in objects[phaseID]?["files"] as? [String] ?? [] {
                guard let fileID = objects[buildID]?["fileRef"] as? String,
                      fileID != ownedID,
                      let file = objects[fileID] else { continue }
                let name = (file["path"] as? String ?? file["name"] as? String ?? "") as NSString
                if name.lastPathComponent == "IntentLabScenarioTests.swift" {
                    return "IntentLabScenarioTests.swift (project file reference \(fileID))"
                }
            }
        }
        return nil
    }

    private func id(_ role: String, _ project: URL) -> String {
        let input = Data((project.path + ":IntentLab:" + role).utf8)
        return SHA256.hash(data: input).prefix(12).map { String(format: "%02X", $0) }.joined()
    }

    private func quoted(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    private func relative(_ target: URL, to base: URL) -> String {
        let targetParts = target.standardizedFileURL.pathComponents
        let baseParts = base.standardizedFileURL.pathComponents
        let shared = zip(targetParts, baseParts).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: baseParts.count - shared) + targetParts.dropFirst(shared)).joined(separator: "/")
    }

    private func addPackage(to doc: inout OpenStepProjectDocument, project: URL,
                            targetID: String, product: String, packageURL: URL,
                            revision: String?) throws {
        let root = try PropertyListSerialization.propertyList(from: doc.data, format: nil) as! [String: Any]
        let objects = root["objects"] as! [String: [String: Any]]
        let packagePath = packageURL.isFileURL
            ? relative(packageURL, to: project.deletingLastPathComponent()) : nil
        let matchingReference = objects.first { _, object in
            if let packagePath {
                return object["isa"] as? String == "XCLocalSwiftPackageReference"
                    && object["relativePath"] as? String == packagePath
            }
            guard object["isa"] as? String == "XCRemoteSwiftPackageReference",
                  object["repositoryURL"] as? String == packageURL.absoluteString else { return false }
            return (object["requirement"] as? [String: String])?["revision"] == revision
        }
        if !packageURL.isFileURL,
           objects.values.contains(where: { $0["isa"] as? String == "XCRemoteSwiftPackageReference"
               && $0["repositoryURL"] as? String == packageURL.absoluteString }) && matchingReference == nil {
            throw IntentLabProjectInstallerError.unsupported("The project references this repository at a different requirement. Review the package version manually.")
        }
        let referenceID = matchingReference?.key ?? id("package-\(packageURL.absoluteString)", project)
        let matchingDependency = objects.first { _, object in
            object["isa"] as? String == "XCSwiftPackageProductDependency"
                && object["package"] as? String == referenceID
                && object["productName"] as? String == product
        }
        let dependencyID = matchingDependency?.key ?? id("product-\(product)-\(referenceID)", project)
        let matchingBuildFile = objects.first { _, object in
            object["isa"] as? String == "PBXBuildFile"
                && object["productRef"] as? String == dependencyID
        }
        let buildFileID = matchingBuildFile?.key ?? id("framework-\(product)-\(referenceID)", project)
        if try !doc.containsObject(referenceID) {
            if let packagePath {
                try doc.addObject(id: referenceID, value: "{isa = XCLocalSwiftPackageReference; relativePath = \(quoted(packagePath)); }")
            } else {
                try doc.addObject(id: referenceID, value: "{isa = XCRemoteSwiftPackageReference; repositoryURL = \(quoted(packageURL.absoluteString)); requirement = {kind = revision; revision = \(quoted(revision!));}; }")
            }
        }
        if try !doc.containsObject(dependencyID) {
            try doc.addObject(id: dependencyID, value: "{isa = XCSwiftPackageProductDependency; package = \(referenceID); productName = \(quoted(product)); }")
        }
        if try !doc.containsObject(buildFileID) {
            try doc.addObject(id: buildFileID, value: "{isa = PBXBuildFile; productRef = \(dependencyID); }")
        }
        try doc.append(referenceID, toObject: try rootProjectID(doc), key: "packageReferences")
        try doc.append(dependencyID, toObject: targetID, key: "packageProductDependencies")
        guard let phases = try doc.object(targetID).dictionary?["buildPhases"]?.array else {
            throw IntentLabProjectInstallerError.unsupported("The UI-test target has no build phases.")
        }
        let existingFrameworkID = try phases.compactMap(\.scalar).first(where: {
            try doc.scalar(object: $0, key: "isa") == "PBXFrameworksBuildPhase"
        })
        let frameworkID = existingFrameworkID ?? id("framework-phase-\(targetID)", project)
        if existingFrameworkID == nil {
            if try !doc.containsObject(frameworkID) {
                try doc.addObject(id: frameworkID, value: "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
            }
            try doc.append(frameworkID, toObject: targetID, key: "buildPhases")
        }
        try doc.append(buildFileID, toObject: frameworkID, key: "files")
    }

    private func setHarnessHints(in doc: inout OpenStepProjectDocument, targetID: String,
                                 declaredCapabilities: [String]) throws {
        guard let listID = try doc.scalar(object: targetID, key: "buildConfigurationList"),
              let configIDs = try doc.object(listID).dictionary?["buildConfigurations"]?.array?.compactMap(\.scalar),
              !configIDs.isEmpty else {
            throw IntentLabProjectInstallerError.unsupported("The UI-test target has no build configurations.")
        }
        for configID in configIDs {
            guard let settings = try doc.object(configID).dictionary?["buildSettings"] else {
                throw IntentLabProjectInstallerError.unsupported("A UI-test build configuration has no settings.")
            }
            let existingVersion = settings.dictionary?["INTENT_LAB_HARNESS_VERSION"]?.scalar
            if let existingVersion, existingVersion != "intent-lab-v2" {
                throw IntentLabProjectInstallerError.unsupported("The selected test target declares an incompatible harness version. Choose a dedicated target.")
            }
            try doc.setKey("INTENT_LAB_HARNESS_VERSION", value: quoted("intent-lab-v2"), in: settings)
            let freshSettings = try doc.object(configID).dictionary!["buildSettings"]!
            let existing = freshSettings.dictionary?["INTENT_LAB_HARNESS_CAPABILITIES"]?.scalar ?? ""
            let merged = Set(existing.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
                .union(declaredCapabilities).sorted()
            try doc.setKey("INTENT_LAB_HARNESS_CAPABILITIES", value: quoted(merged.joined(separator: " ")),
                           in: freshSettings)
        }
    }

    private func setFeatureTestSupportHint(in doc: inout OpenStepProjectDocument,
                                           targetID: String) throws {
        guard let listID = try doc.scalar(object: targetID, key: "buildConfigurationList"),
              let configIDs = try doc.object(listID).dictionary?["buildConfigurations"]?.array?.compactMap(\.scalar),
              !configIDs.isEmpty else {
            throw IntentLabProjectInstallerError.unsupported("The application target has no build configurations for local feature test support.")
        }
        let debugIDs = try configIDs.filter { configID in
            let name = try doc.scalar(object: configID, key: "name") ?? ""
            return name.localizedCaseInsensitiveContains("debug")
        }
        guard !debugIDs.isEmpty else {
            throw IntentLabProjectInstallerError.unsupported("The application target has no Debug build configuration for local feature test support.")
        }
        for configID in debugIDs {
            guard let settings = try doc.object(configID).dictionary?["buildSettings"] else {
                throw IntentLabProjectInstallerError.unsupported("An application Debug configuration has no build settings.")
            }
            let current = settings.dictionary?["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]?.scalar ?? "$(inherited) DEBUG"
            let conditions = Set(current.split(whereSeparator: \.isWhitespace).map(String.init))
            guard conditions.contains("DEBUG") || conditions.contains("$(inherited)") else {
                throw IntentLabProjectInstallerError.unsupported("The application Debug configuration does not define DEBUG; local feature test support cannot be excluded from release builds safely.")
            }
            let next = conditions.union(["INTENT_LAB_TEST_SUPPORT"]).sorted().joined(separator: " ")
            try doc.setKey("SWIFT_ACTIVE_COMPILATION_CONDITIONS", value: quoted(next), in: settings)
        }
    }

    private func attachAppTestSupportSources(
        to doc: inout OpenStepProjectDocument,
        project: URL,
        targetID: String,
        appName: String,
        mainGroup: String,
        fileNames: [String]
    ) throws {
        guard !fileNames.isEmpty else { return }
        let relativePath = "IntentLabIntegration/\(appName)"
        let groupID = id("feature-test-support-group-\(appName)", project)
        let target = try doc.object(targetID)
        let isSynchronized = target.dictionary?["fileSystemSynchronizedGroups"] != nil
        if isSynchronized {
            if try !doc.containsObject(groupID) {
                try doc.addObject(id: groupID, value: "{isa = PBXFileSystemSynchronizedRootGroup; path = \(quoted(relativePath)); sourceTree = \"<group>\"; }")
            }
            try doc.append(groupID, toObject: targetID, key: "fileSystemSynchronizedGroups")
            try doc.append(groupID, toObject: mainGroup, key: "children")
            return
        }

        if try !doc.containsObject(groupID) {
            try doc.addObject(id: groupID, value: "{isa = PBXGroup; children = (); path = \(quoted(relativePath)); sourceTree = \"<group>\"; }")
        }
        try doc.append(groupID, toObject: mainGroup, key: "children")
        guard let phases = try doc.object(targetID).dictionary?["buildPhases"]?.array else {
            throw IntentLabProjectInstallerError.unsupported("The application target has no build phases.")
        }
        guard let sourcePhaseID = try phases.compactMap(\.scalar).first(where: {
            try doc.scalar(object: $0, key: "isa") == "PBXSourcesBuildPhase"
        }) else {
            throw IntentLabProjectInstallerError.unsupported("The application target has no Swift source phase.")
        }
        for fileName in Set(fileNames).sorted() {
            let fileID = fileName == "IntentLabFeatureTestSupport.swift"
                ? id("feature-test-support-file-\(appName)", project)
                : id("app-test-support-file-\(appName)-\(fileName)", project)
            let buildID = fileName == "IntentLabFeatureTestSupport.swift"
                ? id("feature-test-support-build-\(appName)", project)
                : id("app-test-support-build-\(appName)-\(fileName)", project)
            if try !doc.containsObject(fileID) {
                try doc.addObject(id: fileID, value: "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \(quoted(fileName)); sourceTree = \"<group>\"; }")
            }
            if try !doc.containsObject(buildID) {
                try doc.addObject(id: buildID, value: "{isa = PBXBuildFile; fileRef = \(fileID); }")
            }
            try doc.append(fileID, toObject: groupID, key: "children")
            try doc.append(buildID, toObject: sourcePhaseID, key: "files")
        }
    }

    private func rootProjectID(_ doc: OpenStepProjectDocument) throws -> String {
        guard let value = try doc.root().dictionary?["rootObject"]?.scalar else {
            throw OpenStepProjectDocument.Error.missing("rootObject")
        }
        return value
    }

    private func attachSources(to doc: inout OpenStepProjectDocument, project: URL,
                               targetID: String, targetName: String, mainGroup: String) throws {
        let groupID = id("source-group-\(targetName)", project)
        let target = try doc.object(targetID)
        let isSynchronized = target.dictionary?["fileSystemSynchronizedGroups"] != nil
        if isSynchronized {
            if try !doc.containsObject(groupID) {
                try doc.addObject(id: groupID, value: "{isa = PBXFileSystemSynchronizedRootGroup; path = \(quoted("IntentLabIntegration/\(targetName)")); sourceTree = \"<group>\"; }")
            }
            try doc.append(groupID, toObject: targetID, key: "fileSystemSynchronizedGroups")
            try doc.append(groupID, toObject: mainGroup, key: "children")
        } else {
            let sourceID = id("source-file-\(targetName)", project)
            let resourceID = id("declaration-file-\(targetName)", project)
            let adapterID = id("adapter-file-\(targetName)", project)
            let sourceBuildID = id("source-build-\(targetName)", project)
            let resourceBuildID = id("resource-build-\(targetName)", project)
            let adapterBuildID = id("adapter-build-\(targetName)", project)
            if try !doc.containsObject(groupID) {
                try doc.addObject(id: groupID, value: "{isa = PBXGroup; children = (\(sourceID), \(resourceID), \(adapterID),); path = \(quoted("IntentLabIntegration/\(targetName)")); sourceTree = \"<group>\"; }")
            }
            if try !doc.containsObject(sourceID) {
                try doc.addObject(id: sourceID, value: "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IntentLabScenarioTests.swift; sourceTree = \"<group>\"; }")
            }
            if try !doc.containsObject(resourceID) {
                try doc.addObject(id: resourceID, value: "{isa = PBXFileReference; lastKnownFileType = text.json; path = IntentLabIntegration.json; sourceTree = \"<group>\"; }")
            }
            if try !doc.containsObject(adapterID) {
                try doc.addObject(id: adapterID, value: "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IntentLabAppAdapter.swift; sourceTree = \"<group>\"; }")
            }
            if try !doc.containsObject(sourceBuildID) {
                try doc.addObject(id: sourceBuildID, value: "{isa = PBXBuildFile; fileRef = \(sourceID); }")
            }
            if try !doc.containsObject(resourceBuildID) {
                try doc.addObject(id: resourceBuildID, value: "{isa = PBXBuildFile; fileRef = \(resourceID); }")
            }
            if try !doc.containsObject(adapterBuildID) {
                try doc.addObject(id: adapterBuildID, value: "{isa = PBXBuildFile; fileRef = \(adapterID); }")
            }
            try doc.append(groupID, toObject: mainGroup, key: "children")
            try doc.append(adapterID, toObject: groupID, key: "children")
            for (kind, buildID) in [("PBXSourcesBuildPhase", sourceBuildID),
                                    ("PBXSourcesBuildPhase", adapterBuildID),
                                    ("PBXResourcesBuildPhase", resourceBuildID)] {
                guard let phases = try doc.object(targetID).dictionary?["buildPhases"]?.array else {
                    throw IntentLabProjectInstallerError.unsupported("The UI-test target has no build phases.")
                }
                let existingPhaseID = try phases.compactMap(\.scalar).first(where: {
                    try doc.scalar(object: $0, key: "isa") == kind
                })
                let phaseID = existingPhaseID ?? id("\(kind)-\(targetID)", project)
                if existingPhaseID == nil {
                    if try !doc.containsObject(phaseID) {
                        try doc.addObject(id: phaseID, value: "{isa = \(kind); buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
                    }
                    try doc.append(phaseID, toObject: targetID, key: "buildPhases")
                }
                try doc.append(buildID, toObject: phaseID, key: "files")
            }
        }
    }

    private func addUITestTarget(to doc: inout OpenStepProjectDocument, project: URL,
                                 projectID: String, mainGroup: String, appID: String,
                                 appName: String, targetID: String, targetName: String,
                                 objects: [String: [String: Any]],
                                 supportsSynchronizedGroups: Bool) throws {
        let app = objects[appID]!
        guard let appListID = app["buildConfigurationList"] as? String,
              let appList = objects[appListID],
              let configIDs = appList["buildConfigurations"] as? [String],
              !configIDs.isEmpty else { throw IntentLabProjectInstallerError.unsupported("Application build configurations are unavailable.") }
        let configurations = try appConfigurations(appConfigIDs: configIDs,
                                                    projectID: projectID,
                                                    objects: objects)
        guard let firstConfiguration = configurations.first,
              configurations.allSatisfy({ $0.platform == firstConfiguration.platform }) else {
            throw IntentLabProjectInstallerError.unsupported(
                "The selected application uses more than one platform across its build configurations. Create the UI-test target manually so each configuration can match its platform."
            )
        }
        let productID = id("test-product", project)
        let groupID = id("source-group-\(targetName)", project)
        let sourcesID = id("sources", project)
        let resourcesID = id("resources", project)
        let frameworksID = id("frameworks", project)
        let listID = id("configuration-list", project)
        let settingsIDs = configIDs.enumerated().map { id("configuration-\($0.offset)", project) }
        try doc.addObject(id: productID, value: "{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = \(targetName).xctest; sourceTree = BUILT_PRODUCTS_DIR; }")
        try doc.addObject(id: sourcesID, value: "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
        try doc.addObject(id: resourcesID, value: "{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
        try doc.addObject(id: frameworksID, value: "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
        let configPairs = zip(configurations, settingsIDs).map { ($0.0, $0.1) }
        for (configuration, configID) in configPairs {
            let settings = "CODE_SIGN_STYLE = Automatic; \(configuration.developmentTeam.map { "DEVELOPMENT_TEAM = \(quoted($0)); " } ?? "")GENERATE_INFOPLIST_FILE = YES; \(configuration.platform.deploymentSetting) = \(quoted(configuration.deployment)); PRODUCT_BUNDLE_IDENTIFIER = \(quoted(configuration.bundleIdentifier + ".IntentLabUITests")); PRODUCT_NAME = \"$(TARGET_NAME)\"; SDKROOT = \(configuration.platform.sdkRoot); SUPPORTED_PLATFORMS = \(quoted(configuration.supportedPlatforms)); SWIFT_VERSION = 6.0; TEST_TARGET_NAME = \(quoted(appName));"
            try doc.addObject(id: configID, value: "{isa = XCBuildConfiguration; buildSettings = {\(settings)}; name = \(quoted(configuration.name)); }")
        }
        try doc.addObject(id: listID, value: "{isa = XCConfigurationList; buildConfigurations = (\(settingsIDs.joined(separator: ", ")),); defaultConfigurationName = \(quoted(firstConfiguration.name)); }")
        if supportsSynchronizedGroups {
            try doc.addObject(id: groupID, value: "{isa = PBXFileSystemSynchronizedRootGroup; path = \(quoted("IntentLabIntegration/\(targetName)")); sourceTree = \"<group>\"; }")
        }
        let synchronized = supportsSynchronizedGroups ? "fileSystemSynchronizedGroups = (\(groupID),); " : ""
        try doc.addObject(id: targetID, value: "{isa = PBXNativeTarget; buildConfigurationList = \(listID); buildPhases = (\(sourcesID), \(frameworksID), \(resourcesID),); buildRules = (); \(synchronized)name = \(quoted(targetName)); packageProductDependencies = (); productName = \(quoted(targetName)); productReference = \(productID); productType = \"com.apple.product-type.bundle.ui-testing\"; }")
        try doc.append(targetID, toObject: projectID, key: "targets")
        try doc.append(productID, toObject: mainGroup, key: "children")
        if supportsSynchronizedGroups {
            try doc.append(groupID, toObject: mainGroup, key: "children")
        }
        // Signing is inherited only where the app explicitly exposes a team. The
        // installer does not modify the app's own signing or configurations.
    }

    private func appConfigurations(appConfigIDs: [String], projectID: String,
                                    objects: [String: [String: Any]]) throws -> [AppConfiguration] {
        guard let project = objects[projectID],
              let projectListID = project["buildConfigurationList"] as? String,
              let projectConfigIDs = objects[projectListID]?["buildConfigurations"] as? [String] else {
            throw IntentLabProjectInstallerError.unsupported("Project build configurations are unavailable, so the app platform cannot be derived safely.")
        }
        var projectSettingsByName: [String: [String: Any]] = [:]
        for configID in projectConfigIDs {
            guard let object = objects[configID], let name = object["name"] as? String else { continue }
            projectSettingsByName[name] = object["buildSettings"] as? [String: Any] ?? [:]
        }
        return try appConfigIDs.map { configID in
            guard let object = objects[configID], let name = object["name"] as? String else {
                throw IntentLabProjectInstallerError.unsupported("The application has an unnamed build configuration.")
            }
            let targetSettings = object["buildSettings"] as? [String: Any] ?? [:]
            let inherited = projectSettingsByName[name] ?? [:]
            let sdkRoot = resolvedSetting("SDKROOT", target: targetSettings, inherited: inherited)
            let rawPlatforms = resolvedSetting("SUPPORTED_PLATFORMS", target: targetSettings, inherited: inherited)
            if [sdkRoot, rawPlatforms].compactMap({ $0 }).contains(where: { $0.contains("$(") }) {
                throw IntentLabProjectInstallerError.unsupported(
                    "The selected application's SDK or supported platforms use unresolved build-setting expressions. Set SDKROOT and SUPPORTED_PLATFORMS directly before generating a UI-test target."
                )
            }
            var supported = Set((rawPlatforms ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            if supported.isEmpty {
                switch sdkRoot {
                case "macosx": supported = ["macosx"]
                case "iphoneos": supported = ["iphoneos", "iphonesimulator"]
                default: break
                }
            }
            let platform: AppPlatform
            if supported == ["macosx"] {
                platform = .macOS
                guard sdkRoot == nil || ["auto", "macosx"].contains(sdkRoot!) else {
                    throw unsupportedAppPlatform(supported, sdkRoot: sdkRoot)
                }
            } else if !supported.isEmpty && supported.isSubset(of: ["iphoneos", "iphonesimulator"]) {
                platform = .iOS
                guard sdkRoot == nil || ["auto", "iphoneos", "iphonesimulator"].contains(sdkRoot!) else {
                    throw unsupportedAppPlatform(supported, sdkRoot: sdkRoot)
                }
            } else {
                throw unsupportedAppPlatform(supported, sdkRoot: sdkRoot)
            }
            guard let deployment = resolvedSetting(platform.deploymentSetting,
                                                   target: targetSettings, inherited: inherited),
                  deployment.range(of: #"^\d+(?:\.\d+){0,2}$"#, options: .regularExpression) != nil else {
                throw IntentLabProjectInstallerError.unsupported(
                    "The selected application's \(platform.deploymentSetting) is missing or unresolved. Set that deployment target directly before generating a UI-test target."
                )
            }
            guard let bundleIdentifier = resolvedSetting("PRODUCT_BUNDLE_IDENTIFIER",
                                                          target: targetSettings, inherited: inherited),
                  !bundleIdentifier.isEmpty, !bundleIdentifier.contains("$(") else {
                throw IntentLabProjectInstallerError.unsupported(
                    "The selected application's PRODUCT_BUNDLE_IDENTIFIER is missing or unresolved. Set it directly before generating a UI-test target."
                )
            }
            let canonicalPlatforms = platform == .macOS
                ? "macosx"
                : ["iphoneos", "iphonesimulator"].filter(supported.contains).joined(separator: " ")
            return .init(name: name, platform: platform, deployment: deployment,
                         bundleIdentifier: bundleIdentifier,
                         developmentTeam: resolvedSetting("DEVELOPMENT_TEAM", target: targetSettings,
                                                          inherited: inherited),
                         supportedPlatforms: canonicalPlatforms)
        }
    }

    private func resolvedSetting(_ key: String, target: [String: Any],
                                 inherited: [String: Any]) -> String? {
        let targetValue = target[key] as? String
        let inheritedValue = inherited[key] as? String
        guard let targetValue else { return inheritedValue }
        guard targetValue.contains("$(inherited)") else { return targetValue }
        return targetValue.replacingOccurrences(of: "$(inherited)", with: inheritedValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unsupportedAppPlatform(_ supported: Set<String>, sdkRoot: String?) -> IntentLabProjectInstallerError {
        let platformNames = supported.sorted().joined(separator: ", ")
        let sdkDescription = sdkRoot.map { " with SDKROOT \($0)" } ?? ""
        return .unsupported(
            "The generated UI-test target supports iOS and macOS apps. The selected application's platform settings (\(platformNames.isEmpty ? "unresolved" : platformNames))\(sdkDescription) are not supported; configure a matching UI-test target manually."
        )
    }

    private func scheme(existing: Data?, project: URL, scheme: String, appID: String,
                        appName: String, appProductName: String,
                        targetID: String, targetName: String, schemeContainer: URL) throws -> Data {
        let xml: XMLDocument
        if let existing {
            xml = try XMLDocument(data: existing)
        } else {
            xml = try XMLDocument(xmlString: "<Scheme LastUpgradeVersion=\"2700\" version=\"1.3\"><BuildAction parallelizeBuildables=\"YES\" buildImplicitDependencies=\"YES\"><BuildActionEntries/></BuildAction><TestAction buildConfiguration=\"Debug\"><Testables/></TestAction></Scheme>")
        }
        guard let root = xml.rootElement() else { throw IntentLabProjectInstallerError.unsupported("Invalid shared scheme XML.") }
        let buildableNodes = try xml.nodes(forXPath: "//BuildableReference")
        let appReference = buildableNodes.compactMap { $0 as? XMLElement }.first {
            $0.attribute(forName: "BlueprintIdentifier")?.stringValue == appID
        }
        let existingContainer = appReference?.attribute(forName: "ReferencedContainer")?.stringValue
        let referenceContainer = existingContainer ?? "container:\(relative(project, to: schemeContainer))"
        let buildAction = root.elements(forName: "BuildAction").first ?? XMLElement(name: "BuildAction")
        if buildAction.parent == nil { root.addChild(buildAction) }
        let buildEntries = buildAction.elements(forName: "BuildActionEntries").first ?? XMLElement(name: "BuildActionEntries")
        if buildEntries.parent == nil { buildAction.addChild(buildEntries) }
        let builtIDs = buildEntries.elements(forName: "BuildActionEntry")
            .compactMap { $0.elements(forName: "BuildableReference").first?.attribute(forName: "BlueprintIdentifier")?.stringValue }
        let requiredBuilds = existing == nil
            ? [(appID, appName, appProductName), (targetID, targetName, "\(targetName).xctest")]
            : [(targetID, targetName, "\(targetName).xctest")]
        for (id, name, productName) in requiredBuilds where !builtIDs.contains(id) {
            let entry = XMLElement(name: "BuildActionEntry")
            for attribute in ["buildForTesting", "buildForRunning", "buildForProfiling", "buildForArchiving", "buildForAnalyzing"] {
                let enabled = id == appID || attribute == "buildForTesting"
                entry.addAttribute(XMLNode.attribute(withName: attribute, stringValue: enabled ? "YES" : "NO") as! XMLNode)
            }
            entry.addChild(buildableReference(project: project, id: id, name: name,
                                              productName: productName, referenceContainer: referenceContainer))
            buildEntries.addChild(entry)
        }
        let testAction = root.elements(forName: "TestAction").first ?? XMLElement(name: "TestAction")
        if testAction.parent == nil { root.addChild(testAction) }
        let testables = testAction.elements(forName: "Testables").first ?? XMLElement(name: "Testables")
        if testables.parent == nil { testAction.addChild(testables) }
        let existingIDs = testables.elements(forName: "TestableReference")
            .compactMap { $0.elements(forName: "BuildableReference").first?.attribute(forName: "BlueprintIdentifier")?.stringValue }
        if let existing, existingIDs.contains(targetID), builtIDs.contains(targetID) {
            return existing
        }
        if !existingIDs.contains(targetID) {
            let ref = XMLElement(name: "TestableReference")
            ref.addAttribute(XMLNode.attribute(withName: "skipped", stringValue: "NO") as! XMLNode)
            ref.addChild(buildableReference(project: project, id: targetID, name: targetName,
                                            productName: "\(targetName).xctest",
                                            referenceContainer: referenceContainer))
            testables.addChild(ref)
        }
        return xml.xmlData(options: [.nodePrettyPrint])
    }

    private func buildableReference(project: URL, id: String, name: String,
                                    productName: String, referenceContainer: String) -> XMLElement {
        let buildable = XMLElement(name: "BuildableReference")
        for (key, value) in [("BuildableIdentifier", "primary"), ("BlueprintIdentifier", id),
                             ("BuildableName", productName), ("BlueprintName", name),
                             ("ReferencedContainer", referenceContainer)] {
            buildable.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
        }
        return buildable
    }
}
