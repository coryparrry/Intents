import SwiftUI
import AppKit
import IntentsAutomationCore

struct AutomationSourcePreparationControls: View {
    @Bindable var model: AppAutomationStore
    let approveBuild: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Prepare for", selection: $model.preparationDestination) {
                ForEach(AutomationNativePreparationDestination.allCases) { Text($0.title).tag($0) }
            }.accessibilityLabel("Prepare for")
            if model.preparationDestination == .simulator {
                Picker("Simulator", selection: $model.simulatorID) {
                    ForEach(model.simulators) { Text("\($0.name) · \($0.state)").tag($0.id) }
                }.accessibilityLabel("Simulator")
            } else if model.preparationDestination == .physical {
                TextField("Exact physical device ID", text: $model.physicalDeviceID)
                    .accessibilityLabel("Exact physical device ID")
                Text("Choose the device identifier shown in Xcode. Preparation builds a private device copy; it does not install or run it.")
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
            Button("Prepare app…", action: approveBuild).disabled(!model.canPrepare)
        }
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
