import SwiftUI
import AppKit
import IntentsAutomationCore

struct AutomationSourcePreparationControls: View {
    @Bindable var model: AppAutomationStore
    let approveBuild: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Xcode", selection: Binding(get: { model.developerDirectory.path }, set: { id in
                    do { try model.selectInstalledToolchain(id) }
                    catch { model.message = model.errorText(error) }
                })) {
                    if !model.installedToolchains.contains(where: { $0.id == model.developerDirectory.path }) {
                        Text("Current Xcode · unavailable").tag(model.developerDirectory.path)
                    }
                    ForEach(model.installedToolchains) { choice in
                        Text(choice.label + (choice.id == model.defaultDeveloperDirectoryPath ? " · Default" : ""))
                            .tag(choice.id)
                    }
                }.accessibilityIdentifier("automation.preparation.xcode").disabled(model.busy)
                Button("Refresh Xcodes") { model.refreshInstalledToolchains() }.disabled(model.busy)
            }

            Picker("Prepare for", selection: $model.preparationDestination) {
                ForEach(AutomationNativePreparationDestination.allCases) { Text($0.title).tag($0).accessibilityIdentifier($0.rawValue) }
            }.accessibilityLabel("Prepare for").accessibilityIdentifier("automation.preparation.destination")
            LabeledContent {
                TextField("Default Xcode for this destination", text: $model.selectedXcodePath,
                          prompt: Text("/Applications/Xcode.app"))
                    .accessibilityLabel("Default Xcode for this destination")
                    .accessibilityIdentifier("automation.xcode.default")
                    .onSubmit { Task { await model.refreshTargets() } }
                    .disabled(model.busy)
            } label: {
                Text("Default Xcode for this destination").font(.caption)
            }
            LabeledContent {
                TextField("Xcode override for this run", text: $model.runXcodePathOverride,
                          prompt: Text("Use destination default"))
                    .accessibilityLabel("Xcode override for this run")
                    .accessibilityIdentifier("automation.xcode.override")
                    .onSubmit { Task { await model.refreshTargets() } }
                    .disabled(model.busy)
            } label: {
                Text("Xcode override for this session").font(.caption)
            }
            Text("The default is saved separately for simulator, device and Mac. An override applies to preparation and execution in this session.")
                .font(.caption).foregroundStyle(.secondary)
            if model.preparationDestination == .simulator {
                Picker("Simulator", selection: $model.simulatorID) {
                    ForEach(model.simulators) { Text("\($0.name) · \($0.state)").tag($0.id).accessibilityIdentifier($0.id) }
                }.accessibilityLabel("Simulator").accessibilityIdentifier("automation.preparation.simulator")
                Button("Refresh simulators") { Task { await model.refreshTargets() } }
                    .disabled(model.busy).accessibilityIdentifier("automation.preparation.refreshSimulators")
            } else if model.preparationDestination == .physical {
                Picker("iPhone or iPad", selection: $model.physicalDeviceID) {
                    Text("Choose a device").tag("")
                    ForEach(model.physicalDevices) { device in
                        Text(device.selectionLabel + (device.available ? "" : " · Unavailable"))
                            .tag(device.id).disabled(!device.available)
                    }
                }.accessibilityLabel("iPhone or iPad")
                Button("Refresh devices") { Task { await model.refreshTargets() } }.disabled(model.busy)
                Text(model.physicalDevices.isEmpty ? "Connect and unlock your iPhone or iPad, then refresh devices." : "Preparation builds a private copy for the selected device. Installation is reviewed separately.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Build a private Mac copy for inspection. Mac workflow execution is not available yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Additional source folders").font(.subheadline.bold())
                Text("Select sibling folders this project needs, such as local packages. These folders will be copied when you approve the build.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.sourceGrants.urls, id: \.self) { url in
                    HStack(alignment: .top) {
                        Text(url.path).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Remove") { model.removeAdditionalSourceFolder(url) }.disabled(model.busy)
                            .accessibilityLabel("Remove source folder " + url.lastPathComponent)
                    }
                }
                Button("Add source folder…", action: chooseSourceFolder).disabled(model.busy || model.sourceGrants.urls.count >= 8)
            }
            Toggle("Copy installed native dependencies", isOn: $model.includesSourceDependencies).disabled(model.busy)
            HStack {
                Menu("Advanced JavaScript preparation") {
                    Button("Choose existing server qualification…", action: chooseJavaScriptRecipe)
                }.disabled(model.busy)
                if model.servedJavaScriptProfile != nil {
                    Button("Remove server recipe") {
                        do { try model.selectJavaScriptRecipe(nil) }
                        catch { model.message = model.errorText(error) }
                    }.disabled(model.busy)
                }
            }
            if let recipe = model.servedJavaScriptProfile {
                Text("JavaScript endpoint: \(recipe.bundleURL). The approved recipe runs in a private copy and stops after each use.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.preparationDestination != .simulator {
                    Text("This loopback server recipe requires iOS Simulator.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.servedJavaScriptProfile == nil {
                Text("Recognized installed Expo development tools are detected when you review the build. Intents prepares their private server and verifies the selected app receives the pinned JavaScript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("For Flutter and Expo projects, copy dependency folders and linked files within the selected source folders. Add any linked external package folder above.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Prepare app…", action: approveBuild).disabled(!model.canPrepare)
        }
    }
    private func chooseJavaScriptRecipe() {
        guard let root = model.selectedSourceRoot else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = root; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the existing qualified JavaScript server JSON. It must pin installed Node, a leaf server script, the loopback bundle URL, served bytes and the native runtime binding."
        let epoch = model.selectionEpoch
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url, model.selectionEpoch == epoch else { return }
            do { try model.selectJavaScriptRecipe(url) }
            catch { model.message = model.errorText(error) }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add source folder"
        panel.message = "Choose a sibling source or local package folder. Its parent and other sibling folders will not be copied."
        let epoch = model.selectionEpoch
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url, model.selectionEpoch == epoch else { return }
            do { try model.selectAdditionalSourceFolder(url) }
            catch { model.message = "This source folder could not be added. Choose a separate folder outside the selected source folder, up to eight folders." }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

#if DEBUG
@MainActor private func preparationPreview(_ destination: AutomationNativePreparationDestination) -> AppAutomationStore {
    let model = AppAutomationStore(supportDirectory: URL(fileURLWithPath: "/private/tmp/preview-unused"),
        nativeMacTargetReader: { .init(id: "host-macos-local", kind: .nativeMac, loginSession: "preview-only") })
    let intake = #"{"candidates":[{"id":"preview-source","name":"Example app","kind":"sourceTarget","containerPath":"/preview-only/Example.xcodeproj","targetID":"APP","architectures":[],"configurations":["Debug"]}],"gaps":[],"requiresBuildApproval":true}"#
    model.intake = try? JSONDecoder().decode(AutomationIntakeAssessment.self, from: Data(intake.utf8))
    model.candidateID = "preview-source"; model.configuration = "Debug"; model.preparationDestination = destination
    model.simulatorID = "00000000-0000-0000-0000-000000000001"
    let simulator = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"iPhone","runtime":"iOS","state":"Shutdown"}]"#
    model.simulators = (try? JSONDecoder().decode([AutomationSimulator].self, from: Data(simulator.utf8))) ?? []
    return model
}
#Preview("Prepare for This Mac") {
    GroupBox("Source preparation") {
        AutomationSourcePreparationControls(model: preparationPreview(.macOS), approveBuild: {}).padding(10)
    }.padding(20).frame(width: 520)
}
#Preview("Prepare for iOS Simulator") {
    GroupBox("Source preparation") {
        AutomationSourcePreparationControls(model: preparationPreview(.simulator), approveBuild: {}).padding(10)
    }.padding(20).frame(width: 520)
}
#endif
