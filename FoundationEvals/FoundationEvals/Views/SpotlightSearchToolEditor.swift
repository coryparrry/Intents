import SwiftUI
import UniformTypeIdentifiers

struct SpotlightSearchToolEditor: View {
    @Binding var configuration: EvaluationSpotlightSearchConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Use Apple's Spotlight search tool", isOn: $configuration.enabled)
                .accessibilityIdentifier("Enable Spotlight search tool")

            if configuration.enabled {
                Text("The model can search only the sources below. Search is read-only, results are capped, and traces save aggregate counts without queries, file names, paths, identifiers, or result text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SpotlightSourcesEditor(
                    fileSource: $configuration.fileSource,
                    coreSpotlightSource: $configuration.coreSpotlightSource
                )

                Divider()

                SpotlightPipelineEditor(pipeline: $configuration.pipeline)

                Divider()

                SpotlightContactIdentityEditor(identity: $configuration.contactIdentity)

                Divider()

                SpotlightGuidanceEditor(guidance: $configuration.guidance)

                Divider()

                Stepper(
                    value: $configuration.maximumResponseSize,
                    in: EvaluationSpotlightSearchConfiguration.minimumResponseSize
                        ... EvaluationSpotlightSearchConfiguration.maximumAllowedResponseSize,
                    step: 512
                ) {
                    LabeledContent("Maximum tool response size") {
                        Text(configuration.maximumResponseSize, format: .number)
                            .monospacedDigit()
                    }
                }
                .accessibilityIdentifier("Spotlight maximum response size")

                Text("This value is passed directly to SpotlightSearchTool.Configuration.maximumResponseSize to bound the content returned to the model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Spotlight search is off. Runs do not create the built-in tool or access Spotlight data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 11))
    }
}

private struct SpotlightPipelineEditor: View {
    @Binding var pipeline: EvaluationSpotlightPipelineConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom search pipeline")
                .font(.callout.weight(.semibold))

            Toggle(
                "Offer duplicate removal for item results",
                isOn: $pipeline.deduplicateItems
            )
            .accessibilityIdentifier("Enable Spotlight duplicate-removal stage")

            Text("When enabled, Apple's pipeline planner may use the app's native custom stage to remove results with duplicate Spotlight identifiers. The stage only transforms the already bounded result set.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SpotlightContactIdentityEditor: View {
    @Binding var identity: EvaluationSpotlightContactIdentityConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contact-aware queries")
                .font(.callout.weight(.semibold))

            Toggle(
                "Resolve “I” and “me” from a configured identity",
                isOn: $identity.enabled
            )
            .accessibilityIdentifier("Enable Spotlight contact resolver")

            if identity.enabled {
                TextField("Display name", text: $identity.displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("Spotlight contact display name")

                SpotlightContactValuesEditor(
                    title: "Alternate names",
                    placeholder: "Name or alias",
                    values: $identity.alternateNames
                )
                SpotlightContactValuesEditor(
                    title: "Email addresses",
                    placeholder: "Email address",
                    values: $identity.emailAddresses
                )
                SpotlightContactValuesEditor(
                    title: "Phone numbers",
                    placeholder: "Phone number",
                    values: $identity.phoneNumbers
                )

                Text("These values are stored in the suite and passed directly to Apple's ContactResolver. Foundation Evals does not read the Contacts database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SpotlightContactValuesEditor: View {
    let title: LocalizedStringResource
    let placeholder: LocalizedStringResource
    @Binding var values: [String]
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(placeholder, text: $values[index])
                        .textFieldStyle(.roundedBorder)
                    Button("Remove", systemImage: "minus.circle") {
                        values.remove(at: index)
                    }
                    .labelStyle(.iconOnly)
                }
            }

            HStack(spacing: 8) {
                TextField(placeholder, text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addValue)
                Button("Add", action: addValue)
                    .disabled(!canAddValue)
            }
        }
    }

    private var normalizedNewValue: String {
        newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddValue: Bool {
        !normalizedNewValue.isEmpty
            && normalizedNewValue.count
                <= EvaluationSpotlightSearchConfiguration.maximumIdentityValueCharacters
            && values.count
                < EvaluationSpotlightSearchConfiguration.maximumIdentityValuesPerKind
    }

    private func addValue() {
        guard canAddValue else { return }
        values.append(normalizedNewValue)
        newValue = ""
    }
}

private struct SpotlightSourcesEditor: View {
    @Binding var fileSource: EvaluationSpotlightFileSourceConfiguration
    @Binding var coreSpotlightSource: EvaluationCoreSpotlightSourceConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search sources")
                .font(.callout.weight(.semibold))

