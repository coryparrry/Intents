import SwiftUI

struct EvaluationSchemaEditor: View {
    let title: LocalizedStringResource
    let emptyDetail: LocalizedStringResource
    let maximumFields: Int
    @Binding var fields: [EvaluationSchemaField]
    @Binding var definitions: [EvaluationSchemaField]
    @Binding var representNilExplicitlyInGeneratedContent: Bool

    private var definitionOptions: [SchemaDefinitionOption] {
        definitions.map { SchemaDefinitionOption(id: $0.id, name: $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(
                "Represent missing optional fields as null",
                isOn: $representNilExplicitlyInGeneratedContent
            )
            Text("When enabled, generated content includes null for missing optional properties in this object.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SchemaFieldCollectionEditor(
                title: title,
                emptyDetail: emptyDetail,
                maximumFields: maximumFields,
                minimumFields: 0,
                depth: 1,
                role: .property,
                definitionOptions: definitionOptions,
                fields: $fields
            )

            Divider()

            SchemaDefinitionsEditor(
                definitions: $definitions,
                definitionOptions: definitionOptions
            )
        }
    }
}

private struct SchemaDefinitionsEditor: View {
    @Binding var definitions: [EvaluationSchemaField]
    let definitionOptions: [SchemaDefinitionOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reusable definitions")
                .font(.headline)
            Text("Definitions are named schemas that references can reuse in fields, array items, or one-of choices.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SchemaFieldCollectionEditor(
                title: "Definitions",
                emptyDetail: "No reusable definitions.",
                maximumFields: EvaluationCustomToolDefinition.maximumParameters,
                minimumFields: 0,
                depth: 1,
                role: .definition,
                definitionOptions: definitionOptions,
                fields: $definitions
            )
        }
    }
}

private struct SchemaFieldCollectionEditor: View {
    let title: LocalizedStringResource
    let emptyDetail: LocalizedStringResource
    let maximumFields: Int
    let minimumFields: Int
    let depth: Int
    let role: SchemaFieldRole
    let definitionOptions: [SchemaDefinitionOption]
    @Binding var fields: [EvaluationSchemaField]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(role == .property || role == .definition ? .headline : .callout.weight(.semibold))
                Text("\(fields.count) of \(maximumFields)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role.addButtonTitle, systemImage: "plus") {
                    addField()
                }
                .disabled(
                    fields.count >= maximumFields
                        || depth > EvaluationFeatureConfiguration.maximumSchemaDepth
                )
            }

            if fields.isEmpty {
                Text(emptyDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach($fields) { $field in
                        SchemaFieldRow(
                            field: $field,
                            depth: depth,
                            role: role,
                            definitionOptions: definitionOptions,
                            canRemove: fields.count > minimumFields,
                            remove: { fields.removeAll { $0.id == field.id } }
                        )
                    }
                }
            }
        }
    }

    /// Appends a field appropriate to the editor role only while field-count and schema-depth limits permit it.
    private func addField() {
        guard fields.count < maximumFields,
              depth <= EvaluationFeatureConfiguration.maximumSchemaDepth else { return }
        let field: EvaluationSchemaField
        switch role {
        case .property:
            field = EvaluationSchemaField(name: firstAvailableNumberedName(prefix: "field", existing: Set(fields.map(\.name))))
        case .definition:
            field = EvaluationSchemaField(
                name: firstAvailableNumberedName(prefix: "Definition", existing: Set(fields.map(\.name))), type: .object
            )
        case .unionChoice:
            field = EvaluationSchemaField(name: firstAvailableNumberedName(prefix: "choice", existing: Set(fields.map(\.name))))
        case .arrayItem:
            field = EvaluationSchemaField(name: "item")
        }
        fields.append(field)
    }

}

private struct SchemaFieldRow: View {
    @Binding var field: EvaluationSchemaField
    let depth: Int
    let role: SchemaFieldRole
    let definitionOptions: [SchemaDefinitionOption]
    let canRemove: Bool
    let remove: () -> Void

