import SwiftUI

protocol WorkspacePane: CaseIterable, Identifiable, Hashable {
    var title: String { get }
    var subtitle: String { get }
    var symbol: String { get }
    var tint: Color { get }
}

/// A System Settings–style pane list beside the selected pane, collapsing to a menu when narrow.
struct WorkspacePaneLayout<Page: WorkspacePane, Content: View>: View {
    let heading: String
    @Binding var selection: Page
    @ViewBuilder var content: Content
    @State private var availableWidth: CGFloat = 900

    var body: some View {
        let wide = availableWidth >= 824
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        layout {
            if wide {
                paneList.frame(width: 196)
            } else {
                Picker(heading, selection: $selection) {
                    ForEach(Array(Page.allCases)) { page in Text(page.title).tag(page) }
                }
                .pickerStyle(.menu).fixedSize()
            }
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    WorkspaceIconTile(symbol: selection.symbol, tint: selection.tint, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selection.title).font(.title2.weight(.semibold))
                        Text(selection.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private var paneList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(Array(Page.allCases)) { page in
                Button { selection = page } label: {
                    WorkspacePaneRow(title: page.title, symbol: page.symbol, tint: page.tint,
                                     isSelected: page == selection)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == selection ? .isSelected : [])
                .accessibilityHint(page.subtitle)
            }
        }
    }
}

private struct WorkspacePaneRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceIconTile(symbol: symbol, tint: tint, size: 22)
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(background, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected { return Color.primary.opacity(0.08) }
        return isHovering ? Color.primary.opacity(0.04) : .clear
    }
}