            SpotlightFileSourceEditor(fileSource: $fileSource)

            Divider()

            SpotlightCoreSourceEditor(coreSpotlightSource: $coreSpotlightSource)
        }
    }
}

private struct SpotlightFileSourceEditor: View {
    @Binding var fileSource: EvaluationSpotlightFileSourceConfiguration
    @State private var isChoosingFolder = false
    @State private var folderPickerError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Search one selected local folder", isOn: $fileSource.enabled)
                .accessibilityIdentifier("Enable Spotlight file source")

            if fileSource.enabled {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Folder")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(folderDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(fileSource.folderPath)
                            .accessibilityIdentifier("Spotlight selected folder")
                    }

                    Spacer(minLength: 12)

                    Button("Choose Folder…", systemImage: "folder") {
                        isChoosingFolder = true
                    }
                    .accessibilityIdentifier("Choose Spotlight folder")
                }

                if let folderPickerError {
                    Label(folderPickerError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                SpotlightResultLimitEditor(
                    label: "Maximum file results",
                    value: $fileSource.maximumResults,
                    accessibilityIdentifier: "Spotlight file result limit"
                )

                SpotlightAttributeSelectionEditor(
                    title: "File attributes",
                    selection: $fileSource.fetchedAttributes
                )

                Text("The saved suite keeps this canonical path because this app is not sandboxed. The runtime still verifies the folder and rejects the file-system root and home directory before creating the tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let folderURL = try result.get().first else { return }
                fileSource.folderPath = folderURL
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                folderPickerError = nil
            } catch {
                folderPickerError = error.localizedDescription
            }
        }
    }

    private var folderDisplayName: String {
        guard !fileSource.folderPath.isEmpty else { return "No folder selected" }
        return (fileSource.folderPath as NSString).abbreviatingWithTildeInPath
    }
}

private struct SpotlightCoreSourceEditor: View {
    @Binding var coreSpotlightSource: EvaluationCoreSpotlightSourceConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Search this app's Core Spotlight index", isOn: $coreSpotlightSource.enabled)
                .accessibilityIdentifier("Enable Core Spotlight source")