    private var availableTypes: [EvaluationSchemaFieldType] {
        EvaluationSchemaFieldType.allCases.filter { type in
            depth < EvaluationFeatureConfiguration.maximumSchemaDepth || !type.supportsChildren
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SchemaFieldHeader(
                field: $field,
                availableTypes: availableTypes,
                role: role,
                canRemove: canRemove,
                remove: remove
            )

            TextField(role.descriptionPlaceholder, text: $field.description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .accessibilityLabel("Schema field description")

            SchemaFieldDetails(
                field: $field,
                depth: depth,
                definitionOptions: definitionOptions
            )
        }
        .padding(11)
        .background(.background.opacity(depth == 1 ? 1 : 0.72), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.secondary.opacity(depth == 1 ? 0.12 : 0.24))
        }
        .onChange(of: field.type) { _, _ in
            field.normalizeAfterTypeChange()
            if field.type == .reference,
               !definitionOptions.contains(where: { $0.name == field.referenceName }) {
                field.referenceName = definitionOptions.first?.name ?? ""
            }
        }
    }
}

private struct SchemaFieldHeader: View {
    @Binding var field: EvaluationSchemaField
    let availableTypes: [EvaluationSchemaFieldType]
    let role: SchemaFieldRole
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TextField(role.namePlaceholder, text: $field.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(role.nameAccessibilityLabel)

            Picker("Type", selection: $field.type) {
                ForEach(availableTypes) { type in
                    Text(type.title).tag(type)
                }
            }
            .accessibilitySelectionActions(
                availableTypes,
                selection: $field.type,
                title: { String(localized: $0.title) }
            )
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel("Schema field type")

            if role.allowsOptional {
                Toggle("Optional", isOn: $field.isOptional)
                    .fixedSize()
            }

            if role != .arrayItem {
                Button("Delete Field", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .help("Delete this schema entry")
                    .disabled(!canRemove)
            }
        }
    }
}

private struct SchemaFieldDetails: View {
    @Binding var field: EvaluationSchemaField
    let depth: Int
    let definitionOptions: [SchemaDefinitionOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch field.type {
            case .string:
                StringSchemaConstraintsEditor(constraints: $field.constraints)
            case .integer:
                IntegerSchemaConstraintsEditor(constraints: $field.constraints)
            case .number:
                NumberSchemaConstraintsEditor(constraints: $field.constraints)
            case .boolean, .null, .imageReference:
                EmptyView()
            case .enumeration:
                SchemaEnumValuesEditor(values: $field.enumValues)
            case .object:
                Toggle(
                    "Represent missing optional fields as null",
                    isOn: $field.representNilExplicitlyInGeneratedContent
                )
                SchemaFieldCollectionEditor(
                    title: "Object properties",
                    emptyDetail: "This object has no properties.",
                    maximumFields: EvaluationCustomToolDefinition.maximumParameters,
                    minimumFields: 0,
                    depth: depth + 1,
                    role: .property,
                    definitionOptions: definitionOptions,
                    fields: $field.children
                )
            case .array:
                ArraySchemaConstraintsEditor(constraints: $field.constraints)
                if !field.children.isEmpty {
                    SchemaFieldRow(
                        field: $field.children[0],
                        depth: depth + 1,
                        role: .arrayItem,
                        definitionOptions: definitionOptions,
                        canRemove: false,
                        remove: {}
                    )
                }
            case .union:
                SchemaFieldCollectionEditor(
                    title: "One-of choices",
                    emptyDetail: "Add at least two possible schemas.",
                    maximumFields: EvaluationCustomToolDefinition.maximumParameters,
                    minimumFields: 2,
                    depth: depth + 1,
                    role: .unionChoice,
                    definitionOptions: definitionOptions,
                    fields: $field.children
                )
            case .reference:
                SchemaReferenceEditor(
                    referenceName: $field.referenceName,
                    definitionOptions: definitionOptions
                )
            }
        }
        .onAppear { field.prepareForSelectedType() }
    }
}

