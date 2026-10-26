import SwiftUI

/// Local editing state keeps each keystroke out of the surrounding suite views.
/// The binding receives changes immediately so save/run/quit can flush pending text.
struct PromptTextEditor: View {
    @Binding private var text: String
    let label: String
    @State private var editingText: String

    /// Connects the external prompt binding and seeds the local editing buffer from its current value.
    init(text: Binding<String>, label: String) {
        _text = text
        self.label = label
        _editingText = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        TextEditor(text: Binding(
            get: { editingText },
            set: { value in
                editingText = value
                text = value
            }
        ))
        .font(.body)
        .accessibilityLabel(label)
        .accessibilityIdentifier("Case prompt")
        .onChange(of: text) { _, value in
            if editingText != value { editingText = value }
        }
    }
}
