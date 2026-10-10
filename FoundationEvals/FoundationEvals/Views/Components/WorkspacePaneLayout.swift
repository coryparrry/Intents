import SwiftUI

protocol WorkspacePane: CaseIterable, Identifiable, Hashable {
    var title: String { get }
    var subtitle: String { get }
    var symbol: String { get }
    /// An optional heading that groups related panes, such as "Basics" and "Advanced".
    var group: String? { get }
}

extension WorkspacePane {
    var group: String? { nil }
}

/// Section navigation beside the selected pane, collapsing to a menu when narrow.
struct WorkspacePaneLayout<Page: WorkspacePane, Content: View>: View {
    let heading: String
    @Binding var selection: Page
    @ViewBuilder var content: Content
    @State private var availableWidth: CGFloat = 900
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var groups: [(title: String?, pages: [Page])] {
        var result: [(title: String?, pages: [Page])] = []
        for page in Page.allCases {
            if let last = result.indices.last, result[last].title == page.group {
                result[last].pages.append(page)
            } else {
                result.append((page.group, [page]))
            }
        }
        return result
    }

    var body: some View {
        let wide = availableWidth >= 824
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        layout {
            if wide {
                paneList.frame(width: 210)
            } else {
                Picker(heading, selection: $selection) {
                    ForEach(groups.indices, id: \.self) { index in
                        if let title = groups[index].title {
                            Section(title) {
                                ForEach(groups[index].pages) { page in Text(page.title).tag(page) }
                            }
                        } else {
                            ForEach(groups[index].pages) { page in Text(page.title).tag(page) }
                        }
                    }
                }
                .pickerStyle(.menu).fixedSize()
                .accessibilityIdentifier(heading)
            }
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    WorkspaceSectionTitle(selection.title)
                    content
                }
                .id(selection)
                .transition(.blurReplace)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(reduceMotion ? nil : WorkspaceStyle.pageMotion, value: selection)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private var paneList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    if let title = groups[index].title {
                        Text(title)
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(groups[index].pages) { page in
                        Button { selection = page } label: {
                            WorkspacePaneRow(title: page.title, symbol: page.symbol,
                                             isSelected: page == selection)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(page == selection ? .isSelected : [])
                        .accessibilityHint(page.subtitle)
                    }
                }
            }
        }
    }
}

private struct WorkspacePaneRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 20)
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(background, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected { return Color.primary.opacity(0.08) }
        return isHovering ? Color.primary.opacity(0.04) : .clear
    }
}
