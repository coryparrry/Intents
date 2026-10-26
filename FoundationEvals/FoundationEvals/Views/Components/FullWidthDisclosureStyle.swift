import SwiftUI

/// Make the full section heading clickable while keeping expanded content separate.
struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    /// Makes the full heading toggle expansion and renders nested content with the same disclosure style.
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                configuration.content
                    .disclosureGroupStyle(FullWidthDisclosureStyle())
            }
        }
    }
}
