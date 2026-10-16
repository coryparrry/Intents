import SwiftUI
import AppKit
import IntentsAutomationCore

struct AutomationSourceRecipeControls: View {
    @Bindable var model: AppAutomationStore
    @State private var recipe: AutomationSourceRecipe?
    @State private var showingApproval = false
    var body: some View {
        if model.hasXcodeGenSpecification || model.hasTuistSpecification || model.hasSwiftPackage {
            HStack {
                if model.hasXcodeGenSpecification {
                    Button("Generate Xcode project…") {
                        guard let root = model.sourceRecipeRoot else { return }
                        do { recipe = try .xcodegen(source: root); showingApproval = true }
                        catch { model.message = model.errorText(error) }
                    }
                }
                if model.hasSwiftPackage {
                    Button("Choose app packaging script…") { choosePackagingScript() }
                }
                if model.hasTuistSpecification {
                    Button("Generate Tuist project…") {
                        guard let root = model.sourceRecipeRoot else { return }
                        do { recipe = try .tuist(source: root, developerDirectory: model.developerDirectory); showingApproval = true }
                        catch { model.message = model.errorText(error) }
                    }
                    Menu("Advanced") { Button("Choose Tuist qualification…") { chooseTuistPin() } }
                }
            }.disabled(model.busy)
                .confirmationDialog("Prepare a private source copy?", isPresented: $showingApproval, titleVisibility: .visible) {
                    Button(recipe?.kind == .swiftPMPackaging ? "Run packaging script" : "Generate project") {
                        if let recipe { model.runSourceRecipe(recipe) }
                        recipe = nil
                    }
                    Button("Cancel", role: .cancel) { recipe = nil }
                } message: {
                    if let recipe {
                        Text("Run \(recipe.entry) in a frozen copy of this source. The recipe can write to that copy and its private temporary files; writes to the original source and network access are blocked. Intents will inspect the result before any app action is approved.")
                    }
                }
                .onChange(of: model.selectionEpoch) {
                    recipe = nil
                    showingApproval = false
                }
        }
    }
    private func chooseTuistPin() {
        guard let root = model.sourceRecipeRoot else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = root; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose this project's existing Tuist qualification JSON with its installed generator and Xcode toolchain digests."
        let epoch = model.selectionEpoch
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let pin = panel.url, model.selectionEpoch == epoch else { return }
            do { recipe = try .tuist(source: root, pin: pin); showingApproval = true }
            catch { model.message = model.errorText(error) }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func choosePackagingScript() {
        guard let root = model.sourceRecipeRoot else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = root; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose this package's existing shell script that builds a complete .app bundle."
        let epoch = model.selectionEpoch
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let script = panel.url, model.selectionEpoch == epoch else { return }
            do { recipe = try .swiftPMPackaging(source: root, script: script); showingApproval = true }
            catch { model.message = model.errorText(error) }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
