import SwiftUI

/// A titled group of related settings, presented as one surface.
struct EditorSection<Content: View>: View {
    let title: LocalizedStringResource
    let sectionDescription: LocalizedStringResource
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringResource,
        description: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        sectionDescription = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(sectionDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
    }
}
