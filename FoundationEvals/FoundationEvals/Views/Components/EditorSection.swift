import SwiftUI

struct EditorSection<Content: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    let sectionDescription: LocalizedStringResource
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        description: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        sectionDescription = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(sectionDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
    }
}
