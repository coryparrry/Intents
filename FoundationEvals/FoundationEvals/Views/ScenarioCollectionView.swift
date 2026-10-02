import AppKit
import SwiftUI

/// A collection is a frozen set of saved checks. Every batch keeps its own
/// population, including rows that never ran, so partial success stays partial.
struct ScenarioCollectionView: View {
    @Bindable var coordinator: ScenarioCoordinator
    @State private var name = ""
    @State private var creationCaseIDs: Set<UUID> = []
    @State private var runCaseIDs: Set<UUID> = []
    @State private var membershipCaseIDs: Set<UUID> = []
    @State private var variationSourceID: UUID?
    @State private var variationRequest = ""
    @State private var reviewedSameOutcome = false

    private var latestCases: [ScenarioDefinition] {
        let matching = coordinator.definitions.filter {
            $0.schemaVersion == ScenarioDefinition.stableSchemaVersion
                && $0.projectID == coordinator.draft.projectID
        }
        return Dictionary(grouping: matching, by: \.id).values
            .compactMap { $0.max { $0.version < $1.version } }
            .sorted { $0.name < $1.name }
    }

    private var latestCollections: [ScenarioCollection] {
        Dictionary(grouping: coordinator.collections, by: \.id).values
            .compactMap { $0.max { $0.version < $1.version } }
            .filter { $0.projectID == coordinator.draft.projectID }
            .sorted { $0.name < $1.name }
    }

    private var memberCases: [ScenarioDefinition] {
        guard let collection = coordinator.selectedCollection else { return [] }
        return collection.members.compactMap { member in
            coordinator.definitions.first {
                $0.id == member.caseID && $0.version == member.version
                    && $0.definitionDigest == member.definitionDigest
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Regression collections").font(.title2.weight(.semibold))
                IntentLabHelp("Keep several reviewed checks together, run the full collection, or rerun selected cases. Each batch has its own planned population; a partial result never becomes a full pass by reusing older rows.")
                createSection
                if !latestCollections.isEmpty {
                    collectionSection
                }
            }
            .workspacePage()
        }
    }

    private var createSection: some View {
        IntentLabCard("Create collection", subtitle: "Start with saved checks from the current project.") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Collection name", text: $name)
                    .accessibilityIdentifier("Collection name")
                ForEach(latestCases) { definition in
                    Toggle(isOn: Binding(
                        get: { creationCaseIDs.contains(definition.id) },
                        set: { enabled in
                            if enabled { creationCaseIDs.insert(definition.id) }
                            else { creationCaseIDs.remove(definition.id) }
                        }
                    )) {
                        Text("\(definition.name) · version \(definition.version)")
                    }
                }
                if latestCases.isEmpty {
                    Text("Save a developer check before creating a collection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Save collection", systemImage: "square.and.arrow.down") {
                    Task {
                        do {
                            _ = try await coordinator.createCollection(
                                name: name, caseIDs: latestCases.map(\.id).filter(creationCaseIDs.contains)
                            )
                            name = ""
                            creationCaseIDs = []
                        } catch { coordinator.notice = error.localizedDescription }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || creationCaseIDs.isEmpty || coordinator.isRunning)
            }
        }
    }

