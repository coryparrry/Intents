import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Static inspection and a file preview run before project build approval.
struct IntentLabSetupInstallerView: View {
    private enum SupportMode: String, CaseIterable {
        case direct = "App Intent"
        case siri = "Siri"
    }

    @Bindable var coordinator: ScenarioCoordinator
    @State private var projectPaths: [String] = []
    @State private var projectPath = ""
    @State private var inspection: IntentLabProjectInspection?
    @State private var appTargetID = ""
    @State private var uiTestTargetID = ""
    @State private var scheme = ""
    @State private var appBundleID = ""
    @State private var intentIdentifier = ""
    @State private var declaredReadOnly = false
    @State private var supportMode: SupportMode = .direct
    @State private var packageSource = "https://github.com/coryparrry/Intents.git"
    @State private var packageRevision = ""
    @State private var choosingLocalPackage = false
    @State private var choosingManualExport = false
    @State private var choosingInstalledDeclaration = false
    @State private var scopedPackageURL: URL?
    @State private var plan: IntentLabInstallationPlan?
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Install Intent Lab test support", systemImage: "shippingbox.and.arrow.backward")
                .font(.callout.weight(.semibold))
            IntentLabHelp("Inspect the project and review every proposed file before applying. The package is linked only to a UI-test target. Building and running require separate approval in Connect app.")
            if projectPaths.count > 1 {
                Picker("Owning project", selection: $projectPath) {
                    Text("Choose project").tag("")
                    ForEach(projectPaths, id: \.self) { path in
                        Text(URL(filePath: path).lastPathComponent).tag(path)
                    }
                }
                .onChange(of: projectPath) { _, _ in inspectSelectedProject() }
            }
            if let inspection {
                Picker("Application target", selection: $appTargetID) {
                    Text("Choose application").tag("")
                    ForEach(inspection.applications) { target in
                        Text(target.name).tag(target.id)
                    }
                }
                Picker("UI-test target", selection: $uiTestTargetID) {
                    Text("Create a dedicated UI-test target").tag("")
                    ForEach(inspection.uiTestTargets) { target in
                        Text(target.name).tag(target.id)
                    }
                }
                Picker("Shared scheme", selection: $scheme) {
                    Text("Choose scheme").tag("")
                    ForEach(inspection.sharedSchemes, id: \.self) { Text($0).tag($0) }
                }
                Button("Refresh project choices", systemImage: "arrow.clockwise") {
                    inspectSelectedProject()
                }
                .buttonStyle(.borderless)
                TextField("Application bundle ID", text: $appBundleID)
                    .textContentType(.none)
                TextField("Known App Intent identifier", text: $intentIdentifier)
                Toggle("This action is read-only", isOn: $declaredReadOnly)
                IntentLabHelp("The generated Basic integration does not prepare an isolated dataset. Confirm this only for an action that does not mutate app or external state. For a mutating intent, add an isolated test configuration and app-owned preparation/observation adapter before running it.")
                Picker("Test route", selection: $supportMode) {
                    ForEach(SupportMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                TextField("Package Git URL or local development path", text: $packageSource)
                Button("Choose local package checkout…", systemImage: "folder") {
                    choosingLocalPackage = true
                }
                if packageSource.hasPrefix("https://") {
                    TextField("Exact published Git revision (40 hex characters)", text: $packageRevision)
                }
                IntentLabHelp("For a reusable installation, enter an exact published package revision. A local checkout is for development and will not work after that checkout moves or disappears.")
                IntentLabHelp(supportMode == .direct
                    ? "The generated entry point supports Basic direct checks. Behaviour checks require your app's own observation adapter."
                    : "Siri support uses the XCTest-only package. Add a typed app-owned UI observer with a stable selector to the declaration, then implement preparation, observation, and completion in the adapter. Preview will give manual setup steps until that observer exists. The scaffold does not invent app results.")
                HStack {
                    Button("Choose installed integration declaration…", systemImage: "checkmark.seal") {
                        choosingInstalledDeclaration = true
                    }
                    .disabled(uiTestTargetID.isEmpty || appBundleID.isEmpty || scheme.isEmpty)
                }
                IntentLabHelp("For an app-owned adapter, choose the actual JSON bundled with the selected UI-test target. This also supports mutating intents after you add isolated test preparation. A compiled connection check is still required.")
                HStack {
                    Button("Preview support changes") { preview() }
                    if let plan, plan.supported {
                        Button("Apply reviewed changes") { apply(plan) }
                            .disabled(plan.changes.isEmpty)
                    }
                }
            }
            if let plan {
                previewDetails(plan)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .workspaceInset(radius: 10)
        .task(id: coordinator.configuration.containerPath) { inspectContainer() }
        .onChange(of: appTargetID) { _, _ in
            plan = nil; declaredReadOnly = false; coordinator.invalidatePreflight()
        }
        .onChange(of: uiTestTargetID) { _, _ in plan = nil }
        .onChange(of: scheme) { _, _ in plan = nil }
        .onChange(of: appBundleID) { _, _ in
            plan = nil; declaredReadOnly = false; coordinator.invalidatePreflight()
        }
        .onChange(of: intentIdentifier) { _, _ in
            plan = nil; declaredReadOnly = false; coordinator.invalidatePreflight()
        }
        .onChange(of: declaredReadOnly) { _, _ in plan = nil }
        .onChange(of: packageSource) { _, _ in plan = nil }
        .onChange(of: packageRevision) { _, _ in plan = nil }
        .onChange(of: supportMode) { _, _ in plan = nil; coordinator.invalidatePreflight() }
        .fileImporter(isPresented: $choosingLocalPackage, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                scopedPackageURL?.stopAccessingSecurityScopedResource()
                scopedPackageURL = url.startAccessingSecurityScopedResource() ? url : nil
                packageSource = url.path
            } catch {
                status = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosingManualExport, allowedContentTypes: [.folder]) { result in
            do {
                guard let plan else { return }
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let exported = try IntentLabProjectInstaller().exportManualFiles(plan, to: url)
                status = "Exported \(exported.count) reviewable setup files to \(url.lastPathComponent)."
            } catch {
                status = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosingInstalledDeclaration, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try bindInstalledDeclaration(data: Data(contentsOf: url))
            } catch {
                status = error.localizedDescription
            }
        }
    }

    @ViewBuilder private func previewDetails(_ plan: IntentLabInstallationPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.supported ? "Preview · \(plan.changes.count) file changes" : "Manual integration needed")
                .font(.callout.weight(.semibold))
            Text("Package: \(plan.packageSourceDescription)")
                .font(.caption).textSelection(.enabled)
            ForEach(plan.manualSteps, id: \.self) { step in
                Label(step, systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            if !plan.manualFiles.isEmpty {
                Button("Export manual setup files…", systemImage: "square.and.arrow.up") {
                    choosingManualExport = true
                }
                ForEach(plan.manualFiles, id: \.filename) { file in
                    DisclosureGroup(file.filename) {
                        Text(file.purpose).font(.caption)
                        ScrollView([.horizontal, .vertical]) {
                            Text(String(decoding: file.data, as: UTF8.self))
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                }
            }
            if plan.supported && plan.changes.isEmpty {
                Label("Support files are already installed. Build verification is still required.", systemImage: "checkmark.circle")
                    .font(.caption)
            }
            ForEach(plan.changes, id: \.url) { change in
                DisclosureGroup(change.url.lastPathComponent) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(change.summary)
                        Text("Previous: \(change.beforeDigest ?? "new file")")
                        Text("Proposed: \(change.afterDigest)")
                        ScrollView([.horizontal, .vertical]) {
                            Text(String(decoding: change.proposed, as: UTF8.self))
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                    .font(.caption)
                    .padding(.top, 5)
                }
            }
        }
        .padding(10)
        .workspaceInset(radius: 8)
    }

    private func inspectContainer() {
        plan = nil
        inspection = nil
        status = nil
        let container = URL(filePath: coordinator.configuration.containerPath)
        guard !coordinator.configuration.containerPath.isEmpty else { return }
        do {
            if container.pathExtension == "xcworkspace" {
                let projects = try XcodeConnectionDiscoveryService.workspaceProjectURLs(workspace: container)
                projectPaths = projects.map(\.path)
                if projectPaths.isEmpty {
                    status = "Choose the owning Xcode project directly; this workspace has no referenced project."
                }
            } else {
                projectPaths = [container.path]
            }
            projectPath = projectPaths.count == 1 ? projectPaths[0] : ""
            inspectSelectedProject()
        } catch {
            status = error.localizedDescription
        }
    }

    private func inspectSelectedProject() {
        plan = nil
        declaredReadOnly = false
        guard !projectPath.isEmpty else { return }
        do {
            let result = try IntentLabProjectInstaller.inspect(
                projectURL: URL(filePath: projectPath),
                workspaceURL: coordinator.configuration.isWorkspace
                    ? URL(filePath: coordinator.configuration.containerPath) : nil
            )
            inspection = result
            appTargetID = result.applications.count == 1 ? result.applications[0].id : ""
            uiTestTargetID = result.uiTestTargets.count == 1 ? result.uiTestTargets[0].id : ""
            scheme = result.sharedSchemes.count == 1 ? result.sharedSchemes[0] : ""
            appBundleID = coordinator.connectionDiscovery?.applications.first {
                $0.targetID == appTargetID && $0.projectPath == projectPath
            }?.bundleIdentifier
                ?? (coordinator.draft.target.projectPath == coordinator.configuration.containerPath
                    ? coordinator.draft.target.bundleIdentifier : "")
            intentIdentifier = appBundleID == coordinator.draft.target.bundleIdentifier
                ? coordinator.draft.directControl.intentIdentifier : ""
            status = result.applications.isEmpty ? "No app target was found. Review this project manually." : nil
        } catch {
            inspection = nil
            status = error.localizedDescription
        }
    }

    private func preview() {
        do {
            plan = try IntentLabProjectInstaller().preview(makeRequest())
            status = nil
        } catch {
            plan = nil
            status = error.localizedDescription
        }
    }

    private func apply(_ reviewedPlan: IntentLabInstallationPlan) {
        do {
            let receipt = try IntentLabProjectInstaller().apply(reviewedPlan)
            let verification = try IntentLabProjectInstaller().verify(makeRequest())
            guard verification.installed else {
                status = "Support files changed, but verification found: \(verification.missing.joined(separator: ", "))"
                return
            }
            status = receipt.alreadyInstalled
                ? "Support files are already installed. Approve the build to check the compiled integration."
                : "Installed \(receipt.changedFiles.count) files. Approve the build to check the compiled integration."
            if let digest = reviewedPlan.declarationDigest {
                let installedTarget = try IntentLabProjectInstaller.inspect(projectURL: URL(filePath: projectPath))
                    .uiTestTargets.first { $0.name == reviewedPlan.targetName }
                let productID = installedTarget.map { "\(projectPath)#\($0.id)" }
                let applicationProductID = "\(projectPath)#\(appTargetID)"
                if coordinator.draft.schemaVersion != ScenarioDefinition.reusableSchemaVersion
                    && coordinator.draft.schemaVersion != ScenarioDefinition.stableSchemaVersion {
                    coordinator.startReusableCheck()
                }
                coordinator.recordInstalledIntegration(
                    .init(id: "\(appBundleID).intentlab", version: "1", digest: digest),
                    appBundleID: appBundleID,
                    projectPath: projectPath,
                    scheme: scheme,
                    testTarget: reviewedPlan.targetName,
                    applicationProductID: applicationProductID,
                    testProductID: productID
                )
            }
            coordinator.invalidatePreflight()
            plan = try IntentLabProjectInstaller().preview(makeRequest())
        } catch {
            status = error.localizedDescription
        }
    }

    private func bindInstalledDeclaration(data: Data) throws {
        guard let target = inspection?.uiTestTargets.first(where: { $0.id == uiTestTargetID }) else {
            throw IntentLabProjectInstallerError.unsupported(
                "Choose the UI-test target that contains the installed declaration."
            )
        }
        let declaration = try IntentLabProjectInstaller.validateDeclaration(
            data,
            targetBundleIdentifier: appBundleID,
            testTargetName: target.name
        )
        if coordinator.draft.schemaVersion != ScenarioDefinition.reusableSchemaVersion
            && coordinator.draft.schemaVersion != ScenarioDefinition.stableSchemaVersion {
            coordinator.startReusableCheck()
        }
        coordinator.recordInstalledIntegration(
            .init(id: declaration.id, version: declaration.version, digest: declaration.digest),
            appBundleID: appBundleID,
            projectPath: projectPath,
            scheme: scheme,
            testTarget: target.name,
            applicationProductID: "\(projectPath)#\(appTargetID)",
            testProductID: "\(projectPath)#\(target.id)"
        )
        status = "Actual declaration selected. Approve the build, then check its compiled receipt before running."
    }

    private func makeRequest() throws -> IntentLabInstallationRequest {
        guard !projectPath.isEmpty, !scheme.isEmpty, !appTargetID.isEmpty,
              !appBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !intentIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !packageSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntentLabProjectInstallerError.unsupported("Choose a project, scheme, app target, bundle ID, known intent, and package source first.")
        }
        guard declaredReadOnly else {
            throw IntentLabProjectInstallerError.unsupported(
                "The Basic template is for a declared read-only action. Add an isolated test build and app-owned adapter for mutation checks."
            )
        }
        let packageURL: URL
        if packageSource.hasPrefix("https://") {
            guard let remote = URL(string: packageSource) else {
                throw IntentLabProjectInstallerError.unsupported("Enter a valid HTTPS package URL.")
            }
            packageURL = remote
        } else {
            packageURL = URL(filePath: packageSource)
        }
        return .init(
            projectURL: URL(filePath: projectPath),
            workspaceURL: selectedWorkspaceURL,
            scheme: scheme,
            applicationTargetID: appTargetID,
            uiTestTargetID: uiTestTargetID.isEmpty ? nil : uiTestTargetID,
            packageURL: packageURL,
            packageRevision: packageSource.hasPrefix("https://") ? packageRevision : nil,
            packageProduct: supportMode == .siri ? "IntentLabCoreTesting" : "IntentLabTesting",
            consumerSource: supportMode == .siri ? Self.siriConsumerSource : Self.consumerSource,
            declarationData: try declarationData()
        )
    }

    private func declarationData() throws -> Data {
        let targetName = inspection?.uiTestTargets.first(where: { $0.id == uiTestTargetID })?.name
            ?? "IntentLabUITests"
        let usesDraftAction = coordinator.draft.target.bundleIdentifier == appBundleID
            && coordinator.draft.directControl.intentIdentifier == intentIdentifier
        let parameters: [[String: Any]] = try usesDraftAction
            ? coordinator.draft.directControl.parameters.map { parameter in
                ["name": parameter.name, "type": try jsonObject(parameter.type),
                 "required": !parameter.isOptional]
            } : []
        let projections: [[String: Any]] = try usesDraftAction
            ? coordinator.draft.directControl.outputFields.compactMap { field in
                guard let path = field.path else { return nil }
                return ["id": field.name, "type": try jsonObject(field.type),
                        "path": try jsonObject(path)]
            } : []
        var capabilities = supportMode == .siri
            ? ["environment-payload", "preparation", "siri", "siri-completion", "accessible-result", "invocation-correlation"]
            : ["environment-payload", "direct-intent-execution"]
        if supportMode == .direct && !projections.isEmpty { capabilities.append("direct-intent-output") }
        let declaration: [String: Any] = [
            "schemaVersion": 1,
            "id": "\(appBundleID).intentlab",
            "version": "1",
            "targetBundleIdentifier": appBundleID,
            "projectIdentity": IntentLabProjectInstaller.declarationProjectIdentity(
                projectURL: URL(filePath: projectPath), workspaceURL: selectedWorkspaceURL),
            "targetIdentity": targetName,
            "supportedHarnessProtocols": ["intent-lab-v2"],
            "actions": [["id": intentIdentifier, "parameters": parameters]],
            "resultProjections": supportMode == .siri ? [] : projections,
            "preparationOperations": ["none"],
            "observers": [],
            "isolation": ["kind": "readOnly"],
            "capabilities": capabilities
        ]
        return try JSONSerialization.data(withJSONObject: declaration, options: [.prettyPrinted, .sortedKeys])
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private static let consumerSource = """
        import XCTest
        import IntentLabTesting

        @available(macOS 27.0, iOS 27.0, *)
        @MainActor
        final class IntentLabScenarioTests: XCTestCase {
            func testIntentLabScenario() throws {
                try IntentLabScenarioRunner.run(testCase: self, integration: IntentLabBasicIntegration())
            }

            func testIntentLabConnection() throws {
                try IntentLabScenarioRunner.checkConnection(testCase: self, integration: IntentLabBasicIntegration())
            }
        }
        """

    private static let siriConsumerSource = """
        import XCTest
        import IntentLabCoreTesting

        @available(macOS 27.0, iOS 27.0, *)
        @MainActor
        final class IntentLabScenarioTests: XCTestCase {
            func testIntentLabScenario() throws {
                try IntentLabSiriScenarioRunner.run(testCase: self, integration: IntentLabAppAdapter())
            }

            func testIntentLabConnection() throws {
                try IntentLabSiriScenarioRunner.checkConnection(testCase: self, integration: IntentLabAppAdapter())
            }
        }
        """

    private var selectedWorkspaceURL: URL? {
        let containerPath = coordinator.configuration.containerPath
        guard containerPath.hasSuffix(".xcworkspace") else { return nil }
        return URL(filePath: containerPath)
    }
}
