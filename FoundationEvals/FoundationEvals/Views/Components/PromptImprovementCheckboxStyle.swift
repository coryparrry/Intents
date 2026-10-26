import SwiftUI

/// Keeps a two-line example label inside the checkbox's mouse hit region.
struct PromptImprovementCheckboxStyle: ToggleStyle {
    /// Makes the complete example row toggle its bound value while exposing native checkbox accessibility.
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if configuration.isOn {
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 1.5)
                    }
                }
                .frame(width: 16, height: 16).padding(.horizontal, 1).accessibilityHidden(true)
                configuration.label
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}
