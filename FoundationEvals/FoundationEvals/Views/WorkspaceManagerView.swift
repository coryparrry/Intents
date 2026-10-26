import SwiftUI

struct WorkspaceManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: EvaluationStore
    @State private var projectName = ""
    @State private var suiteName = ""
    @State private var error: String?
    @State private var isCreatingProject = false
    @State private var isCreatingSuite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Projects and suites").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Projects").font(.headline)
                    List(selection: Binding(
                        get: { Optional(store.selectedProjectID) },
                        set: { id in if let id { perform { try store.switchProject(id: id) } } }
                    )) {
                        ForEach(store.projects.filter { !$0.isArchived }) { project in
                            Label(project.name, systemImage: "folder").tag(Optional(project.id))
                        }
                    }
                    HStack {
                        Button("New project", systemImage: "plus") { isCreatingProject = true }
                        Spacer()
                        Menu("Project actions", systemImage: "ellipsis") {
                            Button("Duplicate project") { perform { _ = try store.duplicateProject(id: store.selectedProjectID) } }
                            Button("Archive project") { perform { try store.archiveProject(id: store.selectedProjectID) } }
                        }.labelStyle(.iconOnly)
                    }
                }.frame(minWidth: 240)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Suites").font(.headline)
                    List(selection: Binding(
                        get: { Optional(store.selectedSuiteID) },
                        set: { id in if let id { perform { try store.switchSuite(id: id) } } }
                    )) {
                        ForEach(store.suiteRecords.filter { !$0.isArchived }) { record in
                            Label(record.name, systemImage: "checklist").tag(Optional(record.id))
                        }
                    }
                    HStack {
                        Button("New suite", systemImage: "plus") { isCreatingSuite = true }
                        Spacer()
                        Menu("Suite actions", systemImage: "ellipsis") {
                            Button("Duplicate suite") { perform { _ = try store.duplicateSuite(id: store.selectedSuiteID) } }
                            Button("Archive suite") { perform { try store.archiveSuite(id: store.selectedSuiteID) } }
                        }.labelStyle(.iconOnly)
                    }
                }.frame(minWidth: 260)
            }
            .frame(minHeight: 230)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Project name")
                    TextField("Project name", text: $projectName)
                    Button("Rename project") { perform { try store.renameProject(id: store.selectedProjectID, name: projectName) } }
                        .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectName == store.selectedProject.name)
                }
                GridRow {
                    Text("Suite name")
                    TextField("Suite name", text: $suiteName)
                    Button("Rename suite") { perform { try store.renameSuite(id: store.selectedSuiteID, name: suiteName) } }
                        .disabled(suiteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || suiteName == store.selectedSuiteRecord.name)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
        }
        .padding(24)
        .frame(width: 700)
        .onAppear(perform: updateNames)
        .onChange(of: store.selectedProjectID) { _, _ in updateNames() }
        .onChange(of: store.selectedSuiteID) { _, _ in updateNames() }
        .sheet(isPresented: $isCreatingProject) { WorkspaceCreationView(store: store, isProject: true) }
        .sheet(isPresented: $isCreatingSuite) { NewSuiteView(store: store) }
    }

    /// Reloads the editable project and suite names from the current store selections.
    private func updateNames() {
        projectName = store.selectedProject.name
        suiteName = store.selectedSuiteRecord.name
    }

    /// Runs a workspace mutation and refreshes displayed names on success, or retains the localized failure for display.
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil; updateNames() }
        catch { self.error = error.localizedDescription }
    }
}

struct NewSuiteView: View {
    @Bindable var store: EvaluationStore
    var body: some View { WorkspaceCreationView(store: store, isProject: false) }
}

struct WorkspaceCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: EvaluationStore
    let isProject: Bool
    @State private var name = ""
    @State private var starter: EvaluationStarterPack?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isProject ? "New project" : "New suite").font(.title2.weight(.semibold))
            Text(isProject ? "Keep the checks for one app together." : "Start with your own examples or an editable evaluation pack.")
                .font(.callout).foregroundStyle(.secondary)
            TextField(isProject ? "Project name" : "Suite name", text: $name)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
            Picker("Start with", selection: $starter) {
                Text("Blank suite").tag(EvaluationStarterPack?.none)
                ForEach(EvaluationStarterPack.allCases) { pack in Text(pack.title).tag(Optional(pack)) }
            }
            if let starter {
                Text(starter.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isProject ? "Create project" : "Create suite", action: create)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { nameFocused = true }
        .onChange(of: starter) { old, new in
            if !isProject, name.isEmpty || name == old?.makeSuite().name {
                name = new?.makeSuite().name ?? ""
            }
        }
    }

    /// Creates a project or suite from the trimmed name and selected starter, navigates to its destination, and closes the sheet on success.
    /// Creation failures remain visible in the sheet.
    private func create() {
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if isProject {
                _ = try store.createProject(name: title, starter: starter)
                store.selection = .overview
            } else {
                _ = try store.createSuite(name: title, starter: starter)
                store.selection = .suite
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