            if coreSpotlightSource.enabled {
                SpotlightResultLimitEditor(
                    label: "Maximum indexed results",
                    value: $coreSpotlightSource.maximumResults,
                    accessibilityIdentifier: "Core Spotlight result limit"
                )

                SpotlightAttributeSelectionEditor(
                    title: "Indexed-item attributes",
                    selection: $coreSpotlightSource.fetchedAttributes
                )

                Toggle("Allow results from Mail", isOn: $coreSpotlightSource.allowMail)
                    .accessibilityIdentifier("Allow Spotlight Mail results")

                if coreSpotlightSource.allowMail {
                    Label(
                        "Mail search requires Apple's com.apple.corespotlight.search.allow.mail entitlement in the signed app.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct SpotlightResultLimitEditor: View {
    let label: LocalizedStringResource
    @Binding var value: Int
    let accessibilityIdentifier: String

    var body: some View {
        Stepper(
            value: $value,
            in: 1...EvaluationSpotlightSearchConfiguration.maximumResultCount
        ) {
            LabeledContent(label) {
                Text(value, format: .number)
                    .monospacedDigit()
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct SpotlightGuidanceEditor: View {
    @Binding var guidance: EvaluationSpotlightGuidanceConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search guidance")
                .font(.callout.weight(.semibold))

            Picker("Guidance", selection: $guidance.mode) {
                ForEach(EvaluationSpotlightGuidanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("Spotlight guidance mode")

            switch guidance.mode {
            case .complete:
                Text("The model may use every search technique supported by Spotlight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .focused:
                Picker("Content domain", selection: $guidance.focusedDomain) {
                    ForEach(EvaluationSpotlightContentDomain.allCases) { domain in
                        Text(domain.title).tag(domain)
                    }
                }
                .accessibilityIdentifier("Spotlight focused domain")
                .accessibilitySelectionActions(
                    EvaluationSpotlightContentDomain.allCases,
                    selection: $guidance.focusedDomain,
                    title: { String(localized: $0.title) }
                )

                Text("Focused guidance gives the model a smaller schema specialized for this content domain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .dynamic:
                SpotlightDynamicGuidanceEditor(profile: $guidance.dynamicProfile)
            }

            Picker("Result format", selection: $guidance.outputFormat) {
                ForEach(EvaluationSpotlightOutputFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("Spotlight result format")

            Text(formatExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var formatExplanation: LocalizedStringResource {
        switch guidance.outputFormat {
        case .compact:
            "Compact uses a terse representation to reduce context use."
        case .structured:
            "Structured preserves attribute keys and values for higher-fidelity reasoning."
        }
    }
}

private struct SpotlightDynamicGuidanceEditor: View {
    @Binding var profile: EvaluationSpotlightDynamicGuidanceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpotlightGuidanceOptionEditor("Text match", selection: $profile.textMatch)
            SpotlightGuidanceOptionEditor("Similarity match", selection: $profile.similarityMatch)
            SpotlightGuidanceOptionEditor("Numeric match", selection: $profile.numericMatch)
            SpotlightGuidanceOptionEditor("Dates", selection: $profile.dates)
            SpotlightGuidanceOptionEditor("People", selection: $profile.people)
            SpotlightGuidanceOptionEditor("Content type", selection: $profile.contentType)

            SpotlightAttributeSelectionEditor(
                title: "Attributes considered for matching",
                selection: $profile.attributes
            )
        }
    }
}

private struct SpotlightGuidanceOptionEditor: View {
    let label: LocalizedStringResource
    @Binding var selection: EvaluationSpotlightGuidanceOption

    init(
        _ label: LocalizedStringResource,
        selection: Binding<EvaluationSpotlightGuidanceOption>
    ) {
        self.label = label
        _selection = selection
    }

    var body: some View {
        LabeledContent(label) {
            Picker(label, selection: $selection) {
                ForEach(EvaluationSpotlightGuidanceOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilitySelectionActions(
                EvaluationSpotlightGuidanceOption.allCases,
                selection: $selection,
                title: { String(localized: $0.title) }
            )
            .labelsHidden()
            .frame(width: 130)
        }
    }
}

private struct SpotlightAttributeSelectionEditor: View {
    let title: LocalizedStringResource
    @Binding var selection: EvaluationSpotlightAttributeSelection
    @State private var customAttributeName = ""

    private let columns = [
        GridItem(.adaptive(minimum: 150), alignment: .leading)
    ]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                    ForEach(EvaluationSpotlightAttributePreset.allCases) { attribute in
                        Toggle(attribute.title, isOn: binding(for: attribute))
                            .toggleStyle(.checkbox)
                            .disabled(
                                !selection.presets.contains(attribute)
                                    && selection.count >= EvaluationSpotlightSearchConfiguration.maximumFetchAttributes
                            )
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    TextField("Custom metadata attribute", text: $customAttributeName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCustomAttribute)
                        .accessibilityIdentifier("Spotlight custom attribute")

                    Button("Add", action: addCustomAttribute)
                        .disabled(!canAddCustomAttribute)
                }

                ForEach(selection.customAttributeNames, id: \.self) { attributeName in
                    HStack(spacing: 8) {
                        Text(attributeName)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer(minLength: 12)
                        Button("Remove \(attributeName)", systemImage: "minus.circle") {
                            selection.customAttributeNames.removeAll { $0 == attributeName }
                        }
                        .labelStyle(.iconOnly)
                    }
                }

                Text("Custom values use Core Spotlight metadata attribute raw names. With no attributes selected, Spotlight returns only each result's unique identifier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(selection.count) of \(EvaluationSpotlightSearchConfiguration.maximumFetchAttributes)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedCustomAttributeName: String {
        customAttributeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddCustomAttribute: Bool {
        !trimmedCustomAttributeName.isEmpty
            && trimmedCustomAttributeName.count
                <= EvaluationSpotlightSearchConfiguration.maximumAttributeNameCharacters
            && !selection.customAttributeNames.contains(trimmedCustomAttributeName)
            && selection.count < EvaluationSpotlightSearchConfiguration.maximumFetchAttributes
    }

    private func binding(for attribute: EvaluationSpotlightAttributePreset) -> Binding<Bool> {
        Binding(
            get: { selection.presets.contains(attribute) },
            set: { isSelected in
                if isSelected {
                    guard !selection.presets.contains(attribute),
                          selection.count < EvaluationSpotlightSearchConfiguration.maximumFetchAttributes else {
                        return
                    }
                    selection.presets.append(attribute)
                } else {
                    selection.presets.removeAll { $0 == attribute }
                }
            }
        )
    }

    private func addCustomAttribute() {
        guard canAddCustomAttribute else { return }
        selection.customAttributeNames.append(trimmedCustomAttributeName)
        customAttributeName = ""
    }
}