private struct StringSchemaConstraintsEditor: View {
    @Binding var constraints: EvaluationSchemaConstraints

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Pattern")
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                TextField("Regular expression (optional)", text: $constraints.stringPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityLabel("String regular expression")
                Text("A valid Swift regular expression can still use pattern features that the selected model provider does not support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct IntegerSchemaConstraintsEditor: View {
    @Binding var constraints: EvaluationSchemaConstraints

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Minimum", isOn: $constraints.hasIntegerMinimum)
            if constraints.hasIntegerMinimum {
                TextField("Minimum integer", value: $constraints.editableIntegerMinimum, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
            }
            Toggle("Maximum", isOn: $constraints.hasIntegerMaximum)
            if constraints.hasIntegerMaximum {
                TextField("Maximum integer", value: $constraints.editableIntegerMaximum, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
            }
            Spacer()
        }
    }
}

private struct NumberSchemaConstraintsEditor: View {
    @Binding var constraints: EvaluationSchemaConstraints

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Minimum", isOn: $constraints.hasNumberMinimum)
            if constraints.hasNumberMinimum {
                TextField("Minimum number", value: $constraints.editableNumberMinimum, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
            }
            Toggle("Maximum", isOn: $constraints.hasNumberMaximum)
            if constraints.hasNumberMaximum {
                TextField("Maximum number", value: $constraints.editableNumberMaximum, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
            }
            Spacer()
        }
    }
}

private struct ArraySchemaConstraintsEditor: View {
    @Binding var constraints: EvaluationSchemaConstraints

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Set minimum item count", isOn: $constraints.hasArrayMinimumCount)
            if constraints.hasArrayMinimumCount {
                Stepper(
                    "Minimum items: \(constraints.editableArrayMinimumCount)",
                    value: $constraints.editableArrayMinimumCount,
                    in: 0...EvaluationSchemaField.maximumArrayElements
                )
            }
            Toggle("Set maximum item count", isOn: $constraints.hasArrayMaximumCount)
            if constraints.hasArrayMaximumCount {
                Stepper(
                    "Maximum items: \(constraints.editableArrayMaximumCount)",
                    value: $constraints.editableArrayMaximumCount,
                    in: 0...EvaluationSchemaField.maximumArrayElements
                )
            }
        }
    }
}

private struct SchemaEnumValuesEditor: View {
    @Binding var values: [EvaluationSchemaEnumValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Allowed values")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("Add Value", systemImage: "plus") {
                    values.append(EvaluationSchemaEnumValue(
                        value: firstAvailableNumberedName(prefix: "value", existing: Set(values.map(\.value)))
                    ))
                }
                .disabled(values.count >= EvaluationSchemaField.maximumEnumValues)
            }
            ForEach($values) { $value in
                HStack {
                    TextField("Choice value", text: $value.value)
                        .textFieldStyle(.roundedBorder)
                    Button("Delete Value", systemImage: "trash", role: .destructive) {
                        values.removeAll { $0.id == value.id }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(values.count <= 1)
                }
            }
        }
    }

}

private struct SchemaReferenceEditor: View {
    @Binding var referenceName: String
    let definitionOptions: [SchemaDefinitionOption]

    var body: some View {
        if definitionOptions.isEmpty {
            Label("Add a reusable definition before using a reference.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            Picker("Reusable definition", selection: $referenceName) {
                ForEach(definitionOptions) { definition in
                    Text(definition.name.isEmpty ? "Untitled definition" : definition.name)
                        .tag(definition.name)
                }
            }
            .accessibilitySelectionActions(
                definitionOptions.map(\.name),
                selection: $referenceName,
                title: { $0.isEmpty ? "Untitled definition" : $0 }
            )
        }
    }
}

private struct SchemaDefinitionOption: Identifiable, Equatable {
    let id: UUID
    let name: String
}

private enum SchemaFieldRole: Equatable {
    case property
    case definition
    case unionChoice
    case arrayItem

    var allowsOptional: Bool { self == .property }

    var addButtonTitle: LocalizedStringResource {
        switch self {
        case .property: "Add Field"
        case .definition: "Add Definition"
        case .unionChoice: "Add Choice"
        case .arrayItem: "Add Item Schema"
        }
    }

    var namePlaceholder: LocalizedStringResource {
        switch self {
        case .property: "Field name"
        case .definition: "Definition name"
        case .unionChoice: "Choice label"
        case .arrayItem: "Item label"
        }
    }

    var nameAccessibilityLabel: LocalizedStringResource {
        switch self {
        case .property: "Schema field name"
        case .definition: "Schema definition name"
        case .unionChoice: "Schema choice label"
        case .arrayItem: "Array item label"
        }
    }

    var descriptionPlaceholder: LocalizedStringResource {
        switch self {
        case .property: "Field description"
        case .definition: "Definition description"
        case .unionChoice: "Choice description"
        case .arrayItem: "Item description"
        }
    }
}
