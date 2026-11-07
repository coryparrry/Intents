import MacIntentTesting
import SwiftUI

/// Edits one scope's required calls, forbidden calls, and optional reply checks.
struct SiriStudioExpectationEditor: View {
    @Binding var group: SiriStudioExpectations
    let actions: [MacIntentAction]
    let allowsReply: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Required calls", selection: $group.ordering) {
                Text("In this order").tag(SiriStudioExpectations.Ordering.ordered)
                Text("Any order").tag(SiriStudioExpectations.Ordering.unordered)
            }
            callGroup($group.calls, forbidden: false)
            Text("Forbidden calls").font(.subheadline.weight(.semibold))
            callGroup($group.forbidden, forbidden: true)
            if !group.calls.isEmpty && group.forbidden.isEmpty {
                Text("Required calls allow additional actions. Add a forbidden call to catch one you don’t want.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if group.forbidden.contains(where: { !$0.arguments.isEmpty }) {
                Text("Apple’s preview has not been verified for argument constraints on forbidden calls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if allowsReply { replies }
        }
    }

    /// Uses stable call IDs and preserves the authored order as entries are moved.
    private func callGroup(_ calls: Binding<[SiriStudioCall]>, forbidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(calls) { call in
                DisclosureGroup {
                    if let action = actions.first(where: { $0.id == call.wrappedValue.actionIdentifier }) {
                        SiriStudioCallEditor(call: call, action: action, forbidden: forbidden)
                    } else {
                        Text("This action is absent from the selected catalog. Remove it and choose an available action.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if !forbidden {
                            Button("Move up", systemImage: "arrow.up") { move(call.wrappedValue.id, in: calls, by: -1) }
                                .labelStyle(.iconOnly)
                            Button("Move down", systemImage: "arrow.down") { move(call.wrappedValue.id, in: calls, by: 1) }
                                .labelStyle(.iconOnly)
                        }
                        Button("Remove call", role: .destructive) {
                            let id = call.wrappedValue.id
                            calls.wrappedValue.removeAll { $0.id == id }
                        }
                    }.padding(.top, 4)
                } label: {
                    Text(actions.first(where: { $0.id == call.wrappedValue.actionIdentifier })?.title
                         ?? call.wrappedValue.actionIdentifier)
                }
            }
            Menu(forbidden ? "Add forbidden call" : "Add required call") {
                ForEach(actions) { action in
                    Button(action.title) { calls.wrappedValue.append(.init(actionIdentifier: action.id)) }
                }
            }
        }
    }

    /// Adds and removes substring checks without limiting case sensitivity to the entire turn.
    private var replies: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reply contains").font(.subheadline.weight(.semibold))
            ForEach(group.replyContains.indices, id: \.self) { index in
                if group.replyContains.indices.contains(index) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Expected reply text", text: $group.replyContains[index].text)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("siri-studio-reply-check-\(index)")
                        HStack {
                            Toggle("Case sensitive", isOn: $group.replyContains[index].caseSensitive)
                            Spacer()
                            Button("Remove reply check", systemImage: "minus.circle") {
                                group.replyContains.remove(at: index)
                            }.labelStyle(.iconOnly)
                        }
                    }
                }
            }
            Button("Add reply check", systemImage: "plus") { group.replyContains.append(.init()) }
        }
    }

    /// Moves a required call one position if the destination exists.
    private func move(_ id: UUID, in calls: Binding<[SiriStudioCall]>, by offset: Int) {
        guard let index = calls.wrappedValue.firstIndex(where: { $0.id == id }),
              calls.wrappedValue.indices.contains(index + offset) else { return }
        calls.wrappedValue.swapAt(index, index + offset)
    }
}

/// Presents only the matchers supported by a catalog action's parameters and result.
private struct SiriStudioCallEditor: View {
    @Binding var call: SiriStudioCall
    let action: MacIntentAction
    let forbidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(action.parameters) { parameter in
                SiriStudioMatcherEditor(matcher: argument(parameter.id), parameter: parameter)
            }
            if !forbidden && ["String", "Int", "Double", "Bool"].contains(action.outputType) {
                SiriStudioMatcherEditor(matcher: $call.result, parameter: .init(
                    id: "result", name: "Result", type: action.outputType, required: false))
            }
        }.padding(.vertical, 5)
    }

    /// Binds one optional matcher by stable parameter identifier.
    private func argument(_ id: String) -> Binding<SiriStudioMatcher?> {
        Binding {
            call.arguments.first(where: { $0.parameterIdentifier == id })?.matcher
        } set: { matcher in
            if let index = call.arguments.firstIndex(where: { $0.parameterIdentifier == id }) {
                if let matcher { call.arguments[index].matcher = matcher }
                else { call.arguments.remove(at: index) }
            } else if let matcher { call.arguments.append(.init(parameterIdentifier: id, matcher: matcher)) }
        }
    }
}

