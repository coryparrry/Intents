import SwiftUI
import UniformTypeIdentifiers

struct AppleTestConnectionView: View {
    @Bindable var coordinator: ScenarioCoordinator
    @State private var showingProjectImporter = false
    @State private var showingConnectionApproval = false

    var onContinue: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            connectionCard
            if selectedProjectName != nil {
                DisclosureGroup("Add or update test support") {
                    IntentLabSetupInstallerView(coordinator: coordinator)
                        .padding(.top, 12)
                }
            }
            DisclosureGroup("Technical details") {
                VStack(spacing: 16) {
                    advancedConfiguration
                    harnessGuidance
                }.padding(.top, 12)
            }
            DisclosureGroup("About App Intents") {
                VStack(alignment: .leading, spacing: 8) {
                    IntentLabHelp("An intent is an action your app exposes to Shortcuts and Siri, such as opening a note. Tests give the action inputs and check what happened. Your app needs Intent Lab test support before it can run here.")
                    Link("Apple’s guide to App Intents", destination: URL(string: "https://developer.apple.com/documentation/appintents")!)
                }.padding(.top, 8)
            }
        }
        .fileImporter(
            isPresented: $showingProjectImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            do {
                let url = try result.get().first
                guard let url else { return }
                coordinator.selectContainer(url)
                if ["xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()) {
                    showingConnectionApproval = true
                }
            } catch {
                coordinator.notice = error.localizedDescription
            }
        }
        .fileDialogMessage("Choose the app's Xcode project or workspace.")
        .fileDialogConfirmationLabel("Choose Project")
        .confirmationDialog(
            "Connect this app?",
            isPresented: $showingConnectionApproval
        ) {
            Button("Connect app") {
                Task { await coordinator.approveBuildAndDiscover() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We’ll ask Xcode to find your app and test settings. Connecting also allows Xcode to run this project’s build scripts and resolve dependencies when needed. Approval lasts until you quit Intents.")
        }
        .onChange(of: coordinator.configuration.destinationIdentifier) { _, identifier in
            Task { await coordinator.selectDevice(identifier) }
        }
    }

    private var connectionCard: some View {
        IntentLabCard(
            "Connect an app",
            subtitle: "Choose the app project and an available Mac, paired iPhone, or iPhone simulator. Intent Lab discovers the Xcode details for you."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                connectionField(
                    title: "App project",
                    detail: selectedProjectName ?? "Select the app's .xcodeproj or .xcworkspace."
                ) {
                    HStack(spacing: 12) {
                        Button(selectedProjectName == nil ? "Choose Project…" : "Change…", systemImage: "folder") {
                            showingProjectImporter = true
                        }
                        .disabled(coordinator.isDiscoveringConnection || coordinator.isVerifyingIntegration || coordinator.isRunning)
                        if coordinator.isDiscoveringConnection {
                            ProgressView().controlSize(.small)
                            Text("Finding app and test settings…").foregroundStyle(.secondary)
                        } else if coordinator.projectTrusted {
                            Label("Project connected", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        } else if selectedProjectName != nil {
                            Button("Connect app…") { showingConnectionApproval = true }
                                .help("Allow this saved project to connect for the current session")
                        }
                    }

                }

                DeveloperConnectionBanner()

                connectionField(
                    title: "Run on",
                    detail: selectedDeviceDetail
                ) {
                    HStack(spacing: 8) {
                        Picker("Run destination", selection: $coordinator.configuration.destinationIdentifier) {
                            Text("Choose destination").tag("")
                            if !coordinator.configuration.destinationIdentifier.isEmpty,
                               selectedDeviceName == nil {
                                Text("Saved destination unavailable")
                                    .tag(coordinator.configuration.destinationIdentifier)
                            }
                            ForEach(coordinator.discoveredDevices) { device in
                                Text(device.available ? device.name : "\(device.name) — unavailable")
                                    .tag(device.identifier)
                                    .disabled(!device.available)
                            }
                        }
                        .labelsHidden()
                        .fixedSize(horizontal: true, vertical: false)
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await coordinator.refreshDevices() }
                        }
                        .labelStyle(.iconOnly)
                        .help("Refresh available destinations")
                    }
                }

                if coordinator.draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion
                    || coordinator.draft.schemaVersion == ScenarioDefinition.stableSchemaVersion {
                    connectionField(
                        title: "Check installed support",
                        detail: coordinator.verifiedIntegrationSummary
                            ?? "Build the selected app and UI tests, then read the compiled integration receipt. This check does not run an app action."
                    ) {
                        Button(
                            coordinator.isVerifyingIntegration ? "Checking…" : "Build and check support",
                            systemImage: "checkmark.seal"
                        ) {
                            Task { await coordinator.verifyInstalledIntegration() }
                        }
                        .disabled(!coordinator.projectTrusted
                                  || coordinator.configuration.destinationIdentifier.isEmpty
                                  || coordinator.isVerifyingIntegration)
                    }
                }

                if let discovery = coordinator.connectionDiscovery {
                    discoveredChoices(discovery)
                }

                connectionStatus

                recoveryControls

                HStack {
                    Text("Next, describe the action you want to test.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Create test", systemImage: "arrow.right", action: onContinue)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var advancedConfiguration: some View {
        EditorSection(
            "Advanced configuration",
            systemImage: "slider.horizontal.3",
            description: "Xcode scheme, test target and device settings"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                advancedRow("Container", help: "The Xcode project or workspace containing your app and its tests. Choose it in Connection.") {
                    Text(coordinator.configuration.containerPath.isEmpty ? "Choose a project above" : coordinator.configuration.containerPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                advancedRow("Scheme", help: "The Xcode scheme that includes the app and UI tests you want to run. If you change it, approve the build and run connection again.") {
                    TextField("App scheme", text: Binding(
                        get: { coordinator.configuration.scheme },
                        set: { coordinator.selectScheme($0) }
                    ))
                }
                advancedRow("Build configuration", help: "The Xcode configuration used to build the app and UI tests. Intent Lab selects the scheme's Test configuration when available. If you change it, approve the build and run connection again.") {
                    TextField("Debug", text: Binding(
                        get: { coordinator.configuration.configuration },
                        set: { coordinator.selectBuildConfiguration($0) }
                    ))
                }
                advancedRow("Development team", help: "Optional Apple team ID for this build and run. This overrides Xcode's team selection for the command without changing project settings. Approve the connection again after editing it.") {
                    TextField("Apple team ID", text: Binding(
                        get: { coordinator.configuration.developmentTeam ?? "" },
                        set: { coordinator.selectDevelopmentTeam($0) }
                    ))
                }
                advancedRow("Provisioning updates", help: "When enabled, Xcode may create or update Apple development certificates, app IDs, and provisioning profiles for this build. Use only with an account permitted to manage signing.") {
                    Toggle("Allow Xcode to update provisioning", isOn: Binding(
                        get: { coordinator.configuration.allowProvisioningUpdates == true },
                        set: { coordinator.setAllowsProvisioningUpdates($0) }
                    ))
                }
                advancedRow("UI-test target", help: "The group of automated interface tests containing Intent Lab’s test support. This is a test target, not the app target.") {
                    TextField("AppUITests", text: Binding(
                        get: { coordinator.configuration.testTarget },
                        set: {
                            coordinator.configuration.testTarget = $0
                            coordinator.configuration.selectedTestProductID = nil
                            coordinator.invalidatePreflight()
                        }
                    ))
                }
                advancedRow("Test bundle ID", help: "The unique identifier of the compiled UI-test bundle. Use the discovered value or copy it from the test target’s Xcode settings.") {
                    TextField("com.example.AppUITests", text: Binding(
                        get: { coordinator.configuration.testBundleIdentifier },
                        set: { coordinator.configuration.testBundleIdentifier = $0; coordinator.invalidatePreflight() }
                    ))
                }
                advancedRow("Destination identifier", help: "The unique ID of the Mac, paired iPhone, or simulator used for this run. Choosing a destination in Connect app fills this in.") {
                    TextField("000081…", text: Binding(
                        get: { coordinator.configuration.destinationIdentifier },
                        set: { coordinator.configuration.destinationIdentifier = $0; coordinator.invalidatePreflight() }
                    ))
                }
                IntentLabHelp("Command preview shows the Xcode build command for these settings. Opening the preview does not run it.")
                DisclosureGroup("Command preview") {
                    Text(commandPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .workspaceInset(radius: 8)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func connectionField<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            content().controlSize(.regular)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func discoveredChoices(_ discovery: XcodeConnectionDiscovery) -> some View {
        if discovery.schemes.count > 1 || discovery.applications.count > 1 || discovery.uiTestBundles.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Label("Choose the matching app configuration", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout.weight(.semibold))
                IntentLabHelp("Scheme chooses what Xcode builds. Application chooses the app to test. UI-test target chooses the tests that contain Intent Lab support. Select the matching set for your app.")
                if discovery.schemes.count > 1 {
                    Picker("Scheme", selection: Binding(
                        get: { coordinator.configuration.scheme },
                        set: { coordinator.selectScheme($0) }
                    )) {
                        Text("Choose scheme").tag("")
                        ForEach(discovery.schemes, id: \.self) { Text($0).tag($0) }
                    }
                }
                if discovery.applications.count > 1 {
                    Picker("Application", selection: Binding(
                        get: { coordinator.configuration.selectedApplicationProductID ?? "" },
                        set: { identity in
                            guard let product = discovery.applications.first(where: { $0.id == identity }) else { return }
                            coordinator.selectApplication(product)
                        }
                    )) {
                        Text("Choose application").tag("")
                        ForEach(discovery.applications) { product in
                            Text(product.projectPath.map { "\(product.targetName) · \(URL(filePath: $0).lastPathComponent)" }
                                 ?? product.targetName).tag(product.id)
                        }
                    }
                }
                if discovery.uiTestBundles.count > 1 {
                    Picker("UI-test target", selection: Binding(
                        get: { coordinator.configuration.selectedTestProductID ?? "" },
                        set: { identity in
                            guard let product = discovery.uiTestBundles.first(where: { $0.id == identity }) else { return }
                            coordinator.selectUITestBundle(product)
                        }
                    )) {
                        Text("Choose UI-test target").tag("")
                        ForEach(discovery.uiTestBundles) { product in
                            Text(product.projectPath.map { "\(product.targetName) · \(URL(filePath: $0).lastPathComponent)" }
                                 ?? product.targetName).tag(product.id)
                        }
                    }
                }
                Button("Check connection", systemImage: "checklist") {
                    Task { await coordinator.refreshPreflight() }
                }
            }
            .padding(14)
            .workspaceInset(radius: 10)
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        if let report = coordinator.preflight {
            let anyRouteReady = coordinator.routeReadiness.values.contains { $0.state == .ready }
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    report.isReady ? "Ready to run on \(selectedDeviceName ?? "selected destination")"
                        : (anyRouteReady ? "Some routes are ready on \(selectedDeviceName ?? "selected destination")"
                            : "Finish setup before running"),
                    systemImage: report.isReady || anyRouteReady
                        ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(report.isReady ? .green : .orange)
                .font(.callout.weight(.semibold))
                if !report.isReady {
                    DisclosureGroup("See what needs attention") {
                        ForEach(report.checks.filter { $0.state != .ready }) { check in
                            Text(check.detail)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                }
                ForEach(ScenarioLane.allCases.filter {
                    coordinator.draft.coverage[$0] != .notApplicable
                }) { lane in
                    if let readiness = coordinator.routeReadiness[lane] {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(lane.title).font(.caption.weight(.semibold))
                                .frame(width: 130, alignment: .leading)
                            Text(readiness.backendName ?? defaultBackendName(for: lane))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(routeStatus(readiness.state)).font(.caption)
                                .foregroundStyle(readiness.state == .ready ? Color.green : Color.orange)
                            Spacer(minLength: 8)
                        }
                        Text(readiness.detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let operation = readiness.supportOperationID {
                            Text("Readiness support: \(operation)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((report.isReady ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func routeStatus(_ state: ScenarioRouteReadinessState) -> String {
        switch state {
        case .ready: "Ready on selected app and device"
        case .setupRequired: "Setup required"
        case .environmentBlocked: "Environment blocked"
        case .notYetVerified: "Not yet verified"
        }
    }

    private func defaultBackendName(for lane: ScenarioLane) -> String {
        switch lane {
        case .appFeature: coordinator.featureBackend.provenanceLabel
        case .intentIntegration: "AppIntentsTesting"
        case .siri: "CoreTesting Siri driver"
        }
    }

    private var harnessGuidance: some View {
        EditorSection(
            "Test support your app needs",
            systemImage: "checkmark.shield",
            description: "Required test support and observable results"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                IntentLabHelp("A test harness is helper code that prepares sample data, runs the action, and reports what happened. A fixture is that known sample data. Your app needs both before Intent Lab can test it.")
                Text("The selected UI-test target must include IntentLabScenarioTests/testIntentLabScenario and harness version \(ScenarioInvocationIdentity.currentHarnessVersion).")
                Text("The fixture must expose reset, invocation-correlation, and observable-result accessibility values. Intent Lab reports missing signing, test identity, fixture, and evidence separately; it never changes signing automatically.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var recoveryControls: some View {
        if !coordinator.recoveryJournals.isEmpty {
            Divider()
            Label("Device recovery required", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Automatic clearing is intentionally disabled until the device proves that this invocation stopped and the fixture reset. You can clear it after verifying both conditions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("I verified termination and fixture readiness") {
                Task { await coordinator.clearDeviceQuarantine(fixtureReadinessProven: true) }
            }
        }
    }

    private func advancedRow<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                content()
                IntentLabHelp(help)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedProjectName: String? {
        guard !coordinator.configuration.containerPath.isEmpty else { return nil }
        return URL(filePath: coordinator.configuration.containerPath).lastPathComponent
    }

    private var selectedDevice: IntentLabDeviceDestination? {
        coordinator.discoveredDevices.first { $0.identifier == coordinator.configuration.destinationIdentifier }
    }

    private var selectedDeviceName: String? { selectedDevice?.name }

    private var selectedDeviceDetail: String {
        guard !coordinator.configuration.destinationIdentifier.isEmpty else { return "Select an available Mac, paired iPhone, or iPhone simulator." }
        return selectedDeviceName ?? "The saved destination is not currently available."
    }

    private var commandPreview: String {
        let configuration = coordinator.configuration
        let arguments = [
            configuration.isWorkspace ? "-workspace" : "-project", configuration.containerPath,
            "-scheme", configuration.scheme,
            "-configuration", configuration.configuration,
            "-destination", "id=\(configuration.destinationIdentifier)"
        ] + configuration.signingArguments + ["build-for-testing"]
        return "xcodebuild " + arguments.map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
