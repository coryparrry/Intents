import SwiftUI

/// Measures the rendered text so short, multiline responses can also be expanded.
struct WorkspaceExpandableText: View {
    let content: AttributedString
    let lineLimit: Int
    let label: String
    @State private var expanded = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ content: AttributedString, lineLimit: Int, label: String) {
        self.content = content
        self.lineLimit = lineLimit
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(content)
                .lineLimit(expanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !expanded { collapsedHeight = height }
                }
                .background(alignment: .topLeading) {
                    Text(content)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if expanded || fullHeight > collapsedHeight + 1 {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(reduceMotion ? nil : WorkspaceStyle.stateMotion) { expanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.callout)
                .accessibilityLabel(expanded ? "Show less \(label)" : "Show full \(label)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
        .onChange(of: content) { _, _ in expanded = false }
    }
}