/// Edits the value of one typed matcher without accepting arbitrary predicate source.
private struct SiriStudioMatcherEditor: View {
    @Binding var matcher: SiriStudioMatcher?
    let parameter: MacIntentParameter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(parameter.name, selection: Binding(
                get: { Kind(matcher) },
                set: { matcher = $0.initial(parameter) }
            )) {
                ForEach(options, id: \.self) { Text($0.rawValue).tag($0) }
            }
            switch matcher {
            case .equals, .contains, .containsRegex, .entityIdentifier:
                TextField(parameter.entityIdentifier == nil ? "Value" : "Entity identifier", text: textValue)
                    .textFieldStyle(.roundedBorder)
            case .intEquals:
                TextField("Integer value", value: Binding(
                    get: { if case .intEquals(let value) = matcher { value } else { 0 } },
                    set: { matcher = .intEquals($0) }
                ), format: .number.grouping(.never)).textFieldStyle(.roundedBorder)
            case .doubleEquals:
                TextField("Decimal value", value: Binding(
                    get: { if case .doubleEquals(let value) = matcher { value } else { 0 } },
                    set: { matcher = .doubleEquals($0) }
                ), format: .number.grouping(.never)).textFieldStyle(.roundedBorder)
            case .boolEquals:
                Toggle("Expected value is true", isOn: Binding(
                    get: { matcher == .boolEquals(true) }, set: { matcher = .boolEquals($0) }
                ))
            case .enumCase:
                Picker("Expected case", selection: textValue) {
                    ForEach(parameter.enumCases, id: \.self) { Text($0).tag($0) }
                }
            default: EmptyView()
            }
            if options.count == 3 {
                Text("Value matching is unavailable for this type.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Derives choices from the compiled scalar, enum, or entity type.
    private var options: [Kind] {
        let values: [Kind] = switch parameter.type {
        case "String": [.equals, .contains, .regex]
        case "Int", "Double", "Bool": [.equals]
        case "Enum": parameter.enumCases.isEmpty ? [] : [.enumCase]
        default: parameter.entityIdentifier == nil ? [] : [.entity]
        }
        return [.any] + values + [.missing, .present]
    }

    /// Reads and updates string-valued constraints without changing their kind.
    private var textValue: Binding<String> {
        Binding {
            switch matcher {
            case .equals(let value), .contains(let value), .containsRegex(let value),
                 .enumCase(let value), .entityIdentifier(_, let value): value
            default: ""
            }
        } set: { value in
            switch matcher {
            case .equals: matcher = .equals(value)
            case .contains: matcher = .contains(value)
            case .containsRegex: matcher = .containsRegex(value)
            case .enumCase: matcher = .enumCase(value)
            case .entityIdentifier(let type, _): matcher = .entityIdentifier(entityType: type, identifier: value)
            default: break
            }
        }
    }

    /// The menu label and initial value for one editor choice.
    private enum Kind: String {
        case any = "Any value", equals = "Equals", contains = "Contains", regex = "Contains regex"
        case enumCase = "Enum case", entity = "Entity identifier", missing = "Is nil", present = "Is not nil"

        /// Maps the current typed value to its menu selection.
        init(_ matcher: SiriStudioMatcher?) {
            self = switch matcher {
            case nil: .any
            case .equals, .intEquals, .doubleEquals, .boolEquals: .equals
            case .contains: .contains
            case .containsRegex: .regex
            case .enumCase: .enumCase
            case .entityIdentifier: .entity
            case .isNil: .missing
            case .notNil: .present
            }
        }

        /// Starts an appropriate typed value when the author chooses a matcher.
        func initial(_ parameter: MacIntentParameter) -> SiriStudioMatcher? {
            switch self {
            case .any: nil
            case .missing: .isNil
            case .present: .notNil
            case .contains: .contains("")
            case .regex: .containsRegex("")
            case .enumCase: .enumCase(parameter.enumCases.first ?? "")
            case .entity: .entityIdentifier(entityType: parameter.entityIdentifier ?? "", identifier: "")
            case .equals:
                switch parameter.type {
                case "Int": .intEquals(0)
                case "Double": .doubleEquals(0)
                case "Bool": .boolEquals(false)
                default: .equals("")
                }
            }
        }
    }
}
