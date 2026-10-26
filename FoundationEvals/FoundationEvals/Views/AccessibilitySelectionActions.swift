import Foundation
import SwiftUI

struct SelectionActionDescriptor<Selection: Hashable>: Identifiable {
    let option: Selection
    let label: String

    var id: Selection { option }

    /// Builds one accessibility action per distinct option, replacing blank titles and suffixing duplicate labels without collisions.
    static func make(
        options: [Selection],
        title: (Selection) -> String
    ) -> [Self] {
        var seenOptions = Set<Selection>()
        let uniqueOptions = options.filter { seenOptions.insert($0).inserted }
        let baseLabels = uniqueOptions.map { option in
            let optionTitle = title(option)
            let resolvedTitle = optionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled option"
                : optionTitle
            return "Select \(resolvedTitle)"
        }
        let reservedLabels = Set(baseLabels)
        var usedLabels = Set<String>()
        var nextSuffixByLabel: [String: Int] = [:]

        return zip(uniqueOptions, baseLabels).map { option, baseLabel in
            guard !usedLabels.contains(baseLabel) else {
                var suffix = nextSuffixByLabel[baseLabel, default: 1]
                var candidate = "\(baseLabel) (\(suffix))"
                while reservedLabels.contains(candidate) || usedLabels.contains(candidate) {
                    suffix += 1
                    candidate = "\(baseLabel) (\(suffix))"
                }
                nextSuffixByLabel[baseLabel] = suffix + 1
                usedLabels.insert(candidate)
                return Self(option: option, label: candidate)
            }

            usedLabels.insert(baseLabel)
            return Self(option: option, label: baseLabel)
        }
    }
}

extension View {
    /// Exposes direct selection without opening a native popup over another app.
    func accessibilitySelectionActions<Selection: Hashable>(
        _ options: [Selection],
        selection: Binding<Selection>,
        title: @escaping (Selection) -> String
    ) -> some View {
        modifier(SelectionActionsModifier(options: options, selection: selection, title: title))
    }
}

private struct SelectionActionsModifier<Selection: Hashable>: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let options: [Selection]
    @Binding var selection: Selection
    let title: (Selection) -> String

    /// Adds labeled selection actions that update the bound value only while the source view is enabled.
    func body(content: Content) -> some View {
        let actions = SelectionActionDescriptor.make(options: options, title: title)
        content.accessibilityActions {
            ForEach(actions) { action in
                Button(action.label) {
                    guard isEnabled else { return }
                    selection = action.option
                }
                .disabled(!isEnabled)
            }
        }
    }
}
