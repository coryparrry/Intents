import SwiftUI

/// A group of related settings, optionally headed and presented as one surface.
struct EditorSection<Content: View>: View {
    let title: LocalizedStringResource
    let sectionDescription: LocalizedStringResource
    let showsHeader: Bool
    @ViewBuilder let content: Content

    /// Captures a localized section heading and description and evaluates the content builder once.
    init(
        _ title: LocalizedStringResource,
        description: LocalizedStringResource,
        showsHeader: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        sectionDescription = description
        self.showsHeader = showsHeader
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(sectionDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
    }
}