    private var collectionSection: some View {
        IntentLabCard("Saved collection", subtitle: "Run a frozen population and inspect each attempt.") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Collection", selection: $coordinator.selectedCollectionID) {
                    Text("Choose a collection").tag(UUID?.none)
                    ForEach(latestCollections) { collection in
                        Text("\(collection.name) · version \(collection.version)")
                            .tag(UUID?.some(collection.id))
                    }
                }
                .accessibilityIdentifier("Saved collection")
                .onChange(of: coordinator.selectedCollectionID) { _, _ in
                    runCaseIDs = []
                    membershipCaseIDs = Set(coordinator.selectedCollection?.members.map(\.caseID) ?? [])
                }
                .onChange(of: coordinator.selectedCollection?.version) { _, _ in
                    runCaseIDs = []
                    membershipCaseIDs = Set(coordinator.selectedCollection?.members.map(\.caseID) ?? [])
                }
                if let collection = coordinator.selectedCollection {
                    Text("\(collection.members.count) reviewed cases · version \(collection.version)")
                        .font(.caption).foregroundStyle(.secondary)
                    membershipEditor(collection: collection)
                    ForEach(memberCases) { definition in
                        Toggle(isOn: Binding(
                            get: { runCaseIDs.contains(definition.id) },
                            set: { enabled in
                                if enabled { runCaseIDs.insert(definition.id) }
                                else { runCaseIDs.remove(definition.id) }
                            }
                        )) {
                            Text(definition.name)
                        }
                    }
                    HStack {
                        Button("Run full collection", systemImage: "play.fill") {
                            Task { await coordinator.runSelectedCollection() }
                        }
                        Button("Run selected cases", systemImage: "play.square.stack") {
                            Task {
                                await coordinator.runSelectedCollection(
                                    scope: .selected,
                                    selectedCaseIDs: runCaseIDs.intersection(Set(memberCases.map(\.id)))
                                )
                            }
                        }
                        .disabled(runCaseIDs.intersection(Set(memberCases.map(\.id))).isEmpty)
                    }
                    .disabled(coordinator.isRunning)
                    variationSection
                    batchSection(collection: collection)
                }
            }
        }
    }

    private func membershipEditor(collection: ScenarioCollection) -> some View {
        let previous = coordinator.collections.first {
            $0.id == collection.id && $0.version == collection.version - 1
        }
        let difference = previous.flatMap {
            try? ScenarioCollectionService.membershipDifference(baseline: $0, candidate: collection)
        } ?? []
        return DisclosureGroup("Collection membership and versions") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose saved checks, then save a new version. Earlier versions and their batch results remain available.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(latestCases) { definition in
                    Toggle(definition.name, isOn: Binding(
                        get: { membershipCaseIDs.contains(definition.id) },
                        set: { enabled in
                            if enabled { membershipCaseIDs.insert(definition.id) }
                            else { membershipCaseIDs.remove(definition.id) }
                        }
                    ))
                }
                Button("Save new collection version", systemImage: "square.and.arrow.down") {
                    Task {
                        do {
                            _ = try await coordinator.reviseSelectedCollection(
                                caseIDs: latestCases.map(\.id).filter(membershipCaseIDs.contains)
                            )
                        } catch { coordinator.notice = error.localizedDescription }
                    }
                }
                .disabled(membershipCaseIDs.isEmpty
                          || ScenarioCollectionService.membershipMatchesLatest(collection, selectedIDs: membershipCaseIDs, definitions: latestCases)
                          || coordinator.isRunning)
                if !difference.isEmpty {
                    Text("Changes from version \(collection.version - 1): \(difference.filter { $0.change == .added }.count) added · \(difference.filter { $0.change == .removed }.count) removed · \(difference.filter { $0.change == .changed }.count) changed · \(difference.filter { $0.change == .unchanged }.count) unchanged")
                        .font(.caption.weight(.medium))
                    ForEach(difference.filter { $0.change != .unchanged }) { item in
                        Text("\(item.change.rawValue.capitalized): \(name(for: item.caseID))")
                            .font(.caption)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func name(for caseID: UUID) -> String {
        coordinator.definitions.first { $0.id == caseID }?.name ?? caseID.uuidString
    }

    private var variationSection: some View {
        DisclosureGroup("Add a reviewed request variation") {
            VStack(alignment: .leading, spacing: 10) {
                Text("This creates a separate case with the same approved expected outcome. The source case stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Source check", selection: $variationSourceID) {
                    Text("Choose a check").tag(UUID?.none)
                    ForEach(memberCases) { definition in
                        Text(definition.name).tag(UUID?.some(definition.id))
                    }
                }
                TextField("New request wording", text: $variationRequest, axis: .vertical)
                    .lineLimit(2...4)
                if let source = memberCases.first(where: { $0.id == variationSourceID }) {
                    Text("Expected outcome: \(source.goal.expectedBehavior)")
                        .font(.caption)
                    Toggle("I reviewed this wording and expect the same outcome", isOn: $reviewedSameOutcome)
                }
                Button("Save approved variation", systemImage: "plus.circle") {
                    saveVariation()
                }
                .disabled(variationSourceID == nil || !reviewedSameOutcome
                          || variationRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || coordinator.isRunning)
            }
            .padding(.top, 8)
        }
    }

    private func batchSection(collection: ScenarioCollection) -> some View {
        let manifests = coordinator.batchManifests.filter { $0.collectionID == collection.id }
        return VStack(alignment: .leading, spacing: 9) {
            if !manifests.isEmpty {
                Picker("Saved batch", selection: $coordinator.selectedBatchID) {
                    Text("Choose a batch").tag(UUID?.none)
                    ForEach(manifests) { manifest in
                        Text("\(manifest.scope.rawValue) · \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .tag(UUID?.some(manifest.id))
                    }
                }
                .accessibilityIdentifier("Saved collection batch")
            }
            if let manifest = coordinator.selectedBatchManifest,
               manifest.collectionID == collection.id,
               let assessment = coordinator.selectedBatchAssessment {
                Text("\(assessment.passedCount)/\(assessment.plannedCount) planned attempts passed · \(assessment.qualification.rawValue)")
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("Collection batch result")
                if manifest.scope != .full {
                    Text("This batch covers selected cases only. Run the full collection for a full result.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(assessment.coordinates) { row in
                    HStack {
                        Text("\(name(for: row.coordinate.caseID)) · \(row.coordinate.lane.title) · attempt \(row.coordinate.repetition)")
                        Spacer()
                        Text(row.outcome?.rawValue ?? row.terminalState.rawValue)
                    }
                    .font(.caption)
                    if let reason = row.reason {
                        Text(reason).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button("Rerun failed or missing cases", systemImage: "arrow.clockwise") {
                    Task { await coordinator.rerunFailedSelectedBatch() }
                }
                .disabled(coordinator.isRunning || assessment.passedCount == assessment.plannedCount)
                Button("Export selected batch…", systemImage: "square.and.arrow.up") {
                    exportBatch(manifestID: manifest.id)
                }
                .disabled(coordinator.isRunning)
            }
        }
    }

    private func saveVariation() {
        guard let source = memberCases.first(where: { $0.id == variationSourceID }) else { return }
        let wording = variationRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = source
        candidate.id = UUID()
        candidate.version = 1
        candidate.name = "\(source.name) · variation"
        candidate.goal.requestText = wording
        candidate.definitionDigest = ""
        candidate.testContractDigest = nil
        let draft = ScenarioVariationDraft(
            id: UUID(), sourceCaseID: source.id, sourceVersion: source.version,
            requestText: wording, parameters: source.directControl.parameters,
            featureInputs: source.featureBinding?.inputMapping ?? [],
            outcomeReview: .sameOutcome
        )
        Task {
            do {
                _ = try await coordinator.addApprovedVariation(
                    .init(draft: draft, reviewedDefinition: candidate)
                )
                variationRequest = ""
                reviewedSameOutcome = false
            } catch { coordinator.notice = error.localizedDescription }
        }
    }

    private func exportBatch(manifestID: UUID) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "IntentLab-Batch-\(manifestID.uuidString.prefix(8)).intentlabrun"
        panel.canCreateDirectories = true
        panel.message = "Save this batch with its frozen population and each case's evidence."
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                guard coordinator.selectedBatchID == manifestID else {
                    coordinator.notice = "Select the same batch before exporting its evidence."
                    return
                }
                let url = destination.pathExtension == "intentlabrun"
                    ? destination : destination.appendingPathExtension("intentlabrun")
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await coordinator.exportSelectedBatch(to: url)
                    coordinator.notice = "Collection evidence saved to \(url.lastPathComponent)."
                } catch { coordinator.notice = error.localizedDescription }
            }
        }
    }
}
